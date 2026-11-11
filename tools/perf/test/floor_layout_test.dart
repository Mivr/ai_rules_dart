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
  final exeExt = Platform.isWindows ? '.exe' : '';
  for (final rel in [
    'bin/dart$exeExt',
    'bin/dartaotruntime$exeExt',
    'bin/utils/gen_snapshot$exeExt',
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

String _fakeWorkspace(Directory root) {
  for (final name in ['pkg1', 'pkg0']) {
    File('${root.path}/ws/packages/$name/lib/$name.dart')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('');
  }
  return '${root.path}/ws';
}

/// [path] with forward slashes: the layout normalizes the separators.
String? _slashes(String? path) => path?.replaceAll(r'\', '/');

void _testConfigWithoutAppFile(Directory tmp) {
  final ws = _fakeWorkspace(Directory('${tmp.path}/d')..createSync());
  final exe = _fakeExecroot(
    Directory('${tmp.path}/e')..createSync(),
    withConfig: false,
  );
  final layout = FloorLayout.fromApp(appExecutable: exe, workspaceDir: ws);
  final config = layout.packageConfig;
  _check(config != null && File(config).existsSync(), 'A config is built');
  final text = File(config!).readAsStringSync();
  final packages = (jsonDecode(text) as Map)['packages'] as List;
  _check(
    packages.map((p) => '${p['name']}=${p['rootUri']}').join(',') ==
        'pkg0=$floorScheme:///packages/pkg0,'
            'pkg1=$floorScheme:///packages/pkg1',
    'The workspace packages are listed under the scheme',
  );
  _check(layout.scheme == floorScheme, 'The scheme is kept');
  _check(layout.roots.length == 2, 'The roots are kept');

  final entry = _fakeExecroot(
    Directory('${tmp.path}/f')..createSync(),
    withConfig: false,
  );
  File('$entry.entry.kmod.package_config.json').writeAsStringSync('{}');
  _check(
    _slashes(
          FloorLayout.fromApp(
            appExecutable: entry,
            workspaceDir: ws,
          ).packageConfig,
        ) ==
        _slashes('$entry.entry.kmod.package_config.json'),
    'The entry module config of the rules is used',
  );
  final own = _fakeExecroot(
    Directory('${tmp.path}/g')..createSync(),
    withConfig: true,
  );
  _check(
    _slashes(
          FloorLayout.fromApp(
            appExecutable: own,
            workspaceDir: ws,
          ).packageConfig,
        ) ==
        _slashes('$own.package_config.json'),
    'An existing app config is used as is',
  );
}

void _testMissingConfigError(Directory tmp) {
  final exe = _fakeExecroot(
    Directory('${tmp.path}/h')..createSync(),
    withConfig: false,
  );
  String? message;
  try {
    FloorLayout.fromApp(
      appExecutable: exe,
      workspaceDir: '${tmp.path}/h/empty',
    );
  } on StateError catch (e) {
    message = e.message;
  }
  _check(
    message != null &&
        message.contains('app.package_config.json') &&
        message.contains('66dc601d') &&
        message.contains('Linked-kernel'),
    'The error names the input and the rules change',
  );
}

void _testFloorRunsWithoutAppConfig(Directory tmp, SdkTools sdk) {
  final ws = _fakeWorkspace(Directory('${tmp.path}/i')..createSync());
  final exe = _fakeExecroot(
    Directory('${tmp.path}/j')..createSync(),
    withConfig: false,
  );
  final runner = _Runner((_, _) => ProcessResult(1, 0, 'Result: 1\n', ''));
  final res = runAotFloorFlow(
    sdk: sdk,
    workspaceDir: ws,
    floorOutputDir: '${tmp.path}/i/out',
    bazelAppExecutable: exe,
    clock: const _Clock(),
    runner: runner,
  );
  _check(res.identical && res.reason == 'ok', 'The floor runs: ${res.reason}');
  final gen = runner.calls.first;
  final at = gen.indexOf('--packages');
  _check(
    at >= 0 && File(gen[at + 1]).existsSync(),
    'The compiler gets an existing package config',
  );
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
  final root = tmp.path.replaceAll(r'\', '/');
  final exeDir = '$root/c/execroot/_main/bazel-out/k8-fastbuild/bin';
  final test = '$exeDir/packages/p/p_test';
  File('$test.entry.kmod.package_config.json')
    ..parent.createSync(recursive: true)
    ..writeAsStringSync('{}');
  final bazelDill =
      '$test.precompiled/packages/p/test/p_test.dart.vm_test.vm.app.dill';
  final out = '$root/c/out';
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
    workspaceDir: '$root/c/ws',
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
    _testConfigWithoutAppFile(tmp);
    _testMissingConfigError(tmp);
    _testFloorRunsWithoutAppConfig(tmp, sdk);
    _testPrecompiledSplit();
    _testTestKernelIsRebuilt(tmp, sdk);
    _testFloorErrorKeepsSol();
  } finally {
    tmp.deleteSync(recursive: true);
  }
  stdout.writeln('All floor layout tests passed.');
}
