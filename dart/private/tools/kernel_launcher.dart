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
  final config = _readConfig();
  Runfiles? runfiles;
  try {
    runfiles = Runfiles.create();
  } on StateError {
    runfiles = null;
  }

  final dart = _resolvePath(config, 'dart', 'dart_exec', runfiles);
  final dill = _resolvePath(config, 'dill', 'dill_exec', runfiles);

  final vm = await Process.start(dart, [
    dill,
    ...args,
  ], mode: ProcessStartMode.inheritStdio);
  exit(await vm.exitCode);
}

Map<String, dynamic> _readConfig() {
  final adjacent = _adjacentConfigFile();
  if (adjacent != null && adjacent.existsSync()) {
    return jsonDecode(adjacent.readAsStringSync()) as Map<String, dynamic>;
  }

  final key = Platform.environment['RULES_DART_KERNEL_CONFIG'];
  if (key != null && key.isNotEmpty) {
    final r = Runfiles.create();
    final file = File(r.rlocation(key));
    if (file.existsSync()) {
      return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
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
