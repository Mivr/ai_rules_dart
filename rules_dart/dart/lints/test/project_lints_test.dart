// Tests for the wave-1 project lint rules (`rules_dart_project_lints`).
//
// Positive and negative cases for all four rules, plus non-production path
// skipping, driven through a real `AnalysisContextCollection` with the rules
// enabled in a fixture `analysis_options.yaml`.
import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/session.dart';
import 'package:analyzer/file_system/physical_file_system.dart';
import 'package:analyzer/src/lint/registry.dart';
import 'package:rules_dart_project_lints/rules_dart_project_lints.dart';
import 'package:test/test.dart';

/// The executing SDK's root, normalized for `AnalysisContextCollection`.
final String _sdkPath = _normAbs(
  File(Platform.resolvedExecutable).parent.parent.path,
);

/// Normalizes [rawPath] as an absolute host path.
String _normAbs(String rawPath) => PhysicalResourceProvider.INSTANCE.pathContext
    .normalize(PhysicalResourceProvider.INSTANCE.pathContext.absolute(rawPath));

/// Joins POSIX-spelled [relative] segments onto [basePath] using host slashes.
String _joinRel(String basePath, String relative) =>
    PhysicalResourceProvider.INSTANCE.pathContext.normalize(
      PhysicalResourceProvider.INSTANCE.pathContext.joinAll([
        basePath,
        ...relative.split('/'),
      ]),
    );

/// Fixture sources, keyed by POSIX path under the fixture root.
const Map<String, String> _fixtures = {
  // `no_stdout_in_worker`: a worker unit by basename.
  'lib/tool_worker.dart':
      "import 'dart:io';\n"
      'void run() {\n'
      '  print(1);\n'
      "  stdout..writeln('frame');\n"
      '}\n',
  // Not a worker unit: the same `print` stays silent.
  'lib/tool.dart': 'void run() {\n  print(1);\n}\n',
  // A worker unit through a `worker_protocol.dart` import.
  'lib/worker_protocol.dart': 'void check() {}\n',
  'lib/imports_worker.dart':
      "import 'worker_protocol.dart';\n"
      'void run() {\n'
      '  print(1);\n'
      '}\n',
  // A worker unit through a `main` mentioning `--persistent_worker`.
  'lib/entry.dart':
      'void main(List<String> args) {\n'
      "  if (args.contains('--persistent_worker')) {\n"
      '    print(1);\n'
      '  }\n'
      '}\n',
  // A `main` without the flag is not a worker unit.
  'lib/plain_main.dart': 'void main() {\n  print(1);\n}\n',
  // Binary frame writes, `stderr`, local `stdout` sinks, and interception stay allowed.
  'lib/worker_allowed.dart':
      "import 'dart:async';\n"
      "import 'dart:io';\n"
      'void run(List<int> frame, StringSink stdout) {\n'
      "  stdout.writeln('local sink');\n"
      "  stderr.writeln('oops');\n"
      '  runZonedGuarded(() {}, (Object e, StackTrace s) {},\n'
      '      zoneSpecification: ZoneSpecification(print: (self, parent, zone, line) {}));\n'
      '}\n'
      'void sendFrame(List<int> frame) {\n'
      '  stdout.add(frame);\n'
      '}\n',
  // `process_requires_environment`.
  'lib/proc.dart':
      "import 'dart:io';\n"
      'void run() {\n'
      "  Process.run('ls', []);\n"
      '}\n',
  'lib/proc_pinned.dart':
      "import 'dart:io';\n"
      'void run() {\n'
      '  Process.run(\n'
      "    'ls',\n"
      '    [],\n'
      "    environment: const {'A': 'b'},\n"
      '    includeParentEnvironment: false,\n'
      '  );\n'
      '}\n',
  'lib/proc_partial.dart':
      "import 'dart:io';\n"
      'void run() {\n'
      '  Process.runSync(\n'
      "    'ls',\n"
      '    [],\n'
      "    environment: const {'A': 'b'},\n"
      '  );\n'
      '}\n',
  'lib/proc_io.dart':
      "import 'dart:io' as io;\n"
      'void run() {\n'
      '  io.Process.start(\n'
      "    'ls',\n"
      '    [],\n'
      '    environment: null,\n'
      '    includeParentEnvironment: false,\n'
      '  );\n'
      '}\n',
  // `no_wall_clock_in_actions`.
  'lib/clock.dart':
      "import 'dart:math' as math;\n"
      'int stamp() {\n'
      '  DateTime.now();\n'
      '  math.Random();\n'
      '  return 0;\n'
      '}\n',
  'lib/clock_unimported_random.dart':
      'int pick() {\n  Random();\n  return 0;\n}\n',
  'lib/clock_seeded.dart':
      "import 'dart:math';\n"
      'int pick() => Random(1).nextInt(10) + Random.new(2).nextInt(10);\n',
  'lib/clock_secure.dart':
      "import 'dart:math';\n"
      'int pick() => Random.secure().nextInt(10) + Random.new().nextInt(10);\n',
  'lib/clock_utc.dart': 'int stamp() => DateTime.utc(2020).year;\n',
  'lib/clock_temp.dart':
      "import 'dart:io';\n"
      'String dir() => Directory.systemTemp.path;\n',
  // `no_home_env_reads`.
  'lib/env.dart':
      "import 'dart:io';\n"
      "String home() => Platform.environment['HOME'] ?? '';\n",
  'lib/env_write.dart':
      'void scrub(Map<String, String> env, String scratchDir) {\n'
      "  env['HOME'] = scratchDir;\n"
      '}\n',
  'lib/env_contains.dart':
      "import 'dart:io';\n"
      'bool cached() =>\n'
      "    Platform.environment.containsKey('XDG_CONFIG_HOME');\n",
  'lib/env_from.dart':
      "String home() => const String.fromEnvironment('HOME');\n",
  'lib/env_has.dart':
      "bool hasHome() => const bool.hasEnvironment('USERPROFILE');\n",
  'lib/env_bool.dart':
      "bool testing() => const bool.hasEnvironment('TESTING');\n",
  'lib/env_fold.dart':
      'String? look(Map<String, String?> env) {\n'
      "  final direct = env['HO' 'ME'];\n"
      "  final grouped = env[('HOME')];\n"
      "  final added = env['HO' + 'ME'];\n"
      '  return direct ?? grouped ?? added;\n'
      '}\n',
  'lib/env_other.dart':
      "String? look(Map<String, String?> env) => env['OTHER'];\n",
  // Non-production paths stay silent even in worker units.
  'lib/tool_worker_test.dart': 'void run() {\n  print(1);\n}\n',
  'test/tool_worker.dart': 'void run() {\n  print(1);\n}\n',
};

/// Enables all four wave-1 project rules for the fixture project.
const String _fixtureOptions =
    'linter:\n'
    '  rules:\n'
    '    no_home_env_reads: true\n'
    '    no_stdout_in_worker: true\n'
    '    no_wall_clock_in_actions: true\n'
    '    process_requires_environment: true\n';

/// A minimal package config making the fixture root (`..` from `.dart_tool`)
/// package `fixture`.
const String _fixturePackages =
    '{"configVersion": 2, "packages": '
    '[{"name": "fixture", "rootUri": "..", "packageUri": "lib/"}]}';

/// Writes one fixture source at [relative] path under [rootPath].
void _writeFixture(String rootPath, String relative, String content) {
  File(_joinRel(rootPath, relative))
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(content);
}

/// Stages [_fixtures] inside a `bazel-out/...` directory under [tempRoot] so
/// every host exercises the execroot path layout seen on CI.
String _stageFixtures(Directory tempRoot) {
  final String rootPath = _joinRel(
    _normAbs(tempRoot.path),
    'bazel-out/x64_windows-fastbuild/fixture',
  );
  Directory(rootPath).createSync(recursive: true);
  for (final MapEntry<String, String> entry in _fixtures.entries) {
    _writeFixture(rootPath, entry.key, entry.value);
  }
  _writeFixture(rootPath, 'analysis_options.yaml', _fixtureOptions);
  _writeFixture(rootPath, '.dart_tool/package_config.json', _fixturePackages);
  return rootPath;
}

typedef _CodesLookup = Future<List<String>> Function(String relative);

void main() {
  late Directory tempRoot;
  late String rootPath;
  late AnalysisContextCollection collection;

  setUpAll(() {
    rulesDartProjectLints().forEach(Registry.ruleRegistry.registerLintRule);
    tempRoot = Directory.systemTemp.createTempSync('project_lints_test_');
    rootPath = _stageFixtures(tempRoot);
    collection = AnalysisContextCollection(
      includedPaths: [rootPath],
      resourceProvider: PhysicalResourceProvider.INSTANCE,
      sdkPath: _sdkPath,
    );
  });

  tearDownAll(() async {
    await collection.dispose();
    try {
      tempRoot.deleteSync(recursive: true);
    } on FileSystemException catch (e) {
      stderr.writeln('project_lints_test: cleanup skipped: ${e.message}');
    }
  });

  Future<List<String>> codes(String relative) async {
    final AnalysisSession session = collection
        .contextFor(rootPath)
        .currentSession;
    final String filePath = _joinRel(rootPath, relative);
    final SomeErrorsResult result = await session.getErrors(filePath);
    if (result is! ErrorsResult) {
      fail('cannot analyze $relative ($filePath): ${result.runtimeType}');
    }
    return [
      for (final diagnostic in result.diagnostics)
        diagnostic.diagnosticCode.lowerCaseName,
    ];
  }

  _definePathScopeTests();
  _defineNoStdoutTests(codes);
  _defineProcessEnvTests(codes);
  _defineWallClockTests(codes);
  _defineHomeEnvTests(codes);
}

void _definePathScopeTests() {
  group('isProductionProjectLintPath', () {
    test('accepts production lib and staged summary paths', () {
      expect(isProductionProjectLintPath('/repo/lib/a.dart'), isTrue);
      expect(
        isProductionProjectLintPath('/pkg/src/lib/a.dart', packageRoot: '/pkg'),
        isTrue,
      );
      expect(
        isProductionProjectLintPath(
          '/b/out/foo.dart_analyze.proj/src/lib/a.dart',
        ),
        isTrue,
      );
      expect(
        isProductionProjectLintPath(
          '/b/bazel-out/k8/foo.dart_analyze.summary.proj/src/bin/main.dart',
        ),
        isTrue,
      );
      expect(
        isProductionProjectLintPath(
          r'D:\a\bazel-out\x64\foo.dart_analyze.summary.proj\src\lib\a.dart',
        ),
        isTrue,
      );
      expect(
        isProductionProjectLintPath(
          r'D:\bazel-out\pkg\lib\a.dart',
          packageRoot: 'd:/bazel-out/pkg',
        ),
        isTrue,
      );
    });

    test('skips test files and directories including staged summary tests', () {
      expect(isProductionProjectLintPath('/repo/lib/a_test.dart'), isFalse);
      expect(isProductionProjectLintPath('/repo/test/a.dart'), isFalse);
      expect(isProductionProjectLintPath('/repo/tests/a.dart'), isFalse);
      expect(isProductionProjectLintPath('/repo/dart/tests/a.dart'), isFalse);
      expect(isProductionProjectLintPath('/repo/dev/testdata/a.dart'), isFalse);
      expect(isProductionProjectLintPath('/repo/testdata/a.dart'), isFalse);
      expect(
        isProductionProjectLintPath(
          '/b/out/t.dart_analyze.summary.proj/src/dart/tests/fix/lib/a.dart',
          packageRoot: '/b/out/t.dart_analyze.summary.proj/src/dart/tests/fix',
        ),
        isFalse,
      );
    });

    test('skips generated, staged, and documentation paths', () {
      expect(isProductionProjectLintPath('/repo/bazel-out/k8/a.dart'), isFalse);
      expect(
        isProductionProjectLintPath('/repo/__gate_canary_1/a.dart'),
        isFalse,
      );
      expect(isProductionProjectLintPath('/repo/docs/a.dart'), isFalse);
      expect(isProductionProjectLintPath('/repo/e2e/a.dart'), isFalse);
      expect(isProductionProjectLintPath('/repo/.dart_tool/a.dart'), isFalse);
      expect(isProductionProjectLintPath('/repo/third_party/a.dart'), isFalse);
    });
  });
}

void _defineNoStdoutTests(_CodesLookup codes) {
  group('no_stdout_in_worker', () {
    test(
      'reports print and cascaded stdout text writes in a worker unit',
      () async {
        expect(
          await codes('lib/tool_worker.dart'),
          equals(['no_stdout_in_worker', 'no_stdout_in_worker']),
        );
      },
    );

    test('ignores print outside worker units', () async {
      expect(
        await codes('lib/tool.dart'),
        isNot(contains('no_stdout_in_worker')),
      );
    });

    test('reports print through worker imports and flags', () async {
      expect(
        await codes('lib/imports_worker.dart'),
        contains('no_stdout_in_worker'),
      );
      expect(await codes('lib/entry.dart'), contains('no_stdout_in_worker'));
      expect(
        await codes('lib/plain_main.dart'),
        isNot(contains('no_stdout_in_worker')),
      );
    });

    test(
      'allows binary writes, stderr, local sinks, and interception',
      () async {
        expect(
          await codes('lib/worker_allowed.dart'),
          isNot(contains('no_stdout_in_worker')),
        );
      },
    );

    test('skips non-production worker paths', () async {
      expect(
        await codes('lib/tool_worker_test.dart'),
        isNot(contains('no_stdout_in_worker')),
      );
      expect(
        await codes('test/tool_worker.dart'),
        isNot(contains('no_stdout_in_worker')),
      );
    });
  });
}

void _defineProcessEnvTests(_CodesLookup codes) {
  group('process_requires_environment', () {
    test('reports unpinned spawns', () async {
      expect(
        await codes('lib/proc.dart'),
        contains('process_requires_environment'),
      );
    });

    test('allows pinned and rejects partial or null environments', () async {
      expect(
        await codes('lib/proc_pinned.dart'),
        isNot(contains('process_requires_environment')),
      );
      expect(
        await codes('lib/proc_partial.dart'),
        contains('process_requires_environment'),
      );
      expect(
        await codes('lib/proc_io.dart'),
        contains('process_requires_environment'),
      );
    });
  });
}

void _defineWallClockTests(_CodesLookup codes) {
  group('no_wall_clock_in_actions', () {
    test('reports clock, unseeded random, and systemTemp reads', () async {
      expect(
        await codes('lib/clock.dart'),
        equals(['no_wall_clock_in_actions', 'no_wall_clock_in_actions']),
      );
      expect(
        await codes('lib/clock_unimported_random.dart'),
        contains('no_wall_clock_in_actions'),
      );
      expect(
        await codes('lib/clock_secure.dart'),
        equals(['no_wall_clock_in_actions', 'no_wall_clock_in_actions']),
      );
      expect(
        await codes('lib/clock_temp.dart'),
        contains('no_wall_clock_in_actions'),
      );
    });

    test('allows seeded random and utc construction', () async {
      expect(
        await codes('lib/clock_seeded.dart'),
        isNot(contains('no_wall_clock_in_actions')),
      );
      expect(
        await codes('lib/clock_utc.dart'),
        isNot(contains('no_wall_clock_in_actions')),
      );
    });
  });
}

void _defineHomeEnvTests(_CodesLookup codes) {
  group('no_home_env_reads', () {
    test('reports home variable reads across all lookup forms', () async {
      expect(await codes('lib/env.dart'), contains('no_home_env_reads'));
      expect(
        await codes('lib/env_contains.dart'),
        contains('no_home_env_reads'),
      );
      expect(await codes('lib/env_from.dart'), contains('no_home_env_reads'));
      expect(await codes('lib/env_has.dart'), contains('no_home_env_reads'));
      expect(
        await codes('lib/env_fold.dart'),
        equals(['no_home_env_reads', 'no_home_env_reads', 'no_home_env_reads']),
      );
    });

    test('allows writes and unrelated names', () async {
      expect(
        await codes('lib/env_write.dart'),
        isNot(contains('no_home_env_reads')),
      );
      expect(
        await codes('lib/env_other.dart'),
        isNot(contains('no_home_env_reads')),
      );
      expect(
        await codes('lib/env_bool.dart'),
        isNot(contains('no_home_env_reads')),
      );
    });
  });
}
