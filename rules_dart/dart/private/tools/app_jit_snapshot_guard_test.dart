// Tests for the compile wrapper's one-pass guards and its AOT build (see
// `app_jit_snapshot.dart`, and `//dart/private/tools:compile_wrapper`).
//
// The directive scan reads each declared source once and the read-set check
// reads the output once; every refusal keeps its text. The AOT snapshot the
// `exe` and `aot-snapshot` actions run compiles the same bytes as the tool
// run from source, which the `jit-snapshot` training still does.
import 'dart:io';
import 'dart:typed_data';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

import 'app_jit_snapshot.dart' as snapshot;
import 'app_jit_snapshot_test_support.dart';

void main(List<String> args) {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('wrapper_guard_'));
  tearDown(() {
    if (!Platform.isWindows) {
      for (final FileSystemEntity entity in tmp.listSync(recursive: true)) {
        if (entity is! Link) snapshot.chmodFile(entity.path, 0x1ed);
      }
    }
    tmp.deleteSync(recursive: true);
  });

  File write(String name, String text) =>
      File('${tmp.path}/$name')..writeAsStringSync(text);

  group('directive scan', () {
    test('a forbidden directive still fails with its message', () {
      final File main = write('main.dart', "import 'file:///etc/passwd';\n");
      const refusal = "import 'file:///etc/passwd' is not a declared input.";
      expect(snapshot.scanGenKernelDirectives([main.path], const ['.']), [
        'app_jit_snapshot: ${main.path} $refusal',
      ]);
    });

    test('visits each source exactly once', () {
      final File main = write(
        'main.dart',
        "import 'a.dart';\nimport 'b.dart';\n",
      );
      final File a = write('a.dart', "import 'b.dart';\n");
      final File b = write('b.dart', 'void b() {}\n');
      final reads = <String, int>{};
      final List<String> errors = snapshot.scanGenKernelDirectives(
        [main.path, a.path, b.path],
        const ['.'],
        readSource: (String path) {
          reads[path] = (reads[path] ?? 0) + 1;
          return File(path).readAsBytesSync();
        },
      );
      expect(errors, isEmpty);
      expect(reads, {main.path: 1, a.path: 1, b.path: 1});
    });

    test('an unreadable source is left to gen_kernel, not scanned twice', () {
      final File main = write('main.dart', "import 'file:///etc/passwd';\n");
      var reads = 0;
      final List<String> errors = snapshot.scanGenKernelDirectives(
        [main.path],
        const ['.'],
        readSource: (String path) {
          reads++;
          throw FileSystemException('unreadable', path);
        },
      );
      expect(errors, isEmpty);
      expect(reads, 1);
    });
  });

  group('read-set verification', () {
    const prefix = 'org-dartlang-root:///';

    List<String> verify(File out) => snapshot.verifyGenKernelReads(
      outputPath: out.path,
      declaredKeys: const {'app/main.dart'},
      multiRootPrefix: prefix,
      fsRoots: const ['.'],
      packageKeyPrefixes: const {},
      hasNativeAssetsManifest: false,
    );

    test('an undeclared read in the output still fails', () {
      final out = File('${tmp.path}/dirty.dill')
        ..writeAsBytesSync(
          verifyDill(
            sources: [
              ('${prefix}app/main.dart', '${prefix}app/main.dart'),
              ('file:///host/evil.dart', 'file:///host/evil.dart'),
            ],
            libraries: [(0, '${prefix}app/main.dart')],
          ),
        );
      expect(verify(out).join('\n'), contains('reads file:///host/evil.dart'));
    });

    test('an unreadable output still fails closed with its message', () {
      final out = File('${tmp.path}/locked.dill')
        ..writeAsBytesSync(Uint8List(8));
      snapshot.chmodFile(out.path, 0);
      var readable = true;
      try {
        out.readAsBytesSync();
      } on FileSystemException {
        readable = false;
      }
      if (readable) {
        markTestSkipped('the user reads files regardless of their mode');
        return;
      }
      final String path = out.path;
      expect(verify(out), [
        'app_jit_snapshot: cannot read the kernel output at $path; refusing the compile.',
      ]);
    });
  }, skip: Platform.isWindows ? 'POSIX file modes' : false);

  test(
    'the AOT wrapper compiles the same bytes as the tool run from source',
    () {
      final Directory sdk = File(Platform.resolvedExecutable).parent.parent;
      final dartaotruntime = '${sdk.path}/bin/dartaotruntime';
      final String wrapper = Runfiles.create().rlocation(args.first);
      final File main = write('main.dart', 'void main() => print(1 + 2);\n');
      write('package_config.json', '{"configVersion": 2, "packages": []}\n');
      List<String> genKernel(String out) => [
        '--gen-kernel',
        dartaotruntime,
        '--input-source=${main.path}',
        '${sdk.path}/bin/snapshots/gen_kernel_aot.dart.snapshot',
        '--platform',
        '${sdk.path}/lib/_internal/vm_platform_product.dill',
        '--packages',
        '${tmp.path}/package_config.json',
        '--aot',
        '--tfa',
        '-Ddart.vm.product=true',
        '-o',
        out,
        main.path,
      ];
      snapshot.main(genKernel('${tmp.path}/base.dill'));
      final ProcessResult aot = Process.runSync(dartaotruntime, [
        wrapper,
        ...genKernel('${tmp.path}/aot.dill'),
      ]);
      expect(aot.exitCode, 0, reason: '${aot.stdout}\n${aot.stderr}');
      final Uint8List base = File('${tmp.path}/base.dill').readAsBytesSync();
      expect(base, isNotEmpty);
      expect(File('${tmp.path}/aot.dill').readAsBytesSync(), base);

      // The snapshot names its own output path inside, so both compiles write
      // the same path: the first is kept aside before the second runs.
      final compile = [
        '--aot',
        '--dart=${Platform.resolvedExecutable}',
        '--mode=aot-snapshot',
        '--verbosity=error',
        '-o',
        '${tmp.path}/app.aot',
        '${tmp.path}/base.dill',
      ];
      snapshot.main(compile);
      final Uint8List baseAot = File('${tmp.path}/app.aot').readAsBytesSync();
      File('${tmp.path}/app.aot').deleteSync();
      expect(baseAot, isNotEmpty);
      final ProcessResult built = Process.runSync(dartaotruntime, [
        wrapper,
        ...compile,
      ]);
      expect(built.exitCode, 0, reason: '${built.stdout}\n${built.stderr}');
      expect(File('${tmp.path}/app.aot').readAsBytesSync(), baseAot);
    },
    skip: Platform.isWindows ? 'POSIX-only SDK layout' : false,
  );
}
