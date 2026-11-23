/// Normalises and checks the corpus action graph.
///
/// Input is the text of `bazel aquery --output=jsonproto` over the labels in
/// `golden_targets.txt`, either a positional file path or stdin. The
/// checked-in `actions.golden.json` stores one canonical action per line,
/// sorted by `(target, aspect, mnemonic, primary_output)`, with every
/// configuration-specific `bazel-out/<cfg>[/bin|/genfiles|/testlogs]` path
/// replaced by a stable placeholder.
///
/// Without flags it writes the golden next to this source (the workspace is
/// found through `BUILD_WORKSPACE_DIRECTORY`). `--check` compares against the
/// checked-in file (through its runfiles `data`), prints the first differing
/// lines, never writes, and exits 1 on a difference.
///
/// The golden is Linux-x64 specific: its paths name the `flutter_linux-x64` and
/// `llvm-toolchain-minimal-linux-amd64` repositories, so regenerate it on such
/// a host. From the repo root, list the buildable fixtures with
/// `bazel cquery --keep_going --skip_incompatible_explicit_targets
/// --output=label 'kind(rule, //flutter/tests/corpus:all) except
/// kind("dart_binary|dart_test|test_suite|cc_.*", //flutter/tests/corpus:all)'`
/// (dropping labels whose `providers(target)` hold
/// `IncompatiblePlatformProvider`) into `golden_targets.txt`, then run
/// `bazel aquery --skip_incompatible_explicit_targets --output=jsonproto
/// "set($(grep -vE '^\s*(#|$)' flutter/tests/corpus/golden_targets.txt))" >
/// /tmp/flutter_corpus_aquery.json` and
/// `bazel run //flutter/tests/corpus:actions_golden --
/// /tmp/flutter_corpus_aquery.json`.
library;

import 'dart:convert';
import 'dart:io';

/// A failure whose message names the missing input or malformed document.
class ActionsGoldenError implements Exception {
  /// Creates an error with a user-facing [message].
  new(this.message);

  /// What failed, in a sentence.
  final String message;

  @override
  String toString() => message;
}

/// One `depSetOfFiles` entry: direct artifacts and child dep sets live in
/// separate id spaces, so they must not be merged into one list.
class _DepSet {
  /// Creates a dep-set entry from its direct artifacts and child dep sets.
  new(this.direct, this.transitive);

  /// Artifact ids held directly.
  final List<int> direct;

  /// `depSetOfFiles` ids this entry includes.
  final List<int> transitive;
}

final _bindir = RegExp(r'bazel-out/[^/\s]+/bin');
final _genfilesdir = RegExp(r'bazel-out/[^/\s]+/genfiles');
final _testlogsdir = RegExp(r'bazel-out/[^/\s]+/testlogs');
final _bazelOut = RegExp(r'bazel-out/[^/\s]+');

/// Replaces the configuration-specific output-root segments in [text].
String normalizeConfigurationPaths(String text) => text
    .replaceAll(_bindir, '{bindir}')
    .replaceAll(_genfilesdir, '{genfilesdir}')
    .replaceAll(_testlogsdir, '{testlogsdir}')
    .replaceAll(_bazelOut, '{bazel-out}');

String _normalizeString(String value) => normalizeConfigurationPaths(value);

dynamic _normalizeValue(dynamic value) {
  if (value is String) return _normalizeString(value);
  if (value is List) return value.map(_normalizeValue).toList();
  if (value is Map) {
    return <String, dynamic>{
      for (final key in value.keys.toList()..sort())
        key.toString(): _normalizeValue(value[key]),
    };
  }
  return value;
}

/// Whether [aspect] is one of rules_dart's analyzer/format aspects.
///
/// Those aspects run on the corpus' own Dart tests under `bazel test`, so
/// their actions enter a later aquery only after a test run. They are not
/// part of the public rule surface the golden records, so leaving them in
/// would make the checked graph depend on command order.
bool _isToolingAspect(String aspect) => aspect
    .split(',')
    .any(
      (String name) =>
          name.endsWith('%dart_analyze') ||
          name.endsWith('%dart_analyzer_summary'),
    );

String _canonical(dynamic value) => jsonEncode(_normalizeValue(value));

Map<int, String> _pathFragments(Map<String, dynamic> doc) {
  final Object? raw = doc['pathFragments'];
  if (raw is! List) return <int, String>{};
  final byId = <int, Map<String, dynamic>>{};
  for (final Object? entry in raw) {
    if (entry is Map) {
      final Object? id = entry['id'];
      if (id is int) byId[id] = Map<String, dynamic>.from(entry);
    }
  }
  final resolved = <int, String>{};
  String resolve(int id, Set<int> seen) {
    final String? known = resolved[id];
    if (known != null) return known;
    if (!seen.add(id)) return '';
    final Map<String, dynamic>? fragment = byId[id];
    if (fragment == null) return '';
    final Object? label = fragment['label'];
    final Object? parent = fragment['parentId'];
    final String prefix = parent is int ? resolve(parent, seen) : '';
    final path = prefix.isEmpty ? '${label ?? ''}' : '$prefix/${label ?? ''}';
    resolved[id] = path;
    return path;
  }

  for (final int id in byId.keys) {
    resolve(id, <int>{});
  }
  return resolved;
}

Map<int, String> _artifacts(Map<String, dynamic> doc, Map<int, String> paths) {
  final Object? raw = doc['artifacts'];
  if (raw is! List) return <int, String>{};
  final result = <int, String>{};
  for (final Object? entry in raw) {
    if (entry is! Map) continue;
    final Object? id = entry['id'];
    if (id is! int) continue;
    final Object? direct = entry['path'];
    if (direct is String) {
      result[id] = direct;
      continue;
    }
    final Object? fragment = entry['pathFragmentId'];
    if (fragment is int && paths.containsKey(fragment)) {
      result[id] = paths[fragment]!;
    }
  }
  return result;
}

Map<int, _DepSet> _depSets(Map<String, dynamic> doc) {
  final Object? raw = doc['depSetOfFiles'];
  if (raw is! List) return <int, _DepSet>{};
  final result = <int, _DepSet>{};
  for (final Object? entry in raw) {
    if (entry is! Map) continue;
    final Object? id = entry['id'];
    if (id is! int) continue;
    List<int> ids(String key) {
      final Object? list = entry[key];
      return list is List ? list.whereType<int>().toList() : <int>[];
    }

    result[id] = _DepSet(ids('directArtifactIds'), ids('transitiveDepSetIds'));
  }
  return result;
}

List<String> _dedupeSorted(Iterable<String> values) =>
    values.where((value) => value.isNotEmpty).toSet().toList()..sort();

Set<String> _inputPaths(
  List<int>? depSetIds,
  Map<int, _DepSet> depSets,
  Map<int, String> artifacts,
) {
  final files = <String>{};
  void visit(int id, Set<int> seen) {
    if (!seen.add(id)) return;
    final _DepSet? entry = depSets[id];
    if (entry == null) return;
    for (final int child in entry.direct) {
      final String? path = artifacts[child];
      if (path != null) files.add(path);
    }
    for (final int child in entry.transitive) {
      visit(child, seen);
    }
  }

  for (final int id in depSetIds ?? const <int>[]) {
    visit(id, <int>{});
  }
  return files;
}

String _targetLabel(Map<String, dynamic> action, Map<int, String> targets) {
  final Object? id = action['targetId'];
  if (id is int) return targets[id] ?? '//:unknown-$id';
  final Object? direct = action['target'];
  return direct is String ? direct : '';
}

String _aspectLabel(
  Map<String, dynamic> action,
  Map<int, String> aspectNames,
) {
  final Object? direct = action['aspect'];
  if (direct is String && direct.isNotEmpty) return direct;
  final labels = <String>[];
  final Object? ids = action['aspectDescriptorIds'];
  if (ids is List) {
    for (final Object? id in ids) {
      if (id is int && aspectNames[id] != null) labels.add(aspectNames[id]!);
    }
  }
  final Object? descriptors = action['aspectDescriptors'];
  if (descriptors is List) {
    for (final Object? descriptor in descriptors) {
      if (descriptor is! Map) continue;
      for (final key in ['aspect', 'aspectLabel', 'aspectName', 'name']) {
        final Object? value = descriptor[key];
        if (value is String && value.isNotEmpty) {
          labels.add(value);
          break;
        }
      }
    }
  }
  return labels.join(',');
}

List<Map<String, String>> _keyValueList(dynamic raw) {
  if (raw is! List) return const <Map<String, String>>[];
  final entries = <Map<String, String>>[];
  for (final Object? item in raw) {
    if (item is! Map) continue;
    final Object? key = item['key'];
    final Object? value = item['value'];
    if (key is! String) continue;
    entries.add(<String, String>{
      'key': _normalizeString(key),
      'value': value is String ? _normalizeString(value) : '',
    });
  }
  entries.sort((a, b) => a['key']!.compareTo(b['key']!));
  return entries;
}

Map<String, dynamic> _normalizedAction(
  Map<String, dynamic> action,
  Map<int, String> targets,
  Map<int, String> artifacts,
  Map<int, _DepSet> depSets,
  Map<int, String> aspectNames,
) {
  final result = <String, dynamic>{};
  void put(String key, dynamic value) {
    if (value == null) return;
    if (value is String && value.isEmpty) return;
    if (value is List && value.isEmpty) return;
    result[key] = value;
  }

  put('target', _targetLabel(action, targets));
  put('aspect', _aspectLabel(action, aspectNames));
  put('mnemonic', action['mnemonic'] is String ? action['mnemonic'] : '');

  final Object? primary = action['primaryOutputId'];
  if (primary is int && artifacts.containsKey(primary)) {
    put('primary_output', _normalizeString(artifacts[primary]!));
  } else if (action['primaryOutput'] is String) {
    put('primary_output', _normalizeString(action['primaryOutput'] as String));
  }

  final Iterable<int> outputIds = (action['outputIds'] is List)
      ? (action['outputIds'] as List).whereType<int>()
      : const <int>[];
  put(
    'outputs',
    _dedupeSorted(
      outputIds.map(
        (id) => artifacts[id] == null ? '' : _normalizeString(artifacts[id]!),
      ),
    ),
  );

  final depIds = <int>[
    if (action['inputDepSetId'] is int) action['inputDepSetId'] as int,
    if (action['inputDepSetIds'] is List)
      ...(action['inputDepSetIds'] as List).whereType<int>(),
  ];
  put(
    'inputs',
    _dedupeSorted(
      _inputPaths(depIds, depSets, artifacts).map(_normalizeString),
    ),
  );

  final Object? arguments = action['arguments'];
  if (arguments is List) {
    put(
      'arguments',
      arguments.whereType<String>().map(_normalizeString).toList(),
    );
  }
  final List<Map<String, String>> environment = _keyValueList(
    action['environmentVariables'],
  );
  if (environment.isNotEmpty) put('environment', environment);
  final List<Map<String, String>> executionInfo = _keyValueList(
    action['executionInfo'],
  );
  if (executionInfo.isNotEmpty) put('execution_info', executionInfo);
  if (action['discoversInputs'] == true) put('discovers_inputs', true);
  return result;
}

String _sortKey(Map<String, dynamic> action) =>
    '${action['target']}\u0000${action['aspect']}\u0000'
    '${action['mnemonic']}\u0000${action['primary_output']}';

/// Turns aquery jsonproto [text] into the canonical golden document.
String normalizedGolden(String text, {String source = 'aquery input'}) {
  dynamic decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException catch (error) {
    throw ActionsGoldenError(
      'malformed jsonproto in $source: ${error.message}',
    );
  }
  if (decoded is! Map<String, dynamic>) {
    throw ActionsGoldenError(
      'malformed jsonproto in $source: not a JSON object',
    );
  }
  final Object? rawActions = decoded['actions'];
  if (rawActions is! List) {
    throw ActionsGoldenError(
      'malformed jsonproto in $source: no "actions" list',
    );
  }
  final Map<int, String> paths = _pathFragments(decoded);
  final Map<int, String> artifacts = _artifacts(decoded, paths);
  final Map<int, _DepSet> depSets = _depSets(decoded);
  final aspectNames = <int, String>{};
  final Object? rawAspects = decoded['aspectDescriptors'];
  if (rawAspects is List) {
    for (final Object? aspect in rawAspects) {
      if (aspect is! Map) continue;
      final Object? id = aspect['id'];
      final Object? name = aspect['name'] ?? aspect['aspectName'];
      if (id is int && name is String) aspectNames[id] = name;
    }
  }
  final targets = <int, String>{};
  final Object? rawTargets = decoded['targets'];
  if (rawTargets is List) {
    for (final Object? target in rawTargets) {
      if (target is! Map) continue;
      final Object? id = target['id'];
      final Object? label = target['label'];
      if (id is int && label is String) targets[id] = label;
    }
  }

  final actions = <Map<String, dynamic>>[];
  for (final Object? raw in rawActions) {
    if (raw is! Map) continue;
    actions.add(
      _normalizedAction(
        Map<String, dynamic>.from(raw),
        targets,
        artifacts,
        depSets,
        aspectNames,
      ),
    );
  }
  actions.removeWhere(
    (Map<String, dynamic> action) =>
        _isToolingAspect(action['aspect'] as String? ?? ''),
  );
  actions.sort((a, b) {
    final int byKey = _sortKey(a).compareTo(_sortKey(b));
    if (byKey != 0) return byKey;
    return _canonical(a).compareTo(_canonical(b));
  });

  // Each action is a canonical JSON string, so it stays one line under
  // Prettier while the document itself remains valid JSON. A bare object
  // would be re-indented across lines and no longer be the checked text.
  final buffer = StringBuffer('{\n  "actions": [\n');
  for (var i = 0; i < actions.length; i++) {
    buffer.write('    ${jsonEncode(_canonical(actions[i]))}');
    buffer.write(i + 1 == actions.length ? '\n' : ',\n');
  }
  buffer.write('  ]\n}\n');
  return buffer.toString();
}

String _readInput(List<String> positional, String? stdinText) {
  if (positional.length > 1) {
    throw ActionsGoldenError(
      'expected at most one aquery input path, got ${positional.length}',
    );
  }
  if (positional.isEmpty) {
    if (stdinText != null) return stdinText;
    final bytes = <int>[];
    while (true) {
      final int byte = stdin.readByteSync();
      if (byte < 0) break;
      bytes.add(byte);
    }
    return utf8.decode(bytes);
  }
  final String path = positional.single;
  final file = File(path);
  if (!file.existsSync()) {
    throw ActionsGoldenError('aquery input file not found: $path');
  }
  try {
    return file.readAsStringSync();
  } on FileSystemException catch (error) {
    throw ActionsGoldenError(
      'cannot read aquery input $path: ${error.message}',
    );
  }
}

String _runfile(String suffix) {
  final Map<String, String> env = Platform.environment;
  final roots = <String>[
    if (env['RUNFILES_DIR'] case final value? when value.isNotEmpty) value,
    if (env['TEST_SRCDIR'] case final value? when value.isNotEmpty) value,
  ];
  for (final root in roots) {
    final dir = Directory(root);
    if (!dir.existsSync()) continue;
    for (final candidate in [
      'rules_flutter/$suffix',
      'ai_rules_flutter/$suffix',
      '_main/$suffix',
    ]) {
      final file = File('$root/$candidate');
      if (file.existsSync()) return file.path;
    }
    for (final FileSystemEntity entity in dir.listSync(recursive: true)) {
      final String path = entity.path.replaceAll(r'\', '/');
      if (entity is File && path.endsWith(suffix)) return entity.path;
    }
  }
  final String? manifest = env['RUNFILES_MANIFEST_FILE'];
  if (manifest != null && File(manifest).existsSync()) {
    for (final String line in File(manifest).readAsLinesSync()) {
      final int space = line.indexOf(' ');
      if (space <= 0) continue;
      final String target = line.substring(space + 1).trim();
      if (target.replaceAll(r'\', '/').endsWith(suffix) &&
          File(target).existsSync()) {
        return target;
      }
    }
  }
  return '';
}

String _checkedInGolden() {
  final Map<String, String> env = Platform.environment;
  final String fromRunfiles = _runfile(
    'flutter/tests/corpus/actions.golden.json',
  );
  if (fromRunfiles.isNotEmpty) return fromRunfiles;
  final String? workspace = env['BUILD_WORKSPACE_DIRECTORY'];
  if (workspace != null && workspace.isNotEmpty) {
    final candidate = File(
      '$workspace/flutter/tests/corpus/actions.golden.json',
    );
    if (candidate.existsSync()) return candidate.path;
  }
  return '';
}

String _writeTarget() {
  final Map<String, String> env = Platform.environment;
  final String? workspace = env['BUILD_WORKSPACE_DIRECTORY'];
  if (workspace != null && workspace.isNotEmpty) {
    return '$workspace/flutter/tests/corpus/actions.golden.json';
  }
  Directory current = Directory.current;
  for (var i = 0; i < 8; i++) {
    final candidate = File(
      '${current.path}/flutter/tests/corpus/actions.golden.json',
    );
    if (File('${current.path}/MODULE.bazel').existsSync()) {
      return candidate.path;
    }
    final Directory parent = current.parent;
    if (parent.path == current.path) break;
    current = parent;
  }
  throw ActionsGoldenError(
    'cannot find the workspace to write actions.golden.json; '
    'set BUILD_WORKSPACE_DIRECTORY or run through bazel run',
  );
}

int _compareGolden(String actual, String expected) {
  if (actual == expected) return 0;
  final List<String> actualLines = actual.split('\n');
  final List<String> expectedLines = expected.split('\n');
  final int limit = actualLines.length > expectedLines.length
      ? actualLines.length
      : expectedLines.length;
  var shown = 0;
  for (var i = 0; i < limit; i++) {
    final String a = i < actualLines.length ? actualLines[i] : '<missing line>';
    final String e = i < expectedLines.length
        ? expectedLines[i]
        : '<missing line>';
    if (a == e) continue;
    stderr.writeln('actions.golden.json differs at line ${i + 1}:');
    stderr.writeln('- $e');
    stderr.writeln('+ $a');
    shown++;
    if (shown == 5) break;
  }
  return 1;
}

/// Runs the updater or checker and returns its process exit code.
int runActionsGolden(
  List<String> args, {
  String? stdinText,
  String? goldenPath,
  String? outputPath,
}) {
  var check = false;
  final positional = <String>[];
  for (final arg in args) {
    if (arg == '--check') {
      check = true;
    } else if (arg.startsWith('-')) {
      throw ActionsGoldenError('unknown option: $arg');
    } else {
      positional.add(arg);
    }
  }
  final String input = _readInput(positional, stdinText);
  final String golden = normalizedGolden(
    input,
    source: positional.isEmpty ? 'stdin' : positional.single,
  );

  if (check) {
    final String path = goldenPath ?? _checkedInGolden();
    if (path.isEmpty) {
      throw ActionsGoldenError(
        'checked-in actions.golden.json not found '
        'in runfiles, BUILD_WORKSPACE_DIRECTORY or the current tree',
      );
    }
    final file = File(path);
    if (!file.existsSync()) {
      throw ActionsGoldenError('checked-in golden not found: $path');
    }
    return _compareGolden(golden, file.readAsStringSync());
  }

  final String target = outputPath ?? goldenPath ?? _writeTarget();
  try {
    File(target).writeAsStringSync(golden);
  } on FileSystemException catch (error) {
    throw ActionsGoldenError('cannot write $target: ${error.message}');
  }
  return 0;
}

void main(List<String> args) {
  try {
    exitCode = runActionsGolden(args);
  } on ActionsGoldenError catch (error) {
    stderr.writeln('actions_golden: ${error.message}');
    exitCode = 2;
  }
}
