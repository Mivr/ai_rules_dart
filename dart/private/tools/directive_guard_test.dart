import 'dart:convert';
import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

import '../../guard/lib/directive_guard.dart';

/// Unit tests for the shared staged-source check, the byte-identity of its one
/// remaining mirror, and the enumeration of every Dart-reading tool through it.
///
/// The shared check lives in the public `package:rules_dart_guard` library
/// (`dart/guard/lib/directive_guard.dart`), which every tool below imports —
/// except the two that cannot: the whole-program `gen_kernel` wrapper runs
/// from source (`app_jit_snapshot.dart`), and the modular kernel planner
/// takes no `deps` edge (every `dart_library` names it, so that would be a
/// cycle) and reads the same file through `srcs` instead. The wrapper's copy
/// is byte-identical to the library's marked block, pinned by the mirror test
/// below, so it still classifies exactly what the shared check classifies.
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
    const guard = '../../guard/lib/directive_guard.dart';
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
    const relocated = {
      'builder_shim.dart': shim,
      'directive_guard.dart': guard,
    };
    return {
      for (final name in names)
        name: File.fromUri(Platform.script.resolve(relocated[name] ?? name))
            .path,
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

    test('an empty reference names the importing file itself', () {
      expect(
        resolveStagedRelativeTarget('', '/r/proj/lib/a.dart'),
        '/r/proj/lib/a.dart',
      );
      expect(
        resolveStagedRelativeTarget('?query=1', '/r/proj/lib/a.dart'),
        '/r/proj/lib/a.dart',
      );
    });

    test('a query is dropped and the path part resolved', () {
      expect(
        resolveStagedRelativeTarget('b.dart?x=1', '/r/proj/lib/a.dart'),
        '/r/proj/lib/b.dart',
      );
      expect(
        resolveStagedRelativeTarget(
          '../../evil.dart?x=1',
          '/r/proj/lib/a.dart',
        ),
        '/r/evil.dart',
      );
      expect(
        resolveStagedRelativeTarget('/etc/hostname?x=1', '/r/proj/lib/a.dart'),
        '/etc/hostname',
      );
      expect(
        resolveStagedRelativeTarget('../evil.dart?a:b', '/r/proj/main.dart'),
        '/r/evil.dart',
      );
    });

    test('a fragment names no file, whatever path precedes it', () {
      const from = '/r/proj/lib/a.dart';
      expect(resolveStagedRelativeTarget('#frag', from), isNull);
      expect(resolveStagedRelativeTarget('b.dart#frag', from), isNull);
      expect(resolveStagedRelativeTarget('b.dart?x=1#frag', from), isNull);
      expect(resolveStagedRelativeTarget('../../evil.dart#frag', from), isNull);
    });

    test('schemes, authorities and drive paths yield null', () {
      const from = '/r/proj/lib/a.dart';
      expect(resolveStagedRelativeTarget('dart:core', from), isNull);
      expect(resolveStagedRelativeTarget('package:p/a.dart', from), isNull);
      expect(resolveStagedRelativeTarget('file:/etc/hosts', from), isNull);
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

    test('an empty segment escapes: the front end resolves it absolutely', () {
      expect(isEscapingPackageUri('package:p//x.dart'), isTrue);
      expect(isEscapingPackageUri('package:p/a//x.dart'), isTrue);
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

  group('hasEmptyPathSegment', () {
    test('doubled slashes count, wherever they hide', () {
      expect(hasEmptyPathSegment('a//b.dart'), isTrue);
      expect(hasEmptyPathSegment('/a//b.dart'), isTrue);
      expect(hasEmptyPathSegment('package:p//a.dart'), isTrue);
      expect(hasEmptyPathSegment('package:p/a//b.dart'), isTrue);
      expect(hasEmptyPathSegment('org-dartlang-root:////a.dart'), isTrue);
      expect(hasEmptyPathSegment(r'a\\b.dart'), isTrue);
      expect(hasEmptyPathSegment('a//b.dart?x=1'), isTrue);
    });

    test('single slashes and segment-free URIs do not', () {
      expect(hasEmptyPathSegment('a/b.dart'), isFalse);
      expect(hasEmptyPathSegment('/a/b.dart'), isFalse);
      expect(hasEmptyPathSegment('package:p/a.dart'), isFalse);
      expect(hasEmptyPathSegment('org-dartlang-root:///a.dart'), isFalse);
      expect(hasEmptyPathSegment(''), isFalse);
      expect(hasEmptyPathSegment('?x=1'), isFalse);
      expect(hasEmptyPathSegment('#frag'), isFalse);
      expect(hasEmptyPathSegment('//host/a.dart'), isFalse);
      expect(hasEmptyPathSegment('dart:core'), isFalse);
      expect(hasEmptyPathSegment('file:///etc/hosts'), isFalse);
      expect(hasEmptyPathSegment('package:p'), isFalse);
    });
  });

  group('isDisallowedDirectiveUri', () {
    test(
      'schemeless authorities are disallowed in every separator spelling',
      () {
        expect(isDisallowedDirectiveUri('//host/evil.dart'), isTrue);
        expect(isDisallowedDirectiveUri(r'\\host\evil.dart'), isTrue);
        expect(isDisallowedDirectiveUri('//host/evil.dart?v=1'), isTrue);
        expect(isDisallowedDirectiveUri('//host/evil.dart#frag'), isTrue);
      },
    );

    test('relatives and declared schemes pass', () {
      expect(isDisallowedDirectiveUri('b.dart'), isFalse);
      expect(isDisallowedDirectiveUri('../b.dart'), isFalse);
      expect(isDisallowedDirectiveUri('b.dart#frag'), isFalse);
      expect(isDisallowedDirectiveUri('dart:core'), isFalse);
      expect(isDisallowedDirectiveUri('package:demo/b.dart'), isFalse);
      expect(
        isDisallowedDirectiveUri('org-dartlang-root:///pkg/lib/b.dart'),
        isFalse,
      );
      expect(isDisallowedDirectiveUri(''), isFalse);
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
      stagedFile('lib/empty.dart', "import 'a//b.dart';\n");
      stagedFile('lib/emptypkg.dart', "import 'package:demo//evil.dart';\n");
      stagedFile('lib/part.dart', "part '../../evil_part.dart';\n");
      stagedFile('lib/partof.dart', "part of '../../evil_lib.dart';\n");
      stagedFile('lib/dart.dart', "import 'dart:core';\n");
      stagedFile('lib/inside.dart', "import 'package:demo/sub/a.dart';\n");
      stagedFile('lib/self.dart', "import '' as self;\n");
      stagedFile('lib/selfq.dart', "import '?v=1' as self;\n");
      stagedFile('lib/qsib.dart', "import 'b.dart?v=1';\n");
      stagedFile('lib/qclimb.dart', "import '../../evil.dart?v=1';\n");
      stagedFile('lib/qabs.dart', "import '/etc/hostname?v=1';\n");
      stagedFile('lib/frag.dart', "import 'b.dart#frag';\n");
      stagedFile('lib/slashauth.dart', "import '//host/evil.dart';\n");
      // Four source backslashes (0x5C): the scanner unescapes `\\` pairs, so
      // the extracted URI leads with `\\`, which the check reads as the `//`
      // authority refusal. A single source backslash would unescape to one and
      // refuse as an absolute path instead.
      File('${staged.path}/lib/backslash.dart'.replaceAll(r'\', '/'))
        ..createSync(recursive: true)
        ..writeAsBytesSync([
          ...utf8.encode("import '"),
          0x5c,
          0x5c,
          0x5c,
          0x5c,
          ...utf8.encode('host'),
          0x5c,
          0x5c,
          ...utf8.encode("evil.dart';\n"),
        ]);
      File('${staged.path}/lib/malformed.dart'.replaceAll(r'\', '/'))
        ..createSync(recursive: true)
        ..writeAsBytesSync([
          ...utf8.encode("import 'b.dart';\n// "),
          0xff,
          ...utf8.encode("\nimport '../../evil.dart';\n"),
        ]);
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
        "guard-test: ${at('lib/backslash.dart')} import '\\\\host\\evil.dart' "
            'is not a declared input.',
        "guard-test: ${at('lib/climb.dart')} import '../../evil.dart' "
            'is not a declared input.',
        "guard-test: ${at('lib/cond.dart')} import '../../evil.dart' "
            'is not a declared input.',
        "guard-test: ${at('lib/empty.dart')} import 'a//b.dart' "
            'is not a declared input.',
        "guard-test: ${at('lib/emptypkg.dart')} import 'package:demo//evil.dart' "
            'is not a declared input.',
        "guard-test: ${at('lib/frag.dart')} import 'b.dart#frag' "
            'is not a declared input.',
        "guard-test: ${at('lib/malformed.dart')} import '../../evil.dart' "
            'is not a declared input.',
        "guard-test: ${at('lib/part.dart')} part '../../evil_part.dart' "
            'is not a declared input.',
        "guard-test: ${at('lib/partof.dart')} part of '../../evil_lib.dart' "
            'is not a declared input.',
        "guard-test: ${at('lib/pkg.dart')} import "
            "'package:demo/sub/../../evil.dart' is not a declared input.",
        "guard-test: ${at('lib/qabs.dart')} import '/etc/hostname?v=1' "
            'is not a declared input.',
        "guard-test: ${at('lib/qclimb.dart')} import '../../evil.dart?v=1' "
            'is not a declared input.',
        "guard-test: ${at('lib/scheme.dart')} import 'file:///etc/hosts' "
            'is not a declared input.',
        "guard-test: ${at('lib/slashauth.dart')} import '//host/evil.dart' "
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
    test('the library and the wrapper copies are byte-identical', () {
      final sources = _toolSources(args);
      final guard = _mirrorRegion(
        'directive_guard.dart',
        File(sources['directive_guard.dart']!).readAsStringSync(),
      );
      final appJit = _mirrorRegion(
        'app_jit_snapshot.dart',
        File(sources['app_jit_snapshot.dart']!).readAsStringSync(),
      );
      expect(appJit, guard);
    });
  });

  group('every tool enforces the shared check', () {
    // Each Dart-reading tool and the marker proving it enforces the shared
    // staged-source check: the runners call it directly, the whole-program
    // gen_kernel wrapper enforces its byte-identical mirror, the modular
    // kernel planner resolves every directive through the shared file it
    // reads through `srcs`, and the builder shims import the shared library.
    // A tool without its marker fails.
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
