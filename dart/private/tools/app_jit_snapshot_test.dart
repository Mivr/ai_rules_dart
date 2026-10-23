import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

import '../../guard/lib/directive_guard.dart' as guard;
import 'app_jit_snapshot.dart' as snapshot;
import 'comma_patch.dart' as comma;
import 'dill_reader.dart'
    show dillCanonicalRoots, dillLibraryReferences, dillSourceUris;

void main(List<String> args) {
  late Directory tmp;
  late int Function(String, int) realMkdir;
  late bool Function(String) realRemoveStale;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('app_jit_snapshot_test_');
    // Other builds on this host train at the real constant paths
    // concurrently: every training in this file uses test directories.
    snapshot.trainDirOverride = '${tmp.path}/jit_train';
    snapshot.trainLockOverride = '${tmp.path}/jit_train.lock';
    snapshot.trainKeyOverride = null;
    snapshot.lockTimeoutSecs = snapshot.defaultLockTimeoutSecs;
    realMkdir = snapshot.mkdirExclusive;
    realRemoveStale = snapshot.removeStaleEntry;
  });

  tearDown(() {
    snapshot.trainDirOverride = null;
    snapshot.trainLockOverride = null;
    snapshot.trainKeyOverride = null;
    snapshot.lockTimeoutSecs = snapshot.defaultLockTimeoutSecs;
    snapshot.mkdirExclusive = realMkdir;
    snapshot.removeStaleEntry = realRemoveStale;
    if (!Platform.isWindows) {
      // Files and directories alike: a test may leave a read-only tree, and
      // deleting it needs owner access on every directory on the way down.
      for (final entity in tmp.listSync(recursive: true)) {
        if (entity is! Link) {
          snapshot.chmodFile(entity.path, 0x1ed);
        }
      }
    }
    tmp.deleteSync(recursive: true);
  });

  /// Copies the tool and the sources it imports (`comma_patch.dart`,
  /// `dill_reader.dart`, and the guard library the reader resolves URIs
  /// through) into a fresh directory under [tmp] so a subprocess can run the
  /// tool from source, and returns the entry path. The copies keep their
  /// workspace-relative layout, the way the build stages them (see the
  /// `jit_tool_srcs` bundle in BUILD.bazel). Under Bazel the files come from
  /// the test's `args`; a direct `dart test` run resolves them beside this
  /// test.
  String stageTool() {
    const sources = [
      (
        staged: 'dart/private/tools/app_jit_snapshot.dart',
        sibling: 'app_jit_snapshot.dart',
      ),
      (
        staged: 'dart/private/tools/comma_patch.dart',
        sibling: 'comma_patch.dart',
      ),
      (
        staged: 'dart/private/tools/dill_reader.dart',
        sibling: 'dill_reader.dart',
      ),
      (
        staged: 'dart/guard/lib/directive_guard.dart',
        sibling: '../../guard/lib/directive_guard.dart',
      ),
    ];
    final dir = Directory(
      '${tmp.path}/tool_${DateTime.now().microsecondsSinceEpoch}',
    )..createSync(recursive: true);
    for (var i = 0; i < sources.length; i++) {
      final from = args.length > i
          ? Runfiles.create().rlocation(args[i])
          : File.fromUri(Platform.script.resolve(sources[i].sibling)).path;
      final to = File('${dir.path}/${sources[i].staged}')
        ..createSync(recursive: true);
      to.writeAsBytesSync(File(from).readAsBytesSync());
    }
    return '${dir.path}/dart/private/tools/app_jit_snapshot.dart';
  }

  /// Stages the tool with one source replacement applied (failing the test
  /// when [from] is missing, so a silent no-op patch cannot pass), for tests
  /// that force an error path a live host cannot produce on demand.
  String stagePatchedTool(String from, String to) {
    final staged = stageTool();
    final source = File(staged).readAsStringSync();
    expect(source, contains(from), reason: 'patch anchor present');
    File(staged).writeAsStringSync(source.replaceFirst(from, to));
    return staged;
  }

  /// Compiles [source] to a kernel file named [name].dill under [tmp] (as in
  /// real builds the training input is a compiled kernel), returning its path.
  String compileDill(String source, String name) {
    File('${tmp.path}/$name.dart').writeAsStringSync(source);
    final dill = File('${tmp.path}/$name.dill');
    final compileRes = Process.runSync(Platform.resolvedExecutable, [
      'compile',
      'kernel',
      '${tmp.path}/$name.dart',
      '-o',
      dill.path,
    ]);
    expect(compileRes.exitCode, 0, reason: '${compileRes.stderr}');
    return dill.path;
  }

  /// The test training paths for a staged tool subprocess, which cannot see
  /// the in-process overrides: the same directories the in-process
  /// [snapshot.constantTrainDir] and [snapshot.constantTrainLock] name.
  Map<String, String> constantTrainEnv() => {
    'RULES_DART_JIT_TRAIN_DIR': snapshot.constantTrainDir,
    'RULES_DART_JIT_TRAIN_LOCK': snapshot.constantTrainLock,
  };

  /// Writes a lock-holder script under [tmp] that takes an exclusive lock on
  /// its first argument, prints `held` once taken, and holds it for its
  /// second argument's seconds. Returns its path.
  String writeLockHolder() {
    final holder = File('${tmp.path}/lock_holder.dart')
      ..writeAsStringSync(
        "import 'dart:io';\n"
        'void main(List<String> args) {\n'
        '  final lock = File(args[0]).openSync(mode: FileMode.append);\n'
        '  lock.lockSync(FileLock.blockingExclusive);\n'
        "  stdout.writeln('held');\n"
        '  sleep(Duration(seconds: int.parse(args[1])));\n'
        '}\n',
      );
    return holder.path;
  }

  /// Starts [holderScript] holding [lockPath] for [seconds], waiting for its
  /// `held` line. The caller kills the returned process.
  Future<Process> startLockHolder(
    String holderScript,
    String lockPath,
    String seconds,
  ) async {
    final holder = await Process.start(Platform.resolvedExecutable, [
      holderScript,
      lockPath,
      seconds,
    ]);
    final held = await holder.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .first
        .timeout(const Duration(seconds: 60));
    expect(held, 'held', reason: 'holder took $lockPath');
    return holder;
  }

  /// Trains [dill] to [out] in-process at the constant training path,
  /// returning the snapshot bytes. Fails the test when the run leaves
  /// anything but the snapshot beside the output: the fallback trains into a
  /// scratch directory beside the output, so leftovers prove the constant
  /// path was not used.
  List<int> trainAtConstant({required String dill, required String out}) {
    final outJit = File(out);
    snapshot.main([
      '--dart=${Platform.resolvedExecutable}',
      '--snapshot=${outJit.path}',
      '--env=TMPDIR=.',
      '--env=HOME=.',
      '--copy=input.dill=$dill',
      '--',
      'input.dill',
    ]);
    expect(outJit.existsSync(), isTrue, reason: 'snapshot written to $out');
    expect(
      outJit.parent.listSync().map((e) => e.path.split('/').last).toList(),
      ['app.jit'],
      reason: 'no training scratch may stay beside the output ($out)',
    );
    return outJit.readAsBytesSync();
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

  /// A copy of [clean] with the [occurrence]-th (zero-based) recording of
  /// [uri]'s bytes replaced by invalid UTF-8: every length prefix still bounds
  /// its entry, but decoding that recording fails.
  Uint8List corruptRecordedUri(Uint8List clean, String uri, int occurrence) {
    final patched = Uint8List.fromList(clean);
    final needle = utf8.encode(uri);
    var seen = 0;
    for (var i = 0; i + needle.length <= patched.length; i++) {
      var match = true;
      for (var j = 0; j < needle.length; j++) {
        if (patched[i + j] != needle[j]) {
          match = false;
          break;
        }
      }
      if (!match) continue;
      if (seen == occurrence) {
        patched[i] = 0xff;
        return patched;
      }
      seen++;
    }
    throw StateError('recorded URI $uri occurrence $occurrence not found');
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

  test(
    '--gen-kernel accepts the manifest-synthesized native-assets library',
    () {
      final sdkDir = File(Platform.resolvedExecutable).parent.parent;
      final exeSuffix = Platform.isWindows ? '.exe' : '';
      final dartaotruntime = '${sdkDir.path}/bin/dartaotruntime$exeSuffix';
      final genKernel = patchSnapshot(
        '${sdkDir.path}/bin/snapshots/gen_kernel_aot.dart.snapshot',
        'gen_kernel',
      );
      final platformDill =
          '${sdkDir.path}/lib/_internal/vm_platform_strong.dill';

      final ws = Directory('${tmp.path}/na_ws')..createSync(recursive: true);
      File('${ws.path}/package_config.json')
          .writeAsStringSync('{"configVersion": 2, "packages": []}\n');
      final mainDart = File('${ws.path}/main.dart')
        ..writeAsStringSync('void main() {\n  print("native assets ok");\n}\n');
      // Every ABI section the rule layer can emit: only the host section is
      // read, and the rest must be harmless.
      final sections = <String>[
        for (final os in ['linux', 'macos', 'windows'])
          for (final arch in ['x64', 'arm64'])
            '"${os}_$arch": '
                '{"package:example/hook.dart": ["system", "libc.so.6"]}',
      ];
      final manifest = File('${ws.path}/native_assets.yaml')
        ..writeAsStringSync(
          '{"format-version": [1, 0, 0], '
          '"native-assets": {${sections.join(', ')}}}\n',
        );
      final outDill = File('${ws.path}/out.dill');

      snapshot.main([
        '--gen-kernel',
        dartaotruntime,
        '--comma-patched-snapshot',
        '--input-source=${mainDart.path}',
        '--input-source=${manifest.path}',
        genKernel,
        '--platform',
        platformDill,
        '--packages',
        '${ws.path}/package_config.json',
        '--native-assets',
        manifest.path,
        '-o',
        outDill.path,
        mainDart.path,
      ]);

      expect(outDill.existsSync(), isTrue);
      // The manifest was honored, not dropped: the output carries the front
      // end's synthetic entries, and the read-set check accepted them.
      final outBytes = outDill.readAsBytesSync();
      expect(dillSourceUris(outBytes), contains('dummy'));
      expect(dillCanonicalRoots(outBytes), contains('vm:ffi:native-assets'));
    },
  );

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

  test(
    'app-jit training takes no --packages and ignores ancestor .dart_tool',
    () {
      final dartBin = Platform.resolvedExecutable;
      final workDir = Directory('${tmp.path}/nested/work')
        ..createSync(recursive: true);
      final trainScript = File('${workDir.path}/train.dart')
        ..writeAsStringSync('void main(List<String> args) {}\n');
      // The training input is a compiled kernel, as in real builds: kernel
      // training needs no package map, so no `--packages` value is passed.
      final trainDill = File('${workDir.path}/train.dill');
      final compileRes = Process.runSync(dartBin, [
        'compile',
        'kernel',
        trainScript.path,
        '-o',
        trainDill.path,
      ]);
      expect(compileRes.exitCode, 0, reason: '${compileRes.stderr}');
      // Poison the ancestor directory with a malformed
      // .dart_tool/package_config.json after compiling: with no `--packages`
      // value the training must not walk up to it (a source compile would
      // fail on the malformed file, which is why real trainings train
      // kernels, never sources).
      File('${tmp.path}/.dart_tool/package_config.json')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('{malformed package_config');
      final outJit = File('${workDir.path}/out.jit');

      // A planted fixed-path training VM from the old layout: the training
      // must neither read nor execute it. The plant lives at a per-test path:
      // this suite's tests (and the planner suite's) run concurrently, and a
      // shared fixed plant would race between processes.
      final plantedVm = File(
        '${Directory.systemTemp.path}/rules_dart_vm-planted-appjit-test.$pid',
      )..writeAsBytesSync([0x7f, 0x45, 0x4c, 0x46, 0x99]);
      try {
        snapshot.main([
          '--dart=$dartBin',
          '--snapshot=${outJit.path}',
          '--copy=train.dill=${trainDill.path}',
          '--',
          'train.dill',
        ]);
        expect(outJit.existsSync(), isTrue);
        // The training VM lives inside the training scratch directory, which
        // is deleted afterwards: nothing undeclared stays beside the declared
        // output, and the planted file is untouched.
        expect(
          Directory('${outJit.path}.vm').existsSync(),
          isFalse,
          reason: 'no training-VM directory may stay beside the output',
        );
        expect(
          workDir
              .listSync()
              .where(
                (e) => e.path
                    .split(Platform.pathSeparator)
                    .last
                    .startsWith('rules_dart_snapshot.'),
              )
              .toList(),
          isEmpty,
          reason: 'no training scratch may stay beside the output',
        );
        expect(plantedVm.readAsBytesSync(), [0x7f, 0x45, 0x4c, 0x46, 0x99]);
      } finally {
        if (plantedVm.existsSync()) plantedVm.deleteSync();
      }
    },
  );

  test(
    'stageTrainingArgs absolutizes staged paths and passes the rest through',
    () {
      final trainDir = Directory('${tmp.path}/train');
      List<String> stage(List<String> args) => snapshot.stageTrainingArgs(
        args,
        trainDir,
        stagedFiles: {
          'input.dill',
          'test/main_test.dart',
          'runner.dill',
          'dart/private/tools/runner_training_test.dart',
        },
        stagedTrees: const ['precompiled'],
      );

      // The script names a file under the training dir, even when later
      // arguments naming the same staged files stay relative.
      expect(stage(['input.dill']), ['${trainDir.path}/input.dill']);
      expect(stage(['input.dill', 'input.dill']), [
        '${trainDir.path}/input.dill',
        'input.dill',
      ]);
      expect(stage(['test/main_test.dart']), [
        '${trainDir.path}/test/main_test.dart',
      ]);
      // A `--flag=value` form keeps its flag and absolutizes a staged value.
      expect(stage(['--precompiled=precompiled']), [
        '--precompiled=${trainDir.path}/precompiled',
      ]);
      // Flags, test names, URIs and absolute paths pass through untouched.
      expect(
        stage([
          'runner.dill',
          '--precompiled=precompiled',
          'dart/private/tools/runner_training_test.dart',
        ]),
        [
          '${trainDir.path}/runner.dill',
          '--precompiled=${trainDir.path}/precompiled',
          // The runner joins the test path it is given onto the absolute
          // `--precompiled` directory itself, so the test path must stay
          // relative even though its source is staged.
          'dart/private/tools/runner_training_test.dart',
        ],
      );
      // Flags, test names, URIs and absolute paths pass through untouched.
      expect(
        stage([
          '--deterministic',
          '--enable-asserts',
          'a passing test name',
          'package:mypkg/mypkg.dart',
          'dart:async',
          '/abs/path.dart',
          '--out=/abs/out.jit',
          '--flag=',
        ]),
        [
          '--deterministic',
          '--enable-asserts',
          'a passing test name',
          'package:mypkg/mypkg.dart',
          'dart:async',
          '/abs/path.dart',
          '--out=/abs/out.jit',
          '--flag=',
        ],
      );
    },
  );

  test('stageTrainingArgs absolutizes files under staged trees', () {
    final trainDir = Directory('${tmp.path}/train');
    List<String> stage(List<String> args) => snapshot.stageTrainingArgs(
      args,
      trainDir,
      stagedFiles: const {},
      stagedTrees: const ['precompiled'],
    );

    expect(stage(['--precompiled=precompiled']), [
      '--precompiled=${trainDir.path}/precompiled',
    ]);
    expect(stage(['precompiled/a.kmod']), [
      '${trainDir.path}/precompiled/a.kmod',
    ]);
    // A same-named file outside the tree is not staged: only the tree root
    // and what is under it are rewritten.
    expect(stage(['other/precompiled']), ['other/precompiled']);
  });

  test(
    'absoluteHomeEnv resolves scratch-relative home variables absolutely',
    () {
      final trainDir = Directory('${tmp.path}/train');
      // An absolute path on the host: '/abs/cache' reads absolute on POSIX
      // but drive-relative on Windows, so derive it from the test's own
      // temporary directory, which is absolute on every OS.
      final absCache = '${tmp.path}/cache';
      final staged = snapshot.absoluteHomeEnv({
        'HOME': '.',
        'TMPDIR': 'scratch-tmp',
        'DART_TEST_CONFIG': 'none/DartTest.yaml',
        'PUB_CACHE': absCache,
      }, trainDir);

      expect(staged['HOME'], '${trainDir.path}/.');
      expect(staged['TMPDIR'], '${trainDir.path}/scratch-tmp');
      // Non-home variables keep their value, resolving against the training
      // directory at runtime.
      expect(staged['DART_TEST_CONFIG'], 'none/DartTest.yaml');
      expect(staged['PUB_CACHE'], absCache);
    },
  );

  /// Why the constant-training-path tests skip on Windows: there each build
  /// trains in a private scratch directory whose path names the build, so
  /// equal inputs train different bytes by design (see the Windows paragraph
  /// in the app_jit_snapshot.dart header).
  const posixOnlyReason =
      'constant-path training is POSIX-only: on Windows each build trains '
      'in a private scratch directory whose path names the build, so equal '
      'inputs train different bytes by design';

  test('app-jit training matches across working-directory layouts', () {
    final dartBin = Platform.resolvedExecutable;
    // A JIT-heavy program: hot loops that optimize, several small classes,
    // string-keyed maps, closures. Training this in varying directories
    // trains different bytes from the same inputs (systematically, not
    // rarely); at the constant training path every layout must write one
    // snapshot.
    final trainScript = File('${tmp.path}/layout_train.dart')
      ..writeAsStringSync(
        'class K0 { final int v; K0(this.v); int f() => v * 2 + 1; }\n'
        'class K1 { final String s; K1(this.s); int f() => s.length * 3; }\n'
        'class K2 { final double d; K2(this.d); int f() => d.toInt() - 7; }\n'
        'class K3 { final List<int> l; K3(this.l); int f() => l.fold(0, (a, b) => a + b); }\n'
        'class K4 { final Map<String, int> m; K4(this.m); int f() => m.values.fold(0, (a, b) => a + b); }\n'
        'class K5 { final bool b; K5(this.b); int f() => b ? 11 : 13; }\n'
        'class K6 { final int a, c; K6(this.a, this.c); int f() => a * a + c; }\n'
        'class K7 { final String x, y; K7(this.x, this.y); int f() => (x + y).length; }\n'
        'int apply(Object o) => (o as dynamic).f() as int;\n'
        'void main() {\n'
        '  final objs = <Object>[K0(3), K1(\'abc\'), K2(2.5), K3([1, 2, 3]), K4({\'a\': 1}), K5(true), K6(4, 5), K7(\'x\', \'yy\')];\n'
        '  final table = <String, int Function(int)>{};\n'
        '  for (var i = 0; i < objs.length; i++) {\n'
        '    final o = objs[i];\n'
        '    table[\'k\$i\'] = (int x) => apply(o) + x + i;\n'
        '  }\n'
        '  var acc = 0;\n'
        '  for (var iter = 0; iter < 5000; iter++) {\n'
        '    for (var k = 0; k < objs.length; k++) {\n'
        '      acc += table[\'k\$k\']!(iter & 255) + apply(objs[(iter + k) % objs.length]);\n'
        '    }\n'
        '  }\n'
        '  print(acc);\n'
        '}\n',
      );
    // The training input is a compiled kernel, as in real builds (the
    // `jit-snapshot` action trains `input.dill`): compiling once keeps the
    // input bytes fixed, so only the working directories vary.
    final trainDill = File('${tmp.path}/layout_train.dill');
    final compileRes = Process.runSync(dartBin, [
      'compile',
      'kernel',
      trainScript.path,
      '-o',
      trainDill.path,
    ]);
    expect(compileRes.exitCode, 0, reason: '${compileRes.stderr}');

    // Layouts: nine splits with the same total path length but different
    // content (the sandboxed-vs-local shape that trained different bytes),
    // sixteen lengths covering every length mod 16 (a past fixed-length
    // design trained different bytes by length mod 16), one long output
    // directory near the old 290-character budget (which now simply works),
    // and a rerun of the first layout. Every training of the same kernel
    // must write one snapshot.
    String repeat(String char, int count) => List.filled(count, char).join();
    final layoutNames = <String>[
      for (final i in [1, 2, 3, 8, 13, 21, 29, 37, 39])
        'mid/x/m/${repeat('a', i)}/${repeat('b', 40 - i)}/bin/pkg',
      // Sixteen consecutive lengths: whatever `${tmp.path}/layouts` reads,
      // the output directories cover every residue mod 16.
      for (var k = 1; k <= 16; k++) 'mod/${repeat('e', k)}',
      // Near the old 290-character budget (POSIX only, like the rest of
      // this test).
      'long/${repeat('x', 220)}/pkg',
      'mid/x/m/${repeat('a', 1)}/${repeat('b', 39)}/bin/pkg/rerun',
    ];
    expect(layoutNames.length, greaterThanOrEqualTo(12));
    // The sixteen `mod/` output directories really do cover every residue:
    // their lengths are consecutive whatever `${tmp.path}` reads.
    expect({
      for (final layout in layoutNames)
        '${tmp.path}/layouts/$layout'.length % 16,
    }, equals({for (var r = 0; r < 16; r++) r}));

    List<int> trainIn(String layout) {
      final root = Directory('${tmp.path}/layouts/$layout')
        ..createSync(recursive: true);
      final outJit = File('${root.path}/app.jit');
      snapshot.main([
        '--dart=$dartBin',
        '--snapshot=${outJit.path}',
        '--env=TMPDIR=.',
        '--env=HOME=.',
        '--copy=input.dill=${trainDill.path}',
        '--',
        'input.dill',
      ]);
      expect(outJit.existsSync(), isTrue, reason: 'snapshot in $layout');
      // Nothing undeclared stays behind: neither the training VM copy nor
      // the training scratch directory.
      final leftovers = root
          .listSync()
          .where((e) => e.path != outJit.path)
          .toList();
      expect(leftovers, isEmpty, reason: 'no leftovers in $layout: $leftovers');
      return outJit.readAsBytesSync();
    }

    final first = trainIn(layoutNames.first);
    for (final layout in layoutNames.skip(1)) {
      expect(trainIn(layout), equals(first), reason: 'layout $layout');
    }
  }, skip: Platform.isWindows ? posixOnlyReason : false);

  test('app-jit training failure leaves no scratch beside the output', () {
    // A training run that fails (here: the program throws) must fail the
    // tool without stranding its scratch directory. The tool exits on
    // failure, so it runs in a subprocess: an in-process exit would kill
    // this test runner.
    final tool = stageTool();
    final failScript = File('${tmp.path}/fail_train.dart')
      ..writeAsStringSync(
        'void main(List<String> args) {\n  throw "nope";\n}\n',
      );
    final failDill = File('${tmp.path}/fail_train.dill');
    final compileRes = Process.runSync(Platform.resolvedExecutable, [
      'compile',
      'kernel',
      failScript.path,
      '-o',
      failDill.path,
    ]);
    expect(compileRes.exitCode, 0, reason: '${compileRes.stderr}');
    final outJit = File('${tmp.path}/fail/app.jit');
    final res = Process.runSync(
      Platform.resolvedExecutable,
      [
        tool,
        '--dart=${Platform.resolvedExecutable}',
        '--snapshot=${outJit.path}',
        '--copy=input.dill=${failDill.path}',
        '--',
        'input.dill',
      ],
      // The staged tool cannot see the in-process overrides.
      environment: constantTrainEnv(),
    );
    expect(res.exitCode, isNot(0));
    if (!Platform.isWindows) {
      // At the constant path the failed training must delete its directory
      // before releasing the lock, too.
      expect(
        FileSystemEntity.typeSync(
          snapshot.constantTrainDir,
          followLinks: false,
        ),
        FileSystemEntityType.notFound,
        reason: 'constant training directory deleted on failure',
      );
    }
  });

  test(
    'stale own entries are removed and training keeps constant-path bytes',
    () {
      // A stale entry of our own at the training path — file, symlink, FIFO —
      // is removed without being read, and the training uses the constant path
      // with unchanged bytes: no host state leaks into the shared output under
      // the same action key.
      final trainDir = snapshot.constantTrainDir;
      final dill = compileDill(
        'void main(List<String> args) {\n  print(10000);\n}\n',
        'stale_train',
      );

      List<int> train(String name) =>
          trainAtConstant(dill: dill, out: '${tmp.path}/$name/app.jit');

      final first = train('stale_clear');
      expect(
        File(snapshot.constantTrainLock).existsSync(),
        isTrue,
        reason: 'lock file proves the constant path was used',
      );

      // A stale regular file of our own is removed, never read.
      File(trainDir).writeAsStringSync('stale');
      expect(train('stale_file'), equals(first));
      expect(
        FileSystemEntity.typeSync(trainDir, followLinks: false),
        FileSystemEntityType.notFound,
      );

      // A stale symlink of our own is unlinked as a link: its target keeps only
      // its sentinel, with its bytes untouched.
      final victim = Directory('${tmp.path}/stale_victim')..createSync();
      File('${victim.path}/sentinel').writeAsStringSync('untouched');
      Link(trainDir).createSync(victim.path);
      expect(train('stale_link'), equals(first));
      expect(
        FileSystemEntity.typeSync(trainDir, followLinks: false),
        FileSystemEntityType.notFound,
      );
      expect(File('${victim.path}/sentinel').readAsStringSync(), 'untouched');
      expect(victim.listSync().map((e) => e.path.split('/').last).toList(), [
        'sentinel',
      ]);

      // A stale FIFO of our own is unlinked without blocking.
      final mkfifo = Process.runSync('mkfifo', [trainDir]);
      expect(mkfifo.exitCode, 0, reason: '${mkfifo.stderr}');
      expect(train('stale_fifo'), equals(first));
      expect(
        FileSystemEntity.typeSync(trainDir, followLinks: false),
        FileSystemEntityType.notFound,
      );
    },
    skip: Platform.isWindows ? posixOnlyReason : false,
  );

  test('removeStaleEntry removes any entry type without following links', () {
    final base = '${tmp.path}/entries';
    // A regular file.
    final file = File('$base/file')
      ..createSync(recursive: true)
      ..writeAsStringSync('x');
    expect(snapshot.removeStaleEntry(file.path), isTrue);
    expect(file.existsSync(), isFalse);
    // An absent path is already clear.
    expect(snapshot.removeStaleEntry('$base/missing'), isTrue);
    // A symlink is unlinked as a link: its target is untouched.
    final target = Directory('$base/target')..createSync(recursive: true);
    File('${target.path}/sentinel').writeAsStringSync('untouched');
    final link = Link('$base/link');
    link.createSync(target.path);
    expect(snapshot.removeStaleEntry(link.path), isTrue);
    expect(
      FileSystemEntity.typeSync(link.path, followLinks: false),
      FileSystemEntityType.notFound,
    );
    expect(File('${target.path}/sentinel').readAsStringSync(), 'untouched');
    // A FIFO.
    final fifo = '$base/fifo';
    final mkfifo = Process.runSync('mkfifo', [fifo]);
    expect(mkfifo.exitCode, 0, reason: '${mkfifo.stderr}');
    expect(snapshot.removeStaleEntry(fifo), isTrue);
    expect(
      FileSystemEntity.typeSync(fifo, followLinks: false),
      FileSystemEntityType.notFound,
    );
    // A directory holding a nested symlink is removed without following the
    // link: the link's target keeps its file.
    final outerTarget = Directory('$base/outer_target')
      ..createSync(recursive: true);
    File('${outerTarget.path}/keep').writeAsStringSync('keep');
    final dir = Directory('$base/dir')..createSync(recursive: true);
    File('${dir.path}/inner.txt').writeAsStringSync('inner');
    Link('${dir.path}/escape').createSync(outerTarget.path);
    expect(snapshot.removeStaleEntry(dir.path), isTrue);
    expect(Directory(dir.path).existsSync(), isFalse);
    expect(File('${outerTarget.path}/keep').readAsStringSync(), 'keep');
    // The hook is replaceable: a false return pins the fail-closed path.
    final real = snapshot.removeStaleEntry;
    snapshot.removeStaleEntry = (_) => false;
    try {
      expect(snapshot.removeStaleEntry(file.path), isFalse);
    } finally {
      snapshot.removeStaleEntry = real;
    }
  }, skip: Platform.isWindows ? posixOnlyReason : false);

  test('lock file without group/other write bits is fixed to 0666', () {
    // A lock of our own left with a restrictive umask's bits still opens
    // append-only (we own it), and the open fixes the missing group/other
    // write bits umask-proof, so every user on a shared host can open it.
    // The lock file is never written.
    final lock = File(snapshot.constantTrainLock);
    lock.writeAsStringSync('seed');
    snapshot.chmodFile(lock.path, 0x180); // 0600.
    final dill = compileDill(
      'void main(List<String> args) {\n  print(10000);\n}\n',
      'lockbits_train',
    );
    trainAtConstant(dill: dill, out: '${tmp.path}/lockbits/app.jit');
    expect(lock.statSync().mode & 0x1ff, 0x1b6);
    expect(lock.readAsStringSync(), 'seed');
  }, skip: Platform.isWindows ? posixOnlyReason : false);

  test('unwritable lock fails closed without the fallback flag', () {
    // A lock nobody can open append-only (as another user's 0644 lock looks
    // to us) fails the action instead of training under a shared lock: two
    // trainings holding one shared lock could both reach the constant path,
    // and the second would delete the first's live training directory as its
    // own. The tool runs in a subprocess (it exits on failure), with the
    // lock path pointed at the unwritable file through the environment: the
    // variables are the subprocess hook for the in-process overrides.
    final tool = stageTool();
    final dill = compileDill(
      'void main(List<String> args) {\n  print(10000);\n}\n',
      'lockblocked_train',
    );
    final lock = File('${tmp.path}/foreign.lock')
      ..writeAsStringSync('not ours to open');
    snapshot.chmodFile(lock.path, 0x124); // 0444.
    final trainEnv = {
      'RULES_DART_JIT_TRAIN_DIR': snapshot.constantTrainDir,
      'RULES_DART_JIT_TRAIN_LOCK': lock.path,
    };
    List<String> toolArgs(String snapshotOut, {bool fallback = false}) => [
      tool,
      '--dart=${Platform.resolvedExecutable}',
      '--snapshot=$snapshotOut',
      if (fallback) '--fallback-allowed',
      '--copy=input.dill=$dill',
      '--',
      'input.dill',
    ];
    final outJit = '${tmp.path}/lockblocked_out/app.jit';
    final denied = Process.runSync(
      Platform.resolvedExecutable,
      toolArgs(outJit),
      environment: trainEnv,
    );
    expect(denied.exitCode, isNot(0), reason: 'locked-out training must fail');
    expect(File(outJit).existsSync(), isFalse);
    final err = denied.stderr as String;
    expect(err, contains('cannot train in ${snapshot.constantTrainDir}'));
    expect(err, contains('cannot be opened for writing'));
    expect(err, contains(lock.path));
    expect(err, contains('regular file'));
    final id = Process.runSync('id', ['-u']);
    expect(id.exitCode, 0);
    expect(err, contains('owned by uid ${(id.stdout as String).trim()}'));
    expect(err, contains('chmod 0666'));
    expect(err, contains('jit_snapshot_fallback=true'));
    expect(err, contains('test_runner_snapshot=false'));
    expect(
      lock.readAsStringSync(),
      'not ours to open',
      reason: 'lock never touched',
    );

    final allowedOut = '${tmp.path}/lockblocked_allowed/app.jit';
    final allowed = Process.runSync(
      Platform.resolvedExecutable,
      toolArgs(allowedOut, fallback: true),
      environment: trainEnv,
    );
    expect(allowed.exitCode, 0, reason: '${allowed.stderr}');
    expect(File(allowedOut).existsSync(), isTrue);
  }, skip: Platform.isWindows ? posixOnlyReason : false);

  test('libc variadic calls bind through VarArgs', () {
    // `fcntl` and `open` are variadic in libc (`int fcntl(int, int, ...)`).
    // On Apple arm64 variadic arguments travel on the stack, so a fixed
    // binding passes the `struct flock` pointer where `fcntl` never reads
    // it and the holder lookup reports "unknown". Linux passes either way,
    // so this pins the binding shape itself; the deadline test below is the
    // behavioral cover.
    final staged = stageTool();
    final source = File(staged).readAsStringSync();
    expect(
      source,
      contains('ffi.VarArgs<(ffi.Pointer<ffi.Uint8>,)>'),
      reason: 'fcntl binds its flock pointer as a variadic argument',
    );
    expect(
      source,
      contains('ffi.VarArgs<(ffi.Int,)>'),
      reason: 'open binds its mode as a variadic argument',
    );
  });

  test('held lock fails after the deadline naming the holder', () async {
    // Another process holding the training lock must not hang the training
    // forever: the run waits until its deadline, then fails closed naming
    // the lock, the holder's PID, the deadline and the remedies. The tool
    // runs in a subprocess (it exits on failure).
    final holderScript = writeLockHolder();
    final lock = '${tmp.path}/held.lock';
    final holder = await startLockHolder(holderScript, lock, '30');
    try {
      final tool = stageTool();
      final dill = compileDill(
        'void main(List<String> args) {\n  print(10000);\n}\n',
        'deadline_train',
      );
      final trainDir = '${tmp.path}/held_jit';
      final trainEnv = {
        'RULES_DART_JIT_TRAIN_DIR': trainDir,
        'RULES_DART_JIT_TRAIN_LOCK': lock,
      };
      final outJit = '${tmp.path}/held_out/app.jit';
      final stopwatch = Stopwatch()..start();
      final denied = Process.runSync(Platform.resolvedExecutable, [
        tool,
        '--dart=${Platform.resolvedExecutable}',
        '--snapshot=$outJit',
        '--lock-timeout=2',
        '--copy=input.dill=$dill',
        '--',
        'input.dill',
      ], environment: trainEnv);
      stopwatch.stop();
      expect(denied.exitCode, isNot(0), reason: 'held lock must fail');
      expect(File(outJit).existsSync(), isFalse);
      final err = denied.stderr as String;
      expect(err, contains('cannot train in $trainDir'));
      expect(err, contains(lock));
      expect(err, contains('${holder.pid}'));
      expect(err, contains('after waiting 2 seconds'));
      expect(err, contains('jit_snapshot_lock_timeout'));
      expect(err, contains('jit_snapshot_fallback=true'));
      expect(err, contains('test_runner_snapshot=false'));
      // A 2 s deadline waits without a notice: the first notice goes out
      // after 10 s of waiting.
      expect(err, isNot(contains('waiting for')));
      expect(
        stopwatch.elapsedMilliseconds,
        greaterThanOrEqualTo(1000),
        reason: 'the run waits out its deadline rather than failing fast',
      );
    } finally {
      holder.kill();
      await holder.exitCode;
    }
  }, skip: Platform.isWindows ? posixOnlyReason : false);

  test('held lock falls back where allowed', () async {
    // At the deadline the training counts as unavailable, so with the
    // fallback allowed the run trains in scratch and succeeds.
    final holderScript = writeLockHolder();
    final lock = '${tmp.path}/held_fb.lock';
    final holder = await startLockHolder(holderScript, lock, '30');
    try {
      final tool = stageTool();
      final dill = compileDill(
        'void main(List<String> args) {\n  print(10000);\n}\n',
        'deadline_fb_train',
      );
      final trainEnv = {
        'RULES_DART_JIT_TRAIN_DIR': '${tmp.path}/held_fb_jit',
        'RULES_DART_JIT_TRAIN_LOCK': lock,
      };
      final outJit = '${tmp.path}/held_fb_out/app.jit';
      final allowed = Process.runSync(Platform.resolvedExecutable, [
        tool,
        '--dart=${Platform.resolvedExecutable}',
        '--snapshot=$outJit',
        '--lock-timeout=2',
        '--fallback-allowed',
        '--copy=input.dill=$dill',
        '--',
        'input.dill',
      ], environment: trainEnv);
      expect(allowed.exitCode, 0, reason: '${allowed.stderr}');
      expect(File(outJit).existsSync(), isTrue);
    } finally {
      holder.kill();
      await holder.exitCode;
    }
  }, skip: Platform.isWindows ? posixOnlyReason : false);

  test('released lock trains before the deadline', () async {
    // A holder that releases mid-wait hands the lock over: the training
    // proceeds at the injected path with no fallback.
    final holderScript = writeLockHolder();
    final holder = await startLockHolder(
      holderScript,
      snapshot.constantTrainLock,
      '1',
    );
    try {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final dill = compileDill(
        'void main(List<String> args) {\n  print(10000);\n}\n',
        'release_train',
      );
      final outJit = File('${tmp.path}/release_out/app.jit');
      snapshot.main([
        '--dart=${Platform.resolvedExecutable}',
        '--snapshot=${outJit.path}',
        '--lock-timeout=5',
        '--env=TMPDIR=.',
        '--env=HOME=.',
        '--copy=input.dill=$dill',
        '--',
        'input.dill',
      ]);
      expect(outJit.existsSync(), isTrue, reason: 'snapshot written');
      expect(
        FileSystemEntity.typeSync(
          snapshot.constantTrainDir,
          followLinks: false,
        ),
        FileSystemEntityType.notFound,
        reason: 'training directory deleted after the run',
      );
    } finally {
      holder.kill();
      await holder.exitCode;
    }
  }, skip: Platform.isWindows ? posixOnlyReason : false);

  test('no waiting notice when the lock is free', () {
    // A training that takes a free lock stays silent: notices go out only
    // past 10 s of waiting. The tool runs in a subprocess so its stderr can
    // be read back.
    final tool = stageTool();
    final dill = compileDill(
      'void main(List<String> args) {\n  print(10000);\n}\n',
      'quiet_train',
    );
    final outJit = '${tmp.path}/quiet_out/app.jit';
    final res = Process.runSync(Platform.resolvedExecutable, [
      tool,
      '--dart=${Platform.resolvedExecutable}',
      '--snapshot=$outJit',
      '--lock-timeout=2',
      '--copy=input.dill=$dill',
      '--',
      'input.dill',
    ], environment: constantTrainEnv());
    expect(res.exitCode, 0, reason: '${res.stderr}');
    expect(File(outJit).existsSync(), isTrue);
    expect(res.stderr as String, isNot(contains('waiting for')));
  }, skip: Platform.isWindows ? posixOnlyReason : false);

  test('train key selects keyed paths', () {
    // The key routes the training without touching the filesystem: with no
    // injected paths set, the keyed directory and lock name the key, and two
    // keys name different paths, so their trainings run in parallel.
    final realDir = snapshot.trainDirOverride;
    final realLock = snapshot.trainLockOverride;
    snapshot.trainDirOverride = null;
    snapshot.trainLockOverride = null;
    try {
      snapshot.trainKeyOverride = '0123456789abcdef';
      expect(snapshot.constantTrainDir, '/tmp/rules_dart_jit-0123456789abcdef');
      expect(
        snapshot.constantTrainLock,
        '/tmp/rules_dart_jit-0123456789abcdef.lock',
      );
      snapshot.trainKeyOverride = 'fedcba9876543210';
      expect(snapshot.constantTrainDir, '/tmp/rules_dart_jit-fedcba9876543210');
      expect(
        snapshot.constantTrainLock,
        '/tmp/rules_dart_jit-fedcba9876543210.lock',
      );
    } finally {
      snapshot.trainDirOverride = realDir;
      snapshot.trainLockOverride = realLock;
      snapshot.trainKeyOverride = null;
    }
  });

  test('a holder on one path does not block another', () async {
    // Per-path contention: a holder on one training lock leaves a training
    // at another path to take its own lock straight away.
    final holderScript = writeLockHolder();
    final holder = await startLockHolder(
      holderScript,
      '${tmp.path}/other.lock',
      '30',
    );
    try {
      snapshot.trainDirOverride = '${tmp.path}/other_jit';
      snapshot.trainLockOverride = '${tmp.path}/own.lock';
      final dill = compileDill(
        'void main(List<String> args) {\n  print(10000);\n}\n',
        'other_train',
      );
      final outJit = File('${tmp.path}/other_out/app.jit');
      snapshot.main([
        '--dart=${Platform.resolvedExecutable}',
        '--snapshot=${outJit.path}',
        '--env=TMPDIR=.',
        '--env=HOME=.',
        '--copy=input.dill=$dill',
        '--',
        'input.dill',
      ]);
      expect(outJit.existsSync(), isTrue, reason: 'snapshot written');
    } finally {
      holder.kill();
      await holder.exitCode;
    }
  }, skip: Platform.isWindows ? posixOnlyReason : false);

  test(
    'read-only own tree is cleared and training keeps constant-path bytes',
    () {
      // A crashed training can leave a read-only tree (Bazel inputs and
      // outputs are read-only and copies keep modes): an owned directory is
      // made writable before it is listed, so our own stale trees clear and
      // the training uses the constant path with unchanged bytes.
      final trainDir = snapshot.constantTrainDir;
      final dill = compileDill(
        'void main(List<String> args) {\n  print(10000);\n}\n',
        'rotree_train',
      );
      final first = trainAtConstant(
        dill: dill,
        out: '${tmp.path}/rotree_clear/app.jit',
      );
      final deep = Directory('$trainDir/ro/deep')..createSync(recursive: true);
      File('${deep.path}/f').writeAsStringSync('stale');
      snapshot.chmodFile('$trainDir/ro', 0x155); // 0555.
      snapshot.chmodFile(deep.path, 0x155); // 0555.
      expect(
        trainAtConstant(dill: dill, out: '${tmp.path}/rotree_ro/app.jit'),
        equals(first),
      );
      expect(
        FileSystemEntity.typeSync(trainDir, followLinks: false),
        FileSystemEntityType.notFound,
      );
    },
    skip: Platform.isWindows ? posixOnlyReason : false,
  );

  test('unremovable blocker fails closed without the fallback flag', () {
    // A blocker no removal can take: the parent directory is read-only, so
    // unlinking the entry fails even for its owner. The tool runs in a
    // subprocess (it exits on failure), with the training paths pointed at
    // the blocker through the environment.
    final tool = stageTool();
    final dill = compileDill(
      'void main(List<String> args) {\n  print(10000);\n}\n',
      'blocked_train',
    );
    final parent = Directory('${tmp.path}/blocked')..createSync();
    final blocker = File('${parent.path}/jit')
      ..writeAsStringSync('not ours to remove');
    snapshot.chmodFile(parent.path, 0x155); // 0555.
    List<String> toolArgs(String snapshotOut, {bool fallback = false}) => [
      tool,
      '--dart=${Platform.resolvedExecutable}',
      '--snapshot=$snapshotOut',
      if (fallback) '--fallback-allowed',
      '--copy=input.dill=$dill',
      '--',
      'input.dill',
    ];
    final trainEnv = {
      'RULES_DART_JIT_TRAIN_DIR': blocker.path,
      'RULES_DART_JIT_TRAIN_LOCK': snapshot.constantTrainLock,
    };
    try {
      final outJit = '${tmp.path}/blocked_out/app.jit';
      final denied = Process.runSync(
        Platform.resolvedExecutable,
        toolArgs(outJit),
        environment: trainEnv,
      );
      expect(denied.exitCode, isNot(0), reason: 'blocked training must fail');
      expect(File(outJit).existsSync(), isFalse);
      final err = denied.stderr as String;
      expect(err, contains('cannot train in ${blocker.path}'));
      expect(err, contains('cannot be removed'));
      expect(err, contains('regular file'));
      final id = Process.runSync('id', ['-u']);
      expect(id.exitCode, 0);
      expect(err, contains('owned by uid ${(id.stdout as String).trim()}'));
      expect(err, contains('jit_snapshot_fallback=true'));
      expect(err, contains('test_runner_snapshot=false'));
      expect(
        File(blocker.path).readAsStringSync(),
        'not ours to remove',
        reason: 'blocker never touched',
      );

      final allowedOut = '${tmp.path}/blocked_allowed/app.jit';
      final allowed = Process.runSync(
        Platform.resolvedExecutable,
        toolArgs(allowedOut, fallback: true),
        environment: trainEnv,
      );
      expect(allowed.exitCode, 0, reason: '${allowed.stderr}');
      expect(File(allowedOut).existsSync(), isTrue);
    } finally {
      snapshot.chmodFile(parent.path, 0x1ed);
    }
  }, skip: Platform.isWindows ? posixOnlyReason : false);

  test('unclaimable training path fails closed without the fallback flag', () {
    // The delete-to-create race lost: another local user created the training
    // directory in the window, so the atomic mkdir claim sees EEXIST. Forced
    // through the mkdir hook in a staged copy of the tool; the in-process
    // hook resets in tearDown, and the failure names the blocker.
    final tool = stagePatchedTool(
      'int Function(String path, int mode) mkdirExclusive = _libcMkdir;',
      'int Function(String path, int mode) mkdirExclusive = (_, __) => -1;',
    );
    final dill = compileDill(
      'void main(List<String> args) {\n  print(10000);\n}\n',
      'unclaimable_train',
    );
    final trainDir = '${tmp.path}/unclaimable_jit';
    final trainEnv = {
      'RULES_DART_JIT_TRAIN_DIR': trainDir,
      'RULES_DART_JIT_TRAIN_LOCK': snapshot.constantTrainLock,
    };
    List<String> toolArgs(String snapshotOut, {bool fallback = false}) => [
      tool,
      '--dart=${Platform.resolvedExecutable}',
      '--snapshot=$snapshotOut',
      if (fallback) '--fallback-allowed',
      '--copy=input.dill=$dill',
      '--',
      'input.dill',
    ];
    final outJit = '${tmp.path}/unclaimable_out/app.jit';
    final denied = Process.runSync(
      Platform.resolvedExecutable,
      toolArgs(outJit),
      environment: trainEnv,
    );
    expect(denied.exitCode, isNot(0), reason: 'unclaimable training must fail');
    expect(File(outJit).existsSync(), isFalse);
    expect(denied.stderr as String, contains('cannot be claimed'));

    final allowedOut = '${tmp.path}/unclaimable_allowed/app.jit';
    final allowed = Process.runSync(
      Platform.resolvedExecutable,
      toolArgs(allowedOut, fallback: true),
      environment: trainEnv,
    );
    expect(allowed.exitCode, 0, reason: '${allowed.stderr}');
    expect(File(allowedOut).existsSync(), isTrue);
  }, skip: Platform.isWindows ? posixOnlyReason : false);

  test('pre-existing lock file keeps its content after a training run', () {
    // The lock file opens append-only for its flock and is never written, so
    // a regular file already at the lock path trains (at the constant path,
    // under its flock) and keeps its bytes: no truncate-though-symlink, no
    // clobber.
    final constant = snapshot.constantTrainDir;
    final lock = snapshot.constantTrainLock;
    File(
      '${tmp.path}/lock_train.dart',
    ).writeAsStringSync('void main(List<String> args) {\n  print(10000);\n}\n');
    final trivialDill = File('${tmp.path}/lock_train.dill');
    final compileRes = Process.runSync(Platform.resolvedExecutable, [
      'compile',
      'kernel',
      '${tmp.path}/lock_train.dart',
      '-o',
      trivialDill.path,
    ]);
    expect(compileRes.exitCode, 0, reason: '${compileRes.stderr}');
    File(lock).writeAsStringSync('not-ours');
    final outJit = File('${tmp.path}/lock_content/app.jit');
    snapshot.main([
      '--dart=${Platform.resolvedExecutable}',
      '--snapshot=${outJit.path}',
      '--env=TMPDIR=.',
      '--env=HOME=.',
      '--copy=input.dill=${trivialDill.path}',
      '--',
      'input.dill',
    ]);
    expect(outJit.existsSync(), isTrue, reason: 'snapshot written');
    expect(
      File(lock).readAsStringSync(),
      'not-ours',
      reason: 'lock file never truncated',
    );
    expect(
      FileSystemEntity.typeSync(constant, followLinks: false),
      FileSystemEntityType.notFound,
      reason: 'constant training directory deleted after the run',
    );
  }, skip: Platform.isWindows ? posixOnlyReason : false);

  test('racy claim at the constant training path fails closed', () {
    // Another local user creating the training directory in the
    // delete-to-create window must not hand us a directory they own: the
    // atomic mkdir claim sees EEXIST, and the action fails instead of
    // training in a directory they own, where a swapped binary would run as
    // us. Simulated in a staged copy of the tool whose mkdir plants the
    // directory just before the real mkdir runs (the tool exits on failure,
    // so it runs in a subprocess: an in-process exit would kill this test
    // runner).
    final tool = stagePatchedTool(
      'int Function(String path, int mode) mkdirExclusive = _libcMkdir;',
      'int Function(String path, int mode) mkdirExclusive = (path, mode) {\n'
          '  final planted = Directory(path)..createSync();\n'
          '  File("\${planted.path}/sentinel").writeAsStringSync("theirs");\n'
          '  return _libcMkdir(path, mode);\n'
          '};',
    );
    final dill = compileDill(
      'void main(List<String> args) {\n  print(10000);\n}\n',
      'race_train',
    );
    final trainDir = '${tmp.path}/race_jit';
    final trainEnv = {
      'RULES_DART_JIT_TRAIN_DIR': trainDir,
      'RULES_DART_JIT_TRAIN_LOCK': snapshot.constantTrainLock,
    };
    List<String> toolArgs(String snapshotOut, {bool fallback = false}) => [
      tool,
      '--dart=${Platform.resolvedExecutable}',
      '--snapshot=$snapshotOut',
      if (fallback) '--fallback-allowed',
      '--copy=input.dill=$dill',
      '--',
      'input.dill',
    ];
    final outJit = '${tmp.path}/race_claim/app.jit';
    final denied = Process.runSync(
      Platform.resolvedExecutable,
      toolArgs(outJit),
      environment: trainEnv,
    );
    expect(denied.exitCode, isNot(0), reason: 'raced claim must fail');
    expect(File(outJit).existsSync(), isFalse);
    final err = denied.stderr as String;
    expect(err, contains('cannot train in $trainDir'));
    expect(err, contains('cannot be claimed'));
    expect(
      Directory(trainDir)
          .listSync()
          .map((e) => e.path.split('/').last)
          .toList(),
      ['sentinel'],
      reason: 'VM copy never staged into the raced directory',
    );
    expect(
      File('$trainDir/sentinel').readAsStringSync(),
      'theirs',
      reason: 'raced directory untouched',
    );

    final allowedOut = '${tmp.path}/race_allowed/app.jit';
    final allowed = Process.runSync(
      Platform.resolvedExecutable,
      toolArgs(allowedOut, fallback: true),
      environment: trainEnv,
    );
    expect(allowed.exitCode, 0, reason: '${allowed.stderr}');
    expect(File(allowedOut).existsSync(), isTrue);
  }, skip: Platform.isWindows ? posixOnlyReason : false);

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
      // The shared check classifies exactly what the planner classifies.
      expect(
        guard.findDisallowedDirectives({
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

  test(
    '--gen-kernel refuses a vm:ffi:native-assets import without a manifest',
    () {
      final ws = Directory('${tmp.path}/vm_ws')..createSync(recursive: true);
      final main = File('${ws.path}/main.dart')
        ..writeAsStringSync(
          "import 'vm:ffi:native-assets';\n"
          'void main() => print("unreachable");\n',
        );
      // The classifier refuses the asset-library URI as an other-scheme
      // import: user sources can never name it, manifest or not.
      expect(
        guard.findDisallowedDirectives({
          main.path: main.readAsStringSync(),
        }, tool: 'app_jit_snapshot'),
        [
          "app_jit_snapshot: ${main.path} import 'vm:ffi:native-assets' "
              'is not a declared input.',
        ],
      );
      // End to end: the wrapper fails before running gen_kernel (which is
      // never reached, so no SDK snapshot is needed).
      final toolPath = stageTool();
      final res = Process.runSync(Platform.resolvedExecutable, [
        toolPath,
        '--gen-kernel',
        'never-reached-runtime',
        '--input-source=${main.path}',
      ]);
      expect(res.exitCode, isNonZero);
      expect(
        res.stderr as String,
        contains("import 'vm:ffi:native-assets' is not a declared input"),
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

  test('--gen-kernel refuses sources it cannot scan without compiling', () {
    // Each source hides an escaping directive past a syntax error, so the
    // scanner gives up: the wrapper refuses the file instead of calling it
    // clean, before gen_kernel (which is never reached, so no SDK snapshot
    // is needed) runs.
    final ws = Directory('${tmp.path}/scan_ws')..createSync(recursive: true);
    final sources = [
      "import 'dart:core' if (dart.library.io) ;\n"
          "import '../../host/secret.dart';\n",
      "library a.;\nimport 'file:///etc/hosts';\n",
      "import 'a.dart;\nimport 'file:///etc/hosts';\n",
      "export lib.dart;\nimport '../../host/secret.dart';\n",
      "part foo;\nimport 'file:///etc/hosts';\n",
    ];
    final paths = <String>[];
    for (var i = 0; i < sources.length; i++) {
      final file = File('${ws.path}/bad$i.dart')..writeAsStringSync(sources[i]);
      paths.add(file.path);
    }
    final toolPath = stageTool();
    final res = Process.runSync(Platform.resolvedExecutable, [
      toolPath,
      '--gen-kernel',
      'never-reached-runtime',
      for (final path in paths) '--input-source=$path',
    ]);
    expect(res.exitCode, isNonZero);
    for (final path in paths) {
      expect(res.stderr as String, contains(path));
    }
    expect(res.stderr as String, contains('could not be checked'));
    expect(res.stderr as String, contains('syntax error'));
  });

  test('--gen-kernel refuses a triple-quoted import without compiling', () {
    // The front end drops a whitespace-only first line of a multi-line
    // string, so it reads `/secret/s.dart` where the pre-guard sees a
    // relative declared path. The wrapper refuses every spelling before
    // running gen_kernel (which is never reached, so no SDK snapshot is
    // needed), and refuses a relative target with no staged file too.
    final ws = Directory('${tmp.path}/tq_ws')..createSync(recursive: true);
    File('${ws.path}/ok.dart').writeAsStringSync('const ok = 1;\n');
    final main = File('${ws.path}/main.dart')
      ..writeAsStringSync(
        "import '''   \n/secret/s.dart''';\n"
        'void main() => print(hostSecret);\n',
      );
    File('${ws.path}/raw.dart').writeAsStringSync(
      "import r'''\t\n/secret/s.dart''';\n"
      'const raw = 1;\n',
    );
    File('${ws.path}/dq.dart').writeAsStringSync(
      'import """   \n/secret/s.dart""";\n'
      'const dq = 1;\n',
    );
    File('${ws.path}/exp.dart')
        .writeAsStringSync("export '''   \n/secret/s.dart''';\n");
    File('${ws.path}/missing.dart').writeAsStringSync(
      "import 'nosuch.dart';\n"
      'const missing = 1;\n',
    );
    final toolPath = args.isNotEmpty
        ? Runfiles.create().rlocation(args[0])
        : File.fromUri(Platform.script.resolve('app_jit_snapshot.dart')).path;
    final res = Process.runSync(Platform.resolvedExecutable, [
      toolPath,
      '--gen-kernel',
      'never-reached-runtime',
      '--input-source=${main.path}',
      '--input-source=${ws.path}/raw.dart',
      '--input-source=${ws.path}/dq.dart',
      '--input-source=${ws.path}/exp.dart',
      '--input-source=${ws.path}/missing.dart',
      '--input-source=${ws.path}/ok.dart',
    ]);
    expect(res.exitCode, isNonZero);
    expect(
      res.stderr as String,
      contains("import '   \n/secret/s.dart' is not a declared input"),
    );
    expect(
      res.stderr as String,
      contains("import '\t\n/secret/s.dart' is not a declared input"),
    );
    expect(
      res.stderr as String,
      contains("export '   \n/secret/s.dart' is not a declared input"),
    );
    expect(
      res.stderr as String,
      contains("import 'nosuch.dart' is not a declared input"),
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
    // adds may appear below. Every plant carries a per-test tag: this
    // suite's tests (and the planner suite's) run concurrently, and shared
    // fixed plant names would race between processes.
    final before = sharedCacheNames();
    final tag = 'appjit-test.$pid';
    final plants = <String, String>{
      'kernel_worker_nocomma.snapshot.$tag': 'planted',
      'kernel_worker_nocomma.snapshot.version.$tag': 'planted',
      'gen_kernel_nocomma.snapshot.$tag': 'planted',
      'gen_kernel_nocomma.snapshot.version.$tag': 'planted',
    };
    for (final entry in plants.entries) {
      File('${sysTmp.path}/${entry.key}').writeAsStringSync(entry.value);
    }
    final plantedVmDir = Directory('${sysTmp.path}/rules_dart_vm-planted-$tag')
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
      leftovers.remove('rules_dart_vm-planted-$tag');
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
      bool hasNativeAssetsManifest = false,
    }) {
      final out = File('${tmp.path}/$name')..writeAsBytesSync(bytes);
      return snapshot.verifyGenKernelReads(
        outputPath: out.path,
        declaredKeys: declaredKeys,
        multiRootPrefix: prefix,
        fsRoots: const ['.'],
        packageKeyPrefixes: packageKeyPrefixes,
        hasNativeAssetsManifest: hasNativeAssetsManifest,
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

    test('an unreadable library table fails closed', () {
      final clean = verifyDill(
        sources: [('${prefix}app/main.dart', '${prefix}app/main.dart')],
        libraries: [(0, '${prefix}app/main.dart')],
      );
      // One library node: the trailing index holds 13 fields (nine fixed
      // offsets, two library offsets, the node count, the end marker), so the
      // first library offset sits 16 bytes before the end. Clobbering it
      // leaves the source table and the name tables readable while the library
      // table no longer parses.
      final patched = Uint8List.fromList(clean);
      ByteData.sublistView(patched).setUint32(patched.length - 16, 0xffffffff);
      expect(dillSourceUris(patched), isNotNull);
      expect(dillLibraryReferences(patched), isNull);
      final errors = verify('evil_libraries.dill', patched);
      expect(errors, isNotEmpty);
      expect(errors.join('\n'), contains('cannot read the libraries'));
      expect(errors.join('\n'), contains('evil_libraries.dill'));
    });

    test('an unreadable canonical-name table fails closed', () {
      final clean = verifyDill(
        sources: [('${prefix}app/main.dart', '${prefix}app/main.dart')],
        libraries: [(0, '${prefix}app/main.dart')],
      );
      // The string-table offset is the seventh fixed index field: clobbering
      // it leaves the source table readable while the name tables (and so the
      // canonical roots) no longer parse.
      final patched = Uint8List.fromList(clean);
      ByteData.sublistView(patched)
          .setUint32(patched.length - 13 * 4 + 24, 0xffffffff);
      expect(dillSourceUris(patched), isNotNull);
      expect(dillCanonicalRoots(patched), isNull);
      final errors = verify('evil_roots.dill', patched);
      expect(errors, isNotEmpty);
      expect(errors.join('\n'), contains('cannot read the canonical names'));
      expect(errors.join('\n'), contains('evil_roots.dill'));
    });

    test('an empty component verifies through its source table', () {
      // No library nodes means no library references: the name tables are
      // legitimately absent, not unparsable, and the source-table verdict
      // stands alone.
      expect(
        verify(
          'empty.dill',
          verifyDill(
            sources: [('${prefix}app/main.dart', '${prefix}app/main.dart')],
            libraries: const [],
          ),
        ),
        isEmpty,
      );
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
          hasNativeAssetsManifest: false,
        ),
        isEmpty,
      );
    });

    test('a malformed source-table URI fails closed', () {
      final clean = verifyDill(
        sources: [('${prefix}app/main.dart', '${prefix}app/main.dart')],
        libraries: [(0, '${prefix}app/main.dart')],
      );
      // The first recording of the URI is the source entry's file URI:
      // corrupting it leaves every length prefix intact while the entry no
      // longer decodes.
      final patched = corruptRecordedUri(clean, '${prefix}app/main.dart', 0);
      expect(dillSourceUris(patched), isNull);
      final errors = verify('evil_uri.dill', patched);
      expect(errors, isNotEmpty);
      expect(errors.join('\n'), contains('cannot read the sources'));
    });

    test('a malformed source-table import URI fails closed', () {
      final clean = verifyDill(
        sources: [('${prefix}app/other.dart', '${prefix}app/main.dart')],
        libraries: [(0, '${prefix}app/main.dart')],
      );
      // Distinct spellings record the import URI separately from the file URI,
      // so the first recording of the import spelling is the entry's import
      // URI. The source-reader skips import bytes without decoding them, so
      // the source table still parses; the library-reader decodes them, so
      // the library table no longer parses.
      final patched = corruptRecordedUri(clean, '${prefix}app/main.dart', 0);
      expect(dillSourceUris(patched), isNotNull);
      expect(dillLibraryReferences(patched), isNull);
      final errors = verify(
        'evil_import_uri.dill',
        patched,
        declaredKeys: const {'app/other.dart'},
      );
      expect(errors, isNotEmpty);
      expect(errors.join('\n'), contains('cannot read the libraries'));
    });

    test('a malformed string-table entry degrades to an empty reference', () {
      final clean = verifyDill(
        sources: [('${prefix}app/main.dart', '${prefix}app/main.dart')],
        libraries: [(0, '${prefix}app/main.dart')],
      );
      // The last recording of the URI is the string table's copy: corrupting
      // it leaves the source table readable while the canonical name no longer
      // decodes, degrading to the empty reference the check accepts.
      final patched = corruptRecordedUri(clean, '${prefix}app/main.dart', 2);
      expect(dillSourceUris(patched), isNotNull);
      expect(dillCanonicalRoots(patched), equals(['']));
      expect(verify('degraded.dill', patched), isEmpty);
    });

    test('an unparsable recorded file URI fails closed', () {
      const evil = 'file://[::1/host/evil.dart';
      final errors = verify(
        'evil_file_uri.dill',
        verifyDill(sources: [(evil, evil)], libraries: const []),
      );
      expect(errors, isNotEmpty);
      expect(errors.join('\n'), contains('reads $evil'));
    });

    // The exact shape the front end emits for a `--native-assets` manifest:
    // a `dummy` source-table entry, a node with the `dummy` source, no import
    // URI, and the `vm:ffi:native-assets` canonical name (which is also its
    // own root). With a manifest the whole triple verifies; without one every
    // piece is refused.
    Uint8List nativeAssetsDill() => verifyDill(
      sources: [
        ('${prefix}app/main.dart', '${prefix}app/main.dart'),
        ('dummy', ''),
      ],
      libraries: [(0, '${prefix}app/main.dart'), (1, 'vm:ffi:native-assets')],
    );

    test('a manifest-synthesized native-assets library verifies', () {
      expect(
        verify(
          'native_assets.dill',
          nativeAssetsDill(),
          hasNativeAssetsManifest: true,
        ),
        isEmpty,
      );
    });

    test('synthetic native-assets entries are refused without a manifest', () {
      final errors = verify(
        'native_assets_no_manifest.dill',
        nativeAssetsDill(),
      );
      expect(errors, isNotEmpty);
      expect(errors.join('\n'), contains('reads dummy'));
      expect(errors.join('\n'), contains('references vm:ffi:native-assets'));
    });

    test('a near-miss native-assets shape is refused with a manifest', () {
      // A real file behind the asset-library name still fails: the node must
      // name the `dummy` placeholder, not a workspace file.
      final errors = verify(
        'native_assets_miss.dill',
        verifyDill(
          sources: [
            ('${prefix}app/main.dart', '${prefix}app/main.dart'),
            ('${prefix}app/dummy.dart', '${prefix}app/dummy.dart'),
          ],
          libraries: [
            (0, '${prefix}app/main.dart'),
            (1, 'vm:ffi:native-assets'),
          ],
        ),
        declaredKeys: const {'app/main.dart', 'app/dummy.dart'},
        hasNativeAssetsManifest: true,
      );
      expect(errors, isNotEmpty);
      expect(errors.join('\n'), contains('references vm:ffi:native-assets'));
    });

    test('a user file literally named dummy is refused with a manifest', () {
      final errors = verify(
        'user_dummy.dill',
        verifyDill(
          sources: [
            ('${prefix}app/main.dart', '${prefix}app/main.dart'),
            ('${prefix}dummy', '${prefix}dummy'),
          ],
          libraries: [(0, '${prefix}app/main.dart')],
        ),
        hasNativeAssetsManifest: true,
      );
      expect(errors, isNotEmpty);
      expect(errors.join('\n'), contains('reads ${prefix}dummy'));
    });

    test('a smuggled vm: root is refused without a manifest', () {
      final errors = verify(
        'vm_root.dill',
        verifyDill(
          sources: [('${prefix}app/main.dart', '${prefix}app/main.dart')],
          libraries: [(0, '${prefix}app/main.dart')],
          extraRoots: ['vm:ffi:native-assets'],
        ),
      );
      expect(errors, isNotEmpty);
      expect(errors.join('\n'), contains('references vm:ffi:native-assets'));
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

    test('an unparsable file root maps to nothing', () {
      File('${tmp.path}/evil_root.json').writeAsStringSync(
        jsonEncode({
          'configVersion': 2,
          'packages': [
            {
              'name': 'evil',
              'rootUri': 'file://[::1/pkg',
              'packageUri': 'lib/',
            },
          ],
        }),
      );
      expect(
        snapshot.genKernelPackageKeyPrefixes(
          packagesPath: '${tmp.path}/evil_root.json',
          multiRootPrefix: 'org-dartlang-root:///',
          fsRoots: const ['.'],
        ),
        isEmpty,
      );
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
