/// VM-service coverage collection for the `flutter_test` Bazel driver.
///
/// Reuses the same VM service JSON-RPC scaffolding the old `dart`-based
/// runner had, but pointed at flutter_tester instead of the Dart SDK binary.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Collects an LCOV report from every isolate the VM service lists.
///
/// Public so `flutter_test_runner_test.dart` can drive it against a fake VM
/// service; the only other caller is the test runner, which calls it once
/// the suite has run and before the tester is told to close.
///
/// Every failure propagates. The caller turns one into `failed to collect
/// coverage: …` and exits non-zero, which is the only honest answer available:
/// a report missing an isolate — or missing one file within an isolate — is
/// indistinguishable from a complete one once written, so a run that drops
/// part of its coverage reads as a run that simply exercised less code. That
/// sends someone to write tests that already exist, or passes a coverage bar
/// that was never actually met.
///
/// Per-isolate failures must not be swallowed. A bare catch cannot tell an
/// exited isolate from anything else, so it equally hides every RPC error and
/// every `TypeError` thrown by
/// [_formatLcov] casting a malformed report. And the scenario it named does
/// not arise here: collection runs before the suite is told to close, so the
/// isolates `getVM` just listed are alive by construction — measured at one
/// isolate, collected without error, on the `hello_coverage_test` path that is
/// the only coverage run in the repo.
///
/// [libraries] scopes the request: URI prefixes passed to the VM as
/// `libraryFilters`, so only the test's own code is compiled and reported. An
/// empty list sends no filter and collects every library the VM can see.
Future<String> collectCoverage(Uri httpUri, List<String> libraries) async {
  final WebSocket ws = await _connectVmServiceWebSocket(httpUri);
  try {
    final rpc = _VmServiceRpc(ws);
    final Map<String, dynamic> vm = await rpc.call('getVM');
    final List<dynamic> isolates = (vm['isolates'] as List?) ?? const [];
    final lines = <String>[];
    for (final iso in isolates) {
      final id = (iso as Map)['id'] as String;
      final Map<String, dynamic> report = await rpc.call('getSourceReport', {
        'isolateId': id,
        'reports': const ['Coverage'],
        'forceCompile': true,
        if (libraries.isNotEmpty) 'libraryFilters': libraries,
      });
      await _formatLcov(report, lines, rpc, id);
    }
    return lines.join('\n');
  } finally {
    await ws.close();
  }
}

Future<WebSocket> _connectVmServiceWebSocket(Uri httpUri) {
  final Uri wsUri = httpUri.replace(
    scheme: httpUri.scheme == 'https' ? 'wss' : 'ws',
    path: '${httpUri.path}ws',
  );
  return WebSocket.connect(wsUri.toString());
}

class _VmServiceRpc {
  new(this._ws) {
    _sub = _ws.listen(_onMessage);
  }

  final WebSocket _ws;
  late final StreamSubscription<dynamic> _sub;
  final _pending = <String, Completer<Map<String, dynamic>>>{};
  int _id = 1;

  void _onMessage(dynamic raw) {
    final m = json.decode(raw as String) as Map<String, dynamic>;
    final id = m['id']?.toString();
    if (id != null && _pending.containsKey(id)) {
      _pending[id]!.complete(m);
    }
  }

  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic>? params,
  ]) {
    final id = '${_id++}';
    final c = Completer<Map<String, dynamic>>();
    _pending[id] = c;
    _ws.add(
      json.encode({
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        if (params != null) 'params': params,
      }),
    );
    return c.future.then((response) {
      _pending.remove(id);
      if (response.containsKey('error')) {
        throw StateError('VM service error on $method: ${response['error']}');
      }
      return response['result'] as Map<String, dynamic>;
    });
  }

  Future<void> close() async {
    await _sub.cancel();
  }
}

Map<int, int> _buildTokenToLineMap(List<dynamic> tokenPosTable) {
  final map = <int, int>{};
  for (final entry in tokenPosTable) {
    final row = entry as List;
    if (row.isEmpty) continue;
    final line = row[0] as int;
    for (var i = 1; i < row.length; i += 2) {
      map[row[i] as int] = line;
    }
  }
  return map;
}

Future<void> _formatLcov(
  Map<String, dynamic> report,
  List<String> lines,
  _VmServiceRpc rpc,
  String isolateId,
) async {
  final List<dynamic> scripts = (report['scripts'] as List?) ?? const [];
  final List<dynamic> ranges = (report['ranges'] as List?) ?? const [];

  final scriptInfo = <int, ({String id, String uri})>{};
  for (var i = 0; i < scripts.length; i++) {
    final Map<String, dynamic> s = (scripts[i] as Map).cast<String, dynamic>();
    scriptInfo[i] = (id: s['id'] as String, uri: s['uri'] as String);
  }

  final perScript = <int, ({List<int> hits, List<int> misses})>{};
  _accumulateTokenCoverage(ranges, scriptInfo, perScript);

  for (final MapEntry<int, ({List<int> hits, List<int> misses})> entry
      in perScript.entries) {
    final ({String id, String uri}) info = scriptInfo[entry.key]!;
    await _renderScriptCoverage(info, entry.value, rpc, isolateId, lines);
  }
}

/// Folds a source report's raw token hits/misses per script, skipping
/// `dart:` SDK scripts, which carry no user code to attribute.
void _accumulateTokenCoverage(
  List<dynamic> ranges,
  Map<int, ({String id, String uri})> scriptInfo,
  Map<int, ({List<int> hits, List<int> misses})> perScript,
) {
  for (final range in ranges) {
    final scriptIndex = (range as Map)['scriptIndex'] as int?;
    if (scriptIndex == null) continue;
    final ({String id, String uri})? info = scriptInfo[scriptIndex];
    if (info == null) continue;
    if (info.uri.startsWith('dart:')) continue;
    final Map<String, dynamic>? coverage = (range['coverage'] as Map?)
        ?.cast<String, dynamic>();
    if (coverage == null) continue;
    final ({List<int> hits, List<int> misses}) entry = perScript.putIfAbsent(
      scriptIndex,
      () => (hits: <int>[], misses: <int>[]),
    );
    entry.hits.addAll((coverage['hits'] as List?)?.cast<int>() ?? const []);
    entry.misses.addAll((coverage['misses'] as List?)?.cast<int>() ?? const []);
  }
}

/// Resolves one script's tokens to lines and appends its LCOV record.
///
/// Not guarded: a `getObject` that fails drops this script's every line
/// from the report while the surrounding records still look complete, so
/// the loss has to reach the caller. `tokenPosTable` being absent is the
/// one silent skip left, and it is a documented-optional field rather than
/// a failure — a script that reports no token table has no line numbers to
/// attribute hits to.
Future<void> _renderScriptCoverage(
  ({String id, String uri}) info,
  ({List<int> hits, List<int> misses}) tokens,
  _VmServiceRpc rpc,
  String isolateId,
  List<String> lines,
) async {
  final Map<String, dynamic> script = await rpc.call('getObject', {
    'isolateId': isolateId,
    'objectId': info.id,
  });
  final table = script['tokenPosTable'] as List?;
  if (table == null) return;
  final Map<int, int> tokenToLine = _buildTokenToLineMap(table);

  final lineHits = <int, int>{};
  for (final int t in tokens.hits) {
    final int? line = tokenToLine[t];
    if (line != null) lineHits[line] = (lineHits[line] ?? 0) + 1;
  }
  for (final int t in tokens.misses) {
    final int? line = tokenToLine[t];
    if (line != null) lineHits.putIfAbsent(line, () => 0);
  }

  if (lineHits.isEmpty) return;

  String path = info.uri;
  if (path.startsWith('file://')) path = Uri.parse(path).toFilePath();

  lines.add('SF:$path');
  final List<MapEntry<int, int>> sorted = lineHits.entries.toList()
    ..sort((a, b) => a.key.compareTo(b.key));
  for (final lh in sorted) {
    lines.add('DA:${lh.key},${lh.value}');
  }
  lines.add('end_of_record');
}
