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

/// The executing SDK's root: `dart_test` runs on the toolchain SDK's `dart`,
/// so the grandparent of the executable is the SDK.
final String _sdkPath = File(Platform.resolvedExecutable).parent.parent.path;

/// Fixture sources, keyed by path under the fixture root.
const Map<String, String> _fixtures = {
  // `no_stdout_in_worker`: a worker unit by basename.
  'lib/tool_worker.dart': 'void run() {\n  print(1);\n}\n',
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
  // Binary frame writes, `stderr`, and interception stay allowed.
  'lib/worker_allowed.dart':
      "import 'dart:async';\n"
      "import 'dart:io';\n"
      'void run(List<int> frame) {\n'
      '  stdout.add(frame);\n'
      "  stderr.writeln('oops');\n"
      '  runZonedGuarded(() {}, (Object e, StackTrace s) {},\n'
      '      zoneSpecification: ZoneSpecification(print: (self, parent, zone, line) {}));\n'
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
  'lib/clock.dart': 'int stamp() {\n  DateTime.now();\n  return 0;\n}\n',
  'lib/clock_seeded.dart': 'int pick() {\n  return Random(1).nextInt(10);\n}\n',
  'lib/clock_secure.dart':
      'int pick() {\n  return Random.secure().nextInt(10);\n}\n',
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
      "String home() => String.fromEnvironment('HOME', defaultValue: '');\n",
  'lib/env_bool.dart':
      "bool testing() => bool.hasEnvironment('TESTING') || false;\n",
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

/// A minimal package config making the fixture root package `fixture`.
const String _fixturePackages =
    '{"configVersion": 2, "packages": '
    '[{"name": "fixture", "rootUri": ".", "packageUri": "lib/"}]}';

/// Writes one fixture source at [relative] path under [root].
void _writeFixture(Directory root, String relative, String content) {
  File('${root.path}/$relative')
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(content);
}

/// Stages [_fixtures] under a fresh fixture root with options and packages.
Directory _stageFixtures() {
  final Directory root = Directory.systemTemp.createTempSync(
    'project_lints_test_',
  );
  for (final MapEntry<String, String> entry in _fixtures.entries) {
    _writeFixture(root, entry.key, entry.value);
  }
  File('${root.path}/analysis_options.yaml').writeAsStringSync(_fixtureOptions);
  Directory('${root.path}/.dart_tool').createSync(recursive: true);
  File('${root.path}/.dart_tool/package_config.json')
      .writeAsStringSync(_fixturePackages);
  return root;
}

void main() {
  late Directory root;
  late AnalysisContextCollection collection;

  setUpAll(() {
    rulesDartProjectLints().forEach(Registry.ruleRegistry.registerLintRule);
    root = _stageFixtures();
    collection = AnalysisContextCollection(
      includedPaths: [root.path],
      resourceProvider: PhysicalResourceProvider.INSTANCE,
      sdkPath: _sdkPath,
    );
  });

  tearDownAll(() async {
    await collection.dispose();
    root.deleteSync(recursive: true);
  });

  /// The lint codes reported for the fixture at [relative] path.
  Future<List<String>> codes(String relative) async {
    final AnalysisSession session = collection
        .contextFor(root.path)
        .currentSession;
    final SomeErrorsResult result = await session.getErrors(
      '${root.path}/$relative',
    );
    if (result is! ErrorsResult) {
      fail('cannot analyze $relative: ${result.runtimeType}');
    }
    return [
      for (final diagnostic in result.diagnostics)
        diagnostic.diagnosticCode.lowerCaseName,
    ];
  }

  group('isProductionProjectLintPath', () {
    test('accepts production lib paths', () {
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
    });

    test('skips test files and directories', () {
      expect(isProductionProjectLintPath('/repo/lib/a_test.dart'), isFalse);
      expect(isProductionProjectLintPath('/repo/test/a.dart'), isFalse);
      expect(isProductionProjectLintPath('/repo/tests/a.dart'), isFalse);
      expect(isProductionProjectLintPath('/repo/dart/tests/a.dart'), isFalse);
      expect(isProductionProjectLintPath('/repo/dev/testdata/a.dart'), isFalse);
      expect(isProductionProjectLintPath('/repo/testdata/a.dart'), isFalse);
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

  group('no_stdout_in_worker', () {
    test('reports print in a worker unit', () async {
      expect(
        await codes('lib/tool_worker.dart'),
        contains('no_stdout_in_worker'),
      );
    });

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

    test('allows binary writes, stderr, and interception', () async {
      expect(
        await codes('lib/worker_allowed.dart'),
        isNot(contains('no_stdout_in_worker')),
      );
    });

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

  group('process_requires_environment', () {
    test('reports unpinned spawns', () async {
      expect(
        await codes('lib/proc.dart'),
        contains('process_requires_environment'),
      );
    });

    test('allows pinned and partial environments', () async {
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

  group('no_wall_clock_in_actions', () {
    test('reports clock reads', () async {
      expect(
        await codes('lib/clock.dart'),
        contains('no_wall_clock_in_actions'),
      );
      expect(
        await codes('lib/clock_secure.dart'),
        contains('no_wall_clock_in_actions'),
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

  group('no_home_env_reads', () {
    test('reports home variable reads', () async {
      expect(await codes('lib/env.dart'), contains('no_home_env_reads'));
      expect(
        await codes('lib/env_contains.dart'),
        contains('no_home_env_reads'),
      );
      expect(await codes('lib/env_from.dart'), contains('no_home_env_reads'));
      expect(await codes('lib/env_fold.dart'), contains('no_home_env_reads'));
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
