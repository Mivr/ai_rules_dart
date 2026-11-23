@Tags(['e2e'])
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'dev_tool_e2e_harness.dart';
import 'editable_workspace.dart';

/// Start `:app` from a copy of `ios_example` on the simulator and wait until
/// it is running and its HTTP control channel answers.
///
/// The build and the launch wait separately. The dev tool builds the workspace
/// copy before launching, and on a cold CI runner that build takes many
/// minutes; `app.start` fires once the build is done and the launch begins,
/// `app.started` once the app answers. One bound covering both would time out
/// a healthy cold run.
Future<DevToolProcess> _runOnSimulator() async {
  final EditableWorkspace ws = await editableWorkspace('ios_example');
  final DevToolProcess dt = await startDevTool(
    workspace: ws.root,
    target: ':app',
    device: 'ios-simulator',
  );
  await dt.waitForEvent('app.start', timeout: e2eColdBuildTimeout);
  await dt.waitForEvent('app.started', timeout: const Duration(minutes: 10));
  expect(await dt.waitForHttpControl(), isNotNull);
  return dt;
}

/// Send one JSON-RPC [method] to the VM service at [wsUri] and return the
/// decoded reply, without a VM-service client library between the test and
/// the wire.
Future<Map<String, dynamic>> _vmServiceCall(String wsUri, String method) async {
  final WebSocket socket = await WebSocket.connect(
    wsUri,
  ).timeout(const Duration(seconds: 30));
  try {
    socket.add(jsonEncode({'jsonrpc': '2.0', 'id': 1, 'method': method}));
    final Map<String, dynamic> reply = await socket
        .map((frame) => jsonDecode(frame as String))
        .cast<Map<String, dynamic>>()
        .firstWhere((message) => message['id'] == 1)
        .timeout(const Duration(seconds: 30));
    return reply;
  } finally {
    await socket.close();
  }
}

void main() {
  group(
    'iOS Simulator e2e',
    () {
      test(
        'HTTP control channel screenshot captures Flutter UI',
        () async {
          final DevToolProcess dt = await _runOnSimulator();
          await Future<void>.delayed(const Duration(seconds: 3));

          final outputPath =
              '${Directory.systemTemp.path}/ios_sim_http_e2e.png';
          await dt.httpScreenshotToFile(dt.appId!, outputPath);

          final file = File(outputPath);
          expect(file.existsSync(), isTrue);
          file.deleteSync();

          await dt.sendCommand(1, 'daemon.shutdown');
        },
        // Above the waits' sum (20 + 10 + 2 for the control channel).
        timeout: const Timeout(Duration(minutes: 35)),
      );

      // The endpoint `app.debugPort` publishes is what DevTools and every
      // debugger connect to. It has to answer the VM service protocol, and
      // answering is not enough: a blank bundle serves the socket too, so the
      // app's own keyed label is read as well.
      test(
        'app.debugPort endpoint answers getVersion for a rendered app',
        () async {
          final DevToolProcess dt = await _runOnSimulator();
          final Map<String, dynamic> debugPort = await dt.waitForEvent(
            'app.debugPort',
            timeout: const Duration(seconds: 60),
          );
          final wsUri =
              (debugPort['params'] as Map<String, dynamic>?)?['wsUri']
                  as String?;
          expect(wsUri, isNotNull, reason: 'app.debugPort carries a wsUri');

          final Map<String, dynamic> reply = await _vmServiceCall(
            wsUri!,
            'getVersion',
          );
          expect(
            reply['error'],
            isNull,
            reason: 'getVersion answered an error: ${reply['error']}',
          );
          final version = reply['result'] as Map<String, dynamic>?;
          expect(version?['type'], 'Version');
          expect(version?['major'], isA<int>());
          expect(version?['minor'], isA<int>());

          final String appId = dt.appId!;
          final Map<String, dynamic> label = await dt.httpCommand(
            'app.waitFor',
            {
              'appId': appId,
              'key': 'e2e_asset_label',
              'timeoutMs': '30000',
            },
          );
          expect(
            label['error'],
            isNull,
            reason: 'the app must have drawn, not just opened the socket',
          );
          final Map<String, dynamic> text = await dt.httpCommand(
            'app.getText',
            {
              'appId': appId,
              'key': 'e2e_asset_label',
            },
          );
          expect(
            (text['result'] as Map<String, dynamic>?)?['text'],
            'asset v1',
          );

          await dt.sendCommand(1, 'daemon.shutdown');
        },
        timeout: const Timeout(Duration(minutes: 35)),
      );
    },
    skip: !Platform.isMacOS ? 'macOS only (needs Xcode Simulator)' : null,
  );
}
