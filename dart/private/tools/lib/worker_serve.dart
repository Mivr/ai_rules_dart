// Serves Bazel's multiplex persistent-worker protocol: one process answers
// several concurrent `WorkRequest`s, each response carrying its request's
// `request_id`, and a cancel message answers its request as cancelled.
//
// Bazel sends a worker that is not multiplexed one request at a time with
// `request_id` 0, so the same loop serves both protocols. It takes no
// `dart_library` dependency on purpose: `kernel_module` compiles it through
// `srcs`, like `worker_protocol.dart`.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'worker_protocol.dart';

/// What a handler answers for one request.
typedef WorkResult = ({int exitCode, String output});

/// Runs the request in [frame], a raw `WorkRequest` payload. [cancelled]
/// completes if Bazel cancels the request while it is running.
typedef WorkHandler = Future<WorkResult> Function(
  Uint8List frame,
  Future<void> cancelled,
);

/// The `request_id` and `cancel` fields of a raw `WorkRequest` payload, read
/// without decoding the other fields (a request with thousands of inputs is
/// not decoded twice). `error` is the decode failure, if any; the other fields
/// keep what was read until then.
typedef _Header = ({int requestId, bool cancel, FormatException? error});

_Header _peekHeader(Uint8List frame) {
  final reader = WorkerReader(frame);
  var requestId = 0;
  var cancel = false;
  try {
    while (!reader.isDone) {
      final int tag = reader.varint();
      switch (tag >> 3) {
        case 3:
          requestId = reader.varint();
        case 4:
          cancel = reader.varint() != 0;
        default:
          reader.skip(tag & 7);
      }
    }
  } on FormatException catch (error) {
    return (requestId: requestId, cancel: cancel, error: error);
  }
  return (requestId: requestId, cancel: cancel, error: null);
}

/// The answer to a frame that is not a `WorkRequest`; the text also goes to
/// stderr.
WorkerResponse _malformedResponse(Uint8List frame, _Header header) {
  final report =
      'worker: malformed WorkRequest frame of ${frame.length} bytes: '
      '${header.error}\n';
  stderr.write(report);
  return WorkerResponse(
    exitCode: 1,
    output: report,
    requestId: header.requestId,
  );
}

/// Writes responses one at a time: an `IOSink` rejects an add while a flush is
/// pending.
Future<void> Function(WorkerResponse) _serialWriter(IOSink output) {
  var writes = Future<void>.value();
  return (WorkerResponse response) {
    final Future<void> turn = writes.then((_) async {
      output.add(response.write());
      await output.flush();
    });
    writes = turn;
    return turn;
  };
}

/// One request being served: its cancel signal and whether it was answered.
typedef _Job = ({
  int requestId,
  Completer<void> cancelled,
  bool Function() isAnswered,
  bool Function() markAnswered,
});

_Job _createJob(int requestId) {
  var answered = false;
  return (
    requestId: requestId,
    cancelled: Completer<void>(),
    isAnswered: () => answered,
    markAnswered: () {
      if (answered) return false;
      answered = true;
      return true;
    },
  );
}

/// Answers every request read from [input] on [output] until [input] ends.
///
/// At most [maxConcurrent] requests run at once; the rest wait their turn.
/// A cancelled request is answered as cancelled at once, whether it waits or
/// runs, and a result that arrives after that is dropped. Every request is
/// answered exactly once, even one whose handler throws: a worker that closes
/// stdout without a `WorkResponse` fails the action with no diagnostics.
Future<void> serveWorker({
  required Stream<List<int>> input,
  required IOSink output,
  required WorkHandler handle,
  required int maxConcurrent,
}) async {
  final jobs = <int, _Job>{};
  final running = <Future<void>>{};
  final _Slots slots = _createSlots(maxConcurrent);
  final Future<void> Function(WorkerResponse) send = _serialWriter(output);
  Future<void> answer(_Job job, WorkerResponse response) async {
    if (!job.markAnswered()) return;
    jobs.remove(job.requestId);
    await send(response);
  }

  Future<void> serve(_Job job, Uint8List frame) async {
    final cancelledResponse = WorkerResponse(
      exitCode: 0,
      output: '',
      requestId: job.requestId,
      wasCancelled: true,
    );
    unawaited(job.cancelled.future.then((_) => answer(job, cancelledResponse)));
    await slots.acquire();
    try {
      if (job.isAnswered()) return;
      final WorkResult? result = await Future.any<WorkResult?>([
        _guarded(handle, frame, job.cancelled.future),
        job.cancelled.future.then((_) => null),
      ]);
      if (result == null) return;
      await answer(
        job,
        WorkerResponse(
          exitCode: result.exitCode,
          output: result.output,
          requestId: job.requestId,
        ),
      );
    } finally {
      slots.release();
    }
  }

  void track(Future<void> task) {
    running.add(task);
    unawaited(task.whenComplete(() => running.remove(task)));
  }

  await for (final Uint8List frame in WorkerFrames(input)) {
    final _Header header = _peekHeader(frame);
    if (header.error != null) {
      // Not a job: its id may belong to a request in flight.
      track(send(_malformedResponse(frame, header)));
      continue;
    }
    if (header.cancel) {
      final _Job? job = jobs[header.requestId];
      if (job != null && !job.cancelled.isCompleted) job.cancelled.complete();
      continue;
    }
    final _Job job = _createJob(header.requestId);
    jobs[job.requestId] = job;
    track(serve(job, frame));
  }
  await Future.wait(running.toList());
}

Future<WorkResult> _guarded(
  WorkHandler handle,
  Uint8List frame,
  Future<void> cancelled,
) async {
  try {
    return await handle(frame, cancelled);
  } on Object catch (error, stack) {
    final report = 'worker: $error\n$stack\n';
    stderr.write(report);
    return (exitCode: 1, output: report);
  }
}

/// A counting semaphore: `acquire` waits until fewer than the limit are held.
typedef _Slots = ({Future<void> Function() acquire, void Function() release});

_Slots _createSlots(int maxConcurrent) {
  var free = maxConcurrent;
  final waiting = <Completer<void>>[];
  return (
    acquire: () {
      if (free > 0) {
        free--;
        return Future<void>.value();
      }
      final waiter = Completer<void>();
      waiting.add(waiter);
      return waiter.future;
    },
    release: () {
      if (waiting.isEmpty) {
        free++;
      } else {
        waiting.removeAt(0).complete();
      }
    },
  );
}
