import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

import 'directive_guard.dart';

/// Unit tests for the shared staged-source check, the byte-identity of its two
/// mirrors, and the enumeration of every Dart-reading tool through it.
///
/// A Dart-reading tool that stops enforcing the check must fail the
/// `every tool enforces the shared check` test below: each tool source is
/// passed as a test argument (see BUILD.bazel) and must contain its
/// enforcement marker. Tools that only parse Dart text without resolving
/// directives against the filesystem are deliberately absent:
/// `format_runner` (parses text only), `fix_applier`, `test_runner`,
/// `kernel_launcher`, `copy_tree`, `dill_outline`, `kernel_link`, `noop` and
/// `update_cross_sdk_versions` resolve no directive URI.

/// The test's tool sources by file name, from the `rlocationpath` arguments
/// under Bazel or from the source tree for a direct `dart test` run.
Map<String, String> _toolSources(List<String> args) {
  if (args.isEmpty) {
    const shim = '../../ext/lib/builder_shim.dart';
    const names = [
      'analyze_runner.dart',
      'analyzer_summary.dart',
      'app_jit_snapshot.dart',
      'directive_guard.dart',
      'fix_runner.dart',
      'kernel_module.dart',
      'link_hook_runner.dart',
      'web_compile_runner.dart',
      'builder_shim.dart',
    ];
    return {
      for (final name in names)
        name: File.fromUri(
          Platform.script.resolve(name == 'builder_shim.dart' ? shim : name),
        ).path,
    };
  }
  final runfiles = Runfiles.create();
  final sources = <String, String>{};
  for (final arg in args) {
    sources[arg.split('/').last] = runfiles.rlocation(arg);
  }
  return sources;
}

/// The staged-resolver mirror region of a tool source: the lines between the
/// `BEGIN` and `END` markers, trailing whitespace stripped.
String _mirrorRegion(String name, String text) {
  final lines = text.split('\n').map((line) => line.trimRight()).toList();
  final begin = lines.indexWhere(
    (line) => line.startsWith('// BEGIN staged-resolver-mirror'),
  );
  final end = lines.indexWhere(
    (line) => line == '// END staged-resolver-mirror',
  );
  expect(begin, isNot(-1), reason: '$name lacks the mirror BEGIN marker');
  expect(end, isNot(-1), reason: '$name lacks the mirror END marker');
  expect(end, greaterThan(begin), reason: '$name has an empty mirror region');
  return lines.sublist(begin + 1, end).join('\n');
}

void main(List<String> args) {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('directive_guard_test_');
  });

  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  group('resolveStagedRelativeTarget', () {
    test('sibling and nested relatives stay inside', () {
      expect(
        resolveStagedRelativeTarget('b.dart', '/r/proj/lib/a.dart'),
        '/r/proj/lib/b.dart',
      );
      expect(
        resolveStagedRelativeTarget('sub/b.dart', '/r/proj/lib/a.dart'),
        '/r/proj/lib/sub/b.dart',
      );
      expect(
        resolveStagedRelativeTarget('../dep/b.dart', '/r/proj/lib/sub/a.dart'),
        '/r/proj/lib/dep/b.dart',
      );
    });

    test('climbs leave the tree instead of clamping', () {
      expect(
        resolveStagedRelativeTarget('../../evil.dart', '/r/proj/lib/a.dart'),
        '/r/evil.dart',
      );
      expect(
        resolveStagedRelativeTarget('../evil.dart', '/r/proj/main.dart'),
        '/r/evil.dart',
      );
    });

    test('slash-absolute URIs resolve against the filesystem root', () {
      expect(
        resolveStagedRelativeTarget('/lib/b.dart', '/r/proj/lib/a.dart'),
        '/lib/b.dart',
      );
      expect(
        resolveStagedRelativeTarget('/etc/hostname', '/r/proj/lib/a.dart'),
        '/etc/hostname',
      );
    });

    test('backslashes separate like the analyzer', () {
      expect(
        resolveStagedRelativeTarget(r'..\..\evil.dart', '/r/proj/lib/a.dart'),
        '/r/evil.dart',
      );
    });

    test('encoded dots climb, encoded slashes name no file', () {
      expect(
        resolveStagedRelativeTarget('%2e%2e/evil.dart', '/r/proj/lib/a.dart'),
        '/r/proj/evil.dart',
      );
      expect(
        resolveStagedRelativeTarget('%2E%2E/evil.dart', '/r/proj/lib/a.dart'),
        '/r/proj/evil.dart',
      );
      expect(
        resolveStagedRelativeTarget(
          '..%2f..%2fevil.dart',
          '/r/proj/lib/a.dart',
        ),
        isNull,
      );
    });

    test('schemes, queries, fragments and authorities yield null', () {
      const from = '/r/proj/lib/a.dart';
      expect(resolveStagedRelativeTarget('dart:core', from), isNull);
      expect(resolveStagedRelativeTarget('package:p/a.dart', from), isNull);
      expect(resolveStagedRelativeTarget('file:/etc/hosts', from), isNull);
      expect(resolveStagedRelativeTarget('a.dart?x=1', from), isNull);
      expect(resolveStagedRelativeTarget('a.dart#x', from), isNull);
      expect(resolveStagedRelativeTarget('//host/a.dart', from), isNull);
      expect(resolveStagedRelativeTarget('C:/a.dart', from), isNull);
    });
  });

  group('isEscapingPackageUri', () {
    test('climbs above the package escape', () {
      expect(isEscapingPackageUri('package:p/sub/../../x.dart'), isTrue);
      expect(isEscapingPackageUri('package:p/../../x.dart'), isTrue);
      expect(isEscapingPackageUri('package:p/%2e%2e/x.dart'), isTrue);
    });

    test('URIs inside the package do not escape', () {
      expect(isEscapingPackageUri('package:p/a.dart'), isFalse);
      expect(isEscapingPackageUri('package:p/sub/../a.dart'), isFalse);
      expect(isEscapingPackageUri('package:p'), isFalse);
    });

    test('only plain package: URIs are classified', () {
      expect(isEscapingPackageUri('package:p/a.dart?x=1'), isFalse);
      expect(isEscapingPackageUri('../x.dart'), isFalse);
      expect(isEscapingPackageUri('dart:core'), isFalse);
    });
  });

  group('projectStagedRoots', () {
    test('a .proj project scans itself and its .extpkgs sibling', () {
      expect(projectStagedRoots('/r/x.proj'), ['/r/x.proj', '/r/x.extpkgs']);
      expect(projectStagedRoots('/r/x.proj/'), ['/r/x.proj/', '/r/x.extpkgs']);
    });

    test('other roots scan alone', () {
      expect(projectStagedRoots('/r/other'), ['/r/other']);
    });
  });

  group('findStagedDirectiveViolations', () {
    late Directory staged;

    String stagedFile(String relative, String content) {
      final file = File('${staged.path}/$relative')
        ..createSync(recursive: true)
        ..writeAsStringSync(content);
      return file.path.replaceAll(r'\', '/');
    }

    setUp(() {
      staged = Directory('${tmp.path}/pkg/demo.proj')
        ..createSync(recursive: true);
      stagedFile('lib/b.dart', 'library b;\n');
      stagedFile('lib/a.dart', "import 'b.dart';\n");
      stagedFile('lib/sub/ok.dart', "import '../b.dart';\n");
      stagedFile('lib/climb.dart', "import '../../evil.dart';\n");
      stagedFile(
        'lib/cond.dart',
        "import 'b.dart' if (dart.library.io) '../../evil.dart';\n",
      );
      stagedFile('lib/scheme.dart', "import 'file:///etc/hosts';\n");
      stagedFile(
        'lib/pkg.dart',
        "import 'package:demo/sub/../../evil.dart';\n",
      );
      stagedFile('lib/abs.dart', "import '/etc/hostname';\n");
      stagedFile('lib/part.dart', "part '../../evil_part.dart';\n");
      stagedFile('lib/partof.dart', "part of '../../evil_lib.dart';\n");
      stagedFile('lib/dart.dart', "import 'dart:core';\n");
      stagedFile('lib/inside.dart', "import 'package:demo/sub/a.dart';\n");
      stagedFile('main.dart', "import '../evil.dart';\n");
    });

    test('refuses every escape and allows the declared tree', () {
      final violations = findStagedDirectiveViolations([
        staged.path,
      ], tool: 'guard-test');
      final at = (String relative) =>
          '${staged.path}/$relative'.replaceAll(r'\', '/');
      expect(violations, [
        "guard-test: ${at('lib/abs.dart')} import '/etc/hostname' "
            'is not a declared input.',
        "guard-test: ${at('lib/climb.dart')} import '../../evil.dart' "
            'is not a declared input.',
        "guard-test: ${at('lib/cond.dart')} import '../../evil.dart' "
            'is not a declared input.',
        "guard-test: ${at('lib/part.dart')} part '../../evil_part.dart' "
            'is not a declared input.',
        "guard-test: ${at('lib/partof.dart')} part of '../../evil_lib.dart' "
            'is not a declared input.',
        "guard-test: ${at('lib/pkg.dart')} import "
            "'package:demo/sub/../../evil.dart' is not a declared input.",
        "guard-test: ${at('lib/scheme.dart')} import 'file:///etc/hosts' "
            'is not a declared input.',
        "guard-test: ${at('main.dart')} import '../evil.dart' "
            'is not a declared input.',
      ]);
    });

    test('missing roots scan as empty', () {
      expect(
        findStagedDirectiveViolations([
          '${tmp.path}/no-such-dir',
        ], tool: 'guard-test'),
        isEmpty,
      );
    });
  });

  group('staged-resolver mirrors', () {
    test('the three copies are byte-identical', () {
      final sources = _toolSources(args);
      final guard = _mirrorRegion(
        'directive_guard.dart',
        File(sources['directive_guard.dart']!).readAsStringSync(),
      );
      final appJit = _mirrorRegion(
        'app_jit_snapshot.dart',
        File(sources['app_jit_snapshot.dart']!).readAsStringSync(),
      );
      final shim = _mirrorRegion(
        'builder_shim.dart',
        File(sources['builder_shim.dart']!).readAsStringSync(),
      );
      expect(appJit, guard);
      expect(shim, guard);
    });
  });

  group('every tool enforces the shared check', () {
    // Each Dart-reading tool and the marker proving it enforces the shared
    // staged-source check: the runners call it directly, the whole-program
    // gen_kernel wrapper and the builder shims enforce their byte-identical
    // mirrors, and the modular kernel planner resolves every directive
    // through the shared front-end mirror. A tool without its marker fails.
    const markers = {
      'analyze_runner.dart': 'findStagedDirectiveViolations(',
      'analyzer_summary.dart': 'findStagedDirectiveViolations(',
      'fix_runner.dart': 'findStagedDirectiveViolations(',
      'web_compile_runner.dart': 'findStagedDirectiveViolations(',
      'link_hook_runner.dart': 'findStagedDirectiveViolations(',
      'app_jit_snapshot.dart': '_findDisallowedGenKernelDirectives(',
      'kernel_module.dart': 'resolveDirectiveUri(',
      'builder_shim.dart': 'findStagedShimViolations(',
    };

    test('the enumerated tools are exactly the tested sources', () {
      final sources = _toolSources(args);
      expect(
        sources.keys,
        unorderedEquals([
          ...markers.keys,
          ...['directive_guard.dart'],
        ]),
      );
    });

    for (final entry in markers.entries) {
      test('${entry.key} enforces `${entry.value}`', () {
        final sources = _toolSources(args);
        final text = File(sources[entry.key]!).readAsStringSync();
        expect(
          text.contains(entry.value),
          isTrue,
          reason: '${entry.key} does not enforce ${entry.value}',
        );
      });
    }
  });
}
