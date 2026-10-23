import 'dart:convert';
import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

import '../../guard/lib/directive_guard.dart';

/// Unit tests for the shared staged-source check, the absence of its former
/// copies, and the enumeration of every Dart-reading tool through it.
///
/// The shared check lives in the public `package:rules_dart_guard` library
/// (`dart/guard/lib/directive_guard.dart`). Every tool below enforces it: the
/// whole-program `gen_kernel` wrapper imports it from source through its
/// staged tool bundle, and the modular kernel planner — which takes no `deps`
/// edge (every `dart_library` names it, so that would be a cycle) — reads the
/// same file through `srcs` instead. One copy classifies every compile.
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
      expect(isEscapingPackageUri('package:p/%2E%2E/x.dart'), isTrue);
    });

    test('an escaping path still escapes with a query or fragment', () {
      expect(isEscapingPackageUri('package:p/../../x.dart?q'), isTrue);
      expect(
        isEscapingPackageUri('package:p/sub/../../x.dart?x=1#frag'),
        isTrue,
      );
      expect(isEscapingPackageUri('package:p/../../x.dart#frag'), isTrue);
      expect(isEscapingPackageUri('package:p//x.dart?x=1'), isTrue);
      expect(isEscapingPackageUri('package:p/..%2F..%2Fx.dart?q'), isTrue);
    });

    test('a decoded separator escapes however the front end spells it', () {
      expect(isEscapingPackageUri('package:p/..%2F..%2Fx.dart'), isTrue);
      expect(isEscapingPackageUri('package:p/..%2f..%2fx.dart'), isTrue);
      expect(isEscapingPackageUri('package:p/..%5C..%5Cx.dart'), isTrue);
      expect(isEscapingPackageUri('package:p/a%2Fb.dart'), isTrue);
      expect(isEscapingPackageUri('package:p/a%5Cb.dart'), isTrue);
    });

    test('an empty segment escapes: the front end resolves it absolutely', () {
      expect(isEscapingPackageUri('package:p//x.dart'), isTrue);
      expect(isEscapingPackageUri('package:p/a//x.dart'), isTrue);
    });

    test('URIs inside the package do not escape', () {
      expect(isEscapingPackageUri('package:p/a.dart'), isFalse);
      expect(isEscapingPackageUri('package:p/sub/../a.dart'), isFalse);
      expect(isEscapingPackageUri('package:p'), isFalse);
      expect(isEscapingPackageUri('package:p/a.dart?x=1'), isFalse);
      expect(isEscapingPackageUri('package:p/a.dart#frag'), isFalse);
      expect(isEscapingPackageUri('package:p/a.dart?x=1#frag'), isFalse);
      expect(isEscapingPackageUri('package:p/sub/a.dart?x=../../y'), isFalse);
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

  group('findDisallowedDirectives', () {
    test('triple-quoted URIs are refused in every directive kind', () {
      expect(
        findDisallowedDirectives({
          'm.dart': "import '''   \nfile:///etc/hosts''';\n",
          'n.dart': "export '''\t\n/secret/s.dart''';\n",
          'o.dart': "part '''   \n../../evil_part.dart''';\n",
          'p.dart': "part of r'''   \n../../evil_lib.dart''';\n",
        }, tool: 'guard-test'),
        [
          "guard-test: m.dart import '   \nfile:///etc/hosts' "
              'is not a declared input.',
          "guard-test: n.dart export '\t\n/secret/s.dart' "
              'is not a declared input.',
          "guard-test: o.dart part '   \n../../evil_part.dart' "
              'is not a declared input.',
          "guard-test: p.dart part of '   \n../../evil_lib.dart' "
              'is not a declared input.',
        ],
      );
    });

    test('single-line URIs still classify by scheme', () {
      expect(
        findDisallowedDirectives({
          'm.dart': "import 'file:///etc/hosts';\n",
          'n.dart': "import '''b.dart''';\n",
        }, tool: 'guard-test'),
        [
          "guard-test: m.dart import 'file:///etc/hosts' "
              'is not a declared input.',
        ],
      );
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

  group('hasLineBreak', () {
    test('a scanned value holding a line break counts', () {
      expect(hasLineBreak('a\nb.dart'), isTrue);
      expect(hasLineBreak('a\rb.dart'), isTrue);
      expect(hasLineBreak('a\r\nb.dart'), isTrue);
      expect(hasLineBreak('   \n/secret/s.dart'), isTrue);
      expect(hasLineBreak('\n/secret/s.dart'), isTrue);
    });

    test('single-line spellings do not', () {
      expect(hasLineBreak('b.dart'), isFalse);
      expect(hasLineBreak('/etc/hostname'), isFalse);
      expect(hasLineBreak('file:///etc/hosts'), isFalse);
      // A literal backslash-n is two characters, not a break: only the
      // scanner's unescaped value (where an escape became a real break)
      // reaches this predicate.
      expect(hasLineBreak(r'a\nb.dart'), isFalse);
      expect(hasLineBreak(''), isFalse);
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

    group('triple-quoted URIs', () {
      late Directory tq;
      late String hostSecret;

      String tqFile(String relative, String content) {
        final file = File('${tq.path}/$relative')
          ..createSync(recursive: true)
          ..writeAsStringSync(content);
        return file.path.replaceAll(r'\', '/');
      }

      setUp(() {
        tq = Directory('${tmp.path}/tq.proj')..createSync(recursive: true);
        tqFile('lib/ok.dart', 'const ok = 1;\n');
        // A host file outside the staged tree, named by an absolute path.
        hostSecret =
            (File('${tmp.path}/host_secret.dart')
                  ..writeAsStringSync('const hostSecret = 1;\n'))
                .path
                .replaceAll(r'\', '/');
        // Every spelling the front end reads differently from the guard: a
        // whitespace-only (or lone-backslash) first line is dropped, so the
        // front end reads `/secret/s.dart` (or the host path) while the
        // guard would see a relative staged path. All are refused outright.
        tqFile('lib/ws.dart', "import '''   \n/secret/s.dart''';\n");
        tqFile('lib/tab.dart', "import '''\t\t\n/secret/s.dart''';\n");
        tqFile('lib/bs.dart', "import '''\\\n/secret/s.dart''';\n");
        tqFile('lib/raw.dart', "import r'''   \n/secret/s.dart''';\n");
        tqFile('lib/dq.dart', 'import """   \n/secret/s.dart""";\n');
        tqFile('lib/host.dart', "import '''   \n$hostSecret''';\n");
        tqFile('lib/hostfile.dart', "import '''   \nfile:///etc/hosts''';\n");
        tqFile('lib/exp.dart', "export '''   \n/secret/s.dart''';\n");
        tqFile('lib/prt.dart', "part '''   \n../../evil_part.dart''';\n");
        tqFile('lib/pof.dart', "part of '''   \n../../evil_lib.dart''';\n");
        // A relative target with no staged file is refused too: only a
        // staged file backs a declared input.
        tqFile('lib/missing.dart', "import 'nosuch.dart';\n");
      });

      test('every triple-quote spelling is refused', () {
        final violations = findStagedDirectiveViolations([
          tq.path,
        ], tool: 'guard-test');
        final at = (String relative) =>
            '${tq.path}/$relative'.replaceAll(r'\', '/');
        expect(violations, [
          "guard-test: ${at('lib/bs.dart')} import '\n/secret/s.dart' "
              'is not a declared input.',
          "guard-test: ${at('lib/dq.dart')} import '   \n/secret/s.dart' "
              'is not a declared input.',
          "guard-test: ${at('lib/exp.dart')} export '   \n/secret/s.dart' "
              'is not a declared input.',
          "guard-test: ${at('lib/host.dart')} import '   \n$hostSecret' "
              'is not a declared input.',
          "guard-test: ${at('lib/hostfile.dart')} import "
              "'   \nfile:///etc/hosts' is not a declared input.",
          "guard-test: ${at('lib/missing.dart')} import 'nosuch.dart' "
              'is not a declared input.',
          "guard-test: ${at('lib/pof.dart')} part of '   \n../../evil_lib.dart' "
              'is not a declared input.',
          "guard-test: ${at('lib/prt.dart')} part '   \n../../evil_part.dart' "
              'is not a declared input.',
          "guard-test: ${at('lib/raw.dart')} import '   \n/secret/s.dart' "
              'is not a declared input.',
          "guard-test: ${at('lib/tab.dart')} import '\t\t\n/secret/s.dart' "
              'is not a declared input.',
          "guard-test: ${at('lib/ws.dart')} import '   \n/secret/s.dart' "
              'is not a declared input.',
        ]);
      });

      test('single-line triple-quoted URIs still resolve', () {
        tqFile('lib/clean.dart', "import '''ok.dart''';\n");
        tqFile('lib/cleanexp.dart', "export '''ok.dart''';\n");
        // An empty first line is dropped by the guard and the front end
        // alike, so this names the staged sibling, not the host.
        tqFile('lib/emptyfirst.dart', "import '''\nok.dart''';\n");
        final violations = findStagedDirectiveViolations([
          tq.path,
        ], tool: 'guard-test');
        expect(violations.where((v) => v.contains('clean')), isEmpty);
        expect(violations.where((v) => v.contains('emptyfirst')), isEmpty);
      });

      test('the summary runner still refuses multi-line URIs', () {
        // Dependency sources arrive through summaries, not the staged tree,
        // so the summary runner allows a relative target with no staged file
        // — but a URI spanning lines is refused however it spells its target.
        final allowed = findStagedDirectiveViolations(
          [tq.path],
          tool: 'guard-test',
          requireTargetsExist: false,
        );
        expect(allowed.where((v) => v.contains('missing.dart')), isEmpty);
        final wsAt = '${tq.path}/lib/ws.dart'.replaceAll(r'\', '/');
        expect(
          allowed,
          contains(
            "guard-test: $wsAt import '   \n/secret/s.dart' "
            'is not a declared input.',
          ),
        );
      });
    });
  });

  group('no staged-resolver copies', () {
    test('the wrapper imports the shared library instead of copying it', () {
      final sources = _toolSources(args);
      final text = File(sources['app_jit_snapshot.dart']!).readAsStringSync();
      expect(text, contains("import '../../guard/lib/directive_guard.dart';"));
      expect(text, isNot(contains('staged-resolver-mirror')));
      expect(text, isNot(contains('Mirror of `directive_guard.dart`')));
    });
  });

  group('unparsable prologues', () {
    // Each source hides an escaping directive past a syntax error, so the
    // scanner gives up: the checks refuse the file instead of calling it
    // clean. The first is the review's probe.
    const bad = [
      "import 'dart:core' if (dart.library.io) ;\n"
          "import '../../host/secret.dart';\n",
      "library a.;\nimport 'file:///etc/hosts';\n",
      "import 'a.dart;\nimport 'file:///etc/hosts';\n",
    ];

    test('findDisallowedDirectives refuses sources it cannot scan', () {
      for (var i = 0; i < bad.length; i++) {
        final errors = findDisallowedDirectives({
          'bad$i.dart': bad[i],
        }, tool: 'guard-test');
        expect(errors, hasLength(1));
        expect(errors.single, contains('bad$i.dart'));
        expect(errors.single, contains('could not be checked'));
        expect(errors.single, contains('syntax error'));
      }
    });

    test('findStagedDirectiveViolations refuses sources it cannot scan', () {
      final root = Directory('${tmp.path}/unparsable.proj')
        ..createSync(recursive: true);
      for (var i = 0; i < bad.length; i++) {
        File('${root.path}/bad$i.dart').writeAsStringSync(bad[i]);
      }
      final violations = findStagedDirectiveViolations([
        root.path,
      ], tool: 'guard-test');
      expect(violations, hasLength(bad.length));
      for (var i = 0; i < bad.length; i++) {
        expect(violations[i], contains('bad$i.dart'));
        expect(violations[i], contains('could not be checked'));
        expect(violations[i], contains('syntax error'));
      }
    });
  });

  group('valid prologues', () {
    test('scan the same directives as before', () {
      final cases = <String, List<String>>{
        '#!/usr/bin/env dart\nimport \'a.dart\';\n': ['a.dart'],
        '﻿import \'a.dart\';\n': ['a.dart'],
        'library;\nimport \'a.dart\';\n': ['a.dart'],
        'library a.b;\nimport \'a.dart\';\n': ['a.dart'],
        '@Tag(\'x\', (1)) library L;\nimport \'a.dart\';\n': ['a.dart'],
        '@Tag(\'x\') import \'a.dart\';\n': ['a.dart'],
        'import \'a.dart\' if (dart.library.io) \'io.dart\' '
            'if (dart.library.html == \'true\') \'html.dart\';\n': [
          'a.dart',
          'io.dart',
          'html.dart',
        ],
        'export \'a.dart\' if (dart.library.io) \'io.dart\';\n': [
          'a.dart',
          'io.dart',
        ],
        'import \'a.dart\' deferred as a show Foo hide Bar;\n': ['a.dart'],
        'import r\'a.dart\';\n': ['a.dart'],
        'import \'a.dart\' \'b.dart\';\n': ['a.dartb.dart'],
        'import \'\'\'a.dart\'\'\';\n': ['a.dart'],
        'part \'p.dart\';\npart of \'l.dart\';\n': ['p.dart', 'l.dart'],
        'part of my.lib;\n': [],
        '// c\n/* d */ import /* e */ \'a.dart\' /* f */ ; // g\n': ['a.dart'],
        'import \'a.dart\';\nvoid main() {}\nimport \'b.dart\';\n': ['a.dart'],
      };
      for (final entry in cases.entries) {
        expect(
          scanAllDirectiveUris(entry.key).map((r) => r.uri).toList(),
          entry.value,
          reason: entry.key,
        );
      }
    });
  });

  group('isEscapingPackageUri backslashes', () {
    test('backslash spellings climbing out escape', () {
      const escaping = [
        r'package:proj\..\..\host\secret.dart',
        r'package:proj\..%5c..%5chost%5csecret.dart',
        'package:proj%5c..%5c..%5chost%5csecret.dart',
        'package:proj%5C..%5C..%5Chost%5Csecret.dart',
        r'package:proj/..\..\host/secret.dart',
        r'package:\x.dart',
        'package:/x.dart',
      ];
      for (final uri in escaping) {
        expect(isEscapingPackageUri(uri), isTrue, reason: uri);
      }
    });

    test('backslash spellings staying inside do not escape', () {
      const inside = [
        r'package:proj\lib_file.dart',
        r'package:proj/a\..\b.dart',
      ];
      for (final uri in inside) {
        expect(isEscapingPackageUri(uri), isFalse, reason: uri);
      }
    });
  });

  group('every tool enforces the shared check', () {
    // Each Dart-reading tool and the marker proving it enforces the shared
    // staged-source check: the runners call it directly, the whole-program
    // gen_kernel wrapper scans through the shared library it imports, the
    // modular kernel planner resolves every directive through the shared file
    // it reads through `srcs`, and the builder shims import the shared library.
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
