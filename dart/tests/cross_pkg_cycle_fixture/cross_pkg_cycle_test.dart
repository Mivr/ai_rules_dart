import 'dart:convert';
import 'dart:io';

import 'package:pkg_a/a_top.dart';
import 'package:pkg_b/b.dart';
import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

void main(List<String> args) {
  test('sandboxed modular binary and dart_test execute cross-package cycle and match whole-program output', () async {
    expect(
      '${aTopValue()}|${bValue()}',
      'a_top(b(a_base(leaf-v1),a_top_tag),a_base(leaf-v1))|b(a_base(leaf-v1),a_top_tag)',
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
      'a_top(b(a_base(leaf-v1),a_top_tag),a_base(leaf-v1))|'
      'b(a_base(leaf-v1),a_top_tag)\n',
    );
  });

  test('editing an excluded dependency source changes the rebuilt entry and linked kernel output', () async {
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

    final tmp = Directory.systemTemp.createTempSync('cross_pkg_cycle_edit_');
    try {
      void write(String rel, String text) {
        final f = File('${tmp.path}/$rel');
        f.parent.createSync(recursive: true);
        f.writeAsStringSync(text);
      }

      const prefix = 'org-dartlang-root:///';
      write(
        'package_config.json',
        jsonEncode({
          'configVersion': 2,
          'packages': [
            for (final name in ['pkg_leaf', 'pkg_a', 'pkg_b'])
              {'name': name, 'rootUri': '$prefix$name', 'packageUri': 'lib/'},
          ],
        }),
      );
      write('pkg_leaf/lib/leaf.dart', "String leafGreeting() => 'leaf-v1';\n");
      write(
        'pkg_a/lib/a_base.dart',
        "import 'package:pkg_leaf/leaf.dart';\n"
            "String aBaseValue() => 'a_base(\${leafGreeting()})';\n",
      );
      write(
        'pkg_b/lib/b.dart',
        "import 'package:pkg_a/a_base.dart';\n"
            "import 'package:pkg_a/a_top.dart';\n"
            "String bValue() => 'b-v1(\${aBaseValue()},\${aTopTag()})';\n",
      );
      write(
        'pkg_a/lib/a_top.dart',
        "import 'package:pkg_a/a_base.dart';\n"
            "import 'package:pkg_b/b.dart';\n"
            "String aTopTag() => 'tag-v1';\n"
            "String aTopValue() => 'a_top(\${bValue()},\${aBaseValue()})';\n",
      );
      write(
        'main.dart',
        "import 'package:pkg_a/a_top.dart';\n"
            "import 'package:pkg_b/b.dart';\n"
            "void main() { print('\${aTopValue()}|\${bValue()}'); }\n",
      );

      Future<ProcessResult> runKernelModule(
        String name, {
        required List<String> sources,
        List<String> inputSources = const [],
        List<String> inputKmods = const [],
        List<String> closureExcluded = const [],
        bool noDrop = false,
      }) async {
        final kmod = '${tmp.path}/out/$name.kmod';
        final koutline = '${tmp.path}/out/$name.koutline';
        final excluded = '${tmp.path}/out/$name.vm_excluded.txt';
        return Process.run(dartaotruntime, [
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
          '${tmp.path}/package_config.json',
          '--libraries-json',
          librariesJson,
          '--multi-root',
          tmp.path,
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

      Future<String> buildAndRun({required bool passDeclaredInputs}) async {
        for (final step in [
          await runKernelModule(
            'leaf',
            sources: ['package:pkg_leaf/leaf.dart'],
          ),
          await runKernelModule(
            'a_base',
            sources: ['package:pkg_a/a_base.dart'],
            inputKmods: ['${tmp.path}/out/leaf.koutline'],
            closureExcluded: ['${tmp.path}/out/leaf.vm_excluded.txt'],
          ),
          await runKernelModule(
            'b',
            sources: ['package:pkg_b/b.dart'],
            inputKmods: [
              '${tmp.path}/out/leaf.koutline',
              '${tmp.path}/out/a_base.koutline',
            ],
            closureExcluded: [
              '${tmp.path}/out/leaf.vm_excluded.txt',
              '${tmp.path}/out/a_base.vm_excluded.txt',
            ],
          ),
          await runKernelModule(
            'a_top',
            sources: ['package:pkg_a/a_top.dart'],
            inputKmods: [
              '${tmp.path}/out/leaf.koutline',
              '${tmp.path}/out/a_base.koutline',
              '${tmp.path}/out/b.koutline',
            ],
            closureExcluded: [
              '${tmp.path}/out/leaf.vm_excluded.txt',
              '${tmp.path}/out/a_base.vm_excluded.txt',
              '${tmp.path}/out/b.vm_excluded.txt',
            ],
          ),
        ]) {
          expect(step.exitCode, 0, reason: '${step.stdout}\n${step.stderr}');
        }

        final entryRes = await runKernelModule(
          'entry',
          sources: ['${prefix}main.dart'],
          inputSources: passDeclaredInputs
              ? const [
                  'pkg_a/lib/a_base.dart',
                  'pkg_b/lib/b.dart',
                  'pkg_a/lib/a_top.dart',
                ]
              : const [],
          inputKmods: [
            '${tmp.path}/out/leaf.koutline',
            '${tmp.path}/out/a_base.koutline',
            if (passDeclaredInputs) '${tmp.path}/out/b.koutline',
            if (passDeclaredInputs) '${tmp.path}/out/a_top.koutline',
          ],
          closureExcluded: [
            '${tmp.path}/out/leaf.vm_excluded.txt',
            '${tmp.path}/out/a_base.vm_excluded.txt',
            '${tmp.path}/out/b.vm_excluded.txt',
            '${tmp.path}/out/a_top.vm_excluded.txt',
          ],
          noDrop: true,
        );
        if (!passDeclaredInputs) {
          expect(entryRes.exitCode, isNonZero);
          return '${entryRes.stderr}';
        }
        expect(
          entryRes.exitCode,
          0,
          reason: '${entryRes.stdout}\n${entryRes.stderr}',
        );

        final linkedDill = '${tmp.path}/out/app.dill';
        final linkRes = await Process.run(Platform.resolvedExecutable, [
          kernelLinkBin,
          linkedDill,
          '${tmp.path}/out/entry.kmod',
          '${tmp.path}/out/leaf.kmod',
          '${tmp.path}/out/a_base.kmod',
          '${tmp.path}/out/b.kmod',
          '${tmp.path}/out/a_top.kmod',
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

      // 1. Without declared input sources (or staged outline inputs), entry module fails clearly.
      final failLog = await buildAndRun(passDeclaredInputs: false);
      expect(failLog, contains('source is not a declared input.'));

      // 2. With declared input sources, build and run succeeds (v1).
      final outV1 = await buildAndRun(passDeclaredInputs: true);
      expect(
        outV1,
        'a_top(b-v1(a_base(leaf-v1),tag-v1),a_base(leaf-v1))|b-v1(a_base(leaf-v1),tag-v1)',
      );
      final entryBytesV1 = File('${tmp.path}/out/entry.kmod/entry.dill')
          .readAsBytesSync();
      final linkedBytesV1 = File('${tmp.path}/out/app.dill').readAsBytesSync();

      // 3. Edit the excluded dependency file pkg_b/lib/b.dart and rebuild:
      // output bytes and runtime stdout must reflect the edit.
      write(
        'pkg_b/lib/b.dart',
        "import 'package:pkg_a/a_base.dart';\n"
            "import 'package:pkg_a/a_top.dart';\n"
            "String bValue() => 'b-v2-edited(\${aBaseValue()},\${aTopTag()})';\n",
      );
      final outV2 = await buildAndRun(passDeclaredInputs: true);
      expect(
        outV2,
        'a_top(b-v2-edited(a_base(leaf-v1),tag-v1),a_base(leaf-v1))|b-v2-edited(a_base(leaf-v1),tag-v1)',
      );
      final entryBytesV2 = File('${tmp.path}/out/entry.kmod/entry.dill')
          .readAsBytesSync();
      final linkedBytesV2 = File('${tmp.path}/out/app.dill').readAsBytesSync();
      expect(entryBytesV2, isNot(equals(entryBytesV1)));
      expect(linkedBytesV2, isNot(equals(linkedBytesV1)));
    } finally {
      tmp.deleteSync(recursive: true);
    }
  });
}
