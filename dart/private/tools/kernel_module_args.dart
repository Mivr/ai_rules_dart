// Rewrites URI-bearing arguments for `kernel_worker`.

const _kernelWorkerUriFlags = <String>{
  '--dart-sdk-summary',
  '--packages-file',
  '--libraries-file',
  '--multi-root',
  '--input-summary',
  '--input-linked',
  '--source',
  '--native-assets',
};

bool _isAsciiAlpha(int c) =>
    (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a);

/// True when [s] starts with a Windows drive letter (`C:/...`, `d:\...`, `C:`).
bool isWindowsDrivePath(String s) =>
    s.length >= 2 &&
    _isAsciiAlpha(s.codeUnitAt(0)) &&
    s.codeUnitAt(1) == 0x3a &&
    (s.length == 2 || s.codeUnitAt(2) == 0x2f || s.codeUnitAt(2) == 0x5c);

/// Converts a Windows drive-letter or UNC file path to a `file://` URI string
/// for `kernel_worker` (`package:frontend_server/compute_kernel.dart`).
String kernelWorkerUri(String pathOrUri) {
  if (isWindowsDrivePath(pathOrUri) || pathOrUri.startsWith(r'\\')) {
    return Uri.file(pathOrUri, windows: true).toString();
  }
  return pathOrUri;
}

/// Converts [pathOrUri] to a local file system path if it is a `file://` URI,
/// or returns it unchanged.
String filePathOf(String pathOrUri) {
  if (pathOrUri.startsWith('file:///')) {
    final String rest = pathOrUri.substring('file:///'.length);
    if (isWindowsDrivePath(rest)) return rest;
  }
  if (pathOrUri.startsWith('file://')) {
    return Uri.parse(pathOrUri).toFilePath(windows: true);
  }
  return pathOrUri;
}

String _rewriteRedirectUri(String value) {
  final int sep = value.indexOf('|');
  if (sep < 0) return kernelWorkerUri(value);
  return '${kernelWorkerUri(value.substring(0, sep))}|'
      '${kernelWorkerUri(value.substring(sep + 1))}';
}

/// Rewrites Windows drive-letter and UNC paths in `kernel_worker` URI-bearing
/// flags to `file:///` URIs while leaving `--output` and other file-system
/// path flags unchanged.
List<String> kernelWorkerArgs(List<String> args) {
  final out = <String>[];
  for (var i = 0; i < args.length; i++) {
    final String arg = args[i];
    if (_kernelWorkerUriFlags.contains(arg) && i + 1 < args.length) {
      out
        ..add(arg)
        ..add(kernelWorkerUri(args[++i]));
      continue;
    }
    if (arg == '--redirect' && i + 1 < args.length) {
      out
        ..add(arg)
        ..add(_rewriteRedirectUri(args[++i]));
      continue;
    }
    if (arg.startsWith('--redirect=')) {
      final String raw = arg.substring('--redirect='.length);
      out.add('--redirect=${_rewriteRedirectUri(raw)}');
      continue;
    }
    var matchedEq = false;
    for (final String flag in _kernelWorkerUriFlags) {
      final prefix = '$flag=';
      if (arg.startsWith(prefix)) {
        out.add('$flag=${kernelWorkerUri(arg.substring(prefix.length))}');
        matchedEq = true;
        break;
      }
    }
    if (!matchedEq) {
      out.add(arg);
    }
  }
  return out;
}

/// Precomputed canonical summary-to-key and root-to-module index for one
/// unused-inputs calculation, replacing per-(module, summary) linear scans.
typedef KmodRootIndex = ({
  Map<String, Set<String>> keysOfDill,
  String Function(String path) canon,
  Set<String> Function(String dir) definedKeysOf,
  Set<int> Function(String canonPath) ownerIndicesOf,
  String? Function(String canonPath) firstOwnerOf,
});

/// Indexes [dirs] and [graphEntries] using [canonicalize] for realpaths.
KmodRootIndex buildKmodRootIndex({
  required List<String> dirs,
  required Iterable<({String key, String dill})> graphEntries,
  required String Function(String path) canonicalize,
}) {
  final canonMemo = <String, String>{};
  String canon(String path) =>
      canonMemo.putIfAbsent(path, () => canonicalize(path));
  final keysOfDill = <String, Set<String>>{};
  final dillsUnderSlash = <String, Set<String>>{};
  for (final entry in graphEntries) {
    if (!canonMemo.containsKey(entry.dill)) {
      _indexSlashPrefixes(entry.dill, canon(entry.dill), dillsUnderSlash);
    }
    (keysOfDill[canon(entry.dill)] ??= <String>{}).add(entry.key);
  }
  final Map<String, List<int>> ownersByRoot = _buildOwnersByRoot(
    dirs,
    canon,
    dillsUnderSlash,
  );
  Set<int> ownerIndicesOf(String canonPath) =>
      _ownerIndicesIn(ownersByRoot, canonPath);
  final keysByDir = <String, Set<String>>{};
  keysOfDill.forEach((String dill, Set<String> keys) {
    for (final int idx in ownerIndicesOf(dill)) {
      (keysByDir[dirs[idx]] ??= <String>{}).addAll(keys);
    }
  });
  return (
    keysOfDill: keysOfDill,
    canon: canon,
    definedKeysOf: (String dir) => keysByDir[dir] ?? const <String>{},
    ownerIndicesOf: ownerIndicesOf,
    firstOwnerOf: (String canonPath) =>
        _firstOwnerIn(dirs, ownersByRoot, canonPath),
  );
}

Map<String, List<int>> _buildOwnersByRoot(
  List<String> dirs,
  String Function(String path) canon,
  Map<String, Set<String>> dillsUnderSlash,
) {
  const suffix = '/index.json';
  final ownersByRoot = <String, List<int>>{};
  for (var i = 0; i < dirs.length; i++) {
    final String dir = dirs[i];
    final String index = canon('$dir$suffix');
    final roots = <String>{
      canon(dir),
      if (index.endsWith(suffix))
        index.substring(0, index.length - suffix.length),
      ...?dillsUnderSlash['$dir/'],
    };
    for (final root in roots) {
      (ownersByRoot[root] ??= <int>[]).add(i);
    }
  }
  return ownersByRoot;
}

Set<int> _ownerIndicesIn(Map<String, List<int>> ownersByRoot, String path) {
  final matched = <int>{};
  final List<int>? exact = ownersByRoot[path];
  if (exact != null) matched.addAll(exact);
  for (var i = 0; i < path.length; i++) {
    if (path.codeUnitAt(i) != 0x2f) continue;
    final List<int>? atPrefix = ownersByRoot[path.substring(0, i)];
    if (atPrefix != null) matched.addAll(atPrefix);
  }
  return matched;
}

String? _firstOwnerIn(
  List<String> dirs,
  Map<String, List<int>> ownersByRoot,
  String path,
) {
  int? best;
  for (final int idx in _ownerIndicesIn(ownersByRoot, path)) {
    if (best == null || idx < best) best = idx;
  }
  return best == null ? null : dirs[best];
}

void _indexSlashPrefixes(
  String dill,
  String canonDill,
  Map<String, Set<String>> out,
) {
  for (var i = 0; i < dill.length; i++) {
    if (dill.codeUnitAt(i) == 0x2f) {
      (out[dill.substring(0, i + 1)] ??= <String>{}).add(canonDill);
    }
  }
}
