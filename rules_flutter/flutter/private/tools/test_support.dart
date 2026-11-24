/// Harness support shared by `flutter_test_runner.dart` and
/// `flutter_integration_test_runner.dart`.
///
/// Both runners drive the same per-test `package:test_api` `RemoteListener`
/// protocol over a WebSocket harness the test bootstrap dials back on, so the
/// timeout arithmetic, best-effort teardown, per-test event dispatch, suite
/// handshake metadata and result summary live here once instead of in both
/// binaries. Each runner reaches this library through its `srcs` in
/// `BUILD.bazel`.
library;

import 'dart:async';
import 'dart:io';

/// The per-test ceiling the wedged-test backstop waits out.
///
/// Bazel exports the target's timeout in `TEST_TIMEOUT` (seconds), so honour
/// it and stay a beat inside: the backstop exists to name a wedged test here
/// rather than let it run out Bazel's clock, and a flat bound silently
/// overrode whatever `--test_timeout` a longer-running test was given.
/// Outside `bazel test` there is no budget to derive one from, so five
/// minutes stands.
///
/// Public because the unit tests reach it directly.
Duration testCeiling(String? bazelTestTimeout) {
  final int? seconds = int.tryParse(bazelTestTimeout ?? '');
  if (seconds == null || seconds <= 0) return const Duration(minutes: 5);
  final int margin = seconds ~/ 20;
  return Duration(seconds: seconds - (margin < 10 ? 10 : margin));
}

/// How long coverage collection may take, from what is left of the test's
/// budget.
///
/// Three cases, from [bazelTestTimeout] (the raw `TEST_TIMEOUT`, seconds) and
/// [elapsed] (time since the run began):
///
/// * A positive integer: the budget left inside [testCeiling], that is the
///   ceiling minus [elapsed], so a collection that starts after a long test
///   waits only for what the test has left and never for more than the
///   ceiling.
/// * That budget used up: one second, a small positive bound, so an exhausted
///   run still attempts the collection and reports its own timeout instead of
///   parking until Bazel kills it.
/// * Missing, empty, non-numeric or non-positive: [testCeiling]'s own
///   fallback of five minutes, as for a direct run outside `bazel test`.
///
/// Pure in its arguments, so the unit tests need neither clock nor
/// environment. Public because they reach it directly.
Duration coverageBound(String? bazelTestTimeout, Duration elapsed) {
  final Duration ceiling = testCeiling(bazelTestTimeout);
  final int? seconds = int.tryParse(bazelTestTimeout ?? '');
  if (seconds == null || seconds <= 0) return ceiling;
  final Duration left = ceiling - elapsed;
  return left > Duration.zero ? left : const Duration(seconds: 1);
}

/// The suite's default timeout, serialized as `Metadata` carries it.
///
/// Bazel's own limit (`TEST_TIMEOUT`, seconds) in place of `package:test`'s
/// 30-second default, as `dart_test` sets it. Not `none`: `Timeout.merge`
/// lets `none` on either side win, so it would discard a limit a test's
/// author wrote on a case to catch a hang. With Bazel's limit as the default,
/// such a `timeout:` still fires, `Timeout.factor` scales Bazel's limit, and
/// a case with neither runs as long as Bazel lets the target run. Outside
/// `bazel test` there is no limit to state, so the default is none.
///
/// Public because the unit tests reach it directly.
Object suiteTimeout(String? bazelTestTimeout) {
  final int? seconds = int.tryParse(bazelTestTimeout ?? '');
  if (seconds == null || seconds <= 0) return 'none';
  return {
    'duration': Duration(seconds: seconds).inMicroseconds,
    'scaleFactor': null,
  };
}

/// Best-effort synchronous filesystem cleanup.
///
/// Swallows only [FileSystemException]: a file that vanished between the
/// `existsSync` check and the deletion is a race with the platform, not a
/// failure of the run. Anything else is a bug in the cleanup itself and
/// propagates.
///
/// Public because the unit tests reach it directly.
void cleanupQuietly(void Function() action) {
  try {
    action();
  } on FileSystemException catch (_) {
    // Best-effort cleanup only; anything else propagates by design.
  }
}

/// Best-effort asynchronous teardown step.
///
/// Swallows only the races a closing resource reports — [IOException] when
/// the peer went away first, [StateError] when the close already happened —
/// so a bug in teardown itself still surfaces instead of masking the run's
/// real result from a `finally` block.
///
/// Public because the unit tests reach it directly.
Future<void> teardownQuietly(Future<void> Function() step) async {
  try {
    await step();
  } on IOException catch (_) {
    // Best-effort teardown only; anything else propagates by design.
  } on StateError catch (_) {
    // Best-effort teardown only; anything else propagates by design.
  }
}

/// One test's failure, as the harness reports it.
class TestFailureSummary {
  new({
    required this.message,
    required this.type,
    required this.stackChain,
  });

  /// Human-readable failure message, as the harness reported it.
  final String message;

  /// Dotted error type name (`TestFailure`, `TestDeviceException`, ...).
  final String type;

  /// Trailing stack chain text, empty when the harness sent none.
  final String stackChain;

  @override
  String toString() {
    final buf = StringBuffer()..writeln('$type: $message');
    if (stackChain.isNotEmpty) {
      buf.write(stackChain);
    }
    return buf.toString();
  }
}

/// Where a runner files its per-test outcomes.
///
/// Implemented by each runner's result accumulator so the shared run-loop
/// helpers below ([fileUnstartedTest], [resolveTestFailure]) can file cases
/// without each runner copying them.
abstract class TestResultSink {
  void recordSuccess(String name, Duration elapsed, String output);

  void recordFailure(
    String name,
    TestFailureSummary summary,
    Duration elapsed,
    String output,
  );

  void recordSkipped(String name, String? reason);
}

/// Files a test that cannot start and reports whether it was filed.
///
/// A skipped test (unless it is a `setUpAll`/`tearDownAll` [fixture]) files
/// as skipped; a test whose target already disconnected files as a failure
/// naming [disconnectMessage]. Returns true when the test was filed, so the
/// caller returns early instead of running it.
bool fileUnstartedTest({
  required Map<String, dynamic> test,
  required String reportName,
  required bool fixture,
  required bool socketClosed,
  required String disconnectMessage,
  required TestResultSink results,
}) {
  final TestReadiness readiness = testReadiness(
    test: test,
    fixture: fixture,
    socketClosed: socketClosed,
    disconnectMessage: disconnectMessage,
  );
  if (readiness is TestSkipped) {
    results.recordSkipped(reportName, readiness.reason);
    return true;
  }
  if (readiness is TestTargetGone) {
    results.recordFailure(
      reportName,
      TestFailureSummary(
        message: readiness.message,
        type: 'TestDeviceException',
        stackChain: '',
      ),
      Duration.zero,
      '',
    );
    return true;
  }
  return false;
}

/// Resolves the failure to file for a finished test.
///
/// A test that failed on its own keeps its failure; a test with none whose
/// target disconnected mid-test (or never yielded) files [disconnectMessage]
/// instead, so nothing hangs waiting on a `complete` event that will never
/// arrive. Null when the test passed and the target is still connected.
TestFailureSummary? resolveTestFailure({
  required TestFailureSummary? failure,
  required bool socketClosed,
  required String disconnectMessage,
}) {
  if (failure != null) return failure;
  if (!socketClosed) return null;
  return TestFailureSummary(
    message: disconnectMessage,
    type: 'TestDeviceException',
    stackChain: '',
  );
}

/// Bookkeeping for one running test: its channel pair, completion signal,
/// case log and timer.
///
/// Created by [trackTestRun], which also wires the channel's inbound
/// dispatch; the run loop sends `run` on [outputId], waits out [completer],
/// then files the outcome from [output] and [started].
class RunningTest {
  new({
    required this.outputId,
    required this.inputId,
    required this.completer,
    required this.output,
    required this.started,
  });

  /// Channel the run loop sends `run` on to start this test.
  final int outputId;

  /// Channel whose inbound dispatch ([trackTestRun] wires it) feeds this test.
  final int inputId;

  /// Released when the harness posts this test's `complete` event.
  final Completer<void> completer;

  /// Case log: every `message` event the harness posted for this test.
  final StringBuffer output;

  /// Started at channel allocation; stopped when the outcome is filed.
  final Stopwatch started;
}

/// Allocates one running test's channel pair, registers its completion and
/// message dispatch on [pending]/[inbound], and hands back its tracking
/// state. Failures the handler observes go to [noteFailure].
RunningTest trackTestRun({
  required ({int outputId, int inputId}) channel,
  required Map<int, Completer<void>> pending,
  required Map<int, void Function(Object?)> inbound,
  required void Function(TestFailureSummary) noteFailure,
}) {
  final tracked = RunningTest(
    outputId: channel.outputId,
    inputId: channel.inputId,
    completer: Completer<void>(),
    output: StringBuffer(),
    started: Stopwatch()..start(),
  );
  pending[tracked.inputId] = tracked.completer;
  inbound[tracked.inputId] = testMessageHandler(
    completer: tracked.completer,
    output: tracked.output,
    noteFailure: noteFailure,
  );
  return tracked;
}

/// Builds the inbound dispatcher for one running test: explicit error
/// events become [noteFailure], prints go to stdout and the case log, and
/// `complete` releases the test's completer.
///
/// Both runners rely on the explicit error events for failure tracking; state
/// changes alone don't tell us the difference between "still
/// running" and "failed and continuing".
void Function(Object?) testMessageHandler({
  required Completer<void> completer,
  required StringBuffer output,
  required void Function(TestFailureSummary) noteFailure,
}) {
  return (data) {
    final Map<String, dynamic> msg = (data as Map).cast<String, dynamic>();
    switch (msg['type']) {
      case 'state-change':
        break;
      case 'error':
        final Map<String, dynamic> err = (msg['error'] as Map)
            .cast<String, dynamic>();
        noteFailure(
          TestFailureSummary(
            message:
                err['message'] as String? ?? err['toString'] as String? ?? '',
            type: err['type'] as String? ?? 'TestFailure',
            stackChain: err['stackChain'] as String? ?? '',
          ),
        );
      case 'message':
        final String mtype = msg['message-type'] as String? ?? 'print';
        final String text = msg['text'] as String? ?? '';
        final line = mtype == 'print' ? text : '[$mtype] $text';
        stdout.writeln(line);
        output.writeln(line);
      case 'complete':
        if (!completer.isCompleted) completer.complete();
    }
  };
}

/// Minimal `Metadata.serialize` payload — all optional flags omitted, an
/// empty `forTag`, [libraryTags] as the suite's `@Tags`, and [timeout] as
/// [suiteTimeout] serializes it.
Map<String, Object?> defaultSuiteMetadata(
  Object timeout,
  Set<String> libraryTags,
) {
  return {
    'testOn': null,
    'timeout': timeout,
    'skip': null,
    'skipReason': null,
    'verboseTrace': null,
    'chainStackTraces': null,
    'retry': null,
    'tags': libraryTags.toList(),
    'onPlatform': const <List<Object>>[],
    'forTag': const <String, Object?>{},
    'languageVersionComment': null,
  };
}

/// Renders the one-line suite summary both runners print at the end of a run.
String summarizeTestResults({
  required int passed,
  required int failed,
  required int skipped,
  required bool suiteError,
}) {
  final pieces = <String>[
    if (passed > 0) '$passed passed',
    if (failed > 0) '$failed failed',
    if (skipped > 0) '$skipped skipped',
  ];
  final String body = pieces.isEmpty ? 'no tests' : pieces.join(', ');
  return '\n$body${suiteError ? ' (suite error)' : ''}';
}

/// Why a test cannot start, when it cannot start.
///
/// Returned by [testReadiness] so both runners share the skip/offline
/// prologue of their run loops instead of copying it.
sealed class TestReadiness {
  const new();
}

/// The test can run.
final class TestReady extends TestReadiness {
  const new();
}

/// The test is skipped: file it via `recordSkipped` with [reason].
final class TestSkipped extends TestReadiness {
  const new(this.reason);

  /// Skip reason from the test's metadata, null when it gave none.
  final String? reason;
}

/// The target is already gone: file it as a failure with [message].
final class TestTargetGone extends TestReadiness {
  const new(this.message);

  /// Failure message naming the disconnect, filed for the unstarted test.
  final String message;
}

/// Decides whether [test] can start without running it.
///
/// A skipped test (unless it is a `setUpAll`/`tearDownAll` [fixture], which
/// `package:test` hides) files as skipped; a test whose target disconnected
/// files as a failure naming [disconnectMessage], so nothing hangs waiting
/// on a `complete` event that will never arrive.
TestReadiness testReadiness({
  required Map<String, dynamic> test,
  required bool fixture,
  required bool socketClosed,
  required String disconnectMessage,
}) {
  final metadata = test['metadata'] as Map?;
  final bool skipFlag = metadata == null
      ? false
      : (metadata['skip'] as bool? ?? false);
  if (!fixture && skipFlag) {
    return TestSkipped(metadata['skipReason'] as String?);
  }
  if (socketClosed) {
    return TestTargetGone(disconnectMessage);
  }
  return const TestReady();
}

/// Ambient values a launcher forwards into a hermetic child environment.
///
/// Built once where the values are gathered (the platform launchers'
/// `startTarget`, from the decoded `FLUTTER_INTEGRATION_TEST_DECLARED_ENV`,
/// `TZ` and the pinned fontconfig file) and passed down to the
/// `build*Environment` helpers, so the forwarding those helpers used to
/// repeat as long alias lists stays in one place.
class EnvForwarding {
  const new({this.env, this.tz, this.fontconfigFile});

  /// Declared environment entries, merged over the hermetic base map.
  /// A declared `TZ` entry wins over [tz].
  final Map<String, String>? env;

  /// Explicit timezone, used when the declared environment names none.
  final String? tz;

  /// When non-null, materializes as `FONTCONFIG_FILE`/`FONTCONFIG_PATH`.
  /// The Android runtime needs no fontconfig and leaves it unread.
  final String? fontconfigFile;
}
