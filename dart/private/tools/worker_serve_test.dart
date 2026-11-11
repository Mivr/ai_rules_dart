// Tests the multiplex worker loop that `kernel_module` serves with: concurrent
// requests are answered with their own ids, a cancelled request is answered as
// cancelled, and a request id of 0 (Bazel without multiplexing) still works.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

import 'lib/worker_protocol.dart';
import 'lib/worker_serve.dart';

late String _toolSnapshotPath;
late String _dartBin;
late Directory _tmp;

/// A framed `WorkRequest` for [requestId] carrying [arguments] and [inputs];
/// [cancel] marks it a cancel message.
Uint8List _request(
  int requestId,
  List<String> arguments, {
  Map<String, Uint8List> inputs = const {},
  bool cancel = false,
}) {
  final body = WorkerWriter();
  for (final argument in arguments) {
    final Uint8List bytes = utf8.encode(argument);
    body
      ..varint((1 << 3) | 2)
      ..varint(bytes.length)
      ..raw(bytes);
  }
  for (final MapEntry<String, Uint8List> entry in inputs.entries) {
    final Uint8List pathBytes = utf8.encode(entry.key);
    final nested = WorkerWriter()
      ..varint((1 << 3) | 2)
      ..varint(pathBytes.length)
      ..raw(pathBytes)
      ..varint((2 << 3) | 2)
      ..varint(entry.value.length)
      ..raw(entry.value);
    final Uint8List nestedBytes = nested.takeBytes();
    body
      ..varint((2 << 3) | 2)
      ..varint(nestedBytes.length)
      ..raw(nestedBytes);
  }
  body
    ..varint((3 << 3) | 0)
    ..varint(requestId);
  if (cancel) {
    body
      ..varint((4 << 3) | 0)
      ..varint(1);
  }
  final Uint8List payload = body.takeBytes();
  return (WorkerWriter()
        ..varint(payload.length)
        ..raw(payload))
      .takeBytes();
}

/// One decoded `WorkResponse`.
typedef _Answer = ({
  int requestId,
  int exitCode,
  String output,
  bool cancelled,
});

_Answer _decode(Uint8List frame) {
  final reader = WorkerReader(frame);
  var requestId = 0;
  var exitCode = 0;
  var output = '';
  var cancelled = false;
  while (!reader.isDone) {
    final int tag = reader.varint();
    switch (tag >> 3) {
      case 1:
        exitCode = reader.varint();
      case 2:
        output = reader.string();
      case 3:
        requestId = reader.varint();
      case 4:
        cancelled = reader.varint() != 0;
      default:
        reader.skip(tag & 7);
    }
  }
  return (
    requestId: requestId,
    exitCode: exitCode,
    output: output,
    cancelled: cancelled,
  );
}

/// An in-memory worker under test.
typedef _Rig = ({
  void Function(Uint8List framed) send,
  Future<void> Function(int count) waitForAnswers,
  Future<List<_Answer>> Function() finish,
});

_Rig _createRig(WorkHandler handle, {int maxConcurrent = 4}) {
  final input = StreamController<List<int>>();
  final output = StreamController<List<int>>();
  final bytes = <int>[];
  output.stream.listen(bytes.addAll);
  final Future<void> done = serveWorker(
    input: input.stream,
    output: IOSink(output),
    handle: handle,
    maxConcurrent: maxConcurrent,
  );
  Future<List<_Answer>> answers() =>
      WorkerFrames(Stream<List<int>>.value(List<int>.of(bytes)))
          .map(_decode)
          .toList();
  return (
    send: input.add,
    waitForAnswers: (int count) async {
      while ((await answers()).length < count) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    },
    finish: () async {
      await input.close();
      await done;
      await output.close();
      return await answers();
    },
  );
}

String _argumentOf(Uint8List frame) =>
    WorkerRequest.read(frame).arguments.single;

/// Fake `kernel_worker` for subprocess tests: reads `WorkRequest` frames on
/// stdin, coordinates via marker files in `FAKE_SYNC_DIR`, and answers with
/// `WorkResponse(exit_code: 1, output: 'out-<kind>', request_id: 0)`.
const _fakeKernelWorkerSource = r'''
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

void _writeVarint(BytesBuilder out, int value) {
  var v = value;
  while (v >= 0x80) {
    out.addByte((v & 0x7f) | 0x80);
    v >>= 7;
  }
  out.addByte(v);
}

Future<void> main() async {
  final syncDir = Platform.environment['FAKE_SYNC_DIR']!;
  var buf = <int>[];
  await for (final chunk in stdin) {
    buf.addAll(chunk);
    while (true) {
      var len = 0;
      var shift = 0;
      var pos = 0;
      var completeHeader = false;
      while (pos < buf.length) {
        final int b = buf[pos++];
        len |= (b & 0x7f) << shift;
        if ((b & 0x80) == 0) {
          completeHeader = true;
          break;
        }
        shift += 7;
      }
      if (!completeHeader || buf.length < pos + len) break;
      final frame = buf.sublist(pos, pos + len);
      buf = buf.sublist(pos + len);
      final text = utf8.decode(frame, allowMalformed: true);
      if (text.contains('package:pkg/stuck.dart')) {
        File('$syncDir/stuck_started').writeAsStringSync('1');
        await Completer<void>().future;
      }
      var kind = 'fast';
      if (text.contains('package:pkg/slow.dart')) {
        kind = 'slow';
        File('$syncDir/slow_started').writeAsStringSync('1');
        while (!File('$syncDir/release_slow').existsSync()) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      }
      final msgBytes = utf8.encode('out-$kind');
      final body = BytesBuilder()
        ..addByte(0x08)
        ..addByte(0x01)
        ..addByte(0x12);
      _writeVarint(body, msgBytes.length);
      body.add(msgBytes);
      final payload = body.toBytes();
      final framed = BytesBuilder();
      _writeVarint(framed, payload.length);
      framed.add(payload);
      stdout.add(framed.toBytes());
      await stdout.flush();
    }
  }
}
''';

/// Writes a minimal workspace with `package_config.json`, `libraries.json`,
/// `dep.koutline`, and the test sources under [_tmp], returning the digest map
/// for `dep.koutline`.
Map<String, Uint8List> _writeSubprocessFixture() {
  void write(String rel, String content) {
    File('${_tmp.path}/$rel')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(content);
  }

  write(
    'package_config.json',
    jsonEncode({
      'configVersion': 2,
      'packages': [
        for (final name in ['pkg', 'dep'])
          {
            'name': name,
            'rootUri': 'org-dartlang-root:///$name',
            'packageUri': 'lib/',
          },
      ],
    }),
  );
  write(
    'libraries.json',
    jsonEncode({
      'vm': {
        'libraries': <String, Object?>{
          'async': const <String, Object?>{},
          'core': const <String, Object?>{},
          'io': const <String, Object?>{},
        },
      },
    }),
  );
  write(
    'dep.koutline/index.json',
    jsonEncode({
      'version': 1,
      'sccs': [
        {
          'dill': '0.dill',
          'defines': ['dep/lib/one.dart'],
          'imports': <String>[],
        },
      ],
    }),
  );
  write('dep.koutline/0.dill', 'dill-bytes');
  write('pkg/lib/slow.dart', "import 'package:dep/one.dart';\n");
  write('pkg/lib/fast.dart', "import 'package:dep/one.dart';\n");
  write('pkg/lib/stuck.dart', 'class Stuck {}\n');
  write('fake_worker.dart', _fakeKernelWorkerSource);
  return {
    for (final rel in [
      'dep.koutline/index.json',
      'dep.koutline/0.dill',
      'pkg/lib/slow.dart',
      'pkg/lib/fast.dart',
    ])
      '${_tmp.path}/$rel': sha256Of(
        File('${_tmp.path}/$rel').readAsBytesSync(),
      ),
  };
}

List<String> _moduleArgs(Directory sdkDir, String name) {
  final out = '${_tmp.path}/out/$name';
  return [
    '--target',
    'vm',
    '--dart-sdk-summary',
    '${sdkDir.path}/lib/_internal/vm_platform_strong.dill',
    '--packages-file',
    '${_tmp.path}/package_config.json',
    '--libraries-json',
    '${_tmp.path}/libraries.json',
    '--multi-root',
    _tmp.path,
    '--multi-root-scheme',
    'org-dartlang-root',
    '--no-summary-only',
    '--input-kmod',
    '${_tmp.path}/dep.koutline',
    '--source',
    'package:pkg/$name.dart',
    '--own-source-file',
    '${_tmp.path}/pkg/lib/$name.dart',
    '--output',
    out,
    '--excluded-output',
    '$out.vm_excluded.txt',
  ];
}

Future<void> _waitForFile(String path) async {
  while (!File(path).existsSync()) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main(List<String> args) {
  if (args.length >= 2) {
    final r = Runfiles.create();
    _toolSnapshotPath = r.rlocation(args[0]);
    _dartBin = r.rlocation(args[1]);
  } else {
    _toolSnapshotPath = '';
    _dartBin = Platform.resolvedExecutable;
  }

  setUp(() {
    _tmp = Directory.systemTemp.createTempSync('worker_serve_test_');
  });

  tearDown(() {
    _tmp.deleteSync(recursive: true);
  });

  _registerMultiplexInMemoryTests();
  _registerCancelInMemoryTests();
  _registerInterleavedSubprocessTest();
  _registerCancelSubprocessTest();
}

void _registerMultiplexInMemoryTests() {
  test('two interleaved requests are answered with their own ids', () async {
    final slow = Completer<void>();
    final started = <String>[];
    final _Rig rig = _createRig((Uint8List frame, Future<void> _) async {
      final String name = _argumentOf(frame);
      started.add(name);
      if (name == 'slow') await slow.future;
      return (exitCode: name == 'slow' ? 3 : 0, output: 'out-$name');
    });
    rig.send(_request(11, ['slow']));
    rig.send(_request(22, ['fast']));
    await rig.waitForAnswers(1);
    slow.complete();
    final List<_Answer> answers = await rig.finish();
    expect(started, ['slow', 'fast'], reason: 'both ran before either ended');
    expect(answers.map((a) => a.requestId), [22, 11]);
    expect(answers[0].output, 'out-fast');
    expect(answers[0].exitCode, 0);
    expect(answers[1].output, 'out-slow');
    expect(answers[1].exitCode, 3);
    expect(answers.any((a) => a.cancelled), isFalse);
  });

  test('request id 0 and a throwing handler are still answered', () async {
    final _Rig rig = _createRig((Uint8List frame, Future<void> _) async {
      if (_argumentOf(frame) == 'boom') throw StateError('boom');
      return (exitCode: 0, output: '');
    });
    rig.send(_request(0, ['ok']));
    rig.send(_request(9, ['boom']));
    final List<_Answer> answers = await rig.finish();
    final _Answer boom = answers.singleWhere((a) => a.requestId == 9);
    expect(boom.exitCode, 1);
    expect(boom.output, contains('boom'));
    final _Answer ok = answers.singleWhere((a) => a.requestId == 0);
    expect(ok.exitCode, 0);
    expect(ok.cancelled, isFalse);
  });
}

void _registerCancelInMemoryTests() {
  test('a cancelled running request is answered as cancelled once', () async {
    final never = Completer<void>();
    final _Rig rig = _createRig((
      Uint8List frame,
      Future<void> cancelled,
    ) async {
      await Future.any([never.future, cancelled]);
      return (exitCode: 0, output: 'late');
    });
    rig.send(_request(5, ['stuck']));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    rig.send(_request(5, const [], cancel: true));
    await rig.waitForAnswers(1);
    never.complete();
    final List<_Answer> answers = await rig.finish();
    expect(answers, hasLength(1));
    expect(answers.single.requestId, 5);
    expect(answers.single.cancelled, isTrue);
    expect(answers.single.output, isEmpty);
  });

  test('a cancelled queued request never runs', () async {
    final release = Completer<void>();
    final ran = <String>[];
    final _Rig rig = _createRig(maxConcurrent: 1, (
      Uint8List frame,
      Future<void> _,
    ) async {
      final String name = _argumentOf(frame);
      ran.add(name);
      if (name == 'first') await release.future;
      return (exitCode: 0, output: name);
    });
    rig.send(_request(1, ['first']));
    rig.send(_request(2, ['queued']));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    rig.send(_request(2, const [], cancel: true));
    await rig.waitForAnswers(1);
    release.complete();
    final List<_Answer> answers = await rig.finish();
    expect(ran, ['first']);
    expect(answers.map((a) => (a.requestId, a.cancelled)), [
      (2, true),
      (1, false),
    ]);
  });
}

Future<Process> _startKernelModule(Directory sdkDir) {
  final exeSuffix = Platform.isWindows ? '.exe' : '';
  final dartaotruntime = '${sdkDir.path}/bin/dartaotruntime$exeSuffix';
  return Process.start(
    dartaotruntime,
    [
      _toolSnapshotPath,
      '--persistent_worker',
      '--kernel-worker',
      '${_tmp.path}/fake_worker.dart',
      '--dartaotruntime',
      _dartBin,
      '--request-timeout-seconds=120',
    ],
    environment: {'FAKE_SYNC_DIR': _tmp.path},
  );
}

void _registerInterleavedSubprocessTest() {
  test('kernel_module multiplex worker answers interleaved requests out of order and shares outline cache', () async {
    final Map<String, Uint8List> digests = _writeSubprocessFixture();
    final Directory sdkDir = File(_dartBin).parent.parent;
    final Process tool = await _startKernelModule(sdkDir);
    final Future<void> stderrDrain = tool.stderr.drain<void>();
    final responses = StreamIterator<Uint8List>(WorkerFrames(tool.stdout));

    tool.stdin.add(_request(11, _moduleArgs(sdkDir, 'slow'), inputs: digests));
    await tool.stdin.flush();
    await _waitForFile('${_tmp.path}/slow_started')
        .timeout(const Duration(seconds: 30));

    // Delete dep.koutline/index.json from disk: request 22 must hit the
    // outline index cached in-process by request 11.
    File('${_tmp.path}/dep.koutline/index.json').deleteSync();

    tool.stdin.add(_request(22, _moduleArgs(sdkDir, 'fast'), inputs: digests));
    await tool.stdin.flush();
    expect(
      await responses.moveNext().timeout(const Duration(seconds: 30)),
      isTrue,
    );
    final _Answer first = _decode(responses.current);
    expect(first.requestId, 22);
    expect(first.output, contains('out-fast'));
    expect(first.cancelled, isFalse);

    File('${_tmp.path}/release_slow').writeAsStringSync('1');
    expect(
      await responses.moveNext().timeout(const Duration(seconds: 30)),
      isTrue,
    );
    final _Answer second = _decode(responses.current);
    expect(second.requestId, 11);
    expect(second.output, contains('out-slow'));
    expect(second.cancelled, isFalse);

    await tool.stdin.close();
    expect(await tool.exitCode.timeout(const Duration(seconds: 30)), 0);
    await stderrDrain;
  });
}

void _registerCancelSubprocessTest() {
  test('kernel_module multiplex worker honours cancellation and reaps blocked child', () async {
    _writeSubprocessFixture();
    final Directory sdkDir = File(_dartBin).parent.parent;
    final Process tool = await _startKernelModule(sdkDir);
    final Future<void> stderrDrain = tool.stderr.drain<void>();
    final responses = StreamIterator<Uint8List>(WorkerFrames(tool.stdout));

    tool.stdin.add(_request(5, _moduleArgs(sdkDir, 'stuck')));
    await tool.stdin.flush();
    await _waitForFile('${_tmp.path}/stuck_started')
        .timeout(const Duration(seconds: 30));
    tool.stdin.add(_request(5, const [], cancel: true));
    await tool.stdin.flush();
    expect(
      await responses.moveNext().timeout(const Duration(seconds: 30)),
      isTrue,
    );
    final _Answer cancelled = _decode(responses.current);
    expect(cancelled.requestId, 5);
    expect(cancelled.cancelled, isTrue);
    expect(cancelled.output, isEmpty);

    await tool.stdin.close();
    expect(await tool.exitCode.timeout(const Duration(seconds: 30)), 0);
    await stderrDrain;
  });
}
