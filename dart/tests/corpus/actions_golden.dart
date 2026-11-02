import 'dart:convert';
import 'dart:io';

import 'package:runfiles/runfiles.dart';

/// Where the checked-in golden lives, relative to the workspace root.
const String goldenRelativePath = 'dart/tests/corpus/actions.golden.json';

/// The outcome of one updater run, with its streams captured for the tests.
final class GoldenResult {
  const new(this.exitCode, {this.output = '', this.error = ''});

  final int exitCode;
  final String output;
  final String error;
}

/// Runs the updater with injectable runfiles and paths, so the tests never
/// need a second Bazel server.
final class GoldenRunner {
  new({this.runfiles, this.workspaceRoot, this.goldenPath});

  final Runfiles? runfiles;
  final String? workspaceRoot;
  final String? goldenPath;

  /// Parses `--check`, reads the aquery text, and either writes the golden or
  /// compares it. A usage or input error exits 2; a stale golden exits 1.
  GoldenResult run(List<String> args) {
    final _ParsedArgs parsed = _parseArgs(args);
    final String? argsError = parsed.error;
    if (argsError != null) {
      return GoldenResult(2, error: argsError);
    }
    final _TextResult text = _readAquery(parsed.queryPath);
    final String? textError = text.error;
    if (textError != null) {
      return GoldenResult(2, error: textError);
    }
    final _MapResult parsedQuery = _parseJson(
      text.text!,
      text.source!,
      'jsonproto',
    );
    final String? queryError = parsedQuery.error;
    if (queryError != null) {
      return GoldenResult(2, error: queryError);
    }
    final List<Map<String, Object?>> current = normaliseAquery(
      parsedQuery.value!,
    );
    if (parsed.check) {
      return _check(current, text.source!);
    }
    return _write(current);
  }

  GoldenResult _check(List<Map<String, Object?>> current, String source) {
    final String? path = goldenPath ?? _locateGolden();
    if (path == null) {
      return const GoldenResult(
        2,
        error:
            'actions_golden: cannot find the checked-in golden '
            '$goldenRelativePath in runfiles; run this through `bazel run`.\n',
      );
    }
    final expectedFile = File(path);
    if (!expectedFile.existsSync()) {
      return GoldenResult(
        2,
        error: 'actions_golden: golden file $path does not exist.\n',
      );
    }
    final _ActionsResult expected = _parseGolden(
      expectedFile.readAsStringSync(),
      path,
    );
    final String? goldenError = expected.error;
    if (goldenError != null) {
      return GoldenResult(2, error: goldenError);
    }
    final List<String> diffs = _diff(current, expected.value!);
    if (diffs.isEmpty) {
      return const GoldenResult(0);
    }
    return GoldenResult(
      1,
      error:
          'actions_golden: $path is stale for $source. First differences:\n'
          '${diffs.join('\n')}\n',
    );
  }

  GoldenResult _write(List<Map<String, Object?>> current) {
    final String root =
        workspaceRoot ??
        Platform.environment['BUILD_WORKSPACE_DIRECTORY'] ??
        Directory.current.path;
    final String path = goldenPath ?? '$root/$goldenRelativePath';
    final file = File(path);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(encodeGolden(current));
    return GoldenResult(0, output: 'actions_golden: wrote $path\n');
  }

  String? _locateGolden() {
    final Runfiles? source = runfiles ?? _createRunfiles();
    if (source == null) return null;
    for (final prefix in const ['rules_dart', 'ai_rules_dart', '_main', '']) {
      final String candidate = prefix.isEmpty
          ? goldenRelativePath
          : '$prefix/$goldenRelativePath';
      final String resolved = source.rlocation(candidate);
      if (File(resolved).existsSync()) return resolved;
    }
    return null;
  }

  Runfiles? _createRunfiles() {
    try {
      return Runfiles.create();
    } on Object {
      return null;
    }
  }
}

final class _ParsedArgs {
  const new({required this.check, this.queryPath, this.error});

  final bool check;
  final String? queryPath;
  final String? error;
}

_ParsedArgs _parseArgs(List<String> args) {
  var check = false;
  String? queryPath;
  for (final arg in args) {
    if (arg == '--check') {
      check = true;
    } else if (arg.startsWith('-')) {
      return _ParsedArgs(
        check: check,
        error: 'actions_golden: unknown option $arg.\n',
      );
    } else if (queryPath == null) {
      queryPath = arg;
    } else {
      return _ParsedArgs(
        check: check,
        error:
            'actions_golden: expected at most one aquery path, got '
            '$queryPath and $arg.\n',
      );
    }
  }
  return _ParsedArgs(check: check, queryPath: queryPath);
}

final class _TextResult {
  const new(this.text, this.source, {this.error});

  final String? text;
  final String? source;
  final String? error;
}

_TextResult _readAquery(String? path) {
  if (path == null) {
    final lines = <String>[];
    for (
      String? line = stdin.readLineSync();
      line != null;
      line = stdin.readLineSync()
    ) {
      lines.add(line);
    }
    return _TextResult(lines.join('\n'), 'stdin');
  }
  final file = File(path);
  if (!file.existsSync()) {
    return _TextResult(
      null,
      path,
      error: 'actions_golden: aquery file $path does not exist.\n',
    );
  }
  return _TextResult(file.readAsStringSync(), path);
}

final class _MapResult {
  const new(this.value, {this.error});

  final Map<String, Object?>? value;
  final String? error;
}

_MapResult _parseJson(String text, String source, String what) {
  try {
    final Object? decoded = jsonDecode(text);
    if (decoded is! Map) {
      return _MapResult(
        null,
        error: 'actions_golden: $what in $source is not a JSON object.\n',
      );
    }
    return _MapResult(Map<String, Object?>.from(decoded));
  } on FormatException catch (error) {
    return _MapResult(
      null,
      error: 'actions_golden: malformed $what in $source: ${error.message}.\n',
    );
  }
}

final class _ActionsResult {
  const new(this.value, {this.error});

  final List<Map<String, Object?>>? value;
  final String? error;
}

_ActionsResult _parseGolden(String text, String path) {
  final _MapResult parsed = _parseJson(text, path, 'golden');
  if (parsed.error != null) return _ActionsResult(null, error: parsed.error);
  final Object? actions = parsed.value!['actions'];
  if (actions is! List) {
    return _ActionsResult(
      null,
      error: 'actions_golden: golden $path has no "actions" list.\n',
    );
  }
  final value = <Map<String, Object?>>[];
  for (final Object? action in actions) {
    if (action is! Map) {
      return _ActionsResult(
        null,
        error: 'actions_golden: golden $path holds a non-object action.\n',
      );
    }
    value.add(Map<String, Object?>.from(action));
  }
  return _ActionsResult(value);
}

/// Replaces configuration-specific output directories with stable names.
String normalisePath(String value) {
  String out = value.replaceAll(RegExp('bazel-out/[^/]+/bin'), '{bindir}');
  out = out.replaceAll(RegExp('bazel-out/[^/]+/genfiles'), '{genfilesdir}');
  out = out.replaceAll(RegExp('bazel-out/[^/]+/testlogs'), '{testlogsdir}');
  return out.replaceAll(RegExp('bazel-out/[^/]+'), '{bazel-out}');
}

/// Turns a jsonproto action graph into the stable actions the golden holds.
List<Map<String, Object?>> normaliseAquery(Map<String, Object?> query) {
  final index = _AqueryIndex(query);
  final actions = <Map<String, Object?>>[];
  for (final Map<String, Object?> raw in _objectList(query['actions'])) {
    final Map<String, Object?> action = index.action(raw);
    // Every staged input is its own symlink action; they describe the
    // staging tree, not the rule's action, and would drown the golden.
    if (action['mnemonic'] == 'Symlink') continue;
    actions.add(action);
  }
  actions.sort(_compareActions);
  return actions;
}

/// Encodes one action per line, with every object's keys sorted.
String encodeGolden(List<Map<String, Object?>> actions) {
  if (actions.isEmpty) return '{\n  "actions": []\n}\n';
  final List<String> lines = [
    for (final action in actions) '    ${jsonEncode(_sorted(action))}',
  ];
  return '{\n  "actions": [\n${lines.join(',\n')}\n  ]\n}\n';
}

int _compareActions(Map<String, Object?> a, Map<String, Object?> b) {
  for (final key in const ['target', 'aspect', 'mnemonic', 'primaryOutput']) {
    final int result = '${a[key] ?? ''}'.compareTo('${b[key] ?? ''}');
    if (result != 0) return result;
  }
  return jsonEncode(_sorted(a)).compareTo(jsonEncode(_sorted(b)));
}

List<String> _diff(
  List<Map<String, Object?>> current,
  List<Map<String, Object?>> expected,
) {
  final diffs = <String>[];
  final int count = current.length > expected.length
      ? current.length
      : expected.length;
  for (var i = 0; i < count && diffs.length < 5; i++) {
    final String? have = i < current.length
        ? jsonEncode(_sorted(current[i]))
        : null;
    final String? want = i < expected.length
        ? jsonEncode(_sorted(expected[i]))
        : null;
    if (have == want) continue;
    diffs.add('[$i] current: ${have ?? '<absent>'}');
    diffs.add('[$i] golden:  ${want ?? '<absent>'}');
  }
  return diffs;
}

Object? _sorted(Object? value) {
  if (value is Map) {
    final List<String> keys = value.keys.map((key) => '$key').toList()..sort();
    return {for (final key in keys) key: _sorted(value[key])};
  }
  if (value is List) return [for (final item in value) _sorted(item)];
  return value;
}

List<Map<String, Object?>> _objectList(Object? value) {
  if (value is! List) return const [];
  return [
    for (final item in value)
      if (item is Map) Map<String, Object?>.from(item),
  ];
}

final class _AqueryIndex {
  new(this.query) {
    for (final Map<String, Object?> fragment in _objectList(
      query['pathFragments'],
    )) {
      _fragments[_int(fragment['id'])] = (
        label: '${fragment['label'] ?? ''}',
        parent: _int(fragment['parentId']),
      );
    }
    for (final Map<String, Object?> target in _objectList(query['targets'])) {
      _targets[_int(target['id'])] = '${target['label'] ?? ''}';
    }
    for (final Map<String, Object?> artifact in _objectList(
      query['artifacts'],
    )) {
      _artifacts[_int(artifact['id'])] = _artifactPath(artifact);
    }
    for (final Map<String, Object?> depSet in _objectList(
      query['depSetOfFiles'],
    )) {
      _depSets[_int(depSet['id'])] = depSet;
    }
  }

  final Map<String, Object?> query;
  final Map<int?, String> _targets = {};
  final Map<int?, String> _artifacts = {};
  final Map<int?, ({String label, int? parent})> _fragments = {};
  final Map<int?, Map<String, Object?>> _depSets = {};

  Map<String, Object?> action(Map<String, Object?> raw) {
    final List<String> outputs = _paths(raw['outputIds']);
    return {
      'target': _targets[_int(raw['targetId'])] ?? '',
      'aspect': '${raw['aspect'] ?? ''}',
      'mnemonic': '${raw['mnemonic'] ?? ''}',
      'primaryOutput': _artifacts[_int(raw['primaryOutputId'])] ?? '',
      'arguments': [
        for (final arg in _strings(raw['arguments'])) normalisePath(arg),
      ],
      'inputs': _paths(raw['inputDepSetIds'], depSets: true),
      'outputs': outputs,
      'environmentVariables': _environment(raw['environmentVariables']),
    };
  }

  String _artifactPath(Map<String, Object?> artifact) {
    final Object? direct = artifact['path'];
    if (direct is String && direct.isNotEmpty) return normalisePath(direct);
    return normalisePath(_fragmentPath(_int(artifact['pathFragmentId'])));
  }

  String _fragmentPath(int? id) {
    final ({String label, int? parent})? fragment = _fragments[id];
    if (fragment == null) return '';
    final String parent = _fragmentPath(fragment.parent);
    if (parent.isEmpty) return fragment.label;
    return '$parent/${fragment.label}';
  }

  List<String> _paths(Object? ids, {bool depSets = false}) {
    final values = <String>{};
    for (final int id in _ints(ids)) {
      if (!depSets) {
        final String? path = _artifacts[id];
        if (path != null) values.add(path);
        continue;
      }
      final Map<String, Object?>? depSet = _depSets[id];
      if (depSet == null) continue;
      for (final int artifact in _ints(depSet['directArtifactIds'])) {
        final String? path = _artifacts[artifact];
        if (path != null) values.add(path);
      }
    }
    final List<String> sorted = values.toList()..sort();
    return sorted;
  }

  List<Map<String, Object?>> _environment(Object? value) {
    final entries = <Map<String, Object?>>[
      for (final item in _objectList(value))
        {
          'key': normalisePath('${item['key'] ?? ''}'),
          'value': normalisePath('${item['value'] ?? ''}'),
        },
    ];
    entries.sort((a, b) => '${a['key']}'.compareTo('${b['key']}'));
    return entries;
  }
}

int? _int(Object? value) => value is int ? value : null;

Iterable<int> _ints(Object? value) sync* {
  if (value is! List) return;
  for (final Object? item in value) {
    if (item is int) yield item;
  }
}

Iterable<String> _strings(Object? value) sync* {
  if (value is! List) return;
  for (final Object? item in value) {
    if (item is String) yield item;
  }
}

void main(List<String> args) {
  final GoldenResult result = GoldenRunner().run(args);
  stdout.write(result.output);
  stderr.write(result.error);
  if (result.exitCode != 0) exitCode = result.exitCode;
}
