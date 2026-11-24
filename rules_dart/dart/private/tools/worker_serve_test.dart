// Tests the worker loop the build tools serve with: concurrent
// requests are answered with their own ids, a cancelled request is answered as
// cancelled, and a request id of 0 (Bazel without multiplexing) still works.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'lib/worker_protocol.dart';
import 'lib/worker_serve.dart';

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

/// [payload] behind a length prefix, whatever bytes it holds.
Uint8List _framedPayload(List<int> payload) =>
    (WorkerWriter()
          ..varint(payload.length)
          ..raw(payload))
        .takeBytes();

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

void main() {
  _registerMultiplexInMemoryTests();
  _registerCancelInMemoryTests();
  _registerBadFrameInMemoryTests();
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

void _registerBadFrameInMemoryTests() {
  test('a truncated varint is answered, a running request kept', () async {
    final release = Completer<void>();
    final _Rig rig = _createRig((Uint8List frame, Future<void> _) async {
      await release.future;
      return (exitCode: 0, output: 'out-${_argumentOf(frame)}');
    });
    rig.send(_request(11, ['slow']));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    rig.send(_framedPayload([0x18, 0x07, 0x18, 0x80]));
    await rig.waitForAnswers(1);
    release.complete();
    final List<_Answer> answers = await rig.finish();
    expect(answers, hasLength(2));
    final _Answer bad = answers.first;
    expect(bad.requestId, 7, reason: 'the id read before the failure');
    expect(bad.exitCode, 1);
    expect(bad.output, contains('malformed WorkRequest'));
    expect(bad.output, contains('4 bytes'));
    expect(bad.output, contains('truncated varint'));
    final _Answer good = answers.last;
    expect(good.requestId, 11);
    expect(good.exitCode, 0);
    expect(good.output, 'out-slow');
  });

  test('a payload cut off at its first varint answers request id 0', () async {
    final _Rig rig = _createRig((Uint8List frame, Future<void> _) async {
      return (exitCode: 0, output: '');
    });
    rig.send(_framedPayload([0x18, 0x80]));
    final List<_Answer> answers = await rig.finish();
    expect(answers.single.requestId, 0);
    expect(answers.single.exitCode, 1);
    expect(answers.single.output, contains('2 bytes'));
  });

  test('an unsupported wire type is answered with exit code 1', () async {
    final _Rig rig = _createRig((Uint8List frame, Future<void> _) async {
      return (exitCode: 0, output: '');
    });
    rig.send(_framedPayload([0x18, 0x09, 0x0b]));
    final List<_Answer> answers = await rig.finish();
    expect(answers.single.requestId, 9);
    expect(answers.single.exitCode, 1);
    expect(answers.single.output, contains('malformed WorkRequest'));
    expect(answers.single.output, contains('unsupported wire type'));
  });

  test('a valid request after a bad frame is served and serve ends', () async {
    final _Rig rig = _createRig((Uint8List frame, Future<void> _) async {
      return (exitCode: 0, output: 'out-${_argumentOf(frame)}');
    }, maxConcurrent: 1);
    rig.send(_framedPayload([0x18, 0x80]));
    rig.send(_request(5, ['after']));
    final List<_Answer> answers = await rig.finish();
    expect(answers.map((a) => a.requestId), unorderedEquals([0, 5]));
    expect(answers.singleWhere((a) => a.requestId == 5).output, 'out-after');
    expect(answers.singleWhere((a) => a.requestId == 0).exitCode, 1);
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

  test(
    'a cancelled request keeps its slot until its handler returns',
    () async {
      final release = Completer<void>();
      final ran = <String>[];
      var running = 0;
      var mostAtOnce = 0;
      final _Rig rig = _createRig(maxConcurrent: 1, (
        Uint8List frame,
        Future<void> _,
      ) async {
        final String name = _argumentOf(frame);
        ran.add(name);
        running++;
        if (running > mostAtOnce) mostAtOnce = running;
        // A handler that does not stop on cancel, as the module compiler's.
        if (name == 'first') await release.future;
        running--;
        return (exitCode: 0, output: name);
      });
      rig.send(_request(1, ['first']));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      rig.send(_request(1, const [], cancel: true));
      await rig.waitForAnswers(1);
      rig.send(_request(2, ['second']));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(ran, ['first']);
      release.complete();
      final List<_Answer> answers = await rig.finish();
      expect(ran, ['first', 'second']);
      expect(mostAtOnce, 1);
      expect(answers.map((a) => (a.requestId, a.cancelled)), [
        (1, true),
        (2, false),
      ]);
    },
  );

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
