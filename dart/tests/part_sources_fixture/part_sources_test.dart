import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:runfiles/runfiles.dart';
import 'package:same_pkg/parent.dart';
import 'package:same_pkg/rev_parent.dart';
import 'package:same_pkg/sib_parent.dart';
import 'package:test/test.dart';

void main(List<String> args) {
  test('sandboxed modular binary and dart_test execute split part libraries and match whole-program output', () async {
    expect(
      '${parentBanner()}|${revParentBanner()}|${sibParentBanner()}',
      'parent(uri-part-v1,named-part-v1)|rev_parent(rev-part-v1)|sib_parent(sib-part-v1)',
    );

    final runfiles = Runfiles.create();
    final modularDill = runfiles.rlocation(args[0]);
    final wholeDill = runfiles.rlocation(args[1]);

    final modularRes = await Process.run(Platform.resolvedExecutable, [
      modularDill,
    ]);
    expect(
      modularRes.exitCode,
      0,
      reason: 'modular binary failed: ${modularRes.stderr}',
    );

    final wholeRes = await Process.run(Platform.resolvedExecutable, [
      wholeDill,
    ]);
    expect(
      wholeRes.exitCode,
      0,
      reason: 'whole-program binary failed: ${wholeRes.stderr}',
    );

    final modularOut = (modularRes.stdout as String).replaceAll('\r\n', '\n');
    final wholeOut = (wholeRes.stdout as String).replaceAll('\r\n', '\n');
    expect(modularOut, equals(wholeOut));
    expect(
      modularOut,
      'parent(uri-part-v1,named-part-v1)|'
      'rev_parent(rev-part-v1)|'
      'sib_parent(sib-part-v1)\n',
    );
  });

  test('sandboxed and unsandboxed module outputs are byte-identical and editing parent or part changes rebuilt output', () async {
    final runfiles = Runfiles.create();
    final kernelModuleBin = runfiles.rlocation(args[2]);
    final kernelLinkBin = runfiles.rlocation(args[3]);
    final sdkDir = File(Platform.resolvedExecutable).parent.parent;
    final exeSuffix = Platform.isWindows ? '.exe' : '';
    final dartaotruntime = '${sdkDir.path}/bin/dartaotruntime$exeSuffix';
    final kernelWorker =
        '${sdkDir.path}/bin/snapshots/kernel_worker_aot.dart.snapshot';
    final platformDill = '${sdkDir.path}/lib/_internal/vm_platform_strong.dill';
    final librariesJson = '${sdkDir.path}/lib/libraries.json';

    final tmp = Directory.systemTemp.createTempSync('part_sources_edit_');
    try {
      void writeTo(Directory root, String rel, String text) {
        final f = File('${root.path}/$rel');
        f.parent.createSync(recursive: true);
        f.writeAsStringSync(text);
      }

      const prefix = 'org-dartlang-root:///';
      final packageConfigJson = jsonEncode({
        'configVersion': 2,
        'packages': [
          {
            'name': 'same_pkg',
            'rootUri': '${prefix}same_pkg',
            'packageUri': 'lib/',
          },
        ],
      });

      Future<ProcessResult> runKernelModule(
        Directory workRoot,
        Directory outDir,
        String name, {
        required List<String> sources,
        List<String> inputSources = const [],
        List<String> inputKmods = const [],
        List<String> closureExcluded = const [],
        bool noDrop = false,
      }) async {
        final pkgFile = File('${workRoot.path}/package_config.json');
        if (!pkgFile.existsSync()) {
          pkgFile.parent.createSync(recursive: true);
          pkgFile.writeAsStringSync(packageConfigJson);
        }
        final kmod = '${outDir.path}/$name.kmod';
        final koutline = '${outDir.path}/$name.koutline';
        final excluded = '${outDir.path}/$name.vm_excluded.txt';
        return Process.run(Platform.resolvedExecutable, [
          kernelModuleBin,
          '--dartaotruntime',
          dartaotruntime,
          '--kernel-worker',
          kernelWorker,
          '--target',
          'vm',
          '--dart-sdk-summary',
          platformDill,
          '--packages-file',
          pkgFile.path,
          '--libraries-json',
          librariesJson,
          '--multi-root',
          workRoot.path,
          '--multi-root-scheme',
          'org-dartlang-root',
          '--no-summary-only',
          '--exclude-non-sources',
          for (final dir in inputKmods) ...['--input-kmod', dir],
          for (final s in sources) ...['--source', s],
          for (final s in inputSources) ...['--input-source', s],
          '--output',
          kmod,
          if (!noDrop) ...['--output-outline', koutline],
          '--excluded-output',
          excluded,
          if (noDrop) '--no-drop',
          for (final c in closureExcluded) ...['--closure-excluded', c],
        ]);
      }

      Map<String, Uint8List> snapshotTree(Directory dir) {
        final result = <String, Uint8List>{};
        if (!dir.existsSync()) return result;
        final entities =
            dir.listSync(recursive: true).whereType<File>().toList()
              ..sort((a, b) => a.path.compareTo(b.path));
        for (final file in entities) {
          final rel = file.path.substring(dir.path.length + 1);
          result[rel] = file.readAsBytesSync();
        }
        return result;
      }

      Future<String> buildAll(
        Map<String, String> allFiles, {
        required bool sandboxed,
        required Directory outDir,
      }) async {
        if (outDir.existsSync()) outDir.deleteSync(recursive: true);
        outDir.createSync(recursive: true);

        Directory rootForStep(String stepName, List<String> declaredPaths) {
          if (!sandboxed) {
            final shared = Directory('${tmp.path}/unsandboxed_src');
            if (shared.existsSync()) shared.deleteSync(recursive: true);
            for (final e in allFiles.entries) {
              writeTo(shared, e.key, e.value);
            }
            return shared;
          }
          final box = Directory('${tmp.path}/sandbox_$stepName');
          if (box.existsSync()) box.deleteSync(recursive: true);
          for (final rel in declaredPaths) {
            writeTo(box, rel, allFiles[rel]!);
          }
          return box;
        }

        // 1. parent_lib: owns only parent.dart (parts are not declared).
        final rParent = await runKernelModule(
          rootForStep('parent_lib', ['same_pkg/lib/parent.dart']),
          outDir,
          'parent_lib',
          sources: ['package:same_pkg/parent.dart'],
        );
        expect(rParent.exitCode, 0, reason: '${rParent.stderr}');

        // 2. part_lib: owns uri_part.dart + named_part.dart, depends on parent_lib
        // (so parent.dart is a declared --input-source).
        final rPart = await runKernelModule(
          rootForStep('part_lib', [
            'same_pkg/lib/parent.dart',
            'same_pkg/lib/uri_part.dart',
            'same_pkg/lib/named_part.dart',
          ]),
          outDir,
          'part_lib',
          sources: [
            'package:same_pkg/uri_part.dart',
            'package:same_pkg/named_part.dart',
          ],
          inputSources: ['same_pkg/lib/parent.dart'],
          inputKmods: ['${outDir.path}/parent_lib.koutline'],
          closureExcluded: ['${outDir.path}/parent_lib.vm_excluded.txt'],
        );
        expect(rPart.exitCode, 0, reason: '${rPart.stderr}');

        // 3. rev_part_lib: owns only rev_part.dart (rev_parent.dart is not declared).
        final rRevPart = await runKernelModule(
          rootForStep('rev_part_lib', ['same_pkg/lib/rev_part.dart']),
          outDir,
          'rev_part_lib',
          sources: ['package:same_pkg/rev_part.dart'],
        );
        expect(rRevPart.exitCode, 0, reason: '${rRevPart.stderr}');

        // 4. rev_parent_lib: owns rev_parent.dart, depends on rev_part_lib
        // (so rev_part.dart is a declared --input-source).
        final rRevParent = await runKernelModule(
          rootForStep('rev_parent_lib', [
            'same_pkg/lib/rev_parent.dart',
            'same_pkg/lib/rev_part.dart',
          ]),
          outDir,
          'rev_parent_lib',
          sources: ['package:same_pkg/rev_parent.dart'],
          inputSources: ['same_pkg/lib/rev_part.dart'],
          inputKmods: ['${outDir.path}/rev_part_lib.koutline'],
          closureExcluded: ['${outDir.path}/rev_part_lib.vm_excluded.txt'],
        );
        expect(rRevParent.exitCode, 0, reason: '${rRevParent.stderr}');

        // 5. entry: compiles main.dart against the library modules.
        final rEntry = await runKernelModule(
          rootForStep('entry', [
            'main.dart',
            'same_pkg/lib/parent.dart',
            'same_pkg/lib/uri_part.dart',
            'same_pkg/lib/named_part.dart',
            'same_pkg/lib/rev_parent.dart',
            'same_pkg/lib/rev_part.dart',
          ]),
          outDir,
          'entry',
          sources: ['${prefix}main.dart'],
          inputSources: [
            'same_pkg/lib/parent.dart',
            'same_pkg/lib/uri_part.dart',
            'same_pkg/lib/named_part.dart',
            'same_pkg/lib/rev_parent.dart',
            'same_pkg/lib/rev_part.dart',
          ],
          inputKmods: [
            '${outDir.path}/parent_lib.koutline',
            '${outDir.path}/part_lib.koutline',
            '${outDir.path}/rev_part_lib.koutline',
            '${outDir.path}/rev_parent_lib.koutline',
          ],
          closureExcluded: [
            '${outDir.path}/parent_lib.vm_excluded.txt',
            '${outDir.path}/part_lib.vm_excluded.txt',
            '${outDir.path}/rev_part_lib.vm_excluded.txt',
            '${outDir.path}/rev_parent_lib.vm_excluded.txt',
          ],
          noDrop: true,
        );
        expect(rEntry.exitCode, 0, reason: '${rEntry.stderr}');

        final linkedDill = '${outDir.path}/app.dill';
        final linkRes = await Process.run(Platform.resolvedExecutable, [
          kernelLinkBin,
          linkedDill,
          '${outDir.path}/entry.kmod',
          '${outDir.path}/parent_lib.kmod',
          '${outDir.path}/part_lib.kmod',
          '${outDir.path}/rev_part_lib.kmod',
          '${outDir.path}/rev_parent_lib.kmod',
        ]);
        expect(
          linkRes.exitCode,
          0,
          reason: '${linkRes.stdout}\n${linkRes.stderr}',
        );

        final runRes = await Process.run(Platform.resolvedExecutable, [
          linkedDill,
        ]);
        expect(
          runRes.exitCode,
          0,
          reason: '${runRes.stdout}\n${runRes.stderr}',
        );
        return (runRes.stdout as String).replaceAll('\r\n', '\n').trim();
      }

      Map<String, String> filesV1({
        String parentTag = 'parent-v1',
        String uriPart = 'uri-part-v1',
        String namedPart = 'named-part-v1',
        String revParentTag = 'rev-parent-v1',
        String revPart = 'rev-part-v1',
      }) => {
        'same_pkg/lib/parent.dart':
            "library same_pkg.parent;\n"
            "part 'uri_part.dart';\n"
            "part 'named_part.dart';\n"
            "String parentBanner() => '$parentTag(\$uriPartValue,\$namedPartValue)';\n",
        'same_pkg/lib/uri_part.dart':
            "part of 'parent.dart';\n"
            "const String uriPartValue = '$uriPart';\n",
        'same_pkg/lib/named_part.dart':
            'part of same_pkg.parent;\n'
            "const String namedPartValue = '$namedPart';\n",
        'same_pkg/lib/rev_parent.dart':
            "library same_pkg.rev_parent;\n"
            "part 'rev_part.dart';\n"
            "String revParentBanner() => '$revParentTag(\$revPartValue)';\n",
        'same_pkg/lib/rev_part.dart':
            "part of 'rev_parent.dart';\n"
            "const String revPartValue = '$revPart';\n",
        'main.dart':
            "import 'package:same_pkg/parent.dart';\n"
            "import 'package:same_pkg/rev_parent.dart';\n"
            "void main() { print('\${parentBanner()}|\${revParentBanner()}'); }\n",
      };

      final sandboxedOut = Directory('${tmp.path}/out_sandboxed');
      final unsandboxedOut = Directory('${tmp.path}/out_unsandboxed');

      final stdoutSandboxed = await buildAll(
        filesV1(),
        sandboxed: true,
        outDir: sandboxedOut,
      );
      final stdoutUnsandboxed = await buildAll(
        filesV1(),
        sandboxed: false,
        outDir: unsandboxedOut,
      );
      expect(
        stdoutSandboxed,
        'parent-v1(uri-part-v1,named-part-v1)|rev-parent-v1(rev-part-v1)',
      );
      expect(stdoutUnsandboxed, equals(stdoutSandboxed));

      // Verify byte-identical outputs between sandboxed and unsandboxed builds.
      final sandboxedTree = snapshotTree(sandboxedOut);
      final unsandboxedTree = snapshotTree(unsandboxedOut);
      expect(unsandboxedTree.keys, equals(sandboxedTree.keys));
      for (final key in sandboxedTree.keys) {
        expect(
          unsandboxedTree[key],
          equals(sandboxedTree[key]),
          reason:
              'sandboxed and unsandboxed output must be byte-identical for $key',
        );
      }

      // Verify that `part_lib.kmod/0.dill` and `rev_parent_lib.kmod/0.dill`
      // were produced and `rev_part_lib.kmod` did NOT read `rev_parent.dart` from disk.
      expect(sandboxedTree.containsKey('part_lib.kmod/0.dill'), isTrue);
      expect(sandboxedTree.containsKey('rev_parent_lib.kmod/0.dill'), isTrue);
      expect(sandboxedTree.containsKey('rev_part_lib.kmod/0.dill'), isFalse);

      final partLibDillV1 = sandboxedTree['part_lib.kmod/0.dill']!;
      final appDillV1 = sandboxedTree['app.dill']!;

      // Edit the parent library (`parent.dart`) and rebuild: `part_lib.kmod/0.dill`
      // and `app.dill` must change and reflect the edit.
      final editedParentOut = Directory('${tmp.path}/out_edited_parent');
      final stdoutEditedParent = await buildAll(
        filesV1(parentTag: 'parent-v2-edited'),
        sandboxed: true,
        outDir: editedParentOut,
      );
      expect(
        stdoutEditedParent,
        'parent-v2-edited(uri-part-v1,named-part-v1)|rev-parent-v1(rev-part-v1)',
      );
      final editedParentTree = snapshotTree(editedParentOut);
      expect(
        editedParentTree['part_lib.kmod/0.dill'],
        isNot(equals(partLibDillV1)),
        reason: 'editing parent.dart must change part_lib.kmod/0.dill',
      );
      expect(
        editedParentTree['app.dill'],
        isNot(equals(appDillV1)),
        reason: 'editing parent.dart must change linked app.dill',
      );

      // Edit the part (`rev_part.dart`) and rebuild: `rev_parent_lib.kmod/0.dill`
      // and `app.dill` must change and reflect the edit.
      final editedPartOut = Directory('${tmp.path}/out_edited_part');
      final stdoutEditedPart = await buildAll(
        filesV1(revPart: 'rev-part-v2-edited'),
        sandboxed: true,
        outDir: editedPartOut,
      );
      expect(
        stdoutEditedPart,
        'parent-v1(uri-part-v1,named-part-v1)|rev-parent-v1(rev-part-v2-edited)',
      );
      final editedPartTree = snapshotTree(editedPartOut);
      expect(
        editedPartTree['rev_parent_lib.kmod/0.dill'],
        isNot(equals(sandboxedTree['rev_parent_lib.kmod/0.dill'])),
        reason: 'editing rev_part.dart must change rev_parent_lib.kmod/0.dill',
      );
    } finally {
      tmp.deleteSync(recursive: true);
    }
  });
}
