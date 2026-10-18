import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'app_jit_snapshot.dart' as snapshot;

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('app_jit_snapshot_test_');
  });

  tearDown(() {
    if (!Platform.isWindows) {
      for (final entity in tmp.listSync(recursive: true)) {
        if (entity is File) {
          snapshot.chmodFile(entity.path, 0x1ed);
        }
      }
    }
    tmp.deleteSync(recursive: true);
  });

  for (final mode in [0x124 /* 0444 */, 0x16d /* 0555 */]) {
    final octal = mode.toRadixString(8).padLeft(4, '0');
    test(
      'writeAppAotElfExe writes an executable output when runtime input has mode $octal',
      () {
        final runtimeBytes = Uint8List.fromList([
          0x7f,
          0x45,
          0x4c,
          0x46,
          for (var i = 0; i < 100; i++) (i * 7) & 0xff,
        ]);
        final elfBytes = Uint8List.fromList([
          for (var i = 0; i < 250; i++) (i * 13 + 3) & 0xff,
        ]);

        final runtime = File('${tmp.path}/dartaotruntime')
          ..writeAsBytesSync(runtimeBytes);
        final elf = File('${tmp.path}/snapshot.elf')
          ..writeAsBytesSync(elfBytes);
        snapshot.chmodFile(runtime.path, mode);
        snapshot.chmodFile(elf.path, 0x124);

        final output = File('${tmp.path}/out/bin/tool');
        snapshot.writeAppAotElfExe(
          dartaotruntime: runtime,
          snapshotElf: elf,
          output: output,
        );

        expect(output.existsSync(), isTrue);
        if (!Platform.isWindows) {
          expect(output.statSync().mode & 0x1ff, 0x1ed);
        }

        final written = output.readAsBytesSync();
        const pageSize = 65536;
        final expectedOffset = pageSize;
        expect(written.length, expectedOffset + elfBytes.length + 16);
        expect(written.sublist(0, runtimeBytes.length), runtimeBytes);
        expect(
          written.sublist(runtimeBytes.length, expectedOffset),
          everyElement(0),
        );
        expect(
          written.sublist(expectedOffset, expectedOffset + elfBytes.length),
          elfBytes,
        );

        final trailer = ByteData.sublistView(
          written,
          written.length - 16,
          written.length,
        );
        expect(trailer.getUint64(0, Endian.little), expectedOffset);
        expect(written.sublist(written.length - 8), [
          0xdc,
          0xdc,
          0xf6,
          0xf6,
          0x00,
          0x00,
          0x00,
          0x00,
        ]);
      },
    );
  }

  test('writeAppAotElfExe replaces a pre-existing read-only output file', () {
    final runtime = File('${tmp.path}/dartaotruntime')
      ..writeAsBytesSync([0x7f, 0x45, 0x4c, 0x46, 1, 2, 3]);
    final elf = File('${tmp.path}/snapshot.elf')..writeAsBytesSync([4, 5, 6]);
    final output = File('${tmp.path}/out/tool')..createSync(recursive: true);
    output.writeAsBytesSync([9, 9, 9]);
    snapshot.chmodFile(runtime.path, 0x16d);
    snapshot.chmodFile(output.path, 0x124);

    snapshot.writeAppAotElfExe(
      dartaotruntime: runtime,
      snapshotElf: elf,
      output: output,
    );

    expect(output.existsSync(), isTrue);
    if (!Platform.isWindows) {
      expect(output.statSync().mode & 0x1ff, 0x1ed);
    }
    expect(output.lengthSync(), 65536 + 3 + 16);
  });

  test('--gen-kernel preserves comma-containing defines in compiled dill', () {
    final sdkDir = File(Platform.resolvedExecutable).parent.parent;
    final exeSuffix = Platform.isWindows ? '.exe' : '';
    final dartaotruntime = '${sdkDir.path}/bin/dartaotruntime$exeSuffix';
    final genKernel =
        '${sdkDir.path}/bin/snapshots/gen_kernel_aot.dart.snapshot';
    final platformDill = '${sdkDir.path}/lib/_internal/vm_platform_strong.dill';

    final pkgConfig = File('${tmp.path}/package_config.json')
      ..writeAsStringSync('{"configVersion": 2, "packages": []}\n');
    final mainDart = File('${tmp.path}/main.dart')
      ..writeAsStringSync(
        'void main() {\n'
        "  print(const String.fromEnvironment('COMMA_VAL', defaultValue: 'UNSET'));\n"
        '}\n',
      );
    final outDill = File('${tmp.path}/out.dill');

    snapshot.main([
      '--gen-kernel',
      dartaotruntime,
      genKernel,
      '--platform',
      platformDill,
      '--packages',
      pkgConfig.path,
      '-DCOMMA_VAL=a,b',
      '-o',
      outDill.path,
      mainDart.path,
    ]);

    expect(outDill.existsSync(), isTrue);
    final runRes = Process.runSync(Platform.resolvedExecutable, [outDill.path]);
    expect(runRes.exitCode, 0, reason: '${runRes.stdout}\n${runRes.stderr}');
    expect((runRes.stdout as String).trim(), 'a,b');
  });

  test('--aot preserves --enable-asserts in exe and aot-snapshot modes with and without --recorded-uses', () {
    if (Platform.isWindows) return;
    final sdkDir = File(Platform.resolvedExecutable).parent.parent;
    final dartBin = '${sdkDir.path}/bin/dart';
    final dartaotruntime = '${sdkDir.path}/bin/dartaotruntime';
    final genKernel =
        '${sdkDir.path}/bin/snapshots/gen_kernel_aot.dart.snapshot';
    final productPlatform =
        '${sdkDir.path}/lib/_internal/vm_platform_product.dill';
    final strongPlatform =
        '${sdkDir.path}/lib/_internal/vm_platform_strong.dill';
    final platformDill = File(productPlatform).existsSync()
        ? productPlatform
        : strongPlatform;

    final pkgConfig = File('${tmp.path}/package_config.json')
      ..writeAsStringSync('{"configVersion": 2, "packages": []}\n');
    final mainDart = File('${tmp.path}/assert_main.dart')
      ..writeAsStringSync(
        'void main(List<String> args) {\n'
        '  var ran = false;\n'
        '  assert(() {\n'
        '    ran = true;\n'
        '    return true;\n'
        '  }());\n'
        '  if (!ran) {\n'
        "    throw StateError('assert body was stripped');\n"
        '  }\n'
        "  assert(args.isEmpty, 'aot_assert_triggered');\n"
        '}\n',
      );
    final inDill = File('${tmp.path}/assert_main.dill');

    final gkRes = Process.runSync(dartaotruntime, [
      genKernel,
      '--platform=$platformDill',
      '--packages=${pkgConfig.path}',
      '-Ddart.vm.product=true',
      '-Ddart.vm.asan=false',
      '-Ddart.vm.msan=false',
      '-Ddart.vm.tsan=false',
      '--aot',
      '--tfa',
      '--no-embed-sources',
      '--enable-asserts',
      '-o',
      inDill.path,
      mainDart.path,
    ]);
    expect(gkRes.exitCode, 0, reason: '${gkRes.stdout}\n${gkRes.stderr}');

    // 1. exe mode with --enable-asserts (no --recorded-uses)
    final outExe = File('${tmp.path}/out_exe');
    snapshot.main([
      '--aot',
      '--dart=$dartBin',
      '--mode=exe',
      '--enable-asserts',
      '-o',
      outExe.path,
      inDill.path,
    ]);
    expect(outExe.existsSync(), isTrue);
    final exePass = Process.runSync(outExe.path, const []);
    expect(exePass.exitCode, 0, reason: '${exePass.stderr}');
    final exeFail = Process.runSync(outExe.path, const ['--fail']);
    expect(exeFail.exitCode, isNot(0));
    expect(exeFail.stderr as String, contains('aot_assert_triggered'));

    // 2. exe mode with --enable-asserts AND --recorded-uses
    final outExeRecorded = File('${tmp.path}/out_exe_recorded');
    final recordedUsesExe = File('${tmp.path}/exe.recorded_uses.json');
    snapshot.main([
      '--aot',
      '--dart=$dartBin',
      '--mode=exe',
      '--enable-asserts',
      '--recorded-uses=${recordedUsesExe.path}',
      '-o',
      outExeRecorded.path,
      inDill.path,
    ]);
    expect(outExeRecorded.existsSync(), isTrue);
    expect(recordedUsesExe.existsSync(), isTrue);
    final exeRecPass = Process.runSync(outExeRecorded.path, const []);
    expect(exeRecPass.exitCode, 0, reason: '${exeRecPass.stderr}');
    final exeRecFail = Process.runSync(outExeRecorded.path, const ['--fail']);
    expect(exeRecFail.exitCode, isNot(0));
    expect(exeRecFail.stderr as String, contains('aot_assert_triggered'));

    // 3. aot-snapshot mode with --enable-asserts AND --recorded-uses
    final outAotRecorded = File('${tmp.path}/out_recorded.aot');
    final recordedUsesAot = File('${tmp.path}/aot.recorded_uses.json');
    snapshot.main([
      '--aot',
      '--dart=$dartBin',
      '--mode=aot-snapshot',
      '--enable-asserts',
      '--recorded-uses=${recordedUsesAot.path}',
      '-o',
      outAotRecorded.path,
      inDill.path,
    ]);
    expect(outAotRecorded.existsSync(), isTrue);
    expect(recordedUsesAot.existsSync(), isTrue);
    final aotRecPass = Process.runSync(dartaotruntime, [outAotRecorded.path]);
    expect(aotRecPass.exitCode, 0, reason: '${aotRecPass.stderr}');
    final aotRecFail = Process.runSync(dartaotruntime, [
      outAotRecorded.path,
      '--fail',
    ]);
    expect(aotRecFail.exitCode, isNot(0));
    expect(aotRecFail.stderr as String, contains('aot_assert_triggered'));
  });

  test('--gen-kernel preserves comma-containing defines during constant evaluation and isolates --filesystem-root to declared inputs', () {
    final dartBin = Platform.resolvedExecutable;
    final sdkDir = File(dartBin).parent.parent.path;
    final exeSuffix = Platform.isWindows ? '.exe' : '';
    final dartaotruntime = '$sdkDir/bin/dartaotruntime$exeSuffix';
    final genKernel = '$sdkDir/bin/snapshots/gen_kernel_aot.dart.snapshot';
    final platformDill = '$sdkDir/lib/_internal/vm_platform_product.dill';
    final ws = Directory('${tmp.path}/gen_kernel_ws')
      ..createSync(recursive: true);

    File('${ws.path}/package_config.json').writeAsStringSync(
      '{"configVersion": 2, "packages": ['
      '{"name": "pkg", "rootUri": "org-dartlang-root:///pkg", "packageUri": "lib/"}'
      ']}\n',
    );
    // Untracked workspace shadow of generated file:
    File('${ws.path}/pkg/lib/gen.dart')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync("const genOrigin = 'untracked-dot-shadow';\n");
    // Declared generated file in bazel-out:
    File('${ws.path}/bazel-out/k8-fastbuild/bin/pkg/lib/gen.dart')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync("const genOrigin = 'declared-bazel-out';\n");
    // Declared source file in .:
    File('${ws.path}/pkg/lib/hand.dart')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync("const handOrigin = 'declared-dot';\n");
    // Stale generated shadow in bazel-out:
    File('${ws.path}/bazel-out/k8-fastbuild/bin/pkg/lib/hand.dart')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync("const handOrigin = 'stale-bazel-out-shadow';\n");
    File('${ws.path}/app/bin/main.dart')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(
        "import 'package:pkg/gen.dart';\n"
        "import 'package:pkg/hand.dart';\n"
        "void main() {\n"
        "  const val = String.fromEnvironment('COMMA_DEFINE');\n"
        "  const eq = val == 'a,b';\n"
        "  print('\$val|\$eq|\$genOrigin|\$handOrigin');\n"
        "}\n",
      );
    final sourcesFile = File('${ws.path}/sources.params')
      ..writeAsStringSync(
        'app/bin/main.dart\n'
        'bazel-out/k8-fastbuild/bin/pkg/lib/gen.dart\n'
        'pkg/lib/hand.dart\n',
      );
    final outDill = File('${ws.path}/bazel-out/k8-fastbuild/bin/out.dill');
    final prevCwd = Directory.current;
    Directory.current = ws;
    try {
      snapshot.main([
        '--gen-kernel',
        dartaotruntime,
        '--input-sources-file=${sourcesFile.path}',
        genKernel,
        '--platform',
        platformDill,
        '--packages',
        'package_config.json',
        '--filesystem-scheme',
        'org-dartlang-root',
        '--filesystem-root',
        '.',
        '--filesystem-root',
        'bazel-out/k8-fastbuild/bin',
        '-Ddart.vm.product=true',
        '-DCOMMA_DEFINE=a,b',
        '-o',
        'bazel-out/k8-fastbuild/bin/out.dill',
        'org-dartlang-root:///app/bin/main.dart',
      ]);
    } finally {
      Directory.current = prevCwd;
    }
    expect(outDill.existsSync(), isTrue);
    final runRes = Process.runSync(dartBin, [outDill.path]);
    expect(runRes.exitCode, 0, reason: '${runRes.stderr}');
    expect(
      (runRes.stdout as String).trim(),
      'a,b|true|declared-bazel-out|declared-dot',
    );
  });
}
