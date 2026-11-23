// copy_local_file copies raw bytes and normalizes the mode bits.
import 'dart:io';

import 'package:test/test.dart';

import '../copy_local_file.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('copy_local_file_'));
  tearDown(() {
    if (!Platform.isWindows) {
      for (final File f in dir.listSync(recursive: true).whereType<File>()) {
        Process.runSync('chmod', ['u+w', f.path]);
      }
    }
    dir.deleteSync(recursive: true);
  });

  final allBytes = List<int>.generate(256, (i) => i);

  test('copies raw binary bytes and creates parent directories', () {
    final src = File('${dir.path}/src.bin')..writeAsBytesSync(allBytes);
    final dst = '${dir.path}/a/b/dst.bin';
    expect(runCopyLocalFile([src.path, dst, 'false']), 0);
    expect(File(dst).readAsBytesSync(), allBytes);
  });

  test('a read-only source becomes a writable 0644 copy', () {
    final src = File('${dir.path}/ro.snapshot')..writeAsBytesSync(allBytes);
    Process.runSync('chmod', ['444', src.path]);
    final dst = '${dir.path}/rw.snapshot';
    expect(runCopyLocalFile([src.path, dst, 'false']), 0);
    expect(File(dst).statSync().mode & 0x1ff, 0x1a4);
    expect(File(dst).readAsBytesSync(), allBytes);
  }, testOn: '!windows');

  test('executable copies get mode 0755', () {
    final src = File('${dir.path}/dart')..writeAsBytesSync(allBytes);
    final dst = '${dir.path}/out/dart';
    expect(runCopyLocalFile([src.path, dst, 'true']), 0);
    expect(File(dst).statSync().mode & 0x1ff, 0x1ed);
  }, testOn: '!windows');

  test('a missing source reports a non-zero exit', () {
    final dst = '${dir.path}/never';
    expect(runCopyLocalFile(['${dir.path}/absent', dst, 'false']), isNonZero);
    expect(File(dst).existsSync(), isFalse);
  });

  test('bad arguments report a non-zero exit', () {
    expect(runCopyLocalFile(['only-one']), isNonZero);
  });
}
