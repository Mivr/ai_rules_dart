import 'dart:io';

import 'package:perf/src/daemon.dart';
import 'package:test/test.dart';

/// A stand-in for `flutter run --machine`: announces the app, answers every
/// request with code 0 (1 for a restart whose reason is "fail"), and stops
/// on app.stop.
const _tool = r'''
echo 'Launching lib/main.dart on emulator...'
echo '[{"event":"app.start","params":{"appId":"a1"}}]'
echo '[{"event":"app.started","params":{"appId":"a1"}}]'
while read -r line; do
  id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
  case "$line" in
    *app.stop*) echo "[{\"id\":$id,\"result\":true}]"; exit 0 ;;
    *'"fullRestart":true'*) echo "[{\"id\":$id,\"result\":{\"code\":1,\"message\":\"no\"}}]" ;;
    *) echo "[{\"id\":$id,\"result\":{\"code\":0}}]" ;;
  esac
done
''';

void main() {
  test('machine lines are lists of messages; other lines are nothing', () {
    expect(decodeMachineLine('[{"event":"app.started"}]'), [
      {'event': 'app.started'},
    ]);
    expect(decodeMachineLine('Syncing files'), isEmpty);
    expect(decodeMachineLine('[{broken'), isEmpty);
  });

  test('start, reload, a failed restart, stop', () async {
    final s = await MachineSession.start(
      ['sh', '-c', _tool],
      Directory.systemTemp.path,
      Platform.environment,
    );
    await s.event('app.started', timeout: const Duration(seconds: 20));
    expect(s.appId, 'a1');
    await s.restart(full: false);
    await expectLater(s.restart(full: true), throwsStateError);
    await s.stop();
  });
}
