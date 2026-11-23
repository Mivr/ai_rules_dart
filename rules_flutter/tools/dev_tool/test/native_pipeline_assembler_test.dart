/// What the assembler does before it builds anything.
///
/// The app's own `BuildInfo` is read first, because every flag list the
/// assembly uses comes out of it — including the dev build's `--dart-define`s,
/// which land in the `_dev_config.json` the resident frontend_server replays on
/// every recompile. Reading it later would mean `attach` has to be *told* the
/// defines, and told them again correctly, or the app loses them at the first
/// reload.
///
/// [_noWorkspace] is what makes the ordering assertable at all: no bazel can be
/// spawned there, so a message naming the running app is proof the record was
/// read before the first build, and a message naming a missing directory is
/// proof it was not.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_bazel_dev_tool/android_splits.dart';
import 'package:flutter_bazel_dev_tool/bazel.dart';
import 'package:flutter_bazel_dev_tool/build_info.dart';
import 'package:flutter_bazel_dev_tool/device.dart';
import 'package:flutter_bazel_dev_tool/device_android.dart';
import 'package:flutter_bazel_dev_tool/logging.dart';
import 'package:flutter_bazel_dev_tool/native_pipeline_assembler.dart';
import 'package:flutter_bazel_dev_tool/reload_pipeline.dart';
import 'package:flutter_bazel_dev_tool/session.dart';
import 'package:flutter_bazel_dev_tool/session_host.dart';
import 'package:flutter_bazel_dev_tool/toolchain_info.dart';
import 'package:flutter_bazel_dev_tool/vm_service_client.dart';
import 'package:test/test.dart';
import 'package:vm_service/vm_service.dart';

import 'fakes.dart';

/// A directory no bazel invocation can run in: `Process.start` refuses a
/// working directory that does not exist, so anything reaching bazel fails
/// immediately and says so in the reason the gate carries.
const _noWorkspace = '/nonexistent/rules_flutter/assembler_test_workspace';

final _toolchain = ToolchainPaths(
  dart: '/nonexistent/dart',
  dartaotruntime: '/nonexistent/dartaotruntime',
  frontendServer: '/nonexistent/frontend_server.dart.snapshot',
  platformDill: '/nonexistent/platform_strong.dill',
  patchedSdkRoot: '/nonexistent/flutter_patched_sdk',
);

Map<String, dynamic> buildInfoJson({String compilationMode = 'dbg'}) => {
  'label': '@@//:app_flutter',
  'compilationMode': compilationMode,
  'platformBuildArgs': <String>[],
  'dartDefines': <String>['E2E_MESSAGE=from,the,app'],
  'assetsDir': 'bazel-out/darwin_arm64-dbg/bin/app_flutter_flutter_assets',
  'targetPlatform': 'macos',
};

/// A started [NativePipelineAssembler.assemble]: the session it runs against,
/// the pipeline it settles, and the assembly itself.
typedef StartedAssembly = ({
  /// The session the assembly runs against, with the reload commands wired.
  SessionHost host,

  /// The pipeline the assembly settles.
  ReloadPipeline pipeline,

  /// Completes when the assembly has settled the pipeline.
  Future<void> assembly,
});

/// What a test swaps in for the defaults of [main]'s `startAssembly`: the
/// workspace and toolchain the assembler runs against, the device whose build
/// args apply, the user's `--build-arg`s, and the process each bazel spawn
/// starts.
class AssemblySetup {
  const new({
    required this.workspace,
    required this.toolchain,
    required this.configDevice,
    required this.userBuildArgs,
    required this.spawn,
  });

  final String workspace;
  final ToolchainPaths toolchain;
  final Device configDevice;
  final List<String> userBuildArgs;
  final Future<Process> Function(List<String> args) spawn;
}

void main() {
  /// Start assembling against one session, and return with the assembly
  /// running: its `assembly` field settles when it is done.
  ///
  /// [spawnDelay] holds every bazel spawn back by that long, which is what
  /// makes an assembly slower than [readyTimeout] — the case a reload that
  /// arrives mid-assembly has to be held through.
  Future<StartedAssembly> startAssembly({
    Map<String, dynamic>? buildInfo,
    bool withVmService = true,
    bool shuttingDown = false,
    bool extensionRegistered = true,
    Duration readyTimeout = const Duration(seconds: 90),
    Duration spawnDelay = Duration.zero,
    AssemblySetup? setup,
  }) async {
    final logger = Logger('test.native_pipeline_assembler');
    final host = SessionHost(
      isMachine: false,
      logger: logger,
      // `bazel` started straight from `PATH`, without the process-group helper
      // a test has no runfiles to find: what [_noWorkspace] relies on is the
      // spawn itself refusing the directory.
      bazel: Bazel.uninterruptible(
        spawn: (args, {required workingDirectory}) =>
            Future<void>.delayed(
              spawnDelay,
            ).then(
              (_) => setup != null
                  ? setup.spawn(args)
                  : Process.start(
                      'bazel',
                      args,
                      workingDirectory: workingDirectory,
                    ),
            ),
        because: 'this test starts it straight from PATH',
      ),
    );

    VmServiceClient? client;
    if (withVmService) {
      client = VmServiceClient(
        connector: (_) async => _BuildInfoVmService(
          isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
          buildInfo: buildInfo,
          registered: extensionRegistered,
        ),
      );
      // The production default is 30s — long enough to cover a cold browser
      // start, and exactly this test file's own limit. A case that waits the
      // whole window out only needs to prove it waits at all.
      if (!extensionRegistered) {
        client.serviceExtensionTimeout = const Duration(milliseconds: 200);
      }
      await client.connect(Uri.parse('http://127.0.0.1:8181/'));
    }
    host.sessions.add(
      DeviceSession(
        device: _StubDevice(),
        appInstance: AppInstance(process: FakeProcess()),
        vmClient: client,
        appId: 'app_0',
      ),
    );

    // What `performCleanup` does first, and the reason the assembly it
    // interrupts fails: the disposers take the VM service away. It signals
    // `shutdownRequested` only afterwards, which is why that is not the flag
    // the assembler reads.
    if (shuttingDown) await host.teardown.run();

    final pipeline = ReloadPipeline(host: host, readyTimeout: readyTimeout);
    host.registerReloadCommands(pipeline);
    final Future<void> assembly = NativePipelineAssembler(
      workspace: setup?.workspace ?? _noWorkspace,
      toolchain: setup?.toolchain ?? _toolchain,
      target: '//:app',
      configDevice: setup?.configDevice ?? _StubDevice(),
      userBuildArgs: setup?.userBuildArgs ?? const [],
      host: host,
      pipeline: pipeline,
      logger: logger,
      builtBefore: DateTime.now(),
    ).assemble();
    return (host: host, pipeline: pipeline, assembly: assembly);
  }

  /// Assemble against one session whose app answers [buildInfo] — or, when
  /// [withVmService] is false, against a session with no VM service at all —
  /// and wait for the assembly to finish.
  Future<ReloadPipeline> assembleAgainst({
    Map<String, dynamic>? buildInfo,
    bool withVmService = true,
    bool shuttingDown = false,
    bool extensionRegistered = true,
  }) async {
    final StartedAssembly started = await startAssembly(
      buildInfo: buildInfo,
      withVmService: withVmService,
      shuttingDown: shuttingDown,
      extensionRegistered: extensionRegistered,
    );
    await started.assembly;
    return started.pipeline;
  }

  group('NativePipelineAssembler', () {
    // The reload the user sent while the dev build was still running. The
    // assembly is slower than the gate's clock, so the clock alone would answer
    // "still starting up" while the build that settles the gate is in progress.
    test(
      'an assembly slower than readyTimeout holds an in-flight app.hotReload '
      'until it settles the gate',
      () async {
        final StartedAssembly started = await startAssembly(
          buildInfo: buildInfoJson(),
          readyTimeout: const Duration(milliseconds: 20),
          spawnDelay: const Duration(milliseconds: 150),
        );

        final Map<String, dynamic> reply = await started.host.commandRunner.run(
          'app.hotReload',
          {},
        );

        expect(
          started.pipeline.ready.isSettled,
          isTrue,
          reason: 'the reply came before the assembly settled the gate',
        );
        expect(
          reply,
          containsPair('error', started.pipeline.ready.unavailableReason),
          reason:
              "the reply must be the assembly's own verdict, not the clock's",
        );
        await started.assembly;
      },
    );

    test('reads the app’s build record before it builds anything', () async {
      // A release app cannot be reloaded, and the app is the only thing that
      // knows it is one. Reported here means reported before the dev build —
      // the build whose flags this record supplies.
      final ReloadPipeline pipeline = await assembleAgainst(
        buildInfo: buildInfoJson(compilationMode: 'opt'),
      );

      expect(
        pipeline.ready.unavailableReason,
        contains('compilationMode "opt"'),
        reason:
            'a reason naming a missing directory instead means the dev '
            'build ran first, on flags taken from somewhere other than the '
            'running app',
      );
      expect(pipeline.frontendServer, isNull);
    });

    // The assembler runs the moment the VM service answers, which on an iOS
    // simulator is before the app's `main()` has registered the agent
    // extensions. Calling straight through takes `-32601 Unknown method` as
    // "this app has no record" and marks the gate permanently unavailable — so
    // every reload for the rest of the run reports a frontend server that could
    // not start, beside an app that is running fine. Waiting is what makes the
    // read a question about the app rather than about who got there first.
    //
    // Only the shipped AOT binary loses that race; `dart run` spends long
    // enough compiling the tool that the app always wins.
    test(
      'waits for the record’s extension instead of racing the app',
      () async {
        final ReloadPipeline pipeline = await assembleAgainst(
          buildInfo: buildInfoJson(),
          extensionRegistered: false,
        );

        // Never registered at all, within the wait: that is a different report
        // from an app that answered and carried no record.
        expect(pipeline.ready.unavailableReason, contains('never registered'));
        expect(pipeline.frontendServer, isNull);
      },
    );

    test('names the missing record when the app carries none', () async {
      final ReloadPipeline pipeline = await assembleAgainst(buildInfo: null);

      // The app's own words, not the transport's. The refusal arrives as a
      // JSON-RPC error whose `message` is "Invalid params" for every failure
      // the agent reports; a run told that learns nothing, and an escaping
      // `RPCError` leaves the run blaming a broken frontend server instead.
      expect(pipeline.ready.unavailableReason, contains(_noRecordText));
      expect(
        pipeline.ready.unavailableReason,
        isNot(contains('Invalid params')),
      );
      expect(pipeline.frontendServer, isNull);
    });

    test(
      'blames the shutdown, not the pipeline, when one interrupted it',
      () async {
        // `daemon.shutdown` is answered the moment it lands, and its teardown
        // disconnects the VM service the assembler reads from — so whatever the
        // assembly was doing fails. Calling that a broken frontend server names
        // the wrong cause.
        final ReloadPipeline pipeline = await assembleAgainst(
          buildInfo: buildInfoJson(compilationMode: 'opt'),
          shuttingDown: true,
        );

        expect(pipeline.ready.unavailableReason, contains('shut down'));
        expect(pipeline.ready.unavailableReason, isNot(contains('frontend')));
      },
    );

    test('blames the app going away, not the pipeline, when it died first', () async {
      // The other way the VM service the assembler reads from disappears, and
      // the one no `daemon.shutdown` explains: the app itself died. `attach` is
      // where this lands — it did not launch the app, so nothing else can tell
      // it the process ended — and the window is real, between `app.started`
      // and the gate opening.
      //
      // Calling that a broken frontend server names the wrong cause twice over.
      // It reports a failure the user cannot act on, and the specific message it
      // reaches for — `never registered ext.rules_flutter.buildInfo`, whose own
      // words say "not a build this pipeline can be assembled for" — tells the
      // user their app is the wrong kind of build when it is simply gone.
      final logger = Logger('test.native_pipeline_assembler');
      final host = SessionHost(isMachine: false, logger: logger);

      final fake = _BuildInfoVmService(
        isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
        buildInfo: buildInfoJson(),
      );
      var dials = 0;
      final client = VmServiceClient(
        connector: (_) async {
          if (dials++ > 0) throw const SocketException('Connection refused');
          return fake;
        },
      );
      await client.connect(Uri.parse('http://127.0.0.1:8181/'));

      // A dead app from this side: the socket's input stream ends and nothing
      // answers the port any more.
      fake.simulateDisposed();
      // Awaited, so this test asserts the assembler's answer rather than
      // racing the very verdict it is about.
      await client.gone;

      host.sessions.add(
        DeviceSession(
          device: _StubDevice(),
          appInstance: AppInstance(process: FakeProcess()),
          vmClient: client,
          appId: 'app_0',
        ),
      );

      final pipeline = ReloadPipeline(host: host);
      await NativePipelineAssembler(
        workspace: _noWorkspace,
        toolchain: _toolchain,
        target: '//:app',
        configDevice: _StubDevice(),
        host: host,
        pipeline: pipeline,
        logger: logger,
        builtBefore: DateTime.now(),
      ).assemble();

      expect(
        pipeline.ready.unavailableReason,
        contains('went away'),
        reason: 'the gate has to carry what actually happened',
      );
      // The client's own verdict travels with it: whoever reads this should not
      // have to go hunting for a cause that was already established.
      expect(
        pipeline.ready.unavailableReason,
        contains('Connection refused'),
        reason: 'the reason the client recorded is the specific one',
      );
      expect(
        pipeline.ready.unavailableReason,
        isNot(contains('frontend')),
        reason:
            'the frontend server never failed — there was no app left '
            'to assemble one for',
      );
      expect(
        pipeline.ready.unavailableReason,
        isNot(contains('never registered')),
        reason:
            'an app that died is not an app built the wrong way, and '
            'that message tells the user to go fix their build',
      );
      expect(pipeline.frontendServer, isNull);
    });

    test(
      'a split Android run keeps the dev build on its default outputs and '
      'the launch queries on the split output groups',
      () async {
        final Directory tmp = Directory.systemTemp.createTempSync('split_dev_');
        addTearDown(() => tmp.deleteSync(recursive: true));
        final calls = <List<String>>[];
        final AssemblySetup setup = _splitSetup(tmp, calls);

        final StartedAssembly started = await startAssembly(
          buildInfo: {
            ...buildInfoJson(),
            'assetsDir': 'bazel-out/k8-dbg/bin/app_flutter_flutter_assets',
            'targetPlatform': 'android',
          },
          setup: setup,
        );
        await started.assembly;

        final String? reason = started.pipeline.ready.unavailableReason;
        expect(
          reason,
          isNull,
          reason: 'the dev config must be found and the pipeline assembled',
        );
        // The first call is the dev build's own label query; the later ones the
        // dev build and its output cquery name the application, while the launch
        // queries name the platform target they go through.
        final List<List<String>> dev = [
          calls.first,
          for (final List<String> c in calls.skip(1))
            if (c.any((String a) => a.contains('app_flutter'))) c,
        ];
        final List<List<String>> launch = [
          for (final List<String> c in calls.skip(1))
            if (c.any((String a) => a.contains('deps(//:app)'))) c,
        ];
        expect(dev, isNotEmpty);
        expect(launch, isNotEmpty);
        for (final c in dev) {
          expect(c, isNot(contains(splitOutputGroupsFlag)), reason: '$c');
          expect(c, contains('--user-arg'), reason: '$c');
          expect(c, contains('--output_groups=other'), reason: '$c');
        }
        // The platform flag, the define and the user's flags keep their order.
        expect(
          dev.first.indexOf(
            '--platforms=@rules_flutter//flutter/platforms:android_arm64',
          ),
          lessThan(dev.first.indexOf('--user-arg')),
        );
        for (final c in launch) {
          expect(c, contains(splitOutputGroupsFlag), reason: '$c');
        }
      },
    );

    test(
      'leaves the gate to the caller when no session has a VM service',
      () async {
        // No VM service is no app to apply a reload to, so there is nothing here
        // to assemble — and nothing to build, which is why this returns rather
        // than spending a bazel invocation on it. Both callers settle the gate.
        final ReloadPipeline pipeline = await assembleAgainst(
          withVmService: false,
        );

        expect(pipeline.ready.isSettled, isFalse);
        expect(pipeline.frontendServer, isNull);
      },
    );

    test(
      'does not blame the frontend server for a failure that is not its',
      () async {
        // The catch-all's job is the failures nothing else claimed, and naming
        // the frontend server in all of them names a component that in most of
        // them was never started at all. Here bazel cannot even be spawned (the
        // workspace does not exist), which is the shape of everything that
        // reaches this arm: something below the compiler broke before there was
        // a compiler.
        final ReloadPipeline pipeline = await assembleAgainst(
          buildInfo: buildInfoJson(),
        );

        expect(
          pipeline.ready.unavailableReason,
          contains('could not be assembled'),
        );
        expect(
          pipeline.ready.unavailableReason,
          isNot(contains('frontend server')),
          reason:
              'naming a working component sends the reader to the wrong '
              'place: ${pipeline.ready.unavailableReason}',
        );
        // The cause still travels — the arm is generic, the report is not.
        expect(pipeline.ready.unavailableReason, contains('bazel cquery'));
      },
    );
  });
}

/// A frontend_server that answers every `compile` with an empty success, run
/// by the Dart executable running this test.
const _fakeFrontendServer = '''
import 'dart:convert';
import 'dart:io';

void main() {
  stdin.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
    if (line.startsWith('compile ')) {
      stdout.writeln('result boundary_0');
      stdout.writeln('boundary_0 /tmp/app.dill 0');
    } else if (line == 'quit') {
      exit(0);
    }
  });
}
''';

/// The setup for a split Android run over a scripted bazel.
///
/// The bazel it spawns answers like the real one: a `cquery --output=files`
/// of the `flutter_application` lists only its default outputs, and lists
/// nothing when the split output groups were asked for, because the
/// application has neither group. Every spawn is recorded in [calls].
AssemblySetup _splitSetup(Directory tmp, List<List<String>> calls) {
  final String ws = tmp.path;
  const binDir = 'bazel-out/k8-dbg/bin';
  Directory('$ws/$binDir').createSync(recursive: true);
  File('$ws/$binDir/app.dev_package_config.json').writeAsStringSync(
    '{"configVersion":2,"packages":[]}',
  );
  File('$ws/$binDir/app_flutter_dev_config.json').writeAsStringSync(
    jsonEncode({
      'engineRevision': 'e',
      'flutterVersion': 'v',
      'dartSdkRoot': '/nonexistent/sdk',
      'dartaotruntime': Platform.resolvedExecutable,
      'frontendServer': '$ws/frontend_server.dart',
      'patchedSdkRoot': '/nonexistent/flutter_patched_sdk',
      'appEntrypoint': '$ws/main.dart',
      'devPackageConfig': '$binDir/app.dev_package_config.json',
      'dartPluginRegistrants': {'android': ''},
    }),
  );
  File('$ws/frontend_server.dart').writeAsStringSync(_fakeFrontendServer);
  File('$ws/main.dart').writeAsStringSync('void main() {}\n');

  Future<Process> spawn(List<String> args) async {
    calls.add(args);
    final process = FakeProcess();
    final bool split = args.contains(splitOutputGroupsFlag);
    final String out = switch (args) {
      _ when args.contains('--output=label') => '//:app_flutter (abc)',
      _
          when args.contains('--output=files') &&
              args.any((a) => a.startsWith('kind(')) =>
        '$binDir/app_flutter_flutter_assets',
      _ when args.contains('--output=files') =>
        split
            ? '$binDir/app_base.apk\n$binDir/app_payload.apk'
            : '$binDir/app_flutter_dev_config.json',
      _ => '',
    };
    unawaited(
      process.outputAttached.then((_) {
        if (out.isNotEmpty) process.emitStdout(out);
        process.complete(0);
      }),
    );
    return process;
  }

  return AssemblySetup(
    workspace: ws,
    toolchain: ToolchainPaths(
      dart: Platform.resolvedExecutable,
      dartaotruntime: Platform.resolvedExecutable,
      frontendServer: '$ws/frontend_server.dart',
      platformDill: '/nonexistent/platform_strong.dill',
      patchedSdkRoot: '/nonexistent/flutter_patched_sdk',
    ),
    configDevice: AndroidDevice()..splitInstall = true,
    userBuildArgs: const [
      splitOutputGroupsFlag,
      '--output_groups=other',
      '--user-arg',
    ],
    spawn: spawn,
  );
}

/// The text `_handleBuildInfo` refuses with, abbreviated.
///
/// The words are the app's, and they say more than this side could: an empty
/// define means the build was not `-c dbg`, or was made by a rule that bundles
/// no assets, or had its kernel recompiled without the define.
const _noRecordText =
    'this app carries no rules_flutter.build_info: it was not built in -c dbg '
    'by a rule that bundles assets';

/// A [FakeVmService] that answers `ext.rules_flutter.buildInfo`.
///
/// A null [buildInfo] is an app with no record at all — and the agent reports
/// that with `ServiceExtensionResponse.error`, which crosses the VM service as
/// a JSON-RPC error and reaches the client as a **throw**, never as a response
/// carrying an `error` key. A fake that answered with the key would be a shape
/// the wire cannot produce.
///
/// Distinct from an app that never registered the extension, which the
/// `registered` flag covers — by default this one reports it registered, as a
/// real `-c dbg` app does.
class _BuildInfoVmService extends FakeVmService {
  final Map<String, dynamic>? buildInfo;

  new({
    required super.isolates,
    this.buildInfo,
    bool registered = true,
  }) {
    if (registered) extensionRPCs = const [buildInfoExtension];
  }

  @override
  Future<Response> callServiceExtension(
    String method, {
    String? isolateId,
    Map<String, dynamic>? args,
  }) async {
    if (method == buildInfoExtension) {
      final Map<String, dynamic>? record = buildInfo;
      if (record == null) {
        // `_err`'s exact shape: the generic code and message, the handler's
        // own words in `details`.
        throw RPCError(buildInfoExtension, -32602, 'Invalid params', {
          'details': _noRecordText,
        });
      }
      return Response()..json = record;
    }
    return super.callServiceExtension(method, isolateId: isolateId, args: args);
  }
}

/// A device that launches nothing: the assembler only reads its build args and
/// compiler config, and these tests never get that far.
class _StubDevice extends Device {
  @override
  String get name => 'stub';

  @override
  Future<AppInstance> launch(String appPath, {AppLogListener? onLog}) =>
      throw UnsupportedError('stub device does not launch');

  @override
  Future<void> stop(AppInstance instance) async {}
}
