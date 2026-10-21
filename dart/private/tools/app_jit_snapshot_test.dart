import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

import 'app_jit_snapshot.dart' as snapshot;
import 'comma_patch.dart' as comma;

void main(List<String> args) {
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

  /// Copies the tool and its `comma_patch.dart` import into a fresh directory
  /// under [tmp] so a subprocess can run the tool from source, and returns
  /// the entry path. Under Bazel both files come from the test's `args` (see
  /// BUILD.bazel); a direct `dart test` run resolves them beside this test.
  String stageTool() {
    final toolSource = args.isNotEmpty
        ? Runfiles.create().rlocation(args[0])
        : File.fromUri(Platform.script.resolve('app_jit_snapshot.dart')).path;
    final patchSource = args.length > 1
        ? Runfiles.create().rlocation(args[1])
        : File.fromUri(Platform.script.resolve('comma_patch.dart')).path;
    final dir = Directory(
      '${tmp.path}/tool_${DateTime.now().microsecondsSinceEpoch}',
    )..createSync(recursive: true);
    File('${dir.path}/app_jit_snapshot.dart')
        .writeAsBytesSync(File(toolSource).readAsBytesSync());
    File('${dir.path}/comma_patch.dart')
        .writeAsBytesSync(File(patchSource).readAsBytesSync());
    return '${dir.path}/app_jit_snapshot.dart';
  }

  /// Patches the SDK snapshot at [inputPath] into [tmp], failing the test
  /// when the pattern is missing: the build's declared patch action in test
  /// form, with the SDK snapshot in and the patched copy out.
  String patchSnapshot(String inputPath, String kind) {
    final out = File('${tmp.path}/patched_$kind.snapshot');
    final error = comma.patchSnapshotFile(
      inputPath: inputPath,
      outputPath: out.path,
      sdkVersion: Platform.version.split(' ').first,
      snapshotKind: kind,
    );
    expect(error, isNull, reason: '$inputPath: $error');
    return out.path;
  }

  /// A child environment whose temp directories are [scratch] and whose home
  /// is [home]: nothing the child spawns may use the shared system temp.
  Map<String, String> scratchEnv(String scratch, String home) {
    final env = <String, String>{
      'HOME': home,
      'USERPROFILE': home,
      'TMPDIR': scratch,
      'TEMP': scratch,
      'TMP': scratch,
    };
    const keep = {
      'systemroot',
      'windir',
      'systemdrive',
      'comspec',
      'pathext',
      'path',
      'number_of_processors',
      'processor_architecture',
    };
    for (final entry in Platform.environment.entries) {
      if (keep.contains(entry.key.toLowerCase())) env[entry.key] = entry.value;
    }
    return env;
  }

  /// A structurally valid kernel component for read-set unit tests: [sources]
  /// are (`fileUri`, `importUri`) source-table entries, [libraries] are
  /// (source index, canonical root or null) library nodes, and [extraRoots]
  /// are canonical roots no node mentions. It mirrors the builder in
  /// `kernel_module_test.dart`, and the parser-agreement test there pins both
  /// readers to identical verdicts on its bytes.
  Uint8List verifyDill({
    required List<(String, String)> sources,
    required List<(int, String?)> libraries,
    List<String> extraRoots = const [],
  }) {
    final out = BytesBuilder();
    void u30(int v) {
      if (v < 0x80) {
        out.addByte(v);
      } else if (v < 0x4000) {
        out.addByte(0x80 | (v >> 8));
        out.addByte(v & 0xff);
      } else {
        out.addByte(0xc0 | ((v >> 24) & 0x3f));
        out.addByte((v >> 16) & 0xff);
        out.addByte((v >> 8) & 0xff);
        out.addByte(v & 0xff);
      }
    }

    void u32(int v) {
      out.addByte((v >> 24) & 0xff);
      out.addByte((v >> 16) & 0xff);
      out.addByte((v >> 8) & 0xff);
      out.addByte(v & 0xff);
    }

    void str(String s) {
      final bytes = utf8.encode(s);
      u30(bytes.length);
      out.add(bytes);
    }

    final strings = <String>[''];
    int stringIndexOf(String s) {
      var index = strings.indexOf(s);
      if (index < 0) {
        index = strings.length;
        strings.add(s);
      }
      return index;
    }

    u32(0x90ABCDEF);
    u32(138);
    out.add(List.filled(64, 0));
    final sourceTableOffset = out.length;
    u32(sources.length);
    for (final (fileUri, importUri) in sources) {
      str(fileUri);
      str('');
      u30(0);
      str(importUri);
      u30(0);
    }
    final constantTableOffset = out.length;
    u30(0);
    final linkTableOffset = out.length;
    u30(libraries.length + extraRoots.length);
    for (final (_, canon) in libraries) {
      u30(0); // Parent: the nameless root.
      u30(canon == null ? 0 : stringIndexOf(canon));
    }
    for (final root in extraRoots) {
      u30(0); // Parent: the nameless root no node references.
      u30(stringIndexOf(root));
    }
    final stringTableOffset = out.length;
    u30(strings.length);
    var end = 0;
    final ends = <int>[];
    for (final s in strings) {
      end += utf8.encode(s).length;
      ends.add(end);
    }
    for (final e in ends) {
      u30(e);
    }
    for (final s in strings) {
      out.add(utf8.encode(s));
    }
    final libraryOffsets = <int>[];
    for (var i = 0; i < libraries.length; i++) {
      libraryOffsets.add(out.length);
      final (source, canon) = libraries[i];
      out.addByte(4); // Flags.
      u30(3); // Major version.
      u30(0); // Minor version.
      // Canonical-name reference, biased by one; zero names no reference.
      u30(canon == null ? 0 : i + 1);
      u30(0); // Name string reference: the empty name.
      u30(source);
    }
    libraryOffsets.add(out.length);
    u32(sourceTableOffset);
    u32(constantTableOffset);
    u32(constantTableOffset);
    u32(linkTableOffset);
    u32(linkTableOffset);
    u32(linkTableOffset);
    u32(stringTableOffset);
    u32(stringTableOffset);
    u32(stringTableOffset);
    for (final offset in libraryOffsets) {
      u32(offset);
    }
    u32(libraries.length);
    u32(out.length + 4);
    return out.toBytes();
  }

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
    final genKernel = patchSnapshot(
      '${sdkDir.path}/bin/snapshots/gen_kernel_aot.dart.snapshot',
      'gen_kernel',
    );
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
      '--comma-patched-snapshot',
      '--input-source=${mainDart.path}',
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
    final genKernel = patchSnapshot(
      '$sdkDir/bin/snapshots/gen_kernel_aot.dart.snapshot',
      'gen_kernel',
    );
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
        '--comma-patched-snapshot',
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

  test('app-jit training passes explicit --packages in scratch and ignores ancestor .dart_tool', () {
    final dartBin = Platform.resolvedExecutable;
    // Poison the ancestor directory with a malformed .dart_tool/package_config.json
    // so any upward directory walk from the training scratch dir would fail.
    File('${tmp.path}/.dart_tool/package_config.json')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('{malformed package_config');

    final workDir = Directory('${tmp.path}/nested/work')
      ..createSync(recursive: true);
    final trainScript = File('${workDir.path}/train.dart')
      ..writeAsStringSync('void main(List<String> args) {}\n');
    final outJit = File('${workDir.path}/out.jit');

    // A planted fixed-path training VM from the old layout: the training
    // must neither read nor execute it.
    final plantedVm = File(
      '${Directory.systemTemp.path}/rules_dart_vm-planted-test',
    )..writeAsBytesSync([0x7f, 0x45, 0x4c, 0x46, 0x99]);
    try {
      snapshot.main([
        '--dart=$dartBin',
        '--snapshot=${outJit.path}',
        '--copy=train.dart=${trainScript.path}',
        '--',
        'train.dart',
      ]);
      expect(outJit.existsSync(), isTrue);
      // The training VM lives beside the declared output, not at a shared
      // fixed path, and the planted file is untouched.
      final vmDart = File(
        '${outJit.path}.vm/bin/dart${Platform.isWindows ? '.exe' : ''}',
      );
      expect(vmDart.existsSync(), isTrue);
      expect(plantedVm.readAsBytesSync(), [0x7f, 0x45, 0x4c, 0x46, 0x99]);
    } finally {
      if (plantedVm.existsSync()) plantedVm.deleteSync();
    }
  });

  test('buildChildEnvironment on Windows preserves SystemRoot and valid names while isolating home and cache directories', () {
    const privateHome = r'C:\b\tmp\private_home';
    final env = snapshot.buildChildEnvironment(
      homeDir: privateHome,
      parentEnv: const {
        'SYSTEMROOT': r'D:\Windows',
        'ComSpec': r'D:\Windows\System32\cmd.exe',
        'PATHEXT': '.COM;.EXE;.BAT;.CMD',
        'Path': r'D:\Windows\System32;C:\HostTools\bin',
        'USERPROFILE': r'C:\Users\host',
        'LOCALAPPDATA': r'C:\Users\host\AppData\Local',
        'APPDATA': r'C:\Users\host\AppData\Roaming',
        'HOME': r'C:\Users\host',
        'PUB_CACHE': r'C:\Users\host\Pub\Cache',
        'TEMP': r'C:\Users\host\Temp',
        'TMP': r'C:\Users\host\Temp',
        'HOST_SECRET': 'leaked',
        '': 'empty-key',
        '=C:': r'C:\Users\host',
        'BAD=NAME': 'value',
      },
      overrides: const {
        'DART_TEST_CONFIG': 'none/DartTest.yaml',
        '': 'ignored',
        'INVALID=KEY': 'ignored',
      },
      isWindows: true,
    );

    expect(env['SystemRoot'], r'D:\Windows');
    expect(env['WINDIR'], r'D:\Windows');
    expect(env['SystemDrive'], 'D:');
    expect(env['COMSPEC'], r'D:\Windows\System32\cmd.exe');
    expect(env['PATHEXT'], '.COM;.EXE;.BAT;.CMD');
    expect(env['USERPROFILE'], privateHome);
    expect(env['LOCALAPPDATA'], privateHome);
    expect(env['APPDATA'], privateHome);
    expect(env['HOME'], privateHome);
    expect(env['PUB_CACHE'], privateHome);
    expect(env['TEMP'], privateHome);
    expect(env['TMP'], privateHome);
    expect(env['TMPDIR'], privateHome);
    expect(env['DART_TEST_CONFIG'], 'none/DartTest.yaml');
    expect(env.containsKey('HOST_SECRET'), isFalse);

    for (final key in env.keys) {
      expect(key, isNotEmpty);
      expect(key.contains('='), isFalse, reason: 'invalid key $key');
      expect(key.contains('\x00'), isFalse, reason: 'null byte in key $key');
    }

    final fallbackEnv = snapshot.buildChildEnvironment(
      homeDir: privateHome,
      parentEnv: const {},
      isWindows: true,
      includeParent: false,
    );
    expect(fallbackEnv['SystemRoot'], r'C:\Windows');
    expect(fallbackEnv['USERPROFILE'], privateHome);
    expect(fallbackEnv['LOCALAPPDATA'], privateHome);
    expect(fallbackEnv['APPDATA'], privateHome);
    expect(fallbackEnv['HOME'], privateHome);
    expect(fallbackEnv['PUB_CACHE'], privateHome);
    expect(fallbackEnv['TEMP'], privateHome);
    expect(fallbackEnv['TMP'], privateHome);
    for (final key in fallbackEnv.keys) {
      expect(key, isNotEmpty);
      expect(key.contains('='), isFalse, reason: 'invalid key $key');
    }
  });

  test(
    '--gen-kernel refuses a file: import in any spelling without compiling',
    () {
      final ws = Directory('${tmp.path}/file_ws')..createSync(recursive: true);
      final main = File('${ws.path}/main.dart')
        ..writeAsStringSync(
          "import 'file:///proc/self/cwd/pkg/lib/secret.dart';\n"
          'void main() => print(secretValue);\n',
        );
      final conditional = File('${ws.path}/cond.dart')
        ..writeAsStringSync(
          "import 'dart:async' if (dart.library.io) 'FILE:///secret.dart';\n"
          'Future<void> f() async {}\n',
        );
      // The mirror classifies exactly what the planner classifies.
      expect(
        snapshot.findDisallowedDirectives({
          main.path: main.readAsStringSync(),
          conditional.path: conditional.readAsStringSync(),
        }, tool: 'app_jit_snapshot'),
        [
          "app_jit_snapshot: ${conditional.path} import 'FILE:///secret.dart' "
              'is not a declared input.',
          "app_jit_snapshot: ${main.path} import "
              "'file:///proc/self/cwd/pkg/lib/secret.dart' is not a declared input.",
        ],
      );
      // End to end: the wrapper fails before running gen_kernel (which is never
      // reached, so no SDK snapshot is needed).
      final toolPath = stageTool();
      final res = Process.runSync(Platform.resolvedExecutable, [
        toolPath,
        '--gen-kernel',
        'never-reached-runtime',
        '--input-source=${main.path}',
        '--input-source=${conditional.path}',
      ]);
      expect(res.exitCode, isNonZero);
      expect(
        res.stderr as String,
        contains(
          "import 'file:///proc/self/cwd/pkg/lib/secret.dart' "
          'is not a declared input',
        ),
      );
      expect(
        res.stderr as String,
        contains("import 'FILE:///secret.dart' is not a declared input"),
      );
    },
  );

  test('--gen-kernel refuses a climbing relative import without compiling', () {
    final ws = Directory('${tmp.path}/rel_ws')..createSync(recursive: true);
    final main = File('${ws.path}/main.dart')
      ..writeAsStringSync(
        "import '../secret.dart';\n"
        'void main() => print(secretValue);\n',
      );
    final sibling = File('${ws.path}/sibling.dart')
      ..writeAsStringSync(
        "import 'main.dart';\n"
        'void helper() {}\n',
      );
    // End to end: the wrapper fails before running gen_kernel (which is never
    // reached, so no SDK snapshot is needed).
    final toolPath = args.isNotEmpty
        ? Runfiles.create().rlocation(args[0])
        : File.fromUri(Platform.script.resolve('app_jit_snapshot.dart')).path;
    final res = Process.runSync(Platform.resolvedExecutable, [
      toolPath,
      '--gen-kernel',
      'never-reached-runtime',
      '--input-source=${main.path}',
      '--input-source=${sibling.path}',
    ]);
    expect(res.exitCode, isNonZero);
    expect(
      res.stderr as String,
      contains("import '../secret.dart' is not a declared input"),
    );
    // Exactly one diagnostic: the sibling's import stays inside the declared
    // inputs, so the guard refuses nothing for it.
    expect(
      'is not a declared input'.allMatches(res.stderr as String),
      hasLength(1),
    );
  });

  test('--gen-kernel refuses an empty path segment without compiling', () {
    final ws = Directory('${tmp.path}/empty_ws')..createSync(recursive: true);
    final main = File('${ws.path}/main.dart')
      ..writeAsStringSync(
        "import 'sibling//helper.dart';\n"
        'void main() => print(helperValue);\n',
      );
    File('${ws.path}/sibling/helper.dart')
      ..createSync(recursive: true)
      ..writeAsStringSync('const helperValue = 1;\n');
    // End to end: the wrapper fails before running gen_kernel (which is never
    // reached, so no SDK snapshot is needed), even though skipping the empty
    // segment would resolve inside the declared inputs: the front end need
    // not resolve it the same way.
    final toolPath = args.isNotEmpty
        ? Runfiles.create().rlocation(args[0])
        : File.fromUri(Platform.script.resolve('app_jit_snapshot.dart')).path;
    final res = Process.runSync(Platform.resolvedExecutable, [
      toolPath,
      '--gen-kernel',
      'never-reached-runtime',
      '--input-source=${main.path}',
    ]);
    expect(res.exitCode, isNonZero);
    expect(
      res.stderr as String,
      contains("import 'sibling//helper.dart' is not a declared input"),
    );
  });

  test('--gen-kernel with comma define and pristine snapshot fails loudly', () {
    final sdkDir = File(Platform.resolvedExecutable).parent.parent;
    final exeSuffix = Platform.isWindows ? '.exe' : '';
    final dartaotruntime = '${sdkDir.path}/bin/dartaotruntime$exeSuffix';
    final genKernel =
        '${sdkDir.path}/bin/snapshots/gen_kernel_aot.dart.snapshot';
    final platformDill = '${sdkDir.path}/lib/_internal/vm_platform_strong.dill';

    final pkgConfig = File('${tmp.path}/loud_package_config.json')
      ..writeAsStringSync('{"configVersion": 2, "packages": []}\n');
    final mainDart = File('${tmp.path}/loud_main.dart')
      ..writeAsStringSync(
        'void main() {\n'
        "  print(const String.fromEnvironment('COMMA_VAL', defaultValue: 'UNSET'));\n"
        '}\n',
      );
    final outDill = File('${tmp.path}/loud_out.dill');

    // The wrapper fails before running gen_kernel (which is never reached),
    // so the pristine snapshot is enough to prove the fail-closed check.
    final toolPath = stageTool();
    final res = Process.runSync(Platform.resolvedExecutable, [
      toolPath,
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
    expect(res.exitCode, 1);
    expect('${res.stdout}\n${res.stderr}', contains('comma'));
    expect(outDill.existsSync(), isFalse);
  });

  test('--gen-kernel ignores planted shared-temp files', () {
    final sdkDir = File(Platform.resolvedExecutable).parent.parent;
    final exeSuffix = Platform.isWindows ? '.exe' : '';
    final dartaotruntime = '${sdkDir.path}/bin/dartaotruntime$exeSuffix';
    final genKernel = patchSnapshot(
      '${sdkDir.path}/bin/snapshots/gen_kernel_aot.dart.snapshot',
      'gen_kernel',
    );
    final platformDill = '${sdkDir.path}/lib/_internal/vm_platform_strong.dill';

    final sysTmp = Directory.systemTemp;

    /// Basenames in the shared temp dir that look like the old fixed-path
    /// cache: the `*nocomma.snapshot` files and `rules_dart_vm-*` dirs.
    Set<String> sharedCacheNames() {
      final names = <String>{};
      for (final e in sysTmp.listSync()) {
        final base = e.path.split(Platform.pathSeparator).last;
        if (base.contains('nocomma.snapshot') ||
            base.startsWith('rules_dart_vm-')) {
          names.add(base);
        }
      }
      return names;
    }

    // Whatever other builds left in shared temp stays: only files this run
    // adds may appear below.
    final before = sharedCacheNames();
    final plants = <String, String>{
      'kernel_worker_nocomma.snapshot': 'planted',
      'kernel_worker_nocomma.snapshot.version': 'planted',
      'gen_kernel_nocomma.snapshot': 'planted',
      'gen_kernel_nocomma.snapshot.version': 'planted',
    };
    for (final entry in plants.entries) {
      File('${sysTmp.path}/${entry.key}').writeAsStringSync(entry.value);
    }
    final plantedVmDir = Directory('${sysTmp.path}/rules_dart_vm-planted-test')
      ..createSync(recursive: true);
    File('${plantedVmDir.path}/bin_dart${Platform.isWindows ? '.exe' : ''}')
        .writeAsStringSync('planted');
    try {
      final pkgConfig = File('${tmp.path}/plant_package_config.json')
        ..writeAsStringSync('{"configVersion": 2, "packages": []}\n');
      final mainDart = File('${tmp.path}/plant_main.dart')
        ..writeAsStringSync(
          'void main() {\n'
          "  print(const String.fromEnvironment('COMMA_VAL', defaultValue: 'UNSET'));\n"
          '}\n',
        );
      final outDill = File('${tmp.path}/plant_out.dill');

      final toolPath = stageTool();
      final res = Process.runSync(Platform.resolvedExecutable, [
        toolPath,
        '--gen-kernel',
        dartaotruntime,
        '--comma-patched-snapshot',
        '--input-source=${mainDart.path}',
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
      expect(res.exitCode, 0, reason: '${res.stdout}\n${res.stderr}');
      expect(outDill.existsSync(), isTrue);

      for (final entry in plants.entries) {
        expect(
          File('${sysTmp.path}/${entry.key}').readAsStringSync(),
          'planted',
        );
      }
      expect(
        File('${plantedVmDir.path}/bin_dart${Platform.isWindows ? '.exe' : ''}')
            .readAsStringSync(),
        'planted',
      );
      final leftovers = sharedCacheNames().difference(before);
      // Only the plants this test wrote may have appeared.
      leftovers.removeAll(plants.keys);
      leftovers.remove('rules_dart_vm-planted-test');
      expect(leftovers, isEmpty, reason: '$leftovers');
    } finally {
      for (final key in plants.keys) {
        final f = File('${sysTmp.path}/$key');
        if (f.existsSync()) f.deleteSync();
      }
      if (plantedVmDir.existsSync()) {
        plantedVmDir.deleteSync(recursive: true);
      }
    }
  });

  test('--aot leaves scratch TMPDIR empty', () {
    if (Platform.isWindows) return;
    final sdkDir = File(Platform.resolvedExecutable).parent.parent;
    final dartBin = '${sdkDir.path}/bin/dart';
    final dartaotruntime = '${sdkDir.path}/bin/dartaotruntime';
    final genKernel =
        '${sdkDir.path}/bin/snapshots/gen_kernel_aot.dart.snapshot';
    final platformDill = '${sdkDir.path}/lib/_internal/vm_platform_strong.dill';

    final pkgConfig = File('${tmp.path}/aot_package_config.json')
      ..writeAsStringSync('{"configVersion": 2, "packages": []}\n');
    final mainDart = File('${tmp.path}/aot_main.dart')
      ..writeAsStringSync('void main() {}\n');
    final inDill = File('${tmp.path}/aot_main.dill');
    final gkRes = Process.runSync(dartaotruntime, [
      genKernel,
      '--platform=$platformDill',
      '--packages=${pkgConfig.path}',
      '--aot',
      '--tfa',
      '--no-embed-sources',
      '-o',
      inDill.path,
      mainDart.path,
    ]);
    expect(gkRes.exitCode, 0, reason: '${gkRes.stdout}\n${gkRes.stderr}');

    final scratch = Directory('${tmp.path}/aot-scratch')..createSync();
    final home = Directory('${tmp.path}/aot-home')..createSync();
    final outExe = File('${tmp.path}/aot-scratch-out/tool');
    final toolPath = stageTool();
    final res = Process.runSync(Platform.resolvedExecutable, [
      toolPath,
      '--aot',
      '--dart=$dartBin',
      '--mode=exe',
      '-o',
      outExe.path,
      inDill.path,
    ], environment: scratchEnv(scratch.path, home.path));
    expect(res.exitCode, 0, reason: '${res.stdout}\n${res.stderr}');
    expect(outExe.existsSync(), isTrue);
    expect(scratch.listSync(recursive: true).toList(), isEmpty);
  });

  test('--gen-kernel refuses a schemeless authority without compiling', () {
    final ws = Directory('${tmp.path}/auth_ws')..createSync(recursive: true);
    final main = File('${ws.path}/main.dart')
      ..writeAsStringSync(
        "import '//host/evil.dart';\n"
        'void main() => print(secretValue);\n',
      );
    // Four source backslashes: the scanner unescapes `\\` pairs, so the
    // extracted URI leads with `\\`, which fails as the `//` authority.
    const bs = '\\';
    final authSource = '${bs * 4}host${bs * 2}evil.dart';
    final authExtracted = '${bs * 2}host${bs}evil.dart';
    final conditional = File('${ws.path}/cond.dart')
      ..writeAsStringSync(
        "import 'dart:async' if (dart.library.io) '$authSource';\n"
        'Future<void> f() async {}\n',
      );
    // End to end: the wrapper fails before running gen_kernel (which is never
    // reached, so no SDK snapshot is needed).
    final toolPath = stageTool();
    final res = Process.runSync(Platform.resolvedExecutable, [
      toolPath,
      '--gen-kernel',
      'never-reached-runtime',
      '--input-source=${main.path}',
      '--input-source=${conditional.path}',
    ]);
    expect(res.exitCode, isNonZero);
    expect(
      res.stderr as String,
      contains("import '//host/evil.dart' is not a declared input"),
    );
    expect(
      res.stderr as String,
      contains("import '$authExtracted' is not a declared input"),
    );
    expect(
      'is not a declared input'.allMatches(res.stderr as String),
      hasLength(2),
    );
  });

  test(
    '--gen-kernel scans files with malformed UTF-8 instead of skipping them',
    () {
      final ws = Directory('${tmp.path}/malformed_ws')
        ..createSync(recursive: true);
      File('${ws.path}/b.dart').writeAsStringSync('class B {}\n');
      // An invalid byte mid-file: gen_kernel still accepts the file, so the
      // guard scans what it can (with U+FFFD) instead of skipping it.
      File('${ws.path}/main.dart').writeAsBytesSync([
        ...utf8.encode("import 'b.dart';\n// "),
        0xff,
        ...utf8.encode("\nimport '../../evil.dart';\nvoid main() {}\n"),
      ]);
      // End to end: the wrapper fails before running gen_kernel (which is
      // never reached, so no SDK snapshot is needed).
      final toolPath = stageTool();
      final res = Process.runSync(Platform.resolvedExecutable, [
        toolPath,
        '--gen-kernel',
        'never-reached-runtime',
        '--input-source=${ws.path}/main.dart',
        '--input-source=${ws.path}/b.dart',
      ]);
      expect(res.exitCode, isNonZero);
      expect(
        res.stderr as String,
        contains("import '../../evil.dart' is not a declared input"),
      );
      // Exactly one diagnostic: the declared sibling import is clean, and the
      // malformed file itself was scanned, not skipped.
      expect(
        'is not a declared input'.allMatches(res.stderr as String),
        hasLength(1),
      );
    },
  );

  group('verifyGenKernelReads', () {
    const prefix = 'org-dartlang-root:///';

    List<String> verify(
      String name,
      Uint8List bytes, {
      Set<String> declaredKeys = const {'app/main.dart'},
      Map<String, String> packageKeyPrefixes = const {},
    }) {
      final out = File('${tmp.path}/$name')..writeAsBytesSync(bytes);
      return snapshot.verifyGenKernelReads(
        outputPath: out.path,
        declaredKeys: declaredKeys,
        multiRootPrefix: prefix,
        fsRoots: const ['.'],
        packageKeyPrefixes: packageKeyPrefixes,
      );
    }

    test('a clean kernel verifies', () {
      expect(
        verify(
          'clean.dill',
          verifyDill(
            sources: [('${prefix}app/main.dart', '${prefix}app/main.dart')],
            libraries: [(0, '${prefix}app/main.dart')],
          ),
        ),
        isEmpty,
      );
    });

    test('an undeclared file read fails closed and names the file', () {
      final errors = verify(
        'dirty.dill',
        verifyDill(
          sources: [
            ('${prefix}app/main.dart', '${prefix}app/main.dart'),
            ('file:///host/evil.dart', 'file:///host/evil.dart'),
          ],
          libraries: [(0, '${prefix}app/main.dart')],
        ),
      );
      expect(errors, isNotEmpty);
      expect(errors.join('\n'), contains('reads file:///host/evil.dart'));
    });

    test('an undefined import spelling fails closed', () {
      final errors = verify(
        'evil_import.dill',
        verifyDill(
          sources: [('${prefix}app/main.dart', '${prefix}app/main.dart')],
          libraries: [(0, 'package:pkg//evil.dart')],
        ),
      );
      expect(errors, isNotEmpty);
      expect(errors.join('\n'), contains('references package:pkg//evil.dart'));
    });

    test('a smuggled canonical root fails closed', () {
      final errors = verify(
        'evil_root.dill',
        verifyDill(
          sources: [('${prefix}app/main.dart', '${prefix}app/main.dart')],
          libraries: [(0, '${prefix}app/main.dart')],
          extraRoots: ['file:///host/evil.dart'],
        ),
      );
      expect(errors, isNotEmpty);
      expect(errors.join('\n'), contains('references file:///host/evil.dart'));
    });

    test('a package spelling of a declared input verifies', () {
      expect(
        verify(
          'package.dill',
          verifyDill(
            sources: [('${prefix}pkg/lib/a.dart', 'package:pkg/a.dart')],
            libraries: [(0, 'package:pkg/a.dart')],
          ),
          declaredKeys: const {'pkg/lib/a.dart'},
          packageKeyPrefixes: const {'pkg': 'pkg/lib'},
        ),
        isEmpty,
      );
    });

    test('an unparsable kernel fails closed and a missing output passes', () {
      expect(verify('garbage.dill', Uint8List.fromList([1, 2, 3])), isNotEmpty);
      expect(
        snapshot.verifyGenKernelReads(
          outputPath: '${tmp.path}/absent.dill',
          declaredKeys: const {'app/main.dart'},
          multiRootPrefix: prefix,
          fsRoots: const ['.'],
          packageKeyPrefixes: const {},
        ),
        isEmpty,
      );
    });
  });

  group('genKernelPackageKeyPrefixes', () {
    test('scheme, relative, and file roots map to key prefixes', () {
      final dir = Directory('${tmp.path}/cfg/sub')..createSync(recursive: true);
      File('${dir.path}/package_config.json').writeAsStringSync(
        jsonEncode({
          'configVersion': 2,
          'packages': [
            {
              'name': 'a',
              'rootUri': 'org-dartlang-root:///pkg/a',
              'packageUri': 'lib/',
            },
            {'name': 'b', 'rootUri': '../src/b', 'packageUri': 'lib/'},
            {'name': 'c', 'rootUri': 'file:///tmp/abs/c', 'packageUri': 'lib/'},
            {
              'name': 'other',
              'rootUri': 'weird-scheme:///x',
              'packageUri': 'lib/',
            },
            {'name': '', 'rootUri': 'org-dartlang-root:///pkg/a'},
          ],
        }),
      );
      expect(
        snapshot.genKernelPackageKeyPrefixes(
          packagesPath: '${dir.path}/package_config.json',
          multiRootPrefix: 'org-dartlang-root:///',
          fsRoots: const ['.'],
        ),
        {
          'a': 'pkg/a/lib',
          'b': '${tmp.path.replaceAll(r'\', '/')}/cfg/src/b/lib',
          'c': '/tmp/abs/c/lib',
        },
      );
    });

    test('a relative root above the exec root maps to nothing', () {
      final prevCwd = Directory.current;
      Directory.current = tmp;
      try {
        Directory('cfg').createSync();
        File('cfg/package_config.json').writeAsStringSync(
          jsonEncode({
            'configVersion': 2,
            'packages': [
              {'name': 'in', 'rootUri': 'sub/pkg', 'packageUri': 'lib/'},
              {'name': 'out', 'rootUri': '../../outside', 'packageUri': 'lib/'},
            ],
          }),
        );
        expect(
          snapshot.genKernelPackageKeyPrefixes(
            packagesPath: 'cfg/package_config.json',
            multiRootPrefix: 'org-dartlang-root:///',
            fsRoots: const ['.'],
          ),
          {'in': 'cfg/sub/pkg/lib'},
        );
      } finally {
        Directory.current = prevCwd;
      }
    });

    test('a missing or malformed config maps every package to nothing', () {
      File('${tmp.path}/broken.json').writeAsStringSync('{nope');
      for (final path in [
        '${tmp.path}/absent.json',
        '${tmp.path}/broken.json',
      ]) {
        expect(
          snapshot.genKernelPackageKeyPrefixes(
            packagesPath: path,
            multiRootPrefix: 'org-dartlang-root:///',
            fsRoots: const ['.'],
          ),
          isEmpty,
        );
      }
    });
  });

  test(
    '--gen-kernel deletes an output whose read set names an undeclared file',
    () {
      if (Platform.isWindows) return;
      final ws = Directory('${tmp.path}/readset_ws')
        ..createSync(recursive: true);
      final main = File('${ws.path}/main.dart')
        ..writeAsStringSync('void main() {}\n');
      final pkgConfig = File('${ws.path}/package_config.json')
        ..writeAsStringSync('{"configVersion": 2, "packages": []}\n');
      // Whatever the front end would have read, the bytes below name a host
      // file no declared input covers.
      File('${ws.path}/dirty.dill').writeAsBytesSync(
        verifyDill(
          sources: [('file:///host/evil.dart', 'file:///host/evil.dart')],
          libraries: const [],
        ),
      );
      // A stand-in for the runtime: it "compiles" by copying the dirty bytes to
      // the `-o` output and exiting successfully, so only the read-set check
      // can still refuse the action.
      final runtime = File('${ws.path}/fake_runtime.sh')
        ..writeAsStringSync(
          '#!/bin/sh\n'
          'out=""\n'
          'prev=""\n'
          'for a in "\$@"; do\n'
          '  case "\$a" in\n'
          '    -o=*|--output=*) out="\${a#*=}";;\n'
          '    -o|--output) prev="out";;\n'
          '    *) if [ "\$prev" = "out" ]; then out="\$a"; fi; prev="";;\n'
          '  esac\n'
          'done\n'
          '/bin/cp \'${ws.path}/dirty.dill\' "\$out"\n',
        );
      snapshot.chmodFile(runtime.path, 0x1ed);
      final outDill = File('${ws.path}/out.dill');

      final toolPath = stageTool();
      final res = Process.runSync(Platform.resolvedExecutable, [
        toolPath,
        '--gen-kernel',
        runtime.path,
        '--input-source=${main.path}',
        'fake-gen-kernel-snapshot',
        '--platform',
        'fake-platform.dill',
        '--packages',
        pkgConfig.path,
        '-o',
        outDill.path,
        main.path,
      ]);
      expect(res.exitCode, 1, reason: '${res.stdout}\n${res.stderr}');
      expect(res.stderr as String, contains('reads file:///host/evil.dart'));
      expect(
        outDill.existsSync(),
        isFalse,
        reason: 'the dirty output is deleted',
      );
    },
  );
}
