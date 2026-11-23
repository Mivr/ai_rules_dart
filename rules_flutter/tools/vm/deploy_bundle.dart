/// Deploys a Flutter bundle to a GCP VM and runs visual verification.
///
/// Usage:
///   dart run tools/vm/deploy_bundle.dart <vm-name> <bundle_path> [--windows]
///       [--title <window title>]
///
/// Linux (default):
///   1. SCPs the bundle directory to the VM
///   2. SCPs the verification scripts
///   3. Runs verify_linux_app.dart under Xvfb, waiting for a window titled
///      `--title`, which defaults to the bundle's name as the built-in runner
///      does
///   4. Downloads the screenshot
///
/// Windows (--windows):
///   1. SCPs the bundle directory to the VM
///   2. SCPs the DXGI screenshot script
///   3. Discovers the interactive session and Python path
///   4. Runs dxgi_screenshot.py via PsExec in the interactive session
///   5. Downloads the screenshot
library;

import 'dart:io';

import 'gcloud.dart';
import 'vm_deploy.dart';

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln(
      'Usage: dart run tools/vm/deploy_bundle.dart <vm-name> <bundle_path> '
      '[--windows] [--title <window title>]',
    );
    exit(1);
  }

  final String vmName = args[0];
  final String bundlePath = args[1];
  final bool isWindows = args.contains('--windows');
  final int titleFlag = args.indexOf('--title');
  if (titleFlag >= 0 && titleFlag + 1 >= args.length) {
    stderr.writeln('--title needs a value');
    exit(1);
  }

  if (!Directory(bundlePath).existsSync()) {
    stderr.writeln('Bundle directory not found: $bundlePath');
    exit(1);
  }

  final String appName = Uri.parse(bundlePath).pathSegments.last;
  final String title = titleFlag >= 0 ? args[titleFlag + 1] : appName;

  print('Deploying $appName to $vmName ...');

  if (isWindows) {
    await _deployWindows(vmName, bundlePath, appName);
  } else {
    await _deployLinux(vmName, bundlePath, appName, title);
  }
}

Future<void> _deployLinux(
  String vmName,
  String bundlePath,
  String appName,
  String title,
) async {
  // Determine project root (for verification scripts).
  final String scriptDir = Platform.script.resolve('.').toFilePath();
  final String projectRoot = Directory(
    scriptDir,
  ).parent.parent.path; // tools/vm/ -> project root

  // Copy bundle to a temp dir (Bazel tree artifacts are read-only).
  print('Preparing bundle for upload ...');
  final Directory tmpDir = Directory.systemTemp.createTempSync('deploy_');
  final tmpBundle = '${tmpDir.path}/$appName';
  await Process.run('cp', ['-RL', bundlePath, tmpBundle]);
  await Process.run('chmod', ['-R', 'u+rwX', tmpBundle]);

  // Upload bundle.
  print('Uploading bundle ...');
  await sshRun(
    vmName,
    'chmod -R u+w ~/$appName 2>/dev/null; rm -rf ~/$appName || true',
  );
  await scpToVm(vmName, tmpBundle, '~/$appName');
  tmpDir.deleteSync(recursive: true);

  // Upload verification scripts.
  print('Uploading verification scripts ...');
  await sshRun(vmName, 'rm -rf ~/verify_scripts; mkdir -p ~/verify_scripts');
  // SCP individual files to avoid nested directory issues.
  for (final FileSystemEntity file in Directory(
    '$projectRoot/e2e/_linux_test',
  ).listSync()) {
    if (file is File) {
      await scpToVm(vmName, file.path, '~/verify_scripts/');
    }
  }

  // Run verification.
  print('');
  print('Running visual verification ...');
  try {
    final String output = await sshRun(
      vmName,
      'bash -c \'export PATH="/opt/dart-sdk/bin:/usr/local/bin:\$PATH" && dart run ~/verify_scripts/verify_linux_app.dart ~/$appName ${_quoteForBashC(title)}\'',
    );
    print(output);

    // Download screenshot if available.
    final RegExpMatch? screenshotMatch = RegExp(r'Screenshot: (/\S+)')
        .firstMatch(output);
    if (screenshotMatch != null) {
      final String remotePath = screenshotMatch.group(1)!;
      final localPath = '/tmp/${appName}_screenshot.png';
      try {
        await scpFromVm(vmName, remotePath, localPath);
        print('');
        print('Screenshot downloaded to: $localPath');
      } catch (e) {
        print('Could not download screenshot: $e');
      }
    }
  } catch (e) {
    stderr.writeln('Verification failed: $e');
    exit(1);
  }
}

Future<void> _deployWindows(
  String vmName,
  String bundlePath,
  String appName,
) async {
  final String scriptDir = Platform.script.resolve('.').toFilePath();
  final String projectRoot = Directory(scriptDir).parent.parent.path;

  await _ensureWindowsReady(vmName);
  final String sessionId = await _discoverWindowsSession(vmName);
  print('VM ready. Interactive session $sessionId confirmed.');

  // Copy bundle to a temp dir (Bazel tree artifacts are symlinks / read-only).
  print('Preparing bundle for upload ...');
  final Directory tmpDir = Directory.systemTemp.createTempSync('deploy_');
  final tmpBundle = '${tmpDir.path}/$appName';
  await Process.run('cp', ['-RL', bundlePath, tmpBundle]);

  try {
    await _uploadWindowsBundle(vmName, tmpBundle, appName, projectRoot);
  } finally {
    tmpDir.deleteSync(recursive: true);
  }

  final String pythonPath = await _discoverWindowsPython(vmName);
  final String exeName = await _discoverWindowsExe(vmName, appName);
  await _captureWindowsScreenshot(
    vmName,
    sessionId,
    appName,
    exeName,
    pythonPath,
  );
}

/// Fails out when the VM startup script has not finished installing tools.
Future<void> _ensureWindowsReady(String vmName) async {
  // Check that the startup script has finished installing tools.
  print('Checking VM readiness ...');
  try {
    final String status = await sshRun(vmName, 'type C:\\startup_complete.txt');
    if (!status.contains('STARTUP_COMPLETE')) {
      throw Exception('unexpected content');
    }
  } catch (_) {
    stderr.writeln('ERROR: VM startup script has not completed yet.');
    stderr.writeln('Tools (Python, PsExec, dxcam) are still installing.');
    stderr.writeln(
      'Check progress: gcloud compute ssh $vmName --command "type C:\\startup_complete.txt"',
    );
    exit(1);
  }
}

/// Returns the auto-logon session id, failing out when nobody is logged on.
Future<String> _discoverWindowsSession(String vmName) async {
  // Verify the auto-logon interactive session and get the session ID.
  // query user returns exit code 1 even on success — force exit 0.
  final String sessions = await sshRun(vmName, 'query user & exit /b 0');
  final String? sessionId = parseWindowsSessionId(sessions);
  if (sessionId == null) {
    stderr.writeln('ERROR: No active interactive session for testuser.');
    stderr.writeln('Session output:\n$sessions');
    stderr.writeln(
      'The auto-logon may not have completed. Try rebooting the VM.',
    );
    exit(1);
  }
  return sessionId;
}

/// Uploads the staged bundle and the DXGI screenshot script.
Future<void> _uploadWindowsBundle(
  String vmName,
  String tmpBundle,
  String appName,
  String projectRoot,
) async {
  // Upload bundle to a shared location accessible to all users.
  print('Uploading bundle ...');
  await sshRun(
    vmName,
    'if exist C:\\temp\\$appName rmdir /s /q C:\\temp\\$appName',
  );
  await sshRun(vmName, 'if not exist C:\\temp mkdir C:\\temp');
  await scpToVm(vmName, tmpBundle, 'C:/temp/$appName', compress: true);

  // Upload the DXGI screenshot script.
  print('Uploading verification scripts ...');
  await sshRun(
    vmName,
    'if exist C:\\temp\\verify_scripts rmdir /s /q C:\\temp\\verify_scripts',
  );
  await sshRun(vmName, 'mkdir C:\\temp\\verify_scripts');
  await scpToVm(
    vmName,
    '$projectRoot/e2e/_windows_test/dxgi_screenshot.py',
    'C:/temp/verify_scripts/dxgi_screenshot.py',
  );
}

/// Returns the VM's Python install directory, failing out when absent.
Future<String> _discoverWindowsPython(String vmName) async {
  // Discover Python path.
  final String pythonPath = (await sshRun(
    vmName,
    'powershell -Command "(Get-ChildItem C:\\Python* -Directory | Select-Object -First 1).FullName"',
  )).trim();
  if (pythonPath.isEmpty) {
    stderr.writeln('ERROR: Python not found on VM.');
    exit(1);
  }
  print('Python: $pythonPath');
  return pythonPath;
}

/// Returns the app executable name inside the uploaded bundle.
Future<String> _discoverWindowsExe(String vmName, String appName) async {
  // Find the app executable inside the bundle.
  final String exeList = await sshRun(
    vmName,
    'powershell -Command "Get-ChildItem C:\\temp\\$appName\\*.exe | Select-Object -ExpandProperty Name"',
  );
  final String exeName = parseWindowsExeName(exeList);
  if (exeName.isEmpty || !exeName.endsWith('.exe')) {
    stderr.writeln('ERROR: No .exe found in C:\\temp\\$appName\\');
    exit(1);
  }
  print('App executable: $exeName');
  return exeName;
}

/// Runs the screenshot capture in the interactive session and downloads it.
Future<void> _captureWindowsScreenshot(
  String vmName,
  String sessionId,
  String appName,
  String exeName,
  String pythonPath,
) async {
  // PsExec -i runs the process in the interactive session, but stdout goes
  // to that session's console, not back to SSH. Use a batch file that
  // redirects output to a file, then read the file.
  print('');
  print('Running DXGI screenshot capture ...');
  final screenshotRemotePath = 'C:\\temp\\screenshot.png';
  final outputRemotePath = 'C:\\temp\\screenshot_out.txt';

  // Write the wrapper batch file via PowerShell (avoids cmd.exe escaping).
  await sshRun(
    vmName,
    buildWindowsVerifyBat(
      pythonPath: pythonPath,
      appName: appName,
      exeName: exeName,
      screenshotRemotePath: screenshotRemotePath,
      outputRemotePath: outputRemotePath,
    ),
  );

  // Run via PsExec in the interactive session. PsExec propagates the child
  // exit code — force exit 0 so sshRun doesn't throw on screenshot failure.
  try {
    await sshRun(
      vmName,
      'C:\\ProgramData\\chocolatey\\bin\\PsExec64.exe -accepteula '
      '-i $sessionId -u $windowsTestUser -p $windowsTestPassword '
      'C:\\temp\\run_verify.bat & exit /b 0',
    );
  } catch (e) {
    stderr.writeln('PsExec command failed: $e');
  }

  // Read the captured output.
  try {
    final String output = await sshRun(vmName, 'type $outputRemotePath');
    print(output);

    if (output.contains('PASS')) {
      print('');
      print('Visual verification PASSED.');
    } else if (output.contains('FAIL')) {
      stderr.writeln('');
      stderr.writeln('Visual verification FAILED.');
    }
  } catch (e) {
    stderr.writeln('Could not read verification output: $e');
  }

  // Download screenshot.
  final localPath = '/tmp/${appName}_screenshot.png';
  try {
    await scpFromVm(vmName, screenshotRemotePath, localPath);
    print('');
    print('Screenshot downloaded to: $localPath');
  } catch (e) {
    print('Could not download screenshot: $e');
  }
}

/// [value] as one word inside the single-quoted `bash -c '...'` above.
///
/// Double quotes keep the inner shell from splitting or expanding it; a
/// single quote closes and reopens the outer quoting.
String _quoteForBashC(String value) {
  final String inner = value.replaceAllMapped(
    RegExp(r'[\\"$`]'),
    (m) => '\\${m[0]}',
  );
  return '"${inner.replaceAll("'", r"'\''")}"';
}
