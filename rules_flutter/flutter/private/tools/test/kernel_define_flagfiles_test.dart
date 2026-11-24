// Tagged `runfiles`: the code under test imports `package:rules_dart_guard`,
// which Bazel supplies via the `@rules_dart//dart/guard:directive_guard` dep
// its `dart_test` declares. A bare `dart test` resolves only this package's
// pubspec, where that import does not exist, so the file fails to load rather
// than failing a test.
// Coverage comes from //flutter/private/tools:kernel_define_flagfiles_test.
@Tags(['runfiles'])
library;

import 'dart:io';

import 'package:test/test.dart';

import '../kernel_filter.dart';

void main() {
  group('define flagfiles', () {
    late Directory dir;
    late Directory savedCwd;

    setUp(() {
      savedCwd = Directory.current;
      dir = Directory.systemTemp.createTempSync('kernel_define_flagfiles_');
      Directory.current = dir.path;
    });
    tearDown(() {
      Directory.current = savedCwd.path;
      dir.deleteSync(recursive: true);
    });

    File writeFlagfile(String name, List<String> lines) {
      return File('${dir.path}/$name')
        ..writeAsStringSync('${lines.join('\n')}\n');
    }

    String writeManifest() {
      final manifest = File('${dir.path}/inputs.manifest');
      manifest.writeAsStringSync(
        [
          'lib/main.dart',
          '# staged',
          '# allowed-reads',
          '# filesystem-roots',
          '.',
          '# entrypoint',
          'lib/main.dart',
          '# output',
          'out.dill',
        ].join('\n'),
      );
      return manifest.path;
    }

    Future<({int code, String out, String err})> runCompiler(
      File script,
      List<String> args,
    ) async {
      final out = StringBuffer();
      final err = StringBuffer();
      final int code = await runFiltered(
        [
          '--declared-inputs',
          writeManifest(),
          '--',
          Platform.resolvedExecutable,
          script.path,
          ...args,
        ],
        out,
        err,
      );
      return (code: code, out: '$out', err: '$err');
    }

    File writeCompiler(File record) {
      return File('${dir.path}/record_compiler.dart')..writeAsStringSync(
        'import "dart:io";\n'
        'void main(List<String> argv) {\n'
        '  File(r"${record.path}").writeAsStringSync(argv.join("\\n"));\n'
        '  stdout.writeln("+file://${dir.path}/lib/main.dart");\n'
        '}\n',
      );
    }

    test('expands one argument per non-empty line, preserving text', () {
      final File flagfile = writeFlagfile('defines.flags', [
        '-DAPI_KEY=one',
        '',
        "-DNAME='two words'",
      ]);
      expect(
        expandDefineFlagfiles(['--x', '@${flagfile.path}', '--y']),
        ['--x', '-DAPI_KEY=one', "-DNAME='two words'", '--y'],
      );
    });

    test('expands a nested flagfile recursively', () {
      final File nested = writeFlagfile('nested.flags', ['-DSECOND=two']);
      final File outer = writeFlagfile('outer.flags', [
        '-DFIRST=one',
        '@${nested.path}',
      ]);
      expect(expandDefineFlagfiles(['@${outer.path}']), [
        '-DFIRST=one',
        '-DSECOND=two',
      ]);
    });

    test('a fake compiler sees two flagfile defines in order', () async {
      File('${dir.path}/lib/main.dart')
        ..createSync(recursive: true)
        ..writeAsStringSync('void main() {}\n');
      final record = File('${dir.path}/compiler.argv');
      final File script = writeCompiler(record);
      final File flagfile = writeFlagfile('defines.flags', [
        '-DAPI_KEY=one',
        '-DSECOND=two',
      ]);
      final ({int code, String out, String err}) result = await runCompiler(
        script,
        [
          '@${flagfile.path}',
          'entry.dart',
        ],
      );
      expect(result.code, 0, reason: result.err);
      final List<String> argv = record.readAsLinesSync();
      expect(
        argv,
        containsAllInOrder(['-DAPI_KEY=one', '-DSECOND=two']),
      );
    });

    test(
      'a non-define line fails before the compiler names file and line',
      () async {
        File('${dir.path}/lib/main.dart')
          ..createSync(recursive: true)
          ..writeAsStringSync('void main() {}\n');
        final invoked = File('${dir.path}/compiler.invoked');
        final script = File('${dir.path}/record_compiler.dart')
          ..writeAsStringSync(
            'import "dart:io";\n'
            'void main() {\n'
            '  File(r"${invoked.path}").writeAsStringSync("ran");\n'
            '}\n',
          );
        final File flagfile = writeFlagfile('bad.flags', [
          '-DOK=1',
          'NOT_A_DEFINE',
        ]);
        final ({int code, String out, String err}) result = await runCompiler(
          script,
          ['@${flagfile.path}'],
        );
        expect(result.code, 2);
        expect(result.err, contains(flagfile.path));
        expect(result.err, contains('line 2'));
        expect(invoked.existsSync(), isFalse);
      },
    );

    test('naming a missing flagfile fails with its path', () {
      final missing = File('${dir.path}/missing.flags');
      expect(
        () => expandDefineFlagfiles(['@${missing.path}']),
        throwsA(
          predicate(
            (Object? error) =>
                error is FormatException &&
                error.message.contains(missing.path),
            'names the missing flagfile',
          ),
        ),
      );
    });

    test('an unreadable flagfile fails with the chain', () {
      expect(
        () => expandDefineFlagfiles(
          ['@${dir.path}/first.flags'],
          readFile: (path) => throw FileSystemException('denied', path),
        ),
        throwsA(
          predicate(
            (Object? error) =>
                error is FormatException &&
                error.message.contains('first.flags') &&
                error.message.contains('denied'),
            'names the unreadable file and the chain',
          ),
        ),
      );
    });

    test('a cycle fails naming the chain of files', () {
      final File first = writeFlagfile('first.flags', [
        '@${dir.path}/second.flags',
      ]);
      final File second = writeFlagfile('second.flags', [
        '@${dir.path}/first.flags',
      ]);
      expect(
        () => expandDefineFlagfiles(['@${first.path}']),
        throwsA(
          predicate(
            (Object? error) =>
                error is FormatException &&
                error.message.contains('cycle') &&
                error.message.contains(first.path) &&
                error.message.contains(second.path),
            'names the cycle chain',
          ),
        ),
      );
    });
  });

  group('kernelMountContract', () {
    // Goal G pins in plain unit tests what the contract guarantees: the
    // mount order (the stage, then the exec root, then the filesystem_roots),
    // where the entrypoint resolves now (in the exec root, not the stage),
    // and the fail-closed report checks. The behavioral suites above prove
    // each check fires; these pin the shape they check.
    KernelInputsManifest readLines(List<String> lines) {
      final Directory dir = Directory.systemTemp.createTempSync(
        'contract_manifest_',
      );
      addTearDown(() => dir.deleteSync(recursive: true));
      File('${dir.path}/manifest.txt').writeAsStringSync(lines.join('\n'));
      return readKernelInputsManifest('${dir.path}/manifest.txt');
    }

    test('the manifest keeps the stage-exec-roots mount order', () {
      final KernelInputsManifest manifest = readLines([
        'lib/main.dart',
        '# staged',
        'gen.stage/gen/foo.dart',
        '# allowed-reads',
        'pkg_config.json',
        '# filesystem-roots',
        'gen.stage',
        '.',
        'sdk-root',
        '# entrypoint',
        'lib/main.dart',
        '# output',
        'out/app.dill',
      ]);
      expect(manifest.fsRoots, ['gen.stage', '.', 'sdk-root']);
      expect(manifest.entrypoint, ['lib/main.dart']);
    });

    test('entrypoint candidates prefer the explicit section', () {
      final KernelInputsManifest manifest = readLines([
        'lib/main.dart',
        '# entrypoint',
        'lib/main.dart',
        'gen.stage/lib/main.dart',
      ]);
      expect(
        entrypointSpellingCandidates(manifest),
        ['lib/main.dart', 'gen.stage/lib/main.dart'],
      );
    });

    test('entrypoint candidates fall back to the first source', () {
      final KernelInputsManifest manifest = readLines([
        'lib/main.dart',
        'lib/a.dart',
      ]);
      expect(entrypointSpellingCandidates(manifest), ['lib/main.dart']);
    });

    test('the fail-closed messages name the check', () {
      expect(noDeclaredSourceReadsMessage(), contains('declared source'));
      expect(
        missingEntrypointReadMessage('lib/main.dart'),
        contains('lib/main.dart'),
      );
    });
  });
}
