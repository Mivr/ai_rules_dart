import 'dart:convert';
import 'dart:io';

import 'package:runfiles/runfiles.dart';

/// Runs a `dart_binary(compile_mode = "kernel", launcher = True)` kernel with
/// the Dart VM that compiled it.
///
/// When a kernel-mode binary sets `launcher = True`, `DefaultInfo.executable`
/// is a symlink to this native launcher and `<name>.kernel_launcher.json` sits
/// beside it (and in runfiles under `RULES_DART_KERNEL_CONFIG`). Rules that
/// consume `DartCompileInfo` directly (such as `dart_codegen`) still run the
/// `.dill` in a persistent worker without spawning this launcher, while
/// `bazel run` and generic `ctx.executable` consumers can invoke the target
/// as a standalone executable.
Future<void> main(List<String> args) async {
  final env = Platform.environment;
  final runfilesDir = _findRunfilesDir(env);
  final manifestFile = _findManifestFile(env, runfilesDir);
  Runfiles? runfiles;
  try {
    runfiles = Runfiles.create();
  } on StateError {
    runfiles = null;
  }

  final config = _readConfig(runfiles);
  final dart = _resolvePath(config, 'dart', 'dart_exec', runfiles);
  final dill = _resolvePath(config, 'dill', 'dill_exec', runfiles);

  Directory? scratch;
  final cwd = Directory.current;
  if (manifestFile != null && cwd.parent.path.endsWith('.runfiles')) {
    final segments = cwd.uri.pathSegments.where((s) => s.isNotEmpty).toList();
    final workspace = segments.isEmpty ? null : segments.last;
    if (workspace != null && !_workspaceInPlace(manifestFile, workspace)) {
      scratch = Directory(env['TEST_TMPDIR'] ?? Directory.systemTemp.path)
          .createTempSync('dart_binary.');
      _materializeWorkspace(
        manifest: File(manifestFile).readAsLinesSync(),
        workspace: workspace,
        into: scratch.path,
      );
    }
  }

  final childEnv = <String, String>{
    if (runfilesDir != null) 'RUNFILES_DIR': runfilesDir,
    if (manifestFile != null) 'RUNFILES_MANIFEST_FILE': manifestFile,
  };

  final vm = await Process.start(
    scratch == null ? dart : File(dart).absolute.path,
    [scratch == null ? dill : File(dill).absolute.path, ...args],
    workingDirectory: scratch?.path,
    environment: childEnv.isEmpty ? null : childEnv,
    mode: ProcessStartMode.inheritStdio,
  );
  try {
    exit(await vm.exitCode);
  } finally {
    if (scratch != null && !env.containsKey('TEST_TMPDIR')) {
      try {
        scratch.deleteSync(recursive: true);
      } catch (_) {}
    }
  }
}

String? _findRunfilesDir(Map<String, String> env) {
  final fromEnv = env['RUNFILES_DIR'];
  if (fromEnv != null &&
      fromEnv.isNotEmpty &&
      Directory(fromEnv).existsSync()) {
    return Directory(fromEnv).resolveSymbolicLinksSync();
  }
  final exe = Platform.executable;
  for (final candidate in ['$exe.runfiles', '$exe.exe.runfiles']) {
    if (Directory(candidate).existsSync()) {
      return Directory(candidate).resolveSymbolicLinksSync();
    }
  }
  return null;
}

String? _findManifestFile(Map<String, String> env, String? runfilesDir) {
  final fromEnv = env['RUNFILES_MANIFEST_FILE'];
  if (fromEnv != null && fromEnv.isNotEmpty && File(fromEnv).existsSync()) {
    return File(fromEnv).absolute.path;
  }
  final rawDir = env['RUNFILES_DIR'];
  final exe = Platform.executable;
  for (final candidate in [
    if (rawDir != null && rawDir.isNotEmpty) ...[
      '$rawDir/MANIFEST',
      '${rawDir}_manifest',
    ],
    if (runfilesDir != null) ...[
      '$runfilesDir/MANIFEST',
      '${runfilesDir}_manifest',
    ],
    '$exe.runfiles_manifest',
    '$exe.exe.runfiles_manifest',
    '$exe.runfiles/MANIFEST',
    '$exe.exe.runfiles/MANIFEST',
  ]) {
    if (File(candidate).existsSync()) {
      return File(candidate).absolute.path;
    }
  }
  return null;
}

Map<String, dynamic> _readConfig(Runfiles? runfiles) {
  final adjacent = _adjacentConfigFile();
  if (adjacent != null && adjacent.existsSync()) {
    return jsonDecode(adjacent.readAsStringSync()) as Map<String, dynamic>;
  }

  final key = Platform.environment['RULES_DART_KERNEL_CONFIG'];
  if (key != null && key.isNotEmpty && runfiles != null) {
    try {
      final file = File(runfiles.rlocation(key));
      if (file.existsSync()) {
        return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      }
    } on StateError {
      // Fall through to executable-derived candidates.
    }
  }

  if (runfiles != null) {
    for (final candidate in _candidateConfigRlocations(Platform.executable)) {
      try {
        final file = File(runfiles.rlocation(candidate));
        if (file.existsSync()) {
          return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
        }
      } on StateError {
        // Try next candidate.
      }
    }
  }

  stderr.writeln(
    'kernel_launcher: could not locate .kernel_launcher.json config for '
    '${Platform.executable}',
  );
  exit(1);
}

File? _adjacentConfigFile() {
  var exe = Platform.executable;
  if (exe.isEmpty) return null;
  if (exe.toLowerCase().endsWith('.exe')) {
    exe = exe.substring(0, exe.length - 4);
  }
  return File('$exe.kernel_launcher.json');
}

Iterable<String> _candidateConfigRlocations(String exe) sync* {
  if (exe.isEmpty) return;
  var base = exe.replaceAll(r'\', '/');
  if (base.toLowerCase().endsWith('.exe')) {
    base = base.substring(0, base.length - 4);
  }
  final workspace = Platform.environment['TEST_WORKSPACE'];
  final runfilesIdx = base.lastIndexOf('.runfiles/');
  if (runfilesIdx >= 0) {
    final rel = base.substring(runfilesIdx + '.runfiles/'.length);
    yield '$rel.kernel_launcher.json';
  }
  const binExternal = '/bin/external/';
  final binExtIdx = base.lastIndexOf(binExternal);
  if (binExtIdx >= 0) {
    final rel = base.substring(binExtIdx + binExternal.length);
    yield '$rel.kernel_launcher.json';
  } else {
    const bin = '/bin/';
    final binIdx = base.lastIndexOf(bin);
    if (binIdx >= 0) {
      final rel = base.substring(binIdx + bin.length);
      if (workspace != null && workspace.isNotEmpty) {
        yield '$workspace/$rel.kernel_launcher.json';
      }
      yield '_main/$rel.kernel_launcher.json';
    }
  }
  if (!base.startsWith('/')) {
    if (workspace != null && workspace.isNotEmpty) {
      yield '$workspace/$base.kernel_launcher.json';
    }
    yield '_main/$base.kernel_launcher.json';
  }
}

String _resolvePath(
  Map<String, dynamic> config,
  String rlocationKey,
  String execKey,
  Runfiles? runfiles,
) {
  final rloc = config[rlocationKey] as String?;
  if (runfiles != null && rloc != null) {
    try {
      final resolved = runfiles.rlocation(rloc);
      if (File(resolved).existsSync()) {
        return resolved;
      }
    } on StateError {
      // Fall back to execroot path when outside runfiles.
    }
  }
  final execPath = config[execKey] as String?;
  if (execPath != null && File(execPath).existsSync()) {
    return execPath;
  }
  if (runfiles != null && rloc != null) {
    return runfiles.rlocation(rloc);
  }
  stderr.writeln('kernel_launcher: could not resolve $rlocationKey');
  exit(1);
}

bool _workspaceInPlace(String manifest, String workspace) {
  final prefix = '$workspace/';
  for (final line in File(manifest).readAsLinesSync()) {
    final space = line.indexOf(' ');
    if (space < 0 || !line.startsWith(prefix)) continue;
    final relative = line.substring(prefix.length, space);
    final real = line.substring(space + 1);
    if (Directory(real).existsSync()) {
      if (!Directory(relative).existsSync()) return false;
    } else if (File(real).existsSync()) {
      if (!File(relative).existsSync()) return false;
    }
  }
  return true;
}

void _materializeWorkspace({
  required List<String> manifest,
  required String workspace,
  required String into,
}) {
  final prefix = '$workspace/';
  for (final line in manifest) {
    final space = line.indexOf(' ');
    if (space < 0 || !line.startsWith(prefix)) continue;
    final relative = line.substring(prefix.length, space);
    final real = line.substring(space + 1);
    final destination = _join(into, relative);
    if (Directory(real).existsSync()) {
      _copyDirectory(Directory(real), Directory(destination));
    } else if (File(real).existsSync()) {
      final destFile = File(destination);
      destFile.parent.createSync(recursive: true);
      if (destFile.existsSync()) {
        destFile.deleteSync();
      }
      File(real).copySync(destination);
    }
  }
}

void _copyDirectory(Directory from, Directory to) {
  to.createSync(recursive: true);
  for (final entity in from.listSync(recursive: true, followLinks: true)) {
    final relative = entity.path.substring(from.path.length + 1);
    final target = _join(to.path, relative.replaceAll(r'\', '/'));
    if (entity is Directory) {
      Directory(target).createSync(recursive: true);
    } else if (entity is File) {
      final targetFile = File(target);
      targetFile.parent.createSync(recursive: true);
      if (targetFile.existsSync()) {
        targetFile.deleteSync();
      }
      entity.copySync(target);
    }
  }
}

String _join(String base, String relative) {
  final path = [base, ...relative.split('/')].join(Platform.pathSeparator);
  File(path).parent.createSync(recursive: true);
  return path;
}
