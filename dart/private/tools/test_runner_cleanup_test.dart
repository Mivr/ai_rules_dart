import 'dart:io';

import 'package:test/test.dart';

import 'test_runner.dart' show deleteScratchQuietly;

void main() {
  group('deleteScratchQuietly', () {
    test('removes an existing scratch file', () {
      final tmp = Directory.systemTemp.createTempSync('tr_scratch');
      addTearDown(() => deleteScratchQuietly(tmp));
      final file = File('${tmp.path}/combined.dill')
        ..writeAsBytesSync([0, 1, 2]);
      deleteScratchQuietly(file);
      expect(file.existsSync(), isFalse);
    });

    test('ignores a scratch file that is already gone', () {
      final tmp = Directory.systemTemp.createTempSync('tr_scratch');
      addTearDown(() => deleteScratchQuietly(tmp));
      final file = File('${tmp.path}/combined.dill')
        ..writeAsBytesSync([0, 1, 2]);
      file.deleteSync();
      expect(() => deleteScratchQuietly(file), returnsNormally);
    });
  });
}
