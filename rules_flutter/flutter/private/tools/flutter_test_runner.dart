/// Bazel-side driver for `flutter_test` rule.
///
/// Spawns `flutter_tester` with the kernel `.dill` produced by the rule, hosts
/// a localhost WebSocket harness, and drives the per-test
/// `package:test_api/backend.dart` `RemoteListener` protocol. Reports per-test
/// pass/fail to stdout and exits non-zero on the first failure (or on
/// flutter_tester crash).
///
/// Wire protocol (mirrors `package:test`'s `flutter_platform.dart`):
///   - WebSocket transport carries JSON-encoded `[id, data]` lists, plus
///     `[id]` for channel-close. id 0 is the default channel.
///   - We send `{type: 'initial', metadata, platform, ...}` on id 0.
///   - Bootstrap responds `{type: 'success', root: <groupTree>}` on id 0;
///     each test in the tree carries a `channel` id (bootstrap-created).
///   - To run a test, we allocate our own outputId and send
///     `{command: 'run', channel: outputId}` on `testChannel + 1`. Bootstrap
///     replies with `state-change`/`error`/`message`/`complete` events on
///     `outputId + 1`, which we deliver back to our test handler.
///   - When the suite is exhausted we send `{type: 'close'}` on id 0.
///
/// Coverage: when `bazel coverage` sets `COVERAGE_OUTPUT_FILE`, the spawn
/// switches to `--vm-service-port=0`. The runner pulls the VM service URI from
/// flutter_tester's stdout and, once the suite has run and before it is told to
/// close, collects source reports over the VM service JSON-RPC and writes LCOV.
///
/// Goldens: `--update-goldens` (upstream's spelling) sets
/// `FLUTTER_TEST_UPDATE_GOLDENS` in the tester's environment, which the
/// comparator in the bootstrap reads. It is accepted only under `bazel run`,
/// where `BUILD_WORKSPACE_DIRECTORY` names a source tree to write to.
///
/// Bazel's test protocol wins wherever it has one. The suite's default timeout
/// is Bazel's own (`TEST_TIMEOUT`), not `package:test`'s 30 seconds; a test's
/// own `timeout:` still applies — see [suiteTimeout].
/// `--test_filter`, sharding and the per-case XML report follow
/// `bazel_test_protocol.dart`.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:runfiles/runfiles.dart';

import 'bazel_test_protocol.dart';
import 'flutter_test_coverage.dart' as coverage;
import 'run_home.dart' as run_home;
import 'test_support.dart';

typedef _Shutdown = ({bool killedAfterTimeout, int testerExit});

/// Whether this run should regenerate goldens instead of comparing them.
///
/// Pure so it can be tested without a Bazel invocation to produce each case;
/// [workspaceDir] is `BUILD_WORKSPACE_DIRECTORY`, which `bazel run` sets and
/// `bazel test` does not. That variable is the discriminator rather than
/// anything about the arguments, because it is the actual constraint: update
/// mode writes to the source tree, and a test action has no source tree.
///
/// Throws [FormatException] for an unrecognised argument. Nothing passes argv
/// to a `flutter_test` today — not `bazel test`, not `bazel coverage` — so an
/// unrecognised one came from a person, and silently ignoring a mistyped
/// `--update-golden` would report a green run that regenerated nothing.
bool parseUpdateGoldens(List<String> args, String? workspaceDir) {
  var update = false;
  for (final arg in args) {
    if (arg != '--update-goldens') {
      throw FormatException(
        'flutter_test runner: unrecognised argument "$arg". The only '
        'supported argument is --update-goldens.',
      );
    }
    update = true;
  }
  if (update && (workspaceDir == null || workspaceDir.isEmpty)) {
    throw FormatException(
      'flutter_test runner: --update-goldens rewrites goldens in the source '
      'tree, which a test action cannot do. Regenerate with '
      '`bazel run //<pkg>:<target> -- --update-goldens`.',
    );
  }
  return update;
}

/// The launcher arguments left once the seed flag is taken out, and the seed.
typedef SeedArgs = ({int? seed, List<String> rest});

const _seedFlag = '--test-randomize-ordering-seed';

/// Takes Bazel's `--test-randomize-ordering-seed=<value>` out of [args].
///
/// `<value>` is `random` or a non-negative decimal integer. `random` resolves
/// here, once, through [randomSeed], so the run has one integer to print and
/// to reproduce with. Throws [FormatException] naming the argument for an
/// empty, negative or non-numeric value, a bare flag with no `=`, or a flag
/// given twice; every other argument is left in `rest` for
/// [parseUpdateGoldens].
SeedArgs extractSeed(List<String> args, {int Function()? randomSeed}) {
  int? seed;
  final rest = <String>[];
  for (final arg in args) {
    if (arg != _seedFlag && !arg.startsWith('$_seedFlag=')) {
      rest.add(arg);
      continue;
    }
    final String? value = arg.length > _seedFlag.length
        ? arg.substring(_seedFlag.length + 1)
        : null;
    final int? parsed = value == 'random'
        ? (randomSeed ?? _newRandomSeed)()
        : (value == null || !RegExp(r'^[0-9]+$').hasMatch(value)
              ? null
              : int.tryParse(value));
    if (parsed == null || seed != null) {
      throw FormatException(
        'flutter_test runner: invalid argument "$arg". '
        '$_seedFlag takes `random` or a non-negative decimal integer, '
        'once.',
      );
    }
    seed = parsed;
  }
  return (seed: seed, rest: rest);
}

int _newRandomSeed() => Random.secure().nextInt(1 << 32);

/// The one line that records the seed a run used, so Bazel's test log carries
/// what is needed to repeat a failing order.
String seedAnnouncement(int seed) =>
    'flutter_test: running cases in randomized order; reproduce with '
    '$_seedFlag=$seed';

/// Returns [group] with the entries of every group, nested ones included,
/// put in an order derived from [seed].
///
/// The same seed on the same tree gives the same order. Cases are moved, never
/// copied or dropped, and a group keeps its own `setUpAll` and `tearDownAll`,
/// which [_Harness._runGroup] runs around its entries wherever they land.
Map<String, dynamic> shuffleSuite(Map<String, dynamic> group, int seed) =>
    _shuffleGroup(group, Random(seed));

Map<String, dynamic> _shuffleGroup(Map<String, dynamic> group, Random random) {
  final List<dynamic> entries = [...(group['entries'] as List? ?? const [])]
    ..shuffle(random);
  return {
    ...group,
    'entries': [
      for (final entry in entries)
        if ((entry as Map)['type'] == 'group')
          _shuffleGroup(entry.cast<String, dynamic>(), random)
        else
          entry,
    ],
  };
}

void main(List<String> args) async {
  final r = Runfiles.create();

  final bool updateGoldens;
  final int? seed;
  try {
    final SeedArgs parsed = extractSeed(args);
    seed = parsed.seed;
    updateGoldens = parseUpdateGoldens(
      parsed.rest,
      Platform.environment['BUILD_WORKSPACE_DIRECTORY'],
    );
  } on FormatException catch (e) {
    stderr.writeln(e.message);
    exit(64);
  }
  if (seed != null) stdout.writeln(seedAnnouncement(seed));

  final TestRunfiles files;
  try {
    files = resolveTestRunfiles(
      Platform.environment,
      r.rlocation,
      _runfileExists,
    );
  } on FormatException catch (e) {
    stderr.writeln('flutter_test runner: ${e.message}');
    exit(64);
  }
  final String path = Platform.environment['FLUTTER_TEST_PATH'] ?? 'test.dart';
  final String? coverageOutput = Platform.environment['COVERAGE_OUTPUT_FILE'];
  final List<String> coverageLibraries = _coverageLibraries(
    Platform.environment,
  );

  final TestSelection selection;
  try {
    selection = TestSelection.fromEnvironment(Platform.environment);
  } on FormatException catch (e) {
    stderr.writeln('flutter_test runner: ${e.message}');
    exit(64);
  }
  // The suite's library-level `@Tags`, extracted at build time: sent in the
  // handshake below so the test isolate's root group carries them, as
  // `test_core` sends `parseMetadata`'s result.
  final Set<String> libraryTags;
  try {
    libraryTags = readLibraryTags(Platform.environment, r.rlocation);
  } on FormatException catch (e) {
    stderr.writeln('flutter_test runner: ${e.message}');
    exit(64);
  }
  // Touched before the run, as Bazel asks: it is how a runner says it supports
  // sharding at all, and Bazel 9 fails a sharded test whose runner never does.
  final String? shardStatus = Platform.environment['TEST_SHARD_STATUS_FILE'];
  if (shardStatus != null) File(shardStatus).writeAsStringSync('');

  exitCode = await _runOnce(
    FlutterTestRun(
      tester: files.tester,
      icu: files.icu,
      dill: files.dill,
      baseDill: files.baseDill,
      assetsDir: files.assetsDir,
      testPath: path,
      coverageOutput: coverageOutput,
      coverageLibraries: coverageLibraries,
      updateGoldens: updateGoldens,
      seed: seed,
      selection: selection,
      libraryTags: libraryTags,
      xmlOutput: Platform.environment['XML_OUTPUT_FILE'],
      impeller: Platform.environment['FLUTTER_TEST_IMPELLER'] == '1',
    ),
  );
}

/// The coverage scope in `FLUTTER_TEST_COVERAGE_LIBRARIES`: one library URI
/// prefix per line. An absent key, or blank lines, yield no entry, and an
/// empty list leaves the coverage request unscoped.
List<String> _coverageLibraries(Map<String, String> env) =>
    (env['FLUTTER_TEST_COVERAGE_LIBRARIES'] ?? '')
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();

/// Everything `main` gathers for one `flutter_test` run.
///
/// Built once from the environment in [main] and passed down to [_runOnce]
/// and [_Harness.run], so the values that travel together stay in one object
/// instead of a long parameter list.
class FlutterTestRun {
  const new({
    required this.tester,
    required this.icu,
    required this.dill,
    required this.seed,
    required this.coverageLibraries,
    this.baseDill,
    required this.assetsDir,
    required this.testPath,
    required this.coverageOutput,
    required this.updateGoldens,
    required this.selection,
    required this.libraryTags,
    required this.xmlOutput,
    required this.impeller,
  });

  /// `flutter_tester` binary this run executes.
  final String tester;

  /// ICU data file the tester loads.
  final String icu;

  /// Kernel dill of the test bundle.
  final String dill;

  /// Optional base dill appended after [dill] into one combined bundle.
  final String? baseDill;

  /// Flutter assets directory handed to the tester, null when the bundle
  /// ships none.
  final String? assetsDir;

  /// Test file this run executes.
  final String testPath;

  /// LCOV output file; null disables coverage (and the VM service).
  final String? coverageOutput;

  /// Library URI prefixes coverage is scoped to; empty collects everything.
  final List<String> coverageLibraries;

  /// Whether to update golden files instead of comparing against them.
  final bool updateGoldens;

  /// Seed for the case order; null keeps declaration order.
  final int? seed;

  /// Name filter selecting which cases run.
  final TestSelection selection;

  /// The suite's library-level `@Tags`, sent in the handshake so the test
  /// isolate's root group carries them.
  final Set<String> libraryTags;

  /// JUnit XML output file, null when Bazel asked for none.
  final String? xmlOutput;

  /// Whether to run with the Impeller backend.
  final bool impeller;
}

/// Whether [path] names something on disk, as a file or a directory.
///
/// The rule hands the runner files (`FLUTTER_TEST_DILL` and friends) and one
/// directory (`FLUTTER_TEST_ASSETS`), so the probe [resolveTestRunfiles] runs
/// here accepts both; a missing path fails there, naming its variable.
bool _runfileExists(String path) =>
    File(path).existsSync() || Directory(path).existsSync();

Future<int> _runOnce(FlutterTestRun run) async {
  final String? baseDill = run.baseDill;
  File? combinedDill;
  String effectiveDill = run.dill;
  // `baseDill` already passed the existence check in `main`: when the rule
  // shares one it is always combined, never silently dropped for a lone run
  // of the delta kernel. Null (or empty) means a whole-program kernel.
  if (baseDill != null && baseDill.isNotEmpty) {
    final tmpDir = Directory(
      Platform.environment['TEST_TMPDIR'] ?? Directory.systemTemp.path,
    );
    combinedDill = File(
      '${tmpDir.path}/flutter_test_${pid}_${DateTime.now().microsecondsSinceEpoch}.dill',
    );
    final builder = BytesBuilder(copy: false)
      ..add(File(run.dill).readAsBytesSync())
      ..add(File(baseDill).readAsBytesSync());
    combinedDill.writeAsBytesSync(builder.takeBytes(), flush: true);
    effectiveDill = combinedDill.path;
  }
  final _Harness harness = await _Harness.bind();
  try {
    return await harness.run(run, effectiveDill);
  } finally {
    await harness.dispose();
    if (combinedDill != null && combinedDill.existsSync()) {
      cleanupQuietly(combinedDill.deleteSync);
    }
  }
}

/// Harness state: server, tester process, WebSocket, channel demux.
class _Harness {
  new _(this._server);

  final HttpServer _server;
  Process? _process;

  /// Private HOME the tester process runs under (RT37-flutter:02 private
  /// policy), removed in [dispose] once the tester has exited.
  Directory? _testerHome;
  WebSocket? _ws;
  bool _socketClosed = false;

  /// Started when [run] begins; the coverage bound is measured against it.
  final Stopwatch _clock = Stopwatch();

  /// Per-channel inbound dispatchers, keyed by inputId.
  final Map<int, void Function(Object?)> _inbound = {};

  /// Pending test completers indexed by their reply-channel inputId. When the
  /// socket closes mid-suite, we surface that as a failure on every
  /// outstanding test so we can't hang waiting on a `complete` event that
  /// will never arrive.
  final Map<int, Completer<void>> _pendingTests = {};

  /// MultiChannel-compatible counter for our locally-allocated channels.
  /// `package:stream_channel`'s MultiChannel allocates outputId = nextId,
  /// inputId = nextId+1, then increments by 2.
  int _nextId = 1;

  /// Allocates a virtual channel pair for our side. Returns (outputId, inputId).
  ({int outputId, int inputId}) _allocChannel() {
    final int out = _nextId;
    final int inp = _nextId + 1;
    _nextId += 2;
    return (outputId: out, inputId: inp);
  }

  void _send(int outputId, Object? data) {
    if (_socketClosed) return;
    _ws!.add(json.encode([outputId, data]));
  }

  /// Binds the socket the test bootstrap dials back on.
  ///
  /// The IPv4 loopback specifically, and the bootstrap dials
  /// `ws://127.0.0.1:$port` for it — one family at both ends, deliberately.
  /// Only a port number crosses to the tester process
  /// (`FLUTTER_TEST_HARNESS_PORT`), so nothing here publishes a *name* for a
  /// client to choose a family from. That is what makes this unlike the
  /// control channel and the web dev server, which bind both loopbacks
  /// because their URLs say `localhost`: a client resolving that name picks a
  /// family itself, so half of such a URL would reach whatever else holds the
  /// port on the family the server left free. A specific-address bind is also
  /// refused outright by the kernel when the port is already held, so nothing
  /// can be reached here in place of this server.
  ///
  /// The one host this cannot run on is one with no assignable 127.0.0.1 — an
  /// IPv6-only loopback. Never tested, and accepted as untested rather than
  /// coded around, because a Flutter test cannot work there for reasons above
  /// this file. The engine binds its VM service to 127.0.0.1 unless launched
  /// with `--ipv6` (`engine/src/flutter/shell/common/switches.cc`, read at all
  /// five engine revisions `versions.bzl` pins), nothing in this repo passes
  /// that flag, the only VM-service host it does name is the IPv4 wildcard
  /// `0.0.0.0` for a wireless iOS device, and the `adb`/`iproxy` forwards a
  /// device run is dialed through listen on 127.0.0.1. Widening this bind
  /// alone would buy nothing.
  ///
  /// So do not change it without a failure reproduced on such a host — and
  /// never without the dial in `flutter/private/flutter_test.bzl`, which has
  /// to name the same family.
  static Future<_Harness> bind() async {
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    return _Harness._(server);
  }

  /// Closes all three of the harness's resources, independently.
  ///
  /// Separate `try`s because none of the three depends on the one before it,
  /// and this runs on the failure paths too — a socket that will not close
  /// must not leave the tester process alive or the port bound. They stay
  /// broad and quiet because what they throw is "already closed", which is
  /// the state the call was asking for.
  ///
  /// [Process.kill] is not one of them and is no longer wrapped. It answers
  /// with a bool and does not throw for a dead process — dart-sdk
  /// `lib/io/process.dart`: "Returns `true` if the signal is successfully
  /// delivered... Otherwise the signal could not be sent, usually meaning that
  /// the process is already dead." The `try` around it was guarding a failure
  /// that cannot happen, while the value that does report it went unread.
  Future<void> dispose() async {
    final WebSocket? ws = _ws;
    if (ws != null) await teardownQuietly(ws.close);
    _process?.kill(ProcessSignal.sigkill);
    await teardownQuietly(() => _server.close(force: true));
    final Directory? testerHome = _testerHome;
    _testerHome = null;
    if (testerHome != null && testerHome.existsSync()) {
      cleanupQuietly(() => testerHome.deleteSync(recursive: true));
    }
  }

  /// Runs [run] against the combined kernel [effectiveDill] [_runOnce]
  /// prepared (the base `.dill` pre-appended when the rule shares one).
  Future<int> run(FlutterTestRun run, String effectiveDill) async {
    _clock.start();
    final enableVmService = run.coverageOutput != null;
    _process = await _spawnTester(
      _testerCommand(
        tester: run.tester,
        icu: run.icu,
        assetsDir: run.assetsDir,
        dill: effectiveDill,
        enableVmService: enableVmService,
        impeller: run.impeller,
      ),
      run.updateGoldens,
    );

    // Capture flutter_tester output so engine errors are visible. In coverage
    // mode we also need to scan stdout for the VM service URI.
    final vmServiceUriCompleter = Completer<Uri>();
    _watchTesterOutput(_process!, enableVmService, vmServiceUriCompleter);

    final ({bool failed, Uri? uri}) coverageService =
        await _readCoverageServiceUri(enableVmService, vmServiceUriCompleter);
    if (coverageService.failed) return 1;
    final Uri? coverageVmServiceUri = coverageService.uri;

    // Wait for the bootstrap to dial back.
    final int? dialBackExit = await _settleDialBack();
    if (dialBackExit != null) return dialBackExit;

    // Default channel handler — receives the suite tree plus print/error
    // events. We resolve `suiteReady` once the bootstrap finishes registering
    // tests (or surfaces a load failure).
    final suiteReady = Completer<Map<String, dynamic>?>();
    _inbound[0] = (data) => _onDefaultChannel(data, suiteReady);

    _watchSocketClose(suiteReady);

    // Send the initial suite handshake.
    _send(0, _initialMessage(run.testPath, run.libraryTags));

    // Bounded inside Bazel's own budget, like each test below, so a suite that
    // never finishes loading is reported here rather than killed silently.
    final Map<String, dynamic>? root = await suiteReady.future.timeout(
      testCeiling(Platform.environment['TEST_TIMEOUT']),
      onTimeout: () => null,
    );

    final results = _Results();
    await _driveSelectedTests(root, run.selection, run.seed, results);
    await _writeXmlReport(run.xmlOutput, results, run.testPath);

    // Collect coverage before tearing the tester down — the isolate must still
    // be alive when we fetch source reports.
    final String? coverageError = await _collectCoverage(
      elapsed: _clock.elapsed,
      enableVmService: enableVmService,
      coverageVmServiceUri: coverageVmServiceUri,
      coverageOutput: run.coverageOutput,
      coverageLibraries: run.coverageLibraries,
    );
    if (coverageError != null) {
      stderr.writeln('flutter_test (coverage): $coverageError');
    }

    // Politely shut down: tell RemoteListener to close, then close the
    // WebSocket. The bootstrap's `socket.map(...).pipe(sink)` and
    // `socket.addStream(...)` both terminate on socket close, draining the
    // isolate so flutter_tester exits on its own. Without the explicit
    // close, the bootstrap's main isolate keeps the engine alive and
    // we'd block on the tester-exit timeout for every test run.
    _send(0, {'type': 'close'});
    final _Shutdown shutdown = await _shutdownTester();

    stdout.writeln(results.summary());

    if (results.hasFailure) return 1;
    // A requested coverage run that produced no data is a failure — Bazel
    // would otherwise record a green test with an empty/absent LCOV file.
    if (coverageError != null) return 1;
    if (!shutdown.killedAfterTimeout && shutdown.testerExit != 0) {
      stderr.writeln(
        'flutter_test: flutter_tester exited with ${shutdown.testerExit}',
      );
      return shutdown.testerExit;
    }
    return 0;
  }

  /// The `flutter_tester` argv for this run.
  ///
  /// Coverage does not start the tester paused, and `flutter test --coverage`
  /// does not either. Nothing needs holding: the VM records coverage from
  /// the first line `main()` runs, and collection happens before the suite
  /// is told to close, while the isolate is still alive. Starting paused and
  /// resuming over the VM service hung one run in ten, measured on
  /// `:hello_coverage_test`: the resumed isolate sat idle inside the
  /// bootstrap, never dialling the harness, until an unrelated VM service
  /// request woke it. Unpaused, 80 runs in a row passed with identical
  /// covered lines.
  static List<String> _testerCommand({
    required String tester,
    required String icu,
    required String? assetsDir,
    required String dill,
    required bool enableVmService,
    required bool impeller,
  }) {
    return <String>[
      tester,
      if (enableVmService) '--vm-service-port=0' else '--disable-vm-service',
      '--icu-data-file-path=$icu',
      '--enable-checked-mode',
      '--verify-entry-points',
      // `flutter test --enable-impeller`'s choice: Impeller, or software
      // Skia rendered deterministically.
      if (impeller)
        '--enable-impeller'
      else ...[
        '--enable-software-rendering',
        '--skia-deterministic-rendering',
      ],
      '--enable-dart-profiling',
      '--non-interactive',
      '--use-test-fonts',
      '--disable-asset-fonts',
      if (assetsDir != null) '--flutter-assets-dir=$assetsDir',
      dill,
    ];
  }

  /// Starts `flutter_tester` against this harness's port.
  ///
  /// `flutter test` bakes `autoUpdateGoldenFiles = true` into a bootstrap
  /// it regenerates for every run. Here the bootstrap is a build artifact
  /// shared by every run of the target, so update mode has to reach the
  /// tester at runtime instead. The parent environment comes along by
  /// default, which is how the comparator also sees
  /// BUILD_WORKSPACE_DIRECTORY and TEST_UNDECLARED_OUTPUTS_DIR.
  ///
  /// Private HOME policy (RT37-flutter:02): only the home-locating keys are
  /// overridden, at a fresh dir [dispose] removes; everything else is
  /// inherited unchanged.
  Future<Process> _spawnTester(List<String> command, bool updateGoldens) {
    final Directory testerHome = run_home.createPrivateHome(
      Platform.environment['TEST_TMPDIR'] ?? Directory.systemTemp.path,
    );
    _testerHome = testerHome;
    return Process.start(
      command.first,
      command.sublist(1),
      environment: {
        'FLUTTER_TEST': 'true',
        'FLUTTER_TEST_HARNESS_PORT': '${_server.port}',
        if (updateGoldens) 'FLUTTER_TEST_UPDATE_GOLDENS': '1',
        ...run_home.privateHomeEnv(testerHome.path),
      },
    );
  }

  /// Forwards `flutter_tester`'s stdout/stderr to ours, watching stdout for
  /// the VM service URI in coverage mode.
  void _watchTesterOutput(
    Process process,
    bool enableVmService,
    Completer<Uri> vmServiceUriCompleter,
  ) {
    final vmServicePattern = RegExp(
      r'(?:Observatory|The Dart VM service is) (?:listening on|listening on) (http\S+)',
    );
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          stderr.writeln('[flutter_tester] $line');
          if (enableVmService && !vmServiceUriCompleter.isCompleted) {
            final RegExpMatch? m = vmServicePattern.firstMatch(line);
            if (m != null) {
              vmServiceUriCompleter.complete(Uri.parse(m.group(1)!));
            }
          }
        });
    process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          stderr.writeln('[flutter_tester] $line');
        });
  }

  /// Waits for the VM service URI in coverage mode.
  ///
  /// A coverage run that cannot reach the VM service cannot produce what it
  /// exists for, so [failed] is set rather than running the whole suite first
  /// and failing at collection.
  Future<({Uri? uri, bool failed})> _readCoverageServiceUri(
    bool enableVmService,
    Completer<Uri> vmServiceUriCompleter,
  ) async {
    if (!enableVmService) return (uri: null, failed: false);
    try {
      final Uri uri = await vmServiceUriCompleter.future.timeout(
        const Duration(seconds: 30),
      );
      return (uri: uri, failed: false);
    } catch (e) {
      stderr.writeln(
        'flutter_test (coverage): failed to bring up the VM service: $e',
      );
      return (uri: null, failed: true);
    }
  }

  /// Waits for the bootstrap's dial-back and adopts the socket.
  ///
  /// Returns the run's exit code when the suite will not run because the
  /// tester exited or stayed silent, or null once the socket is adopted.
  Future<int?> _settleDialBack() async {
    switch (await _awaitDialBack()) {
      case _TesterExited(:final int exitCode):
        stderr.writeln(
          'flutter_test: flutter_tester exited with code $exitCode before '
          'connecting to the harness.',
        );
        return exitCode == 0 ? 1 : exitCode;
      case _DialBackTimedOut():
        stderr.writeln(
          'flutter_test: flutter_tester did not connect to the harness within '
          '${_dialBackBound.inMinutes} minutes and is still running; killing '
          'it.',
        );
        return 1;
      case _BootstrapConnected(:final HttpRequest request):
        _ws = await WebSocketTransformer.upgrade(request);
        return null;
    }
  }

  /// Watches the bootstrap socket: when it closes mid-suite, every
  /// outstanding test surfaces that as a failure so nothing hangs waiting on
  /// a `complete` event that will never arrive.
  void _watchSocketClose(Completer<Map<String, dynamic>?> suiteReady) {
    _ws!.listen(
      _onSocketMessage,
      onDone: () {
        _socketClosed = true;
        if (!suiteReady.isCompleted) suiteReady.complete(null);
        for (final Completer<void> c in _pendingTests.values) {
          if (!c.isCompleted) c.complete();
        }
        _pendingTests.clear();
      },
    );
  }

  /// Handles one message on the default channel: the suite tree plus
  /// print/error events. Resolves [suiteReady] once the bootstrap finishes
  /// registering tests (or surfaces a load failure).
  static void _onDefaultChannel(
    Object? data,
    Completer<Map<String, dynamic>?> suiteReady,
  ) {
    final Map<String, dynamic> msg = (data as Map).cast<String, dynamic>();
    switch (msg['type']) {
      case 'success':
        if (!suiteReady.isCompleted) {
          suiteReady.complete((msg['root'] as Map).cast<String, dynamic>());
        }
      case 'loadException':
        stderr.writeln('flutter_test: load failure — ${msg['message']}');
        if (!suiteReady.isCompleted) suiteReady.complete(null);
      case 'error':
        final Map<String, dynamic> err = (msg['error'] as Map)
            .cast<String, dynamic>();
        stderr.writeln(
          'flutter_test: top-level error — ${err['message']}\n'
          '${err['stackChain']}',
        );
        if (!suiteReady.isCompleted) suiteReady.complete(null);
      case 'print':
        stdout.writeln(msg['line']);
    }
  }

  /// Runs the suite the bootstrap registered, honouring [selection].
  Future<void> _driveSelectedTests(
    Map<String, dynamic>? root,
    TestSelection selection,
    int? seed,
    _Results results,
  ) async {
    if (root == null) {
      results.recordError('suite did not load');
      return;
    }
    Map<String, dynamic>? selected;
    try {
      selected = selection.select(root);
    } on FormatException catch (e) {
      // An `include_tags` attribute selection that matches no test: a tag
      // name nobody carries is a typo, and passing an empty suite would
      // hide it. Recorded as a suite error so the target fails with the
      // message; a `--test_env` selection that matches nothing still
      // passes with the note below.
      results.recordError(e.message);
    }
    if (selected != null) {
      await _runGroup(
        seed == null ? selected : shuffleSuite(selected, seed),
        results,
      );
    } else if (!results.hasFailure && selection.narrows) {
      stdout.writeln(
        'flutter_test: no test case in this suite matches this run\'s '
        '--test_filter, tags or shard.',
      );
    }
  }

  /// Writes the per-case JUnit XML report Bazel merges, when asked.
  static Future<void> _writeXmlReport(
    String? xmlOutput,
    _Results results,
    String testPath,
  ) async {
    if (xmlOutput != null) {
      await File(xmlOutput)
          .writeAsString(junitXml(results.cases, suiteName: testPath));
    }
  }

  /// Collects the LCOV report over the VM service in coverage mode.
  ///
  /// Returns the failure to report, or null when there is nothing to report.
  /// Bounded: a VM service that stops answering mid-collection would
  /// otherwise park here until Bazel's outer test timeout, killed with no
  /// reason given. The bound is what is left of the test's `TEST_TIMEOUT`
  /// budget after [elapsed] ([coverageBound]), so a loaded machine that
  /// slows the collection is not failed while the test still had budget.
  static Future<String?> _collectCoverage({
    required Duration elapsed,
    required bool enableVmService,
    required Uri? coverageVmServiceUri,
    required String? coverageOutput,
    required List<String> coverageLibraries,
  }) async {
    final coverageFile = coverageOutput;
    if (!enableVmService ||
        coverageVmServiceUri == null ||
        coverageFile == null) {
      return null;
    }
    try {
      final String lcov = await coverage
          .collectCoverage(coverageVmServiceUri, coverageLibraries)
          .timeout(
            coverageBound(Platform.environment['TEST_TIMEOUT'], elapsed),
          );
      // Every healthy run yields at least the bootstrap's own record, so an
      // empty report means collection reached no source at all. Writing it
      // would produce exactly the green-test-with-empty-LCOV outcome the
      // exit below exists to prevent.
      if (lcov.isEmpty) return 'collected no coverage records';
      await File(coverageFile).writeAsString(lcov);
      return null;
    } on IOException catch (e) {
      // A source read or the LCOV write failed; reported as a coverage
      // failure, never mistaken for a healthy run.
      return _coverageFailure(e);
    } on StateError catch (e) {
      // The VM service refused an RPC; reported as a coverage failure.
      return _coverageFailure(e);
    } on TimeoutException catch (e) {
      // The VM service stopped answering mid-collection; reported as a
      // coverage failure rather than parking until Bazel's outer timeout.
      return _coverageFailure(e);
    } on TypeError catch (e) {
      // A malformed report is a broken run, not empty coverage; reported.
      return _coverageFailure(e);
    }
  }

  /// Formats a coverage collection failure for the run's stderr report.
  static String _coverageFailure(Object e) => 'failed to collect coverage: $e';

  /// Closes the suite down and waits for `flutter_tester` to exit.
  ///
  /// `-1` can't double as a "we killed it" sentinel here: on POSIX a
  /// signal-killed process reports `-signum`, and SIGHUP is signal 1, so
  /// `-1` is a real exit value. Track the timeout kill explicitly instead.
  Future<_Shutdown> _shutdownTester() async {
    final WebSocket? ws = _ws;
    if (ws != null) await teardownQuietly(ws.close);
    var killedAfterTimeout = false;
    final int testerExit = await _process!.exitCode.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        killedAfterTimeout = true;
        _process!.kill(ProcessSignal.sigkill);
        return 0;
      },
    );
    if (killedAfterTimeout) {
      stderr.writeln(
        'flutter_test: flutter_tester did not exit within 30s after the '
        'suite finished; killed it.',
      );
    }
    return (killedAfterTimeout: killedAfterTimeout, testerExit: testerExit);
  }

  /// How long flutter_tester gets to open its socket back to us.
  static const _dialBackBound = Duration(minutes: 2);

  /// Waits for the bootstrap's dial-back, reporting which of the three
  /// possible outcomes happened.
  ///
  /// The distinction is load-bearing rather than tidiness. A single nullable
  /// `HttpRequest?` collapses "flutter_tester died" and "flutter_tester is
  /// alive and silent" into one `null`, and only the first of those has an
  /// exit code worth awaiting — awaiting it on the second blocks forever, and
  /// a paused coverage run then reaches Bazel's outer test timeout with no
  /// diagnostic of its own.
  Future<_DialBack> _awaitDialBack() async {
    final _DialBack? outcome = await Future.any([
      _server.first.then<_DialBack?>(_BootstrapConnected.new),
      _process!.exitCode.then<_DialBack?>(_TesterExited.new),
    ]).timeout(_dialBackBound, onTimeout: () => null);
    return outcome ?? const _DialBackTimedOut();
  }

  void _onSocketMessage(dynamic raw) {
    final list = json.decode(raw as String) as List;
    final int id = (list[0] as num).toInt();
    if (list.length == 1) {
      // Channel closed by remote — drop the handler so we stop dispatching.
      _inbound.remove(id);
      return;
    }
    final void Function(Object?)? handler = _inbound[id];
    if (handler != null) handler(list[1]);
  }

  Future<void> _runGroup(Map<String, dynamic> group, _Results results) async {
    final setUpAll = group['setUpAll'] as Map?;
    if (setUpAll != null) {
      await _runTest(setUpAll.cast<String, dynamic>(), results, fixture: true);
    }

    final List<dynamic> entries = group['entries'] as List? ?? const [];
    for (final entry in entries) {
      final Map<String, dynamic> m = (entry as Map).cast<String, dynamic>();
      if (m['type'] == 'group') {
        await _runGroup(m, results);
      } else {
        await _runTest(m, results);
      }
    }

    final tearDownAll = group['tearDownAll'] as Map?;
    if (tearDownAll != null) {
      await _runTest(
        tearDownAll.cast<String, dynamic>(),
        results,
        fixture: true,
      );
    }
  }

  /// Runs one test, or one `setUpAll`/`tearDownAll` when [fixture] is set: a
  /// fixture is reported only when it fails, as `package:test` hides it.
  ///
  /// `test['name']` is already the full name, enclosing groups included —
  /// `package:test` names a test that way when it is declared.
  Future<void> _runTest(
    Map<String, dynamic> test,
    _Results results, {
    bool fixture = false,
  }) async {
    final int testChannelId = (test['channel'] as num).toInt();
    final String reportName = test['name'] as String? ?? '';

    if (fileUnstartedTest(
      test: test,
      reportName: reportName,
      fixture: fixture,
      socketClosed: _socketClosed,
      disconnectMessage: 'flutter_tester disconnected before this test ran',
      results: results,
    )) {
      return;
    }

    TestFailureSummary? failure;
    void noteFailure(TestFailureSummary summary) => failure ??= summary;
    final RunningTest tracked = trackTestRun(
      channel: _allocChannel(),
      pending: _pendingTests,
      inbound: _inbound,
      noteFailure: noteFailure,
    );

    // Send "run" to the test channel. testChannelId is bootstrap's outputId
    // for the test's virtual channel; per MultiChannel framing we send back
    // on testChannelId+1.
    _send(testChannelId + 1, {'command': 'run', 'channel': tracked.outputId});

    // `test_api` enforces the timeout from the metadata we sent — Bazel's own,
    // or the test's — but that's a Timer: a test that spins synchronously
    // without yielding never lets it fire. This ceiling stays just inside
    // Bazel's limit, so a wedged test is named as a failure here instead of the
    // whole target being killed with no word on which test hung. Kill the tester and treat
    // the socket as gone so the remaining tests bail out fast.
    final Duration ceiling = testCeiling(Platform.environment['TEST_TIMEOUT']);
    await _awaitTestCompletion(
      completer: tracked.completer,
      ceiling: ceiling,
      reportName: reportName,
    );
    _pendingTests.remove(tracked.inputId);
    _inbound.remove(tracked.inputId);

    failure = resolveTestFailure(
      failure: failure,
      socketClosed: _socketClosed,
      disconnectMessage:
          'flutter_tester disconnected mid-test (or test timed out)',
    );

    tracked.started.stop();
    _recordTestResult(
      results: results,
      reportName: reportName,
      failure: failure,
      elapsed: tracked.started.elapsed,
      output: tracked.output.toString(),
      fixture: fixture,
    );
  }

  /// Waits out one test's ceiling, killing the tester when a wedged test
  /// never yields so the remaining tests bail out fast.
  Future<void> _awaitTestCompletion({
    required Completer<void> completer,
    required Duration ceiling,
    required String reportName,
  }) async {
    await completer.future.timeout(
      ceiling,
      onTimeout: () {
        stderr.writeln(
          'flutter_test: test "$reportName" did not finish within '
          '${ceiling.inSeconds}s; killing flutter_tester.',
        );
        _socketClosed = true;
        _process?.kill(ProcessSignal.sigkill);
      },
    );
  }

  /// Files one finished test away: a failure, or a pass unless it is a
  /// `setUpAll`/`tearDownAll` fixture, which `package:test` hides.
  static void _recordTestResult({
    required _Results results,
    required String reportName,
    required TestFailureSummary? failure,
    required Duration elapsed,
    required String output,
    required bool fixture,
  }) {
    if (failure != null) {
      results.recordFailure(reportName, failure, elapsed, output);
    } else if (!fixture) {
      results.recordSuccess(reportName, elapsed, output);
    }
  }

  Map<String, dynamic> _initialMessage(
    String testPath,
    Set<String> libraryTags,
  ) => {
    'type': 'initial',
    'metadata': defaultSuiteMetadata(
      suiteTimeout(Platform.environment['TEST_TIMEOUT']),
      libraryTags,
    ),
    'platform': _suitePlatform(),
    'platformVariables': const <String>[],
    'collectTraces': true,
    'noRetry': true,
    'allowDuplicateTestNames': true,
    'foldTraceExcept': const <String>[],
    'foldTraceOnly': const <String>[],
    'path': testPath,
    'asciiGlyphs': !stdout.supportsAnsiEscapes,
    'ignoreTimeouts': false,
  };

  /// Built-in `Runtime.vm` and `Compiler.kernel` serialize as plain identifiers.
  static Map<String, Object?> _suitePlatform() => {
    'runtime': 'vm',
    'compiler': 'kernel',
    'os': _osIdentifier(),
    'inGoogle': false,
  };

  static String _osIdentifier() {
    if (Platform.isMacOS) return 'mac-os';
    if (Platform.isLinux) return 'linux';
    if (Platform.isWindows) return 'windows';
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    return 'none';
  }
}

/// The outcome of waiting for flutter_tester's bootstrap to connect back.
sealed class _DialBack {
  const new();
}

/// The bootstrap connected; [request] is the HTTP request to upgrade.
final class _BootstrapConnected extends _DialBack {
  const new(this.request);

  final HttpRequest request;
}

/// flutter_tester exited before connecting, with [exitCode].
final class _TesterExited extends _DialBack {
  const new(this.exitCode);

  final int exitCode;
}

/// Nothing happened within the bound: flutter_tester is alive and has not
/// connected. There is no exit code to wait for.
final class _DialBackTimedOut extends _DialBack {
  const new();
}

class _Results implements TestResultSink {
  int passed = 0;
  int failed = 0;
  int skipped = 0;
  bool _suiteError = false;

  /// Every case in the order it ran, for the JUnit report.
  final List<TestCaseResult> cases = [];

  void recordSuccess(String name, Duration elapsed, String output) {
    passed++;
    cases.add(TestCaseResult.passed(name, elapsed, output));
    stdout.writeln('  PASS  $name');
  }

  void recordFailure(
    String name,
    TestFailureSummary summary,
    Duration elapsed,
    String output,
  ) {
    failed++;
    cases.add(
      TestCaseResult.failed(
        name,
        elapsed,
        output,
        failureType: summary.type,
        message: summary.message,
        detail: summary.toString(),
      ),
    );
    stdout.writeln('  FAIL  $name');
    stdout.writeln(_indent(summary.toString(), '        '));
  }

  void recordSkipped(String name, String? reason) {
    skipped++;
    cases.add(TestCaseResult.skipped(name));
    stdout.writeln(
      reason == null ? '  SKIP  $name' : '  SKIP  $name (${reason.trim()})',
    );
  }

  void recordError(String message) {
    _suiteError = true;
    stderr.writeln('flutter_test: $message');
  }

  bool get hasFailure => failed > 0 || _suiteError;

  String summary() => summarizeTestResults(
    passed: passed,
    failed: failed,
    skipped: skipped,
    suiteError: _suiteError,
  );
}

String _indent(String body, String prefix) =>
    body.split('\n').map((l) => l.isEmpty ? l : '$prefix$l').join('\n');
