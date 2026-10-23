// Unit tests for the shared worker-protocol and staged-source plumbing in
// `lib/worker_protocol.dart` and `lib/worker_tool_fs.dart`: the single copy
// every build-action runner now shares. The expectations pin the exact
// behaviour the per-tool copies had (param-file variants, normalization,
// digests, protobuf framing, pruning), so a regression here means a
// behaviour change in a tool.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:rules_dart_worker/worker_protocol.dart';
import 'package:rules_dart_worker/worker_tool_fs.dart';
import 'package:test/test.dart';

late Directory _tmp;

void main() {
  setUp(() {
    _tmp = Directory.systemTemp.createTempSync('worker_protocol_test.');
  });

  tearDown(() {
    _tmp.deleteSync(recursive: true);
  });

  group('expandParamFiles', () {
    test('passes arguments without @ through untouched', () {
      expect(expandParamFiles(['a', '--b=c', '', '-@']), [
        'a',
        '--b=c',
        '',
        '-@',
      ]);
    });

    test('strict mode expands lines and keeps empty ones', () {
      final param = File('${_tmp.path}/args.txt')
        ..writeAsStringSync('a\n\nb\n');
      expect(expandParamFiles(['@${param.path}', 'c']), ['a', '', 'b', 'c']);
    });

    test('strict mode throws for a missing file', () {
      expect(
        () => expandParamFiles(['@${_tmp.path}/no-such-file.txt']),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('skipEmptyLines drops blank lines', () {
      final param = File('${_tmp.path}/args.txt')
        ..writeAsStringSync('a\n\nb\n');
      expect(expandParamFiles(['@${param.path}'], skipEmptyLines: true), [
        'a',
        'b',
      ]);
    });

    test('keepMissingArg keeps missing paths and a bare @', () {
      final param = File('${_tmp.path}/args.txt')..writeAsStringSync('a\n');
      expect(
        expandParamFiles([
          '@${_tmp.path}/no-such-file.txt',
          '@',
          '@${param.path}',
        ], keepMissingArg: true),
        ['@${_tmp.path}/no-such-file.txt', '@', 'a'],
      );
    });
  });

  group('normalizePath', () {
    test('leaves normalized relatives alone', () {
      for (final path in ['a', 'a/b', 'a/b/c.dart', 'a..b', 'a/.../b']) {
        expect(normalizePath(path), path, reason: path);
      }
    });

    test('resolves dot segments and duplicate slashes', () {
      expect(
        {
          for (final path in [
            '',
            '.',
            './a',
            'a/./b',
            'a/../b',
            '../a',
            'a/../../b',
            '/a//b/',
            '/',
          ])
            path: normalizePath(path),
        },
        {
          '': '.',
          '.': '.',
          './a': 'a',
          'a/./b': 'a/b',
          'a/../b': 'b',
          '../a': '../a',
          'a/../../b': '../b',
          '/a//b/': '/a/b',
          '/': '/',
        },
      );
    });

    test('unifies backslashes and keeps drive prefixes', () {
      expect(normalizePath(r'a\b'), 'a/b');
      expect(normalizePath('C:/a/../b'), 'C:/b');
      expect(normalizePath(r'C:\a\b'), 'C:/a/b');
      expect(normalizePath('..'), '..');
    });
  });

  group('sha256Of', () {
    test('matches the standard vectors, including a two-block input', () {
      expect(
        _hexOf(''),
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca'
        '495991b7852b855',
      );
      expect(
        _hexOf('abc'),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9c'
        'b410ff61f20015ad',
      );
      expect(
        _hexOf('abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq'),
        '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1',
      );
    });
  });

  group('worker codec', () {
    test('round-trips arguments, inputs, and the request id', () {
      final payload = _encodeRequest(
        arguments: ['--a', 'b c'],
        inputs: {
          'in/a.dart': [1, 2, 3],
          'out/b.dart': <int>[],
        },
        requestId: 7,
      );
      final request = WorkerRequest.read(payload);
      expect(request.arguments, ['--a', 'b c']);
      expect(request.requestId, 7);
      expect(request.cancel, isFalse);
      expect(request.inputs.keys.toSet(), {'in/a.dart', 'out/b.dart'});
      expect(request.inputs['in/a.dart'], [1, 2, 3]);
      expect(request.inputs['out/b.dart'], isEmpty);
    });

    test('defaults an empty payload', () {
      final request = WorkerRequest.read(Uint8List(0));
      expect(request.arguments, isEmpty);
      expect(request.inputs, isEmpty);
      expect(request.requestId, 0);
      expect(request.cancel, isFalse);
    });

    test('reads cancel and skips unknown fields of every shape', () {
      final body = WorkerWriter();
      _writeString(body, 1, 'go');
      body
        ..varint((9 << 3) | 0)
        ..varint(42);
      final fixed32 = WorkerWriter()
        ..varint((10 << 3) | 5)
        ..raw([9, 9, 9, 9]);
      body.raw(fixed32.takeBytes());
      final fixed64 = WorkerWriter()
        ..varint((11 << 3) | 1)
        ..raw([8, 8, 8, 8, 8, 8, 8, 8]);
      body.raw(fixed64.takeBytes());
      _writeString(body, 12, 'skip me');
      body
        ..varint((4 << 3) | 0)
        ..varint(1);
      final request = WorkerRequest.read(body.takeBytes(), copyDigests: false);
      expect(request.arguments, ['go']);
      expect(request.cancel, isTrue);
    });

    test('WorkerResponse round-trips exit code, output, and id', () {
      const response = WorkerResponse(
        exitCode: 1,
        output: 'boom ✓',
        requestId: 9,
      );
      final fields = _decodeFields(_deframe(response.write()));
      expect(fields[1]!.single, [1]);
      expect(utf8.decode(fields[2]!.single), 'boom ✓');
      expect(fields[3]!.single, [9]);
    });

    test('an empty WorkerResponse writes a single zero byte', () {
      const response = WorkerResponse(exitCode: 0, output: '', requestId: 0);
      expect(response.write(), [0]);
    });
  });

  group('WorkerReader and WorkerWriter', () {
    test('round-trips varints across byte-width boundaries', () {
      const values = [0, 1, 127, 128, 300, 1 << 28, (1 << 32) - 1];
      final writer = WorkerWriter();
      for (final value in values) {
        writer.varint(value);
      }
      final reader = WorkerReader(writer.takeBytes());
      for (final value in values) {
        expect(reader.varint(), value);
      }
      expect(reader.isDone, isTrue);
    });
  });

  group('WorkerFrames', () {
    test('reassembles frames split across chunks and joined chunks', () async {
      final first = _encodeRequest(arguments: ['a'], requestId: 1);
      final second = _encodeRequest(arguments: ['b'], requestId: 2);
      final joined = [..._frame(first), ..._frame(second)];
      final chunks = [
        joined.sublist(0, 2),
        joined.sublist(2, first.length + 3),
        joined.sublist(first.length + 3),
      ];
      final frames = WorkerFrames(Stream.fromIterable(chunks));
      expect(await frames.toList(), [first, second]);
    });
  });

  group('staged-source pruning', () {
    test('pruneUnlistedUnder keeps listed files and leaves dirs', () {
      final src = Directory('${_tmp.path}/src')..createSync(recursive: true);
      Directory('${src.path}/sub').createSync();
      final keep = File('${src.path}/keep.dart')..writeAsStringSync('');
      final drop = File('${src.path}/drop.dart')..writeAsStringSync('');
      final nested = File('${src.path}/sub/nested.dart')..writeAsStringSync('');
      pruneUnlistedUnder(src.path, {p.normalize(keep.absolute.path)});
      expect(keep.existsSync(), isTrue);
      expect(drop.existsSync(), isFalse);
      expect(nested.existsSync(), isFalse);
      expect(Directory('${src.path}/sub').existsSync(), isTrue);
    });

    test('pruneStagedSrcFiles without a manifest deletes nothing', () {
      final project = Directory('${_tmp.path}/proj')..createSync();
      final src = Directory('${project.path}/src')..createSync();
      final kept = File('${src.path}/a.dart')..writeAsStringSync('');
      expect(pruneStagedSrcFiles(project.path), isNull);
      expect(kept.existsSync(), isTrue);
    });

    test('pruneStagedSrcFiles prunes orphans outside the manifest', () {
      final project = Directory('${_tmp.path}/proj')..createSync();
      final src = Directory('${project.path}/src')..createSync();
      Directory('${project.path}/.dart_tool').createSync();
      File('${project.path}/.dart_tool/src_manifest.txt')
          .writeAsStringSync('keep.dart\n');
      final keep = File('${src.path}/keep.dart')..writeAsStringSync('');
      final drop = File('${src.path}/drop.dart')..writeAsStringSync('');
      final allowed = pruneStagedSrcFiles(project.path);
      expect(allowed, {p.normalize(keep.absolute.path)});
      expect(keep.existsSync(), isTrue);
      expect(drop.existsSync(), isFalse);
    });

    test('pruneStagedSrcFiles prunes sibling extpkgs for .proj trees', () {
      final project = Directory('${_tmp.path}/x.proj')..createSync();
      Directory('${project.path}/.dart_tool').createSync();
      File('${project.path}/.dart_tool/extpkgs_manifest.txt')
          .writeAsStringSync('keep.dart\n');
      final ext = Directory('${_tmp.path}/x.extpkgs')..createSync();
      final keep = File('${ext.path}/keep.dart')..writeAsStringSync('');
      final drop = File('${ext.path}/drop.dart')..writeAsStringSync('');
      pruneStagedSrcFiles(project.path);
      expect(keep.existsSync(), isTrue);
      expect(drop.existsSync(), isFalse);
    });
  });
}

String _hexOf(String input) {
  final digest = sha256Of(Uint8List.fromList(utf8.encode(input)));
  return digest.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

void _writeString(WorkerWriter writer, int field, String value) {
  final bytes = utf8.encode(value);
  writer
    ..varint((field << 3) | 2)
    ..varint(bytes.length)
    ..raw(bytes);
}

Uint8List _encodeRequest({
  List<String> arguments = const [],
  Map<String, List<int>> inputs = const {},
  int requestId = 0,
}) {
  final body = WorkerWriter();
  for (final arg in arguments) {
    _writeString(body, 1, arg);
  }
  for (final entry in inputs.entries) {
    final nested = WorkerWriter();
    _writeString(nested, 1, entry.key);
    nested
      ..varint((2 << 3) | 2)
      ..varint(entry.value.length)
      ..raw(entry.value);
    final payload = nested.takeBytes();
    body
      ..varint((2 << 3) | 2)
      ..varint(payload.length)
      ..raw(payload);
  }
  if (requestId != 0) {
    body
      ..varint((3 << 3) | 0)
      ..varint(requestId);
  }
  return body.takeBytes();
}

Uint8List _frame(Uint8List payload) {
  final frame = WorkerWriter()
    ..varint(payload.length)
    ..raw(payload);
  return frame.takeBytes();
}

Uint8List _deframe(Uint8List frame) {
  final length = WorkerReader(frame).varint();
  // The payload is the frame's tail; the length prefix heads it.
  return Uint8List.fromList(
    Uint8List.sublistView(frame, frame.length - length),
  );
}

Map<int, List<List<int>>> _decodeFields(Uint8List payload) {
  final fields = <int, List<List<int>>>{};
  final reader = WorkerReader(payload);
  while (!reader.isDone) {
    final tag = reader.varint();
    final field = tag >> 3;
    if ((tag & 7) == 0) {
      fields.putIfAbsent(field, () => <List<int>>[]).add([reader.varint()]);
    } else {
      fields.putIfAbsent(field, () => <List<int>>[]).add(reader.bytes());
    }
  }
  return fields;
}
