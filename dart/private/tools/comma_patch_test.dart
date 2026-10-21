import 'dart:io';
import 'dart:typed_data';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

import 'comma_patch.dart' as patch;

void main(List<String> args) {
  late Directory tmp;
  late List<String> sdkDirs;
  late String commaPatchSource;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('comma_patch_test_');
  });

  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  setUpAll(() {
    // Under Bazel the first argument is the `comma_patch.dart` source (see
    // BUILD.bazel) and the rest are SDK `dart` binaries; a direct `dart test`
    // run passes none, so the source sits beside this test and the running
    // `dart` names its SDK.
    final dartArgs = <String>[];
    if (args.isNotEmpty) {
      final r = Runfiles.create();
      commaPatchSource = r.rlocation(args[0]);
      dartArgs.addAll([for (final a in args.sublist(1)) r.rlocation(a)]);
    } else {
      commaPatchSource = File.fromUri(
        Platform.script.resolve('comma_patch.dart'),
      ).path;
    }
    if (dartArgs.isEmpty) dartArgs.add(Platform.resolvedExecutable);
    sdkDirs = [for (final d in dartArgs) File(d).parent.parent.path];
  });

  group('patchSnapshotSplitCommasBytes', () {
    test('patches the x64 pattern at the documented offsets', () {
      final bytes = Uint8List.fromList([
        0x00,
        0x01,
        0x48,
        0x8b,
        0x45,
        0xf0,
        0x48,
        0x8b,
        0x48,
        0x5f,
        0xf6,
        0xc1,
        0x10,
        0x0f,
        0x85,
        0x3a,
        0x01,
        0x00,
        0x00,
        0x48,
        0x8b,
        0x4d,
        0xe8,
        0x8b,
        0x51,
        0xff,
        0x02,
        0x03,
      ]);
      expect(patch.patchSnapshotSplitCommasBytes(bytes), isTrue);
      // +11 becomes nop, +12 becomes the jmp opcode; the pattern no longer
      // matches, so a second patch reports nothing to do.
      expect(bytes[2 + 11], 0x90);
      expect(bytes[2 + 12], 0xe9);
      expect(patch.patchSnapshotSplitCommasBytes(bytes), isFalse);
      expect(bytes.sublist(bytes.length - 2), [0x02, 0x03]);
    });

    test('patches the arm64 pattern at the documented offsets', () {
      final bytes = Uint8List.fromList([
        0xa3,
        0x03,
        0x5f,
        0xf8,
        0x60,
        0xf0,
        0x45,
        0xf8,
        0xc0,
        0x09,
        0x20,
        0x37,
        0xa0,
        0x83,
        0x5e,
        0xf8,
        0x01,
        0xf0,
        0x5f,
        0xf8,
      ]);
      expect(patch.patchSnapshotSplitCommasBytes(bytes), isTrue);
      expect(bytes.sublist(8, 12), [0x4e, 0x00, 0x00, 0x14]);
      expect(patch.patchSnapshotSplitCommasBytes(bytes), isFalse);
    });

    test('leaves buffers without a pattern untouched', () {
      final bytes = Uint8List.fromList([for (var i = 0; i < 256; i++) i]);
      final before = Uint8List.fromList(bytes);
      expect(patch.patchSnapshotSplitCommasBytes(bytes), isFalse);
      expect(bytes, before);
      expect(patch.patchSnapshotSplitCommasBytes(Uint8List(0)), isFalse);
    });
  });

  group('hasCommaDefineArgs', () {
    test('detects every spelling the frontend accepts', () {
      expect(patch.hasCommaDefineArgs(['-DFOO=a,b']), isTrue);
      expect(patch.hasCommaDefineArgs(['-D', 'FOO=a,b']), isTrue);
      expect(patch.hasCommaDefineArgs(['--define=FOO=a,b']), isTrue);
      expect(patch.hasCommaDefineArgs(['--define', 'FOO=a,b']), isTrue);
      expect(
        patch.hasCommaDefineArgs(['--platform=x', '-DFOO=a,b', '-o=out']),
        isTrue,
      );
    });

    test('ignores comma-free defines', () {
      expect(patch.hasCommaDefineArgs([]), isFalse);
      expect(patch.hasCommaDefineArgs(['-DFOO=a', '--define=B=c']), isFalse);
      expect(patch.hasCommaDefineArgs(['-D']), isFalse);
      expect(patch.hasCommaDefineArgs(['--define']), isFalse);
      // A comma in a non-define flag is not a define value.
      expect(patch.hasCommaDefineArgs(['--filesystem-root=a,b']), isFalse);
    });
  });

  group('unpatchedCommaDefinesError', () {
    test('fails loudly only for comma defines without a patched snapshot', () {
      expect(
        patch.unpatchedCommaDefinesError(
          [],
          snapshotPatched: false,
          snapshotKind: 'gen_kernel',
          toolName: 'test',
        ),
        isNull,
      );
      expect(
        patch.unpatchedCommaDefinesError(
          ['-DFOO=a,b'],
          snapshotPatched: true,
          snapshotKind: 'gen_kernel',
          toolName: 'test',
        ),
        isNull,
      );
      final error = patch.unpatchedCommaDefinesError(
        ['-DFOO=a,b'],
        snapshotPatched: false,
        snapshotKind: 'gen_kernel',
        toolName: 'test',
      );
      expect(error, isNotNull);
      expect(error, contains('comma'));
      expect(error, contains('gen_kernel'));
    });
  });

  group('patchSnapshotFile', () {
    test('reports an unreadable input without writing an output', () {
      final out = File('${tmp.path}/out.snapshot');
      final error = patch.patchSnapshotFile(
        inputPath: '${tmp.path}/missing.snapshot',
        outputPath: out.path,
        sdkVersion: '3.13.5',
        snapshotKind: 'kernel_worker',
      );
      expect(error, contains('cannot read'));
      expect(error, contains('kernel_worker'));
      expect(out.existsSync(), isFalse);
    });

    test('fails loudly when no pattern matches', () {
      final input = File('${tmp.path}/in.snapshot')
        ..writeAsBytesSync([for (var i = 0; i < 64; i++) i]);
      final out = File('${tmp.path}/out.snapshot');
      final error = patch.patchSnapshotFile(
        inputPath: input.path,
        outputPath: out.path,
        sdkVersion: '3.13.5',
        snapshotKind: 'gen_kernel',
      );
      expect(error, contains('matches no known comma-split pattern'));
      expect(error, contains('3.13.5'));
      expect(error, contains('gen_kernel'));
      expect(out.existsSync(), isFalse);
    });

    test('patches every listed SDK snapshot into the given output', () {
      var sdkIndex = 0;
      for (final sdkDir in sdkDirs) {
        sdkIndex++;
        for (final name in const [
          'bin/snapshots/kernel_worker_aot.dart.snapshot',
          'bin/snapshots/gen_kernel_aot.dart.snapshot',
        ]) {
          final input = File('$sdkDir/$name');
          if (!input.existsSync()) continue;
          final out = File(
            '${tmp.path}/sdk${sdkIndex}_${name.split('/').last}',
          );
          final error = patch.patchSnapshotFile(
            inputPath: input.path,
            outputPath: out.path,
            sdkVersion: 'test-sdk',
            snapshotKind: name.split('/').last,
          );
          expect(error, isNull, reason: '$name: $error');
          expect(out.existsSync(), isTrue);
          expect(out.lengthSync(), input.lengthSync());
          // The input snapshot is never modified in place.
          expect(out.readAsBytesSync(), isNot(equals(input.readAsBytesSync())));
          // The patch is one-shot: the output no longer matches.
          final repatch = patch.patchSnapshotFile(
            inputPath: out.path,
            outputPath: '${out.path}.again',
            sdkVersion: 'test-sdk',
            snapshotKind: name.split('/').last,
          );
          expect(repatch, contains('matches no known comma-split pattern'));
        }
      }
    });
  });

  group('runPatchCli', () {
    test('rejects missing and unknown arguments without touching files', () {
      expect(patch.runPatchCli([]), 2);
      expect(patch.runPatchCli(['--bogus=1']), 2);
      expect(
        patch.runPatchCli([
          '--input=${tmp.path}/in.snapshot',
          '--output=${tmp.path}/out.snapshot',
        ]),
        2,
      );
      expect(File('${tmp.path}/out.snapshot').existsSync(), isFalse);
    });

    test('patches through the CLI and stays silent on success', () {
      final sdkDir = sdkDirs.first;
      final input = File('$sdkDir/bin/snapshots/gen_kernel_aot.dart.snapshot');
      final out = File('${tmp.path}/cli.snapshot');
      final exitCode = patch.runPatchCli([
        '--input=${input.path}',
        '--output=${out.path}',
        '--sdk-version=3.13.5',
        '--kind=gen_kernel',
      ]);
      expect(exitCode, 0);
      expect(out.existsSync(), isTrue);
    });

    test('exits 1 when no pattern matches', () {
      final input = File('${tmp.path}/in.snapshot')
        ..writeAsBytesSync([1, 2, 3]);
      final exitCode = patch.runPatchCli([
        '--input=${input.path}',
        '--output=${tmp.path}/out.snapshot',
        '--sdk-version=3.13.5',
        '--kind=gen_kernel',
      ]);
      expect(exitCode, 1);
    });

    test('the CLI runs through an isolated dartvm with no SDK beside it', () {
      // Covers M-7's mechanism: the patch action executes `dartvm`
      // directly, so `dartvm` must run the tool even when no `dart`
      // launcher or SDK tree sits beside it.
      final sdkDir = sdkDirs.first;
      final vmName = Platform.isWindows ? 'dartvm.exe' : 'dartvm';
      final vm = File('$sdkDir/bin/$vmName');
      if (!vm.existsSync()) {
        markTestSkipped('no $vmName in $sdkDir/bin');
        return;
      }
      final iso = Directory('${tmp.path}/iso')..createSync();
      final isoVm = vm.copySync('${iso.path}/$vmName').path;
      // A loader may need DLLs the VM ships with; those are not the SDK.
      for (final entity in Directory('$sdkDir/bin').listSync()) {
        if (entity is File && entity.path.endsWith('.dll')) {
          entity.copySync('${iso.path}/${entity.uri.pathSegments.last}');
        }
      }
      File(commaPatchSource).copySync('${iso.path}/comma_patch.dart');
      File('$sdkDir/bin/snapshots/gen_kernel_aot.dart.snapshot')
          .copySync('${iso.path}/in.snapshot');
      final result = Process.runSync(isoVm, [
        'comma_patch.dart',
        '--input=in.snapshot',
        '--output=out.snapshot',
        '--sdk-version=3.13.5',
        '--kind=gen_kernel',
      ], workingDirectory: iso.path);
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
      final out = File('${iso.path}/out.snapshot');
      expect(out.existsSync(), isTrue);
      expect(
        out.readAsBytesSync(),
        isNot(equals(File('${iso.path}/in.snapshot').readAsBytesSync())),
      );
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  group('no shared state', () {
    test('the implementation names no shared temp path', () {
      final source = File(commaPatchSource).readAsStringSync();
      for (final banned in [
        'systemTemp',
        'TMPDIR',
        'codesign',
        'nopatch',
        'nocomma_',
      ]) {
        expect(
          source,
          isNot(contains(banned)),
          reason: 'comma_patch.dart must not reference $banned',
        );
      }
    });
  });
}
