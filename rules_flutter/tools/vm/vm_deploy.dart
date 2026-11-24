/// Pure helpers for the Windows bundle deploy.
///
/// [`deploy_bundle.dart`](deploy_bundle.dart) shells out to a VM for every
/// step; the parsing and command rendering below need no VM, so they live here
/// where unit tests can reach them without credentials or a network.
library;

/// Parses the interactive session id out of `query user` output.
///
/// Returns null when no `Active` session for the auto-logon user is listed,
/// which is the state the deploy step reports and exits on.
String? parseWindowsSessionId(String queryOutput) {
  final RegExpMatch? sessionMatch = RegExp(
    r'testuser\s+\S*\s+(\d+)\s+Active',
  ).firstMatch(queryOutput);
  return sessionMatch?.group(1);
}

/// Picks the app executable out of the `Get-ChildItem *.exe` listing.
///
/// The caller checks the result ends in `.exe` and reports when it does not.
String parseWindowsExeName(String exeList) =>
    exeList.trim().split('\n').first.trim();

/// Renders the wrapper batch file that runs the DXGI screenshot capture.
///
/// PsExec `-i` runs the process in the interactive session, but stdout goes to
/// that session's console, not back to SSH, so the batch file redirects output
/// to [outputRemotePath] for the deploy step to read back.
String buildWindowsVerifyBat({
  required String pythonPath,
  required String appName,
  required String exeName,
  required String screenshotRemotePath,
  required String outputRemotePath,
}) {
  // Written via PowerShell Set-Content to avoid cmd.exe escaping.
  return "powershell -Command \"Set-Content -Path C:\\temp\\run_verify.bat "
      "'$pythonPath\\python.exe C:\\temp\\verify_scripts\\dxgi_screenshot.py "
      "C:\\temp\\$appName\\$exeName $screenshotRemotePath 15 "
      "> $outputRemotePath 2>&1' -Force\"";
}
