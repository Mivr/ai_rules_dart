import 'dart:io';

import 'package:runfiles/runfiles.dart';

void _verifyAotTarget({
  required String name,
  required String executable,
  required List<String> baseArgs,
}) {
  final pass = Process.runSync(executable, baseArgs);
  if (pass.exitCode != 0) {
    throw StateError(
      '$name failed when assertions should pass (exit ${pass.exitCode}):\n'
      '${pass.stdout}\n${pass.stderr}',
    );
  }
  final fail = Process.runSync(executable, [...baseArgs, '--fail']);
  if (fail.exitCode == 0) {
    throw StateError(
      '$name exited 0 on failing assert; assertions were stripped',
    );
  }
  final stderrText = fail.stderr as String;
  if (!stderrText.contains('failing_assert_triggered')) {
    throw StateError(
      '$name did not report failing_assert_triggered on stderr:\n$stderrText',
    );
  }
}

void main() {
  if (Platform.isWindows) return;
  final runfiles = Runfiles.create();
  final sdkBin = File(Platform.resolvedExecutable).parent.path;
  final dartaotruntime = '$sdkBin/dartaotruntime';

  for (final envKey in [
    'EXE_ASSERTS_PATH',
    'EXE_RECORD_USE_ASSERTS_PATH',
    'EXE_RECORD_USE_DBG_PATH',
  ]) {
    final exePath = runfiles.rlocation(Platform.environment[envKey]!);
    _verifyAotTarget(name: envKey, executable: exePath, baseArgs: const []);
  }

  for (final envKey in [
    'AOT_ASSERTS_PATH',
    'AOT_RECORD_USE_ASSERTS_PATH',
    'AOT_RECORD_USE_DBG_PATH',
  ]) {
    final aotPath = runfiles.rlocation(Platform.environment[envKey]!);
    _verifyAotTarget(
      name: envKey,
      executable: dartaotruntime,
      baseArgs: [aotPath],
    );
  }
}
