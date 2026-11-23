@Tags(['e2e'])
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

import 'dev_tool_e2e_harness.dart';
import 'editable_workspace.dart';

/// What a paused-start check runs: the `workspace` to launch `:app` from on
/// `device`, the keyed `labelKey` the app draws once it runs, and how long the
/// build and then the install and launch may take (`buildTimeout`, before
/// `app.start`; `launchTimeout`, before `app.debugPort`).
typedef _PausedApp = ({
  String workspace,
  String device,
  String labelKey,
  Duration buildTimeout,
  Duration launchTimeout,
});

/// Start [app] with `--start-paused` and prove the engine holds the main
/// isolate, the control channel still answers, and a resume lets it draw.
Future<void> _holdsUntilResumed(_PausedApp app) async {
  final DevToolProcess dt = await startDevTool(
    workspace: app.workspace,
    target: ':app',
    device: app.device,
    extraArgs: ['--start-paused'],
  );

  final Map<String, dynamic> start = await dt.waitForEvent(
    'app.start',
    timeout: app.buildTimeout,
  );
  final String appId = start['params']?['appId'] as String? ?? dt.appId!;
  final Map<String, dynamic> debugPort = await dt.waitForEvent(
    'app.debugPort',
    timeout: app.launchTimeout,
  );
  final wsUri = debugPort['params']?['wsUri'] as String;

  // The tool says it observed the pause rather than assuming the switch
  // took — this is that observation, made independently.
  await dt.waitForStderr(
    'start_paused',
    timeout: const Duration(seconds: 60),
  );

  final VmService service = await vmServiceConnectUri(wsUri);
  addTearDown(service.dispose);
  final VM vm = await service.getVM();
  final IsolateRef main = vm.isolates!.firstWhere((i) => i.name == 'main');
  final Isolate isolate = await service.getIsolate(main.id!);
  expect(
    isolate.pauseEvent?.kind,
    EventKind.kPauseStart,
    reason: 'the engine must be holding the root isolate before main()',
  );

  // Nothing that needs the framework can work yet — the binding has not
  // run, so the agent's extensions are not registered. It has to *answer*,
  // though: the extension runs on the isolate that is paused, so
  // dispatching it would block the control channel for the rest of the
  // run.
  await dt.waitForHttpControl(timeout: const Duration(seconds: 60));
  final Map<String, dynamic> tooEarly = await dt
      .httpCommand('app.getText', {
        'appId': appId,
        'key': app.labelKey,
      })
      .timeout(
        const Duration(seconds: 20),
        onTimeout: () => throw StateError(
          'app.getText never answered on a paused app — the control '
          'channel is wedged behind an isolate that cannot run',
        ),
      );
  expect(
    tooEarly['error'],
    contains('--start-paused'),
    reason:
        'a paused app has no widget tree to read, and the reason '
        'must name the pause rather than the widget',
  );

  // Resume, exactly as a debugger would, and the app comes up.
  await service.resume(main.id!);

  final Map<String, dynamic> ready = await dt.httpCommand('app.waitFor', {
    'appId': appId,
    'key': app.labelKey,
    'timeoutMs': '30000',
  });
  expect(
    ready['error'],
    isNull,
    reason:
        'resuming must let the app run to a rendered frame: '
        '${ready['error']}',
  );
}

/// End-to-end: `--start-paused` really holds the app at `main()`.
///
/// The switch travels a different way on every platform — an environment
/// variable on desktop, an intent extra on Android, trailing argv on iOS — so
/// unit tests can only prove the argument was formed. Whether the engine acted
/// on it is a question about a running app, and the answer is the main
/// isolate's own `pauseEvent`.
///
/// The second half matters as much as the first: an app that pauses and can
/// never be resumed is a hang, not a debugging aid.
void main() {
  group('start-paused e2e', () {
    test(
      'holds main() until a debugger resumes it',
      () => _holdsUntilResumed((
        workspace: e2eWorkspace('macos_example'),
        device: 'macos',
        labelKey: 'e2e_define_label',
        buildTimeout: const Duration(seconds: 240),
        launchTimeout: const Duration(seconds: 120),
      )),
      timeout: const Timeout(Duration(minutes: 5)),
      skip: !Platform.isMacOS ? 'macOS only' : null,
    );

    // The switch reaches an iOS app as trailing argv after the bundle id, a
    // path neither desktop nor Android shares. The build and launch of a cold
    // simulator run are bounded apart from the pause checks, as in the other
    // simulator cases.
    test(
      'iOS simulator: holds main() until a debugger resumes it',
      () async {
        await _holdsUntilResumed(
          (
            workspace: (await editableWorkspace('ios_example')).root,
            device: 'ios-simulator',
            labelKey: 'e2e_asset_label',
            buildTimeout: e2eColdBuildTimeout,
            launchTimeout: const Duration(minutes: 10),
          ),
        );
      },
      skip: !Platform.isMacOS ? 'macOS only (needs Xcode Simulator)' : null,
      timeout: const Timeout(Duration(minutes: 35)),
    );

    test(
      'holds the browser app until a debugger resumes it',
      () async {
        // There is no engine switch to pass a browser. DWDS is what gates
        // `main()`, so pausing means withholding the run request — a different
        // mechanism reaching the same observable.
        final DevToolProcess dt = await startDevTool(
          workspace: e2eWorkspace('web_example'),
          target: ':app_wasm',
          device: 'chrome',
          extraArgs: ['--start-paused'],
        );

        await dt.waitForEvent(
          'app.start',
          timeout: const Duration(seconds: 240),
        );
        final Map<String, dynamic> debugPort = await dt.waitForEvent(
          'app.debugPort',
          timeout: const Duration(seconds: 180),
        );
        await dt.waitForStderr(
          'start_paused',
          timeout: const Duration(seconds: 60),
        );

        final VmService service = await vmServiceConnectUri(
          debugPort['params']!['wsUri'] as String,
        );
        addTearDown(service.dispose);
        final VM vm = await service.getVM();
        final IsolateRef isolate = vm.isolates!.first;

        // The widget inspector answers only once the framework is up, which
        // only happens once `main()` has run — a check that goes through the
        // tool's own control channel rather than guessing at what DWDS reports.
        Future<bool> frameworkIsUp() async {
          final Map<String, dynamic> tree = await dt.httpCommand(
            'app.dumpWidgetTree',
            {
              'appId': dt.appId!,
            },
          );
          return tree['error'] == null;
        }

        await dt.waitForHttpControl(timeout: const Duration(seconds: 60));
        expect(
          await frameworkIsUp(),
          isFalse,
          reason: 'main() must not have run before a debugger resumed it',
        );

        // DWDS runs `main()` when a client resumes an app that has not started,
        // so this is exactly what pressing resume in a debugger does.
        await service.resume(isolate.id!);

        final DateTime deadline = DateTime.now().add(
          const Duration(seconds: 90),
        );
        while (!await frameworkIsUp()) {
          expect(
            DateTime.now().isBefore(deadline),
            isTrue,
            reason: 'resuming must release main(); the app never started',
          );
          await Future<void>.delayed(const Duration(milliseconds: 500));
        }
      },
      timeout: const Timeout(Duration(minutes: 6)),
    );
  });
}
