import 'dart:io';

import 'package:test/test.dart';

import 'test_runner.dart' show deleteScratchQuietly, materializeWorkspace;
import 'test_runner_workspace.dart' show workspaceInPlace;

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

  group('materializeWorkspace', () {
    test('lays out listed files and copies listed directories whole', () {
      final real = Directory.systemTemp.createTempSync('tr_real');
      addTearDown(() => real.deleteSync(recursive: true));
      final into = Directory.systemTemp.createTempSync('tr_into');
      addTearDown(() => into.deleteSync(recursive: true));
      File('${real.path}/data.txt').writeAsStringSync('data');
      Directory('${real.path}/tree/sub').createSync(recursive: true);
      File('${real.path}/tree/sub/nested.txt').writeAsStringSync('nested');
      materializeWorkspace(
        manifest: [
          'ws/data.txt ${real.path}/data.txt',
          'ws/tree ${real.path}/tree',
          'other/ignored.txt ${real.path}/data.txt',
          'ws-malformed-line',
        ],
        workspace: 'ws',
        into: into.path,
      );
      expect(File('${into.path}/data.txt').readAsStringSync(), 'data');
      expect(
        File('${into.path}/tree/sub/nested.txt').readAsStringSync(),
        'nested',
      );
      expect(File('${into.path}/ignored.txt').existsSync(), isFalse);
    });

    test('replaces a stale file already at the destination', () {
      final real = Directory.systemTemp.createTempSync('tr_real');
      addTearDown(() => real.deleteSync(recursive: true));
      final into = Directory.systemTemp.createTempSync('tr_into');
      addTearDown(() => into.deleteSync(recursive: true));
      File('${real.path}/data.txt').writeAsStringSync('fresh');
      File('${into.path}/data.txt').writeAsStringSync('stale');
      materializeWorkspace(
        manifest: ['ws/data.txt ${real.path}/data.txt'],
        workspace: 'ws',
        into: into.path,
      );
      expect(File('${into.path}/data.txt').readAsStringSync(), 'fresh');
    });
  });

  group('workspaceInPlace', () {
    test('holds without a manifest or workspace to check', () {
      expect(workspaceInPlace(), isTrue);
      expect(
        workspaceInPlace(manifest: 'no-such-manifest', workspace: null),
        isTrue,
      );
    });

    test('fails when the test path is missing', () {
      expect(
        workspaceInPlace(
          testPath: 'no-such-test-path_xyz',
          manifest: null,
          workspace: null,
        ),
        isFalse,
      );
    });

    test('spots a workspace file missing from the directory', () {
      final dir = Directory.systemTemp.createTempSync('tr_inplace');
      addTearDown(() => dir.deleteSync(recursive: true));
      final real = File('${dir.path}/data.txt')..writeAsStringSync('data');
      final manifest = File('${dir.path}/MANIFEST')
        ..writeAsStringSync('ws/data.txt ${real.path}\n');
      // `ws/data.txt` is not under the test's working directory.
      expect(
        workspaceInPlace(manifest: manifest.path, workspace: 'ws'),
        isFalse,
      );
      expect(
        workspaceInPlace(manifest: manifest.path, workspace: 'other'),
        isTrue,
      );
    });
  });
}
