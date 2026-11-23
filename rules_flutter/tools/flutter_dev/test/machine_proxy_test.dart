import 'dart:convert';

import 'package:flutter_dev/src/session.dart';
import 'package:test/test.dart';

String _line(Map<String, Object?> message) => jsonEncode(<Object?>[message]);

void main() {
  late List<String> toTool;
  late List<String> toClient;
  MachineProxy proxy({required bool restart}) {
    toTool = <String>[];
    toClient = <String>[];
    return MachineProxy(
      toTool: toTool.add,
      toClient: toClient.add,
      restart: restart,
    );
  }

  final String start = _line(<String, Object?>{
    'event': 'app.start',
    'params': <String, Object?>{'appId': 'a1'},
  });
  final String started = _line(<String, Object?>{
    'event': 'app.started',
    'params': <String, Object?>{'appId': 'a1'},
  });
  final String progress = _line(<String, Object?>{
    'event': 'app.progress',
    'params': <String, Object?>{'appId': 'a1'},
  });
  final String restarted = _line(<String, Object?>{
    'id': restartRequestId,
    'result': <String, Object?>{'code': 0, 'message': ''},
  });

  test('app.started is held until the injected restart answers, and its answer is dropped', () {
    final MachineProxy p = proxy(restart: true);
    p.fromTool('Launching lib/main.dart on emulator-5584 in debug mode...');
    p.fromTool(start);
    p.fromTool(started);
    expect(toClient, <String>[
      'Launching lib/main.dart on emulator-5584 in debug mode...',
      start,
    ]);
    expect(toTool, hasLength(1));
    final request =
        (jsonDecode(toTool.single) as List<Object?>).single!
            as Map<String, Object?>;
    expect(request['method'], 'app.restart');
    expect(request['id'], restartRequestId);
    expect(request['params'], containsPair('appId', 'a1'));
    expect(request['params'], containsPair('fullRestart', true));

    p.fromTool(progress);
    p.fromTool(restarted);
    expect(toClient, <String>[
      'Launching lib/main.dart on emulator-5584 in debug mode...',
      start,
      progress,
      started,
    ]);
  });

  test('a failed restart still lets the client see the app as started', () {
    final MachineProxy p = proxy(restart: true);
    p.fromTool(started);
    p.fromTool(
      _line(<String, Object?>{'id': restartRequestId, 'error': 'boom'}),
    );
    expect(toClient, <String>[started]);
  });

  test('only one restart, and later traffic passes untouched both ways', () {
    final MachineProxy p = proxy(restart: true);
    p.fromTool(started);
    p.fromTool(restarted);
    final String reload = _line(<String, Object?>{
      'id': 7,
      'result': <String, Object?>{'code': 0},
    });
    p.fromTool(started);
    p.fromTool(reload);
    expect(toTool, hasLength(1));
    expect(toClient, <String>[started, started, reload]);
  });

  test('without the restart every line passes through', () {
    final MachineProxy p = proxy(restart: false);
    <String>[start, started, restarted, 'plain output'].forEach(p.fromTool);
    expect(toTool, isEmpty);
    expect(toClient, <String>[start, started, restarted, 'plain output']);
  });
}
