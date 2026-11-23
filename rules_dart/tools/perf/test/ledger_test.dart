import 'dart:io';

import 'package:perf/src/ledger.dart';
import 'package:test/test.dart';

void main() {
  test('a row survives the round trip through a file', () {
    final dir = Directory.systemTemp.createTempSync('ledger');
    addTearDown(() => dir.deleteSync(recursive: true));
    final row = Row(
      date: nowIso(),
      tool: 'stock',
      sdk: 'flutter-3.47.7+dart-3.13.5',
      corpus: 'counter',
      flow: 'debug_app_edit',
      state: 'edit_body',
      id: 'flutter.plain.stock',
      unit: 's',
      runs: [1.0, 3.0, 2.0, 5.0, 4.0],
      notes: 'flutter build bundle --debug',
      load1: [1.5, 2.5, 1, 1, 1],
      bazelServers: [0, 1, 0, 0, 0],
      noisy: true,
      mnemonics: {'DartKernel': 2},
      workers: {
        'killed_unknown': [0, 0],
      },
      extra: {
        'heap': [1, 2],
      },
    );
    appendRows('${dir.path}/rows.jsonl', [row, row]);
    final back = readRows('${dir.path}/rows.jsonl');
    expect(back, hasLength(2));
    final j = back.first.toJson();
    expect(j['wall_s'], 3.0);
    expect(j['range'], [1.0, 5.0]);
    expect(j['noisy'], isTrue);
    expect(j['mnemonics'], {'DartKernel': 2});
    expect(back.first.load1, [1.5, 2.5, 1, 1, 1]);
    expect(back.first.workers, {
      'killed_unknown': [0, 0],
    });
  });

  test('a count row reports a value, not wall seconds', () {
    final j = Row(
      date: '',
      tool: 'rules_dart',
      sdk: '',
      corpus: '',
      flow: '',
      state: '',
      id: 'x',
      unit: 'actions',
      runs: [2, 2],
      notes: '',
    ).toJson();
    expect(j['wall_s'], isNull);
    expect(j['value'], 2);
  });

  test('rows of the older writers read with their own fields', () {
    final r = Row.fromJson({
      'date': 'd',
      'tool': 'stock',
      'corpus': 'counter',
      'flow': 'test',
      'state': 'warm',
      'wall_s': null,
      'runs': <double>[],
      'notes': 'FAILED',
    });
    expect(r.status, 'failed');
    expect(r.id, 'stock/counter/test/warm');
  });

  test('the time carries its offset', () {
    expect(
      nowIso(),
      matches(RegExp(r'^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d[+-]\d\d:\d\d$')),
    );
  });
}
