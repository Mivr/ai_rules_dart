/// Unit tests for the floor's workspace layout and failure isolation.
library;

import 'dart:convert';
import 'dart:io';

import 'package:perf/cpu.dart';
import 'package:perf/floor.dart';
import 'package:perf/floor_chains.dart';
import 'package:perf/floor_layout.dart';
import 'package:perf/result_writer.dart';

void _check(bool condition, String message) {
  if (!condition) throw StateError('FAIL: $message');
}

final class _Clock implements ChildCpuClock {
  const _Clock();
  @override
  double getChildCpuSeconds() => 1.0;
}

final class _Runner implements FloorProcessRunner {
  _Runner(this.handler);
  final ProcessResult Function(String exe, List<String> args) handler;
  final calls = <List<String>>[];

  @override
  ProcessResult runSync(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) {
    calls.add([executable, ...arguments]);
    return handler(executable, arguments);
  }
}

SdkTools _fakeSdk(Directory dir) {
  for (final rel in [
    'bin/dart',
    'bin/dartaotruntime',
    'bin/utils/gen_snapshot',
    'bin/snapshots/gen_kernel_aot.dart.snapshot',
    'bin/snapshots/frontend_server_aot.dart.snapshot',
    'lib/_internal/vm_platform_product.dill',
    'lib/_internal/vm_platform_strong.dill',
  ]) {
    final f = File('${dir.path}/$rel')..parent.createSync(recursive: true);
    f.writeAsStringSync('fake');
  }
  return SdkTools.fromSdkDir(dir.path);
}

String _fakeExecroot(Directory root, {required bool withConfig}) {
  final exe = '${root.path}/execroot/_main/bazel-out/k8-fastbuild/bin/app/app';
  File(exe).parent.createSync(recursive: true);
  File(exe).writeAsStringSync('fake');
  if (withConfig) File('$exe.package_config.json').writeAsStringSync('{}');
  return exe;
}

void _testLayoutAndAotArguments(Directory tmp, SdkTools sdk) {
  final missing = _fakeExecroot(
    Directory('${tmp.path}/a')..createSync(),
    withConfig: false,
  );
  var named = false;
  try {
    FloorLayout.fromApp(appExecutable: missing, workspaceDir: '/ws');
  } on StateError catch (e) {
    named = e.message.contains('app.package_config.json');
  }
  _check(named, 'A missing package config names itself');

  final exe = _fakeExecroot(
    Directory('${tmp.path}/b')..createSync(),
    withConfig: true,
  );
  final layout = FloorLayout.fromApp(appExecutable: exe, workspaceDir: '/ws');
  _check(layout.scheme == floorScheme, 'The app compiles under the scheme');
  _check(
    layout.entrypoint == '$floorScheme:///app/bin/main.dart',
    'The entrypoint is a scheme URI',
  );
  _check(
    layout.roots.join(',') == '.,bazel-out/k8-fastbuild/bin',
    'The roots are the exec root and the bin root',
  );
  _check(
    layout.workingDirectory.endsWith('execroot/_main'),
    'The compilers run in the exec root',
  );
  _check(
    layout.uriFor('/ws/packages/pkg0/lib/src/f0.dart') ==
        '$floorScheme:///packages/pkg0/lib/src/f0.dart',
    'An edited file maps to its scheme URI',
  );

  final steps = buildAppAotChain(
    AppAotChainSpec(
      sdk: sdk,
      entrypoint: layout.entrypoint,
      outputDill: '/o/app.dill',
      outputAot: '/o/app.aot',
      packageConfig: layout.packageConfig,
      filesystemScheme: layout.scheme,
      filesystemRoots: layout.roots,
    ),
  );
  final args = steps[0].arguments;
  _check(
    args.contains('--packages') && args.contains(layout.packageConfig),
    'gen_kernel_aot gets the package config',
  );
  _check(
    args.indexOf('--filesystem-scheme') >= 0 &&
        args.where((a) => a == '--filesystem-root').length == 2,
    'gen_kernel_aot gets the scheme and both roots',
  );
  _check(args.last == layout.entrypoint, 'The entrypoint comes last');
}

void _testPrecompiledSplit() {
  final parts = splitPrecompiledDill(
    '/b/bin/packages/p/p_test.precompiled/packages/p/test/p_test.dart'
    '.vm_test.vm.app.dill',
  )!;
  _check(
    parts.precompiled == '/b/bin/packages/p/p_test.precompiled',
    'The precompiled directory ends at .precompiled',
  );
  _check(
    parts.testPath == 'packages/p/test/p_test.dart',
    'The test path follows the directory',
  );
  _check(splitPrecompiledDill('/x/test.dill') == null, 'Other dills: null');
}

void _testTestKernelIsRebuilt(Directory tmp, SdkTools sdk) {
  final exeDir = '${tmp.path}/c/execroot/_main/bazel-out/k8-fastbuild/bin';
  final test = '$exeDir/packages/p/p_test';
  File('$test.entry.kmod.package_config.json')
    ..parent.createSync(recursive: true)
    ..writeAsStringSync('{}');
  final bazelDill =
      '$test.precompiled/packages/p/test/p_test.dart.vm_test.vm.app.dill';
  final out = '${tmp.path}/c/out';
  final runner = _Runner((exe, args) {
    if (args.any((a) => a.contains('mode=compile-only'))) {
      final dill = args
          .firstWhere((a) => a.startsWith('--output-dill='))
          .substring('--output-dill='.length);
      File(dill)
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('kernel');
      return ProcessResult(
        1,
        0,
        jsonEncode({'status': 'ok', 'cpuSeconds': 0, 'outputDill': dill}),
        '',
      );
    }
    return ProcessResult(2, 0, '', '');
  });
  final res = runTestLeafFloorFlow(
    sdk: sdk,
    workspaceDir: '${tmp.path}/c/ws',
    testDillPath: bazelDill,
    floorOutputDir: out,
    clock: const _Clock(),
    runner: runner,
  );
  _check(res.identical && res.reason == 'ok', 'Rebuilt test kernel passes');
  final testCall = runner.calls.last;
  _check(testCall[0] == sdk.dart && testCall[1] == 'test', 'dart test runs');
  _check(
    testCall.contains('--precompiled=$out/test.precompiled') &&
        testCall.last == 'packages/p/test/p_test.dart',
    'The runner gets the floor kernel directory and the test path',
  );
  _check(
    File(
      '$out/test.precompiled/packages/p/test/p_test.dart.vm_test.vm.app.dill',
    ).existsSync(),
    'The floor kernel sits where the runner loads it',
  );
}

void _testFloorErrorKeepsSol() {
  const replay = FlowResult(
    method: 'warm-server',
    bazelCpu: 2.0,
    solCpu: 1.0,
    identical: true,
    reason: 'ok',
    chain: <String, dynamic>{},
    workerSteps: <String, int>{},
  );
  final flow = attachFloorError(replay, 'no dill', 'aot');
  _check(flow.solCpu == 1.0 && flow.identical, 'sol is untouched');
  _check(flow.reason == 'ok', 'The replay reason is untouched');
  _check(flow.floor.reason == 'no dill', 'The floor reason is set');
  _check(!flow.floor.identical, 'The floor is not identical');
}

void main() {
  final tmp = Directory.systemTemp.createTempSync('floor_layout_');
  try {
    final sdk = _fakeSdk(Directory('${tmp.path}/sdk')..createSync());
    _testLayoutAndAotArguments(tmp, sdk);
    _testPrecompiledSplit();
    _testTestKernelIsRebuilt(tmp, sdk);
    _testFloorErrorKeepsSol();
  } finally {
    tmp.deleteSync(recursive: true);
  }
  stdout.writeln('All floor layout tests passed.');
}
