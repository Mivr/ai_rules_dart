import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import '../macho_constants.dart' as macho;
import '../macho_edit.dart' as macho;
import '../macho_fat.dart' as macho;
import '../macho_stub.dart' as macho;

/// Wraps [objects] in a minimal `ar` archive, one member per object.
Uint8List _archive(List<Uint8List> objects) {
  final out = BytesBuilder()..add(ascii.encode('!<arch>\n'));
  for (var i = 0; i < objects.length; i++) {
    final Uint8List object = objects[i];
    final header =
        '${'m$i.o/'.padRight(16)}${'0'.padRight(12)}'
        '${'0'.padRight(6)}${'0'.padRight(6)}${'100644'.padRight(8)}'
        '${'${object.length}'.padRight(10)}`\n';
    out
      ..add(ascii.encode(header))
      ..add(object);
    if (object.length.isOdd) out.addByte(0x0a);
  }
  return out.toBytes();
}

Uint8List _object(String arch) => macho.generateStubMachO(
  arch: arch,
  platform: macho.platformIos,
  minOs: macho.parsePackedVersion('13.0'),
  sdkVersion: macho.parsePackedVersion('13.0'),
  installName: '@rpath/Plugin.framework/Plugin',
);

void main() {
  late Directory tempDir;
  setUp(() => tempDir = Directory.systemTemp.createTempSync('fat_archive_'));
  tearDown(() => tempDir.deleteSync(recursive: true));

  test('fat combines static archives into a universal archive', () {
    final arm = File('${tempDir.path}/arm.a')
      ..writeAsBytesSync(_archive([_object('arm64')]));
    final x86 = File('${tempDir.path}/x86.a')
      ..writeAsBytesSync(_archive([_object('x86_64')]));
    final out = '${tempDir.path}/fat.a';

    macho.main(['fat', '--output', out, arm.path, x86.path]);

    final Uint8List fat = File(out).readAsBytesSync();
    expect(macho.isFatMachO(fat), isTrue);
    final List<macho.FatSlice> slices = macho.extractFatSlices(fat);
    expect(slices.map((s) => s.cputype), [
      macho.cpuTypeArm64,
      macho.cpuTypeX86_64,
    ]);
    expect(slices.first.bytes, arm.readAsBytesSync());
  });

  test('fat rejects a file that is neither Mach-O nor an archive', () {
    final junk = File('${tempDir.path}/junk')..writeAsStringSync('not macho');
    expect(
      () => macho.main(['fat', '--output', '${tempDir.path}/o', junk.path]),
      throwsFormatException,
    );
  });
}
