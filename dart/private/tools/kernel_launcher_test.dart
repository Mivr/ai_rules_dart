import 'dart:io';

import 'package:test/test.dart';

import 'kernel_launcher.dart'
    show adjacentConfigFile, candidateConfigRlocations, deleteScratchQuietly;

void main() {
  group('kernel_launcher config lookup (Windows path form)', () {
    test('yields .exe-stripped config name', () {
      final candidates = candidateConfigRlocations(
        r'C:\Users\runner\bin\create_probe_kernel.exe',
      ).toList();
      expect(
        candidates,
        contains('_main/create_probe_kernel.kernel_launcher.json'),
      );
    });

    test('yields .exe-retaining config name', () {
      final candidates = candidateConfigRlocations(
        r'C:\Users\runner\bin\create_probe_kernel.exe',
      ).toList();
      expect(
        candidates,
        contains('_main/create_probe_kernel.exe.kernel_launcher.json'),
      );
    });

    test('adjacent config finds existing .exe-stripped sidecar', () {
      final tmp = Directory.systemTemp.createTempSync('kl_adjacent');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final exe = '${tmp.path}\\create_probe_kernel.exe';
      File('${tmp.path}\\create_probe_kernel.kernel_launcher.json')
          .writeAsStringSync('{}');
      final file = adjacentConfigFile(exe);
      expect(file, isNotNull);
      expect(file!.path, endsWith('create_probe_kernel.kernel_launcher.json'));
    });
  });

  group('deleteScratchQuietly', () {
    test('removes an existing scratch directory', () {
      final tmp = Directory.systemTemp.createTempSync('kl_scratch');
      File('${tmp.path}/entry').writeAsStringSync('x');
      deleteScratchQuietly(tmp);
      expect(tmp.existsSync(), isFalse);
    });

    test('ignores a scratch directory that is already gone', () {
      final tmp = Directory.systemTemp.createTempSync('kl_scratch');
      tmp.deleteSync(recursive: true);
      expect(() => deleteScratchQuietly(tmp), returnsNormally);
    });
  });
}
