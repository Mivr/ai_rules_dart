@Tags(['e2e'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'dev_tool_e2e_harness.dart';
import 'editable_workspace.dart';
import '../zip_fixture.dart';

typedef _AttachedApp = ({Process process, String vmServiceUri});

/// `flutter_bazel attach` against an app this test launches itself.
///
/// The app has to be started outside the dev tool — attaching to a process it
/// spawned would prove nothing about the path a user takes, which is "my app is
/// already running, connect to it".
void main() {
  group('Attach e2e', () {
    /// Build, unpack and launch the macOS app, and return its VM service URI.
    ///
    /// [buildArgs] go to bazel only — attach is never told about them, which is
    /// the point of passing any: whatever they bake into the app has to reach
    /// the reload pipeline through the app's own report.
    ///
    /// Registers its own teardown, so a failure anywhere below still leaves no
    /// app and no unpacked bundle behind.
    Future<({Process process, String vmServiceUri})> launchAppDirectly(
      EditableWorkspace ws, {
      List<String> buildArgs = const [],
    }) async {
      final ProcessResult build = await Process.run('bazel', [
        'build',
        ':app',
        '-c',
        'dbg',
        ...buildArgs,
      ], workingDirectory: ws.root);
      expect(build.exitCode, 0, reason: 'bazel build failed: ${build.stderr}');

      final Directory tmpDir = await Directory.systemTemp.createTemp(
        'attach_e2e_',
      );
      addTearDown(() async {
        if (tmpDir.existsSync()) await tmpDir.delete(recursive: true);
      });
      await extractZip(
        zipPath: '${ws.root}/bazel-bin/app.zip',
        destDir: tmpDir,
      );
      final Iterable<FileSystemEntity> apps = tmpDir.listSync().where(
        (e) => e.path.endsWith('.app'),
      );
      expect(apps, isNotEmpty, reason: 'No .app found in app.zip');

      final String appPath = apps.first.path;
      final String bundleName = appPath.split('/').last.replaceAll('.app', '');
      // Bound rather than followed by an `addTearDown`: the bazel build above
      // takes minutes, and a timeout during it leaves this frame running with
      // the test's teardowns already done — the app would launch onto the
      // screen with nothing left to close it.
      final Process process = await spawnBoundToTest(
        spawn: () => Process.start(
          '$appPath/Contents/MacOS/$bundleName',
          [],
          environment: {'FLUTTER_VM_SERVICE_PORT': '0'},
        ),
        dispose: (app) async {
          app.kill();
          await app.exitCode;
        },
      );

      final uriPattern = RegExp(
        r'(?:Observatory|Dart VM service) (?:listening|is listening) on (http\S+)',
      );
      final announced = Completer<String>();
      process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            final RegExpMatch? match = uriPattern.firstMatch(line);
            if (match != null && !announced.isCompleted) {
              announced.complete(match.group(1)!);
            }
          });

      return (
        process: process,
        vmServiceUri: await announced.future.timeout(
          const Duration(seconds: 60),
        ),
      );
    }

    test(
      'attaches to a running app and reports its VM service',
      () async {
        final EditableWorkspace ws = await editableWorkspace('macos_example');
        final _AttachedApp app = await launchAppDirectly(ws);

        final DevToolProcess dt = await attachDevTool(
          workspace: ws.root,
          target: ':app',
          debugUrl: app.vmServiceUri,
        );

        // `app.debugPort` is the event that can only be emitted after
        // `vmClient.connect` returned, so it — not a log line — is the proof.
        final Map<String, dynamic> debugPort = await dt.waitForEvent(
          'app.debugPort',
          timeout: const Duration(minutes: 4),
        );
        expect(debugPort['params']?['baseUri'], app.vmServiceUri);
        await dt.waitForEvent('app.started');
      },
      timeout: const Timeout(Duration(minutes: 6)),
    );

    // Attach's reload path: the frontend server needs an initial `compile` or
    // the first `recompile` asks for a delta from nothing; the session loop
    // needs a `SourceUriResolver` or every watched path maps to no package URI
    // and the watcher drops it; and `app.hotReload`/`app.restart` have to be
    // registered or a machine client gets `Unknown command` for the one thing
    // attach exists to do after connecting.
    //
    // The app is built with a `--dart-define` that attach is never given. The
    // recompiled library has to still see it, which it can only do if the
    // pipeline built its dev config from what the app reports about itself —
    // a `--dart-define` flag on attach itself would make the user know the
    // run's defines and repeat them exactly. The define matches
    // `dart_defines_e2e_test`'s so both share one bazel configuration.
    test(
      'drives a hot reload that keeps the app’s own dart defines',
      () async {
        final EditableWorkspace ws = await editableWorkspace('macos_example');
        final File appMain = ws.file('lib/main.dart');
        final String appMainOrig = appMain.readAsStringSync();
        expect(
          appMainOrig,
          contains(" v1'"),
          reason: 'fixture marker present in macos_example main.dart',
        );

        final _AttachedApp app = await launchAppDirectly(
          ws,
          buildArgs: const [
            '--@rules_flutter//flutter:extra_dart_defines=E2E_MESSAGE=defines,live',
          ],
        );
        final DevToolProcess dt = await attachDevTool(
          workspace: ws.root,
          target: ':app',
          debugUrl: app.vmServiceUri,
        );
        final Map<String, dynamic> start = await dt.waitForEvent(
          'app.start',
          timeout: const Duration(minutes: 4),
        );
        final String appId = start['params']?['appId'] as String? ?? dt.appId!;
        await dt.waitForHttpControl(timeout: const Duration(seconds: 90));

        // The tool being up does not mean the attached app has drawn yet.
        final Map<String, dynamic> firstFrame = await dt.httpCommand(
          'app.waitFor',
          {
            'appId': appId,
            'text': 'defines,live v1',
            'timeoutMs': '30000',
          },
        );
        expect(
          firstFrame['error'],
          isNull,
          reason: 'the attached app must render its first frame: $firstFrame',
        );

        // Also the only place the agent surface is exercised over attach: an
        // attached app has to be readable at all.
        Map<String, dynamic> label = await dt.httpCommand('app.getText', {
          'appId': appId,
          'key': 'e2e_define_label',
        });
        expect(
          label['result']?['text'],
          'defines,live v1',
          reason:
              'app.getText must work on an attached app, and the app was '
              'built with the define: ${label['error']}',
        );

        appMain.writeAsStringSync(appMainOrig.replaceFirst(" v1'", " v2'"));
        final Map<String, dynamic> reload = await dt.sendCommand(
          1,
          'app.hotReload',
          params: {'appId': appId},
          timeout: e2eColdBuildTimeout,
        );
        expect(
          reload['error'],
          isNull,
          reason: 'app.hotReload: ${reload['error']}',
        );
        expect(
          reload['result']?['message'],
          contains('successful'),
          reason: 'reload reported: ${reload['result']}',
        );

        label = await dt.httpCommand('app.getText', {
          'appId': appId,
          'key': 'e2e_define_label',
        });
        expect(
          label['result']?['text'],
          'defines,live v2',
          reason:
              'the edit must be live in the attached app, and the '
              'recompile must carry the define attach was never told about',
        );
      },
      timeout: const Timeout(Duration(minutes: 25)),
    );

    // Restart is the half of the pipeline reload does not reach: it re-runs
    // `main()` in a fresh isolate via `runInView`, which needs the asset
    // directory the assembler wires up on attach. A build()-level edit would
    // pass here even if `main()` never re-ran, so the edit is deliberately
    // *inside* `main()`.
    test(
      'drives a hot restart that re-runs main()',
      () async {
        final EditableWorkspace ws = await editableWorkspace('macos_example');
        final File appMain = ws.file('lib/main.dart');
        final String appMainOrig = appMain.readAsStringSync();
        expect(
          appMainOrig,
          contains('add(3, 4)'),
          reason: 'fixture marker present in macos_example main.dart',
        );

        final _AttachedApp app = await launchAppDirectly(ws);
        final DevToolProcess dt = await attachDevTool(
          workspace: ws.root,
          target: ':app',
          debugUrl: app.vmServiceUri,
        );
        final Map<String, dynamic> start = await dt.waitForEvent(
          'app.start',
          timeout: const Duration(minutes: 4),
        );
        final String appId = start['params']?['appId'] as String? ?? dt.appId!;
        await dt.waitForHttpControl(timeout: const Duration(seconds: 90));

        final Map<String, dynamic> before = await dt.httpCommand(
          'app.waitFor',
          {
            'appId': appId,
            'text': '3 + 4 = 7',
          },
        );
        expect(
          before['error'],
          isNull,
          reason: 'the attached app renders its main()-computed sum: $before',
        );

        appMain.writeAsStringSync(
          appMainOrig.replaceFirst('add(3, 4)', 'add(30, 4)'),
        );
        final Map<String, dynamic> restart = await dt.sendCommand(
          1,
          'app.restart',
          params: {'appId': appId},
          timeout: e2eColdBuildTimeout,
        );
        expect(
          restart['error'],
          isNull,
          reason: 'app.restart: ${restart['error']}',
        );
        expect(
          restart['result']?['message'],
          contains('successful'),
          reason: 'restart reported: ${restart['result']}',
        );

        // Only a restart makes this appear: `result` is computed in `main()`, so
        // a hot reload would rebuild the same widget tree around the old 7. The
        // call also proves the agent surface came back with the fresh isolate —
        // the engine's pre-main registrant hook runs against the dill attach's
        // own frontend server produced.
        final Map<String, dynamic> after = await dt.httpCommand('app.waitFor', {
          'appId': appId,
          'text': '3 + 4 = 34',
        });
        expect(
          after['error'],
          isNull,
          reason:
              'a restart must re-run main(); a reload would still show 7. '
              'Got: $after',
        );
      },
      timeout: const Timeout(Duration(minutes: 25)),
    );

    // The other way an attach ends, and the one it does not control: the app
    // it was watching goes away. Attach did not launch it, so there is no
    // process exit to observe — the VM service closing and not coming back is
    // the whole of the evidence, and an attach that does not watch for it waits
    // forever with nothing left to talk to.
    //
    // Deliberately not driven from the keyboard: this run is in machine mode
    // with no terminal, which is exactly the case that could hang unnoticed.
    test(
      'exits when the app it attached to goes away',
      () async {
        final EditableWorkspace ws = await editableWorkspace('macos_example');
        final _AttachedApp app = await launchAppDirectly(ws);

        final DevToolProcess dt = await attachDevTool(
          workspace: ws.root,
          target: ':app',
          debugUrl: app.vmServiceUri,
        );

        await dt.waitForEvent(
          'app.started',
          timeout: const Duration(minutes: 4),
        );
        // The session loop has to be the thing waiting, which it only is once
        // the pipeline is assembled — `app.started` is emitted several seconds
        // before that. An app killed in the assembly window fails the assembly
        // instead, which is a different path with a different (loud) answer.
        await dt.waitForHttpControl(timeout: const Duration(seconds: 90));

        app.process.kill();
        await app.process.exitCode;

        final int code = await dt.exitCodeWithin(
          const Duration(seconds: 60),
          stillRunning:
              'the app attach was connected to exited, and attach did not. '
              'Nothing on the attach path observed the app going away, so the '
              'session waits forever',
        );
        expect(code, 0);
        // And it has to say why. A `run` that ends this way has the process exit
        // to explain itself; an attach that exits silently is indistinguishable
        // from the tool giving up on its own.
        expect(
          dt.stderrLines.join('\n'),
          contains('attached_app_gone'),
          reason: 'the run ended without saying the app was gone',
        );
      },
      timeout: const Timeout(Duration(minutes: 6)),
    );

    // The same death, in the window the test above deliberately waits past.
    //
    // `app.started` is emitted as soon as the VM service answers; the pipeline
    // is assembled for several seconds after that. An app killed in between
    // must not take a different path with a different answer: the assembly
    // failure that follows reports `frontend_server_failed` and sends the
    // reader off to fix a build that was never wrong, when the tool has already
    // logged `attached_app_gone`.
    //
    // Which side of the window a kill lands on is not something a user can see
    // or control, so it cannot be what decides the exit status.
    test(
      'exits the same way when the app goes away mid-assembly',
      () async {
        final EditableWorkspace ws = await editableWorkspace('macos_example');
        final _AttachedApp app = await launchAppDirectly(ws);

        final DevToolProcess dt = await attachDevTool(
          workspace: ws.root,
          target: ':app',
          debugUrl: app.vmServiceUri,
        );

        // Deliberately NOT `waitForHttpControl`: that is what the test above uses
        // to get *past* assembly, and this one is about being inside it.
        await dt.waitForEvent(
          'app.started',
          timeout: const Duration(minutes: 4),
        );
        app.process.kill();
        await app.process.exitCode;

        final int code = await dt.exitCodeWithin(
          const Duration(seconds: 120),
          stillRunning: 'the app died during assembly and attach did not exit',
        );
        expect(
          code,
          0,
          reason:
              'the app going away is the session ending, not this command '
              'failing — whichever side of assembly it lands on',
        );

        final String stderr = dt.stderrLines.join('\n');
        expect(
          stderr,
          contains('attached_app_gone'),
          reason: 'the run ended without saying the app was gone',
        );
        expect(
          stderr,
          isNot(contains('never registered')),
          reason:
              'an app that died is not an app built the wrong way, and '
              'that message tells the user to go fix their build',
        );
        expect(
          stderr,
          isNot(contains('Cannot start interactive session')),
          reason:
              'there was no session to refuse — the app it would have been '
              'for is gone',
        );
      },
      timeout: const Timeout(Duration(minutes: 6)),
    );

    // The `run` command has this assertion too, and it matters most on attach:
    // its pseudo-device has no process whose exit can end the session, so the
    // shutdown signal is the only thing that can.
    test(
      'daemon.shutdown ends the process, not just the session',
      () async {
        final EditableWorkspace ws = await editableWorkspace('macos_example');
        final _AttachedApp app = await launchAppDirectly(ws);

        final DevToolProcess dt = await attachDevTool(
          workspace: ws.root,
          target: ':app',
          debugUrl: app.vmServiceUri,
        );

        await dt.waitForEvent(
          'app.started',
          timeout: const Duration(minutes: 4),
        );
        final Map<String, dynamic> response = await dt.sendCommand(
          1,
          'daemon.shutdown',
        );
        expect(response['result']?['message'], 'shutdown');

        final int code = await dt.exitCodeWithin(
          const Duration(seconds: 30),
          stillRunning:
              'daemon.shutdown was answered but the attach process did not '
              'exit. Something the run owns is holding the VM open',
        );
        expect(code, 0);

        // The app it attached to is not the dev tool's to stop: attaching must
        // leave the process it found running.
        expect(
          await _isAlive(app.process),
          isTrue,
          reason: 'attach must not kill an app it did not launch',
        );
      },
      timeout: const Timeout(Duration(minutes: 6)),
    );

    // The whole attach path on the simulator: the app is installed and
    // launched with `xcrun simctl`, never by the dev tool, so everything the
    // tool knows about it comes from the VM service URI it is handed.
    test(
      'iOS simulator: attaches to an app launched outside the tool, then '
      'hot reloads an edit',
      () async {
        final EditableWorkspace ws = await editableWorkspace('ios_example');
        final File appMain = ws.file('lib/main.dart');
        final String original = appMain.readAsStringSync();
        expect(
          original,
          contains('attach marker v1'),
          reason: 'fixture marker present in ios_example main.dart',
        );

        final String vmServiceUri = await _launchSimulatorAppDirectly(ws);
        final DevToolProcess dt = await attachDevTool(
          workspace: ws.root,
          target: ':app',
          debugUrl: vmServiceUri,
        );

        final Map<String, dynamic> debugPort = await dt.waitForEvent(
          'app.debugPort',
          timeout: const Duration(minutes: 4),
        );
        expect(_params(debugPort)['baseUri'], vmServiceUri);
        final Map<String, dynamic> started = await dt.waitForEvent(
          'app.started',
          timeout: const Duration(minutes: 4),
        );
        final String appId = _params(started)['appId'] as String? ?? dt.appId!;
        await dt.waitForHttpControl(timeout: const Duration(seconds: 90));

        // `waitForHttpControl` says the tool is up, not that the attached app
        // has drawn its first frame, so wait for the label instead of reading
        // it once.
        final Map<String, dynamic> before = await dt.httpCommand(
          'app.waitFor',
          {
            'appId': appId,
            'text': 'iOS attach marker v1',
            'timeoutMs': '30000',
          },
        );
        expect(
          before['error'],
          isNull,
          reason: 'the attached app must render its first frame: $before',
        );

        appMain.writeAsStringSync(
          original.replaceFirst('attach marker v1', 'attach marker v2'),
        );
        final Map<String, dynamic> reload = await dt.sendCommand(
          1,
          'app.hotReload',
          params: {'appId': appId},
          timeout: e2eColdBuildTimeout,
        );
        expect(
          reload['error'],
          isNull,
          reason: 'app.hotReload: ${reload['error']}',
        );
        expect(
          _result(reload)['message'],
          contains('successful'),
          reason: 'reload reported: ${reload['result']}',
        );

        final Map<String, dynamic> after = await dt.httpCommand('app.waitFor', {
          'appId': appId,
          'text': 'iOS attach marker v2',
          'timeoutMs': '30000',
        });
        expect(
          after['error'],
          isNull,
          reason: 'the edit must be live in the attached app: $after',
        );

        await dt.sendCommand(2, 'daemon.shutdown');
      },
      timeout: const Timeout(Duration(minutes: 45)),
    );
  }, skip: !Platform.isMacOS ? 'macOS only' : null);
}

/// The bundle id of `ios_example`'s `:app`.
const _iosBundleId = 'com.rulesflutter.ios.example';

/// The `params` of an event, or an empty map.
Map<String, dynamic> _params(Map<String, dynamic> event) =>
    (event['params'] as Map<String, dynamic>?) ?? const {};

/// The `result` of a response, or an empty map.
Map<String, dynamic> _result(Map<String, dynamic> response) =>
    (response['result'] as Map<String, dynamic>?) ?? const {};

/// Kill [process] and wait for it to be gone.
Future<void> _killAndWait(Process process) async {
  process.kill();
  await process.exitCode;
}

/// Run [command] to completion in [workingDirectory], failing the test when it
/// exits non-zero or outlives [timeout]. Spawned bound to the test, so a
/// timeout leaves nothing running.
Future<String> _runChecked(
  List<String> command, {
  required Duration timeout,
  String? workingDirectory,
}) async {
  final Process process = await spawnBoundToTest(
    spawn: () => Process.start(
      command.first,
      command.sublist(1),
      workingDirectory: workingDirectory,
    ),
    dispose: _killAndWait,
  );
  final Future<String> stdout = process.stdout.transform(utf8.decoder).join();
  final Future<String> stderr = process.stderr.transform(utf8.decoder).join();
  final int code = await process.exitCode.timeout(
    timeout,
    onTimeout: () => throw StateError('`${command.join(' ')}` timed out'),
  );
  expect(code, 0, reason: '`${command.join(' ')}` failed: ${await stderr}');
  return await stdout;
}

/// Build the debug simulator `:app` of [ws], install it on the booted
/// simulator and launch it with `xcrun simctl`, outside the dev tool, and
/// return the app's Dart VM service URI.
///
/// The URI comes from the simulator's own log, which is where the engine
/// announces it. The log stream starts before the launch so the announcement
/// cannot be missed. The app is uninstalled when the test ends, and the log
/// stream is bound to the test like every other process it starts.
Future<String> _launchSimulatorAppDirectly(EditableWorkspace ws) async {
  await _runChecked(
    ['bazel', 'build', ':app', '-c', 'dbg', '--ios_multi_cpus=sim_arm64'],
    timeout: e2eColdBuildTimeout,
    workingDirectory: ws.root,
  );
  const short = Duration(minutes: 2);
  final String booted = await _runChecked([
    'xcrun',
    'simctl',
    'list',
    'devices',
    'booted',
    '-j',
  ], timeout: short);
  final String? udid = RegExp(
    r'"udid"\s*:\s*"([^"]+)"',
  ).firstMatch(booted)?.group(1);
  expect(udid, isNotNull, reason: 'no booted iOS simulator: $booted');
  final String simulator = udid!;

  final Directory tmpDir = await Directory.systemTemp.createTemp(
    'attach_ios_e2e_',
  );
  addTearDown(() async {
    if (tmpDir.existsSync()) await tmpDir.delete(recursive: true);
  });
  await extractZip(zipPath: '${ws.root}/bazel-bin/app.ipa', destDir: tmpDir);
  final Iterable<FileSystemEntity> apps = Directory(
    '${tmpDir.path}/Payload',
  ).listSync().where((e) => e.path.endsWith('.app'));
  expect(apps, isNotEmpty, reason: 'No .app found in app.ipa');

  // Registered before the install, so a failure part-way still removes it.
  addTearDown(() async {
    for (final verb in ['terminate', 'uninstall']) {
      await Process.run('xcrun', ['simctl', verb, simulator, _iosBundleId]);
    }
  });
  await _runChecked([
    'xcrun',
    'simctl',
    'install',
    simulator,
    apps.first.path,
  ], timeout: short);

  final Process log = await spawnBoundToTest(
    spawn: () => Process.start('xcrun', [
      'simctl',
      'spawn',
      simulator,
      'log',
      'stream',
      '--style',
      'compact',
      '--predicate',
      'eventMessage contains "Dart VM service"',
    ]),
    dispose: _killAndWait,
  );
  final announced = Completer<String>();
  log.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((
    line,
  ) {
    final RegExpMatch? match = RegExp(
      r'Dart VM service is listening on (http\S+)',
    ).firstMatch(line);
    if (match != null && !announced.isCompleted) {
      announced.complete(match.group(1)!);
    }
  });

  await _runChecked([
    'xcrun',
    'simctl',
    'launch',
    simulator,
    _iosBundleId,
  ], timeout: short);
  return await announced.future.timeout(const Duration(minutes: 3));
}

/// Whether [process] is still running, decided without waiting on it.
Future<bool> _isAlive(Process process) async {
  final int exited = await process.exitCode.timeout(
    const Duration(milliseconds: 200),
    onTimeout: () => -999,
  );
  return exited == -999;
}
