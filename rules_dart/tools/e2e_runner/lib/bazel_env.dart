/// Environment and `PATH` preparation for inner commands spawned by the
/// runner.
library;

import 'dart:io';

final RegExp _multiSlash = RegExp('/+');
final RegExp _bazeliskCacheDir = RegExp(
  r'(^|/)\.?bazelisk/(downloads|local)(/|$)',
);
final RegExp _casDownloadDir = RegExp(
  r'(^|/)downloads/sha256/[0-9a-f]{64}(/bin)?$',
);
final RegExp _forkDownloadDir = RegExp(
  r'(^|/)downloads/[^/]+/bazel-[^/]+(/bin)?$',
);

/// Returns [environment] with any launching Bazel directory prepended by
/// Bazelisk removed from `PATH`, or an unchanged copy when none is present.
Map<String, String> innerEnvironment(Map<String, String> environment) {
  final pathKey = _findEnvKey(environment, 'PATH');
  if (pathKey == null) return Map<String, String>.of(environment);
  final sep = Platform.isWindows ? ';' : ':';
  final homeKey = _findEnvKey(environment, 'BAZELISK_HOME');
  final normHome = homeKey == null
      ? null
      : _normalizeEntry(environment[homeKey]!);
  final kept = <String>[];
  var removed = false;
  for (final entry in environment[pathKey]!.split(sep)) {
    if (_isLaunchingBazelDir(entry, normHome)) {
      removed = true;
    } else {
      kept.add(entry);
    }
  }
  if (!removed) return Map<String, String>.of(environment);
  return {...environment, pathKey: kept.join(sep)};
}

/// Resolves a bare command [executable] against [environment]'s `PATH` so
/// `Process.runSync` launches the entry from the cleaned `PATH` on every OS.
String resolveExecutableInPath(
  String executable,
  Map<String, String> environment,
) {
  if (executable.contains('/') || executable.contains(r'\')) {
    return executable;
  }
  final pathKey = _findEnvKey(environment, 'PATH');
  if (pathKey == null) return executable;
  final sep = Platform.isWindows ? ';' : ':';
  final extensions = Platform.isWindows
      ? _windowsPathExtensions(environment)
      : const <String>[];
  for (final rawDir in environment[pathKey]!.split(sep)) {
    final dir = _unquote(rawDir);
    if (dir.isEmpty) continue;
    final match = _matchInDir(dir, executable, extensions);
    if (match != null) return match;
  }
  return executable;
}

String? _findEnvKey(Map<String, String> environment, String name) {
  if (environment.containsKey(name)) return name;
  if (!Platform.isWindows) return null;
  final upper = name.toUpperCase();
  for (final key in environment.keys) {
    if (key.toUpperCase() == upper) return key;
  }
  return null;
}

String _unquote(String raw) {
  final trimmed = raw.trim();
  if (trimmed.length >= 2 && trimmed.startsWith('"') && trimmed.endsWith('"')) {
    return trimmed.substring(1, trimmed.length - 1);
  }
  return trimmed;
}

String _normalizeEntry(String raw) {
  var s = _unquote(raw);
  if (s.isEmpty) return '';
  s = s.replaceAll(r'\', '/').replaceAll(_multiSlash, '/');
  if (s.length > 1 && s.endsWith('/')) {
    s = s.substring(0, s.length - 1);
  }
  return Platform.isWindows ? s.toLowerCase() : s;
}

bool _isLaunchingBazelDir(String raw, String? normHome) {
  final norm = _normalizeEntry(raw);
  if (norm.isEmpty) return false;
  if (normHome != null && normHome.isNotEmpty) {
    if (norm == '$normHome/downloads' ||
        norm.startsWith('$normHome/downloads/') ||
        norm == '$normHome/local' ||
        norm.startsWith('$normHome/local/')) {
      return true;
    }
  }
  return _bazeliskCacheDir.hasMatch(norm) ||
      _casDownloadDir.hasMatch(norm) ||
      _forkDownloadDir.hasMatch(norm);
}

List<String> _windowsPathExtensions(Map<String, String> environment) {
  final key = _findEnvKey(environment, 'PATHEXT');
  final raw = key == null ? '.COM;.EXE;.BAT;.CMD' : environment[key]!;
  return raw
      .split(';')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .map((e) => e.startsWith('.') ? e : '.$e')
      .toList();
}

String? _matchInDir(String dir, String executable, List<String> extensions) {
  if (!Platform.isWindows) {
    final file = File('$dir/$executable');
    if (file.existsSync() && (file.statSync().mode & 0x49) != 0) {
      return file.path;
    }
    return null;
  }
  final lower = executable.toLowerCase();
  final hasExt = extensions.any((ext) => lower.endsWith(ext.toLowerCase()));
  final candidates = <String>[
    if (hasExt) executable,
    for (final ext in extensions) '$executable$ext',
    if (!hasExt) executable,
  ];
  for (final candidate in candidates) {
    final file = File('$dir${Platform.pathSeparator}$candidate');
    if (file.existsSync()) return file.path;
  }
  return null;
}
