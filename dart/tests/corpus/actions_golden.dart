import 'dart:convert';
import 'dart:io';

import 'package:runfiles/runfiles.dart';

import 'golden_digest.dart';

/// Where the checked-in golden lives, relative to the workspace root.
const String goldenRelativePath = 'dart/tests/corpus/actions.golden.json';

/// The outcome of one updater run, with its streams captured for the tests.
final class GoldenResult {
  /// Creates a result with [exitCode] and captured [output] and [error] text.
  const new(this.exitCode, {this.output = '', this.error = ''});

  /// Process exit status (`0` on success, `1` on golden diff, `2` on usage or input failure).
  final int exitCode;

  /// Captured standard output text.
  final String output;

  /// Captured standard error text.
  final String error;
}

/// Runs the updater with injectable runfiles, streams, and paths so the tests
/// never need a second Bazel server.
final class GoldenRunner {
  /// Creates an updater runner with optional test overrides.
  const new({
    this.runfiles,
    this.workspaceRoot,
    this.workingDirectory,
    this.goldenPath,
    this.readStdin,
  });

  /// Optional runfiles override for locating the checked-in golden.
  final Runfiles? runfiles;

  /// Optional workspace root override for writing [goldenRelativePath].
  final String? workspaceRoot;

  /// Optional caller working directory override for relative aquery paths.
  final String? workingDirectory;

  /// Optional explicit golden file path override.
  final String? goldenPath;

  /// Optional standard input reader override when no positional path is passed.
  final String Function()? readStdin;

  /// Parses `--check`, reads the aquery text, and either writes the golden or
  /// compares it. A usage or input error exits 2; a stale golden exits 1.
  GoldenResult run(List<String> args) {
    final _ParsedArgs parsed = _parseArgs(args);
    if (parsed.error != null) {
      return GoldenResult(2, error: parsed.error!);
    }
    final _TextResult text = _readAquery(parsed.queryPath);
    if (text.error != null) {
      return GoldenResult(2, error: text.error!);
    }
    final _MapResult parsedQuery = _parseJson(
      text.text!,
      text.source!,
      'jsonproto',
    );
    if (parsedQuery.error != null) {
      return GoldenResult(2, error: parsedQuery.error!);
    }
    final String? listError = validateAquery(parsedQuery.value!, text.source!);
    if (listError != null) {
      return GoldenResult(2, error: listError);
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
    if (expected.error != null) {
      return GoldenResult(2, error: expected.error!);
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

  _TextResult _readAquery(String? path) {
    if (path == null) {
      final String content = readStdin != null ? readStdin!() : _readAllStdin();
      return _TextResult(content, 'stdin');
    }
    final file = File(_resolveCallerPath(path));
    if (!file.existsSync()) {
      return _TextResult(
        null,
        path,
        error: 'actions_golden: aquery file $path does not exist.\n',
      );
    }
    return _TextResult(file.readAsStringSync(), path);
  }

  String _resolveCallerPath(String path) {
    if (_isAbsolutePath(path)) return path;
    final String base =
        workingDirectory ??
        Platform.environment['BUILD_WORKING_DIRECTORY'] ??
        Directory.current.path;
    return '$base/$path';
  }

  String? _locateGolden() =>
      locateCorpusRunfile(goldenRelativePath, runfiles: runfiles);
}

/// Resolves [workspaceRelativePath] against Bazel [runfiles], or returns `null`
/// when runfiles are unavailable or do not contain the file.
String? locateCorpusRunfile(
  String workspaceRelativePath, {
  Runfiles? runfiles,
}) {
  final Runfiles? source = runfiles ?? _createRunfiles();
  if (source == null) return null;
  for (final prefix in const ['_main', 'rules_dart', 'ai_rules_dart', '']) {
    final candidate = prefix.isEmpty
        ? workspaceRelativePath
        : '$prefix/$workspaceRelativePath';
    try {
      final String resolved = source.rlocation(candidate);
      if (File(resolved).existsSync()) return resolved;
    } on Object {
      // Manifest-only runfiles throw StateError when a candidate repo prefix is unmapped.
    }
  }
  return null;
}

Runfiles? _createRunfiles() {
  try {
    return Runfiles.create();
  } on Object {
    // Direct `dart` invocations outside Bazel have no runfiles tree or manifest.
    return null;
  }
}

bool _isAbsolutePath(String path) =>
    path.startsWith('/') ||
    path.startsWith(r'\\') ||
    RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path);

String _readAllStdin() {
  final lines = <String>[];
  for (
    String? line = stdin.readLineSync(encoding: utf8);
    line != null;
    line = stdin.readLineSync(encoding: utf8)
  ) {
    lines.add(line);
  }
  return lines.join('\n');
}

String? _validateActionsList(Object? actions, String source) {
  if (actions is! List) {
    return 'actions_golden: malformed jsonproto in $source: '
        '"actions" is not a list.\n';
  }
  for (final Object? entry in actions) {
    if (entry is! Map) {
      return 'actions_golden: malformed jsonproto in $source: '
          'action entry is not a JSON object.\n';
    }
  }
  return null;
}

/// Checks that [query] holds every table the golden is built from and that
/// every id the normaliser follows resolves; returns the message naming the
/// table, or `null` when the jsonproto is whole.
String? validateAquery(Map<String, Object?> query, String source) {
  final String? actionsError = _validateActionsList(query['actions'], source);
  if (actionsError != null) return actionsError;
  final tables = <String, Set<int>>{};
  for (final table in const [
    'targets',
    'artifacts',
    'depSetOfFiles',
    'pathFragments',
  ]) {
    final Object? rows = query[table];
    if (rows is! List) {
      return 'actions_golden: malformed jsonproto in $source: '
          'table "$table" is missing.\n';
    }
    tables[table] = {
      for (final Map<String, Object?> row in _objectList(rows))
        if (_int(row['id']) != null) _int(row['id'])!,
    };
  }
  return _danglingId(query, tables, source);
}

typedef _Reference = ({String table, Object? ids, String from});

String? _danglingId(
  Map<String, Object?> query,
  Map<String, Set<int>> tables,
  String source,
) {
  for (final _Reference ref in _references(query)) {
    for (final int id in _ints(ref.ids)) {
      if (!tables[ref.table]!.contains(id)) {
        return 'actions_golden: malformed jsonproto in $source: '
            '${ref.from} refers to $id, which is not in table "${ref.table}".\n';
      }
    }
  }
  return null;
}

Iterable<_Reference> _references(Map<String, Object?> query) sync* {
  for (final Map<String, Object?> action in _objectList(query['actions'])) {
    yield (table: 'targets', ids: [action['targetId']], from: 'an action');
    yield (
      table: 'artifacts',
      ids: [action['primaryOutputId'], ...?_list(action['outputIds'])],
      from: 'an action',
    );
    yield (
      table: 'depSetOfFiles',
      ids: action['inputDepSetIds'],
      from: 'an action',
    );
  }
  for (final Map<String, Object?> depSet in _objectList(
    query['depSetOfFiles'],
  )) {
    yield (
      table: 'artifacts',
      ids: depSet['directArtifactIds'],
      from: 'depset ${depSet['id']}',
    );
    yield (
      table: 'depSetOfFiles',
      ids: depSet['transitiveDepSetIds'],
      from: 'depset ${depSet['id']}',
    );
  }
  for (final Map<String, Object?> artifact in _objectList(query['artifacts'])) {
    if (artifact['path'] is String) continue;
    yield (
      table: 'pathFragments',
      ids: [artifact['pathFragmentId']],
      from: 'artifact ${artifact['id']}',
    );
  }
  for (final Map<String, Object?> fragment in _objectList(
    query['pathFragments'],
  )) {
    yield (
      table: 'pathFragments',
      ids: [fragment['parentId']],
      from: 'path fragment ${fragment['id']}',
    );
  }
}

List<Object?>? _list(Object? value) => value is List ? value : null;

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
        error:
            'actions_golden: malformed $what in $source: '
            'top-level value is not a JSON object.\n',
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

/// Replaces configuration-specific output directories, host SDK repositories
/// and host-platform tokens with stable placeholders.
///
/// The golden is generated on Linux but checked on macOS as well, so a token
/// that names the host platform must not reach it:
///
/// * `{target-os-arch}` for a Dart native-asset target key such as `linux_x64`
///   or `macos_arm64` (the `native-assets` mapping the build writes);
/// * `{solib-dir}` for the C++ shared-library directory name, `_solib_k8` on
///   Linux and `_solib_darwin_arm64` on macOS;
/// * `{shlib-ext}` for a shared-library file extension (`.so`, `.dylib`,
///   `.dll`) at the end of a file name.
///
/// Each pattern is anchored on the token's whole shape and a boundary, so text
/// that merely contains it (`linux_x64_extra`, `my_solib_dir`, `libx.sox`) is
/// left alone, and every first-party value around the token stays recorded.
String normalisePath(String value) {
  String out = value.replaceAll(
    RegExp(r'\+dart\+dart_[^/\s"|,;:]+'),
    '{dart-sdk}',
  );
  out = out.replaceAll(
    RegExp(r'bazel-out/[^/\s"|,;:]+/bin(?=/|$|[\s"|,;:])'),
    '{bindir}',
  );
  out = out.replaceAll(
    RegExp(r'bazel-out/[^/\s"|,;:]+/genfiles(?=/|$|[\s"|,;:])'),
    '{genfilesdir}',
  );
  out = out.replaceAll(
    RegExp(r'bazel-out/[^/\s"|,;:]+/testlogs(?=/|$|[\s"|,;:])'),
    '{testlogsdir}',
  );
  out = out.replaceAll(RegExp(r'bazel-out/[^/\s"|,;:]+'), '{bazel-out}');
  return _normaliseHostPlatform(out);
}

const String _nativeAssetOs = 'linux|macos|windows|android|ios';
const String _nativeAssetArch = 'x64|arm64|arm|ia32|riscv64';

final RegExp _nativeAssetTarget = RegExp(
  '(?<![A-Za-z0-9_-])(?:$_nativeAssetOs)_(?:$_nativeAssetArch)'
  '(?![A-Za-z0-9_-])',
);

final RegExp _solibDirectory = RegExp(
  r'(?<![A-Za-z0-9_-])_solib_[A-Za-z0-9_-]+(?=/|$|[\s"|,;:])',
);

final RegExp _sharedLibraryExtension = RegExp(
  r'(?<=[A-Za-z0-9_-])\.(?:so|dylib|dll)(?=$|[\s"|,;:])',
);

String _normaliseHostPlatform(String value) => value
    .replaceAll(_nativeAssetTarget, '{target-os-arch}')
    .replaceAll(_solibDirectory, '{solib-dir}')
    .replaceAll(_sharedLibraryExtension, '{shlib-ext}');

/// Whether [normalised] (a path after [normalisePath]) is a file of the
/// toolchain's Dart SDK repository, whose file set differs between host
/// platforms.
bool isSdkInput(String normalised) =>
    normalised == 'external/{dart-sdk}' ||
    normalised.startsWith('external/{dart-sdk}/');

/// Turns a jsonproto action graph into the stable actions the golden holds.
///
/// Every action in the query is kept, in `(target, aspect, mnemonic,
/// primaryOutput)` order; the golden records the whole action graph so a
/// change that adds or removes any action, including the runfiles-tree
/// `Symlink` actions, shows up in `--check`.
List<Map<String, Object?>> normaliseAquery(Map<String, Object?> query) {
  final index = _AqueryIndex(query);
  final actions = <Map<String, Object?>>[];
  for (final Map<String, Object?> raw in _objectList(query['actions'])) {
    actions.add(index.action(raw));
  }
  actions.sort(_compareActions);
  return actions;
}

/// Encodes one action per line, with every object's keys sorted.
String encodeGolden(List<Map<String, Object?>> actions) {
  if (actions.isEmpty) return '{\n  "actions": []\n}\n';
  final List<String> lines = [
    for (final action in actions) '    ${_inline(action)}',
  ];
  return '{\n  "actions": [\n${lines.join(',\n')}\n  ]\n}\n';
}

String _inline(Object? value) {
  if (value is Map) {
    final List<String> keys = value.keys.map((key) => '$key').toList()..sort();
    if (keys.isEmpty) return '{}';
    final List<String> fields = [
      for (final key in keys) '${jsonEncode(key)}: ${_inline(value[key])}',
    ];
    return '{ ${fields.join(', ')} }';
  }
  if (value is List) {
    if (value.isEmpty) return '[]';
    return '[${value.map(_inline).join(', ')}]';
  }
  return jsonEncode(value);
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
    for (final Map<String, Object?> aspect in _objectList(
      query['aspectDescriptors'],
    )) {
      _aspects[_int(aspect['id'])] = '${aspect['name'] ?? ''}';
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
  final Map<int?, String> _aspects = {};
  final Map<int?, String> _artifacts = {};
  final Map<int?, ({String label, int? parent})> _fragments = {};
  final Map<int?, Map<String, Object?>> _depSets = {};

  Map<String, Object?> action(Map<String, Object?> raw) {
    final mnemonic = '${raw['mnemonic'] ?? ''}';
    return {
      'target': _targets[_int(raw['targetId'])] ?? '',
      'aspect': _aspect(raw),
      'mnemonic': mnemonic,
      'primaryOutput': _artifacts[_int(raw['primaryOutputId'])] ?? '',
      'arguments': [
        for (final arg in _strings(raw['arguments'])) normalisePath(arg),
      ],
      'inputs': _inputs(raw['inputDepSetIds']),
      'outputs': _outputs(raw['outputIds']),
      'environmentVariables': _pairs(raw['environmentVariables']),
      'executionInfo': _pairs(raw['executionInfo']),
      if (mnemonic == 'FileWrite')
        'fileContents': normalisePath('${raw['fileContents'] ?? ''}'),
    };
  }

  String _aspect(Map<String, Object?> raw) {
    final direct = '${raw['aspect'] ?? ''}';
    if (direct.isNotEmpty) return direct;
    final List<String> names = [
      for (final int id in _ints(raw['aspectDescriptorIds']))
        if ((_aspects[id] ?? '').isNotEmpty) _aspects[id]!,
    ];
    return names.join(',');
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

  List<String> _outputs(Object? ids) {
    final List<String> paths = [
      for (final int id in _ints(ids))
        if (_artifacts[id] != null) _artifacts[id]!,
    ];
    return paths..sort();
  }

  /// The inputs of an action, as the count and SHA-256 of its input closure.
  ///
  /// The closure is every artifact reachable from [ids] through
  /// `directArtifactIds` and `transitiveDepSetIds`, to any depth, each artifact
  /// once, normalised like every other path, sorted and joined by newlines.
  /// Listing the paths would take the golden past 32 MB (the closures of the
  /// corpus actions hold about 155,000 paths), so the golden keeps the count
  /// and the digest instead: dropping or adding one input changes both.
  ///
  /// The toolchain SDK's own files (`external/{dart-sdk}/...` after
  /// normalisation) are left out of the count and the digest. The SDK archive's
  /// file set differs between host platforms (Linux and macOS), and the golden
  /// is generated on Linux but checked on macOS too. The action arguments
  /// already name which SDK tool runs, so every first-party input stays covered.
  Map<String, Object?> _inputs(Object? ids) {
    final List<String> paths = [
      for (final int artifact in _closure(ids))
        if (!isSdkInput(_artifacts[artifact] ?? '')) _artifacts[artifact] ?? '',
    ]..sort();
    return {
      'count': paths.length,
      'sha256': sha256Hex(utf8.encode(paths.join('\n'))),
    };
  }

  Set<int> _closure(Object? ids) {
    final seen = <int>{};
    final artifacts = <int>{};
    final List<int> pending = _ints(ids).toList();
    while (pending.isNotEmpty) {
      final int id = pending.removeLast();
      final Map<String, Object?>? depSet = _depSets[id];
      if (!seen.add(id) || depSet == null) continue;
      artifacts.addAll(_ints(depSet['directArtifactIds']));
      pending.addAll(_ints(depSet['transitiveDepSetIds']));
    }
    return artifacts;
  }

  List<Map<String, Object?>> _pairs(Object? value) {
    final entries = <Map<String, Object?>>[
      for (final item in _objectList(value))
        {
          'key': normalisePath('${item['key'] ?? ''}'),
          'value': normalisePath('${item['value'] ?? ''}'),
        },
    ];
    entries.sort((a, b) {
      final int byKey = '${a['key']}'.compareTo('${b['key']}');
      return byKey != 0 ? byKey : '${a['value']}'.compareTo('${b['value']}');
    });
    return entries;
  }
}

int? _int(Object? value) {
  if (value is int) return value;
  if (value is String) return int.tryParse(value);
  return null;
}

Iterable<int> _ints(Object? value) sync* {
  if (value is! List) return;
  for (final Object? item in value) {
    final int? parsed = _int(item);
    if (parsed != null) yield parsed;
  }
}

Iterable<String> _strings(Object? value) sync* {
  if (value is! List) return;
  for (final Object? item in value) {
    if (item is String) yield item;
  }
}

bool _readsStdin(List<String> args) => args.every((arg) => arg == '--check');

/// CLI entry point for `bazel run //dart/tests/corpus:actions_golden`.
Future<void> main(List<String> args) async {
  String? piped;
  if (_readsStdin(args)) {
    try {
      piped = await utf8.decoder.bind(stdin).join();
    } on FormatException catch (error) {
      stderr.write(
        'actions_golden: malformed jsonproto in stdin: ${error.message}.\n',
      );
      exitCode = 2;
      return;
    }
  }
  final GoldenResult result = GoldenRunner(
    readStdin: piped == null ? null : () => piped!,
  ).run(args);
  stdout.write(result.output);
  stderr.write(result.error);
  if (result.exitCode != 0) exitCode = result.exitCode;
}
