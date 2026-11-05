/// Command-line flag parsing, path resolution and process environment helpers.
library;

import 'dart:io';

/// Host variables spawned tools may inherit, matched case-insensitively.
const Set<String> _hostEnvAllowlist = {
  'PATH',
  'HOME',
  'USER',
  'LOGNAME',
  'TMPDIR',
  'LANG',
  'LC_ALL',
  'XDG_CACHE_HOME',
  'XDG_CONFIG_HOME',
  'BAZELISK_HOME',
  'USE_BAZEL_VERSION',
  'JAVA_HOME',
  'SYSTEMROOT',
  'SYSTEMDRIVE',
  'WINDIR',
  'COMSPEC',
  'PATHEXT',
  'TEMP',
  'TMP',
  'USERPROFILE',
  'LOCALAPPDATA',
  'APPDATA',
  'HOMEDRIVE',
  'HOMEPATH',
  'PROGRAMDATA',
};

/// Parses `--key=value` and `--key value` flags from [args].
Map<String, List<String>> parseCliFlags(List<String> args) {
  final parsed = <String, List<String>>{};
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (!arg.startsWith('--') || arg == '--') continue;

    final eq = arg.indexOf('=');
    if (eq != -1) {
      final key = arg.substring(2, eq);
      final value = arg.substring(eq + 1);
      parsed.putIfAbsent(key, () => <String>[]).add(value);
      continue;
    }

    final key = arg.substring(2);
    if (i + 1 < args.length && !args[i + 1].startsWith('--')) {
      parsed.putIfAbsent(key, () => <String>[]).add(args[i + 1]);
      i++;
    } else {
      parsed.putIfAbsent(key, () => <String>[]).add('');
    }
  }
  return parsed;
}

/// Looks up the last value provided for any alias in [names].
String? lastFlagValue(Map<String, List<String>> flags, List<String> names) {
  String? found;
  for (final name in names) {
    final values = flags[name];
    if (values != null && values.isNotEmpty) {
      found = values.last;
    }
  }
  return found;
}

/// Parses an integer CLI flag from [names], returning [defaultValue] if absent,
/// or `null` if present with a non-integer value.
int? intFlagValue(
  Map<String, List<String>> flags,
  List<String> names, {
  int? defaultValue,
}) {
  final raw = lastFlagValue(flags, names);
  if (raw == null || raw.isEmpty) return defaultValue;
  return int.tryParse(raw);
}

/// Returns whether [path] is an absolute POSIX, UNC or Windows drive path.
bool isAbsoluteCliPath(String path) {
  if (path.startsWith('/') || path.startsWith(r'\\')) return true;
  return path.length >= 3 &&
      RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(path.substring(0, 3));
}

/// Normalizes `.` and `..` segments in an absolute path with forward slashes.
String normalizeAbsolutePath(String rawPath) {
  final norm = rawPath.replaceAll(r'\', '/');
  String prefix;
  String rest;
  if (norm.startsWith('//')) {
    prefix = '//';
    rest = norm.substring(2);
  } else if (norm.length >= 2 && norm[1] == ':') {
    prefix = '${norm.substring(0, 2)}/';
    rest = norm.length > 2 ? norm.substring(2) : '';
  } else if (norm.startsWith('/')) {
    prefix = '/';
    rest = norm.substring(1);
  } else {
    prefix = '';
    rest = norm;
  }

  final out = <String>[];
  for (final seg in rest.split('/')) {
    if (seg.isEmpty || seg == '.') continue;
    if (seg == '..') {
      if (out.isNotEmpty) out.removeLast();
    } else {
      out.add(seg);
    }
  }
  return '$prefix${out.join('/')}';
}

/// Resolves a CLI path relative to `BUILD_WORKING_DIRECTORY` or cwd.
String resolveCliPath(
  String path, {
  Map<String, String>? environment,
  String? currentDirectory,
}) {
  final trimmed = path.trim();
  if (trimmed.isEmpty) return trimmed;
  if (isAbsoluteCliPath(trimmed)) {
    return normalizeAbsolutePath(trimmed);
  }

  final env = environment ?? Platform.environment;
  final bwd = env['BUILD_WORKING_DIRECTORY'];
  final base = (bwd != null && bwd.trim().isNotEmpty)
      ? bwd.trim()
      : (currentDirectory ?? Directory.current.path);
  return normalizeAbsolutePath('$base/$trimmed');
}

/// Builds a minimal child environment: allowlisted host variables plus [overlay].
Map<String, String> cleanProcessEnvironment({
  Map<String, String>? baseEnvironment,
  Map<String, String> overlay = const {},
}) {
  final source = baseEnvironment ?? Platform.environment;
  final env = <String, String>{
    for (final entry in source.entries)
      if (_hostEnvAllowlist.contains(entry.key.toUpperCase()))
        entry.key: entry.value,
  };
  env.addAll(overlay);
  return env;
}

/// Parsed `runner` output-related flags.
final class _OutputFlags {
  const _OutputFlags({
    required this.hasExplicitRepeat,
    required this.repeat,
    required this.repeatsCount,
    required this.resultsDir,
    required this.out,
  });

  factory _OutputFlags.parse(Map<String, List<String>> flags) {
    return _OutputFlags(
      hasExplicitRepeat:
          flags.containsKey('repeat') ||
          flags.containsKey('repeat-index') ||
          flags.containsKey('repeat_index'),
      repeat: intFlagValue(flags, const [
        'repeat',
        'repeat-index',
        'repeat_index',
      ], defaultValue: 1),
      repeatsCount: intFlagValue(flags, const ['repeats']),
      resultsDir: lastFlagValue(flags, const ['results-dir', 'results_dir']),
      out: lastFlagValue(flags, const ['out', 'output']),
    );
  }

  final bool hasExplicitRepeat;
  final int? repeat;
  final int? repeatsCount;
  final String? resultsDir;
  final String? out;

  bool get hasResultsDir => resultsDir != null && resultsDir!.isNotEmpty;
  bool get hasOutFlag => out != null && out!.isNotEmpty;

  bool get isInvalid {
    final r = repeat;
    final n = repeatsCount;
    return r == null ||
        r <= 0 ||
        (n != null && n <= 0) ||
        !(hasOutFlag || hasResultsDir);
  }
}

/// Resolves `(repeatIndex, outputFilePath)` pairs from parsed `runner` [flags].
List<(int, String)> resolveRunnerOutputs(
  Map<String, List<String>> flags, {
  Map<String, String>? environment,
  String? currentDirectory,
}) {
  final f = _OutputFlags.parse(flags);
  if (f.isInvalid) return const [];

  String resolve(String p) => resolveCliPath(
    p,
    environment: environment,
    currentDirectory: currentDirectory,
  );

  final repeatsCount = f.repeatsCount;
  final rawOut = f.out;
  final singleJsonOut =
      repeatsCount == 1 &&
      !f.hasResultsDir &&
      rawOut != null &&
      rawOut.endsWith('.json') &&
      !Directory(resolve(rawOut)).existsSync();
  if (!f.hasExplicitRepeat && repeatsCount != null && !singleJsonOut) {
    final outDir = resolve(f.hasResultsDir ? f.resultsDir! : rawOut!);
    return [
      for (var i = 1; i <= repeatsCount; i++) (i, '$outDir/repeat-$i.json'),
    ];
  }

  final targetRepeat = (!f.hasExplicitRepeat && repeatsCount == 1)
      ? 1
      : f.repeat!;
  if (!f.hasOutFlag) {
    final outDir = resolve(f.resultsDir!);
    return [(targetRepeat, '$outDir/repeat-$targetRepeat.json')];
  }
  final resolvedOut = resolve(rawOut!);
  if (Directory(resolvedOut).existsSync()) {
    return [(targetRepeat, '$resolvedOut/repeat-$targetRepeat.json')];
  }
  return [(targetRepeat, resolvedOut)];
}
