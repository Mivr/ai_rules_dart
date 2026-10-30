// Command-line and diagnostic models shared inside the summary-mode analyzer.
//
// Kept apart from `analyzer_summary.dart` so that runner file holds the
// analysis flow rather than these small value types.
import 'package:analyzer/diagnostic/diagnostic.dart' show Severity;

/// A command-line usage error, reported with the usage exit code.
final class AnalyzerUsageException implements Exception {
  const AnalyzerUsageException(this.message);

  /// What is wrong with the command line.
  final String message;
}

/// Parsed command-line arguments: repeatable `--name value` pairs, and bare
/// `--flag`s.
final class AnalyzerArgs {
  AnalyzerArgs._(this._values, this._flags);

  /// Parses [args], rejecting anything that is not a flag or a value pair.
  factory AnalyzerArgs.parse(List<String> args) {
    final values = <String, List<String>>{};
    final flags = <String>{};
    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      if (!arg.startsWith('--')) {
        throw AnalyzerUsageException('unexpected argument `$arg`');
      }
      final name = arg.substring(2);
      if (name == 'fatal-infos') {
        flags.add(name);
        continue;
      }
      if (i + 1 >= args.length) {
        throw AnalyzerUsageException('`$arg` needs a value');
      }
      values.putIfAbsent(name, () => []).add(args[++i]);
    }
    return AnalyzerArgs._(values, flags);
  }

  final Map<String, List<String>> _values;
  final Set<String> _flags;

  /// Whether the bare `--[name]` flag was given.
  bool flag(String name) => _flags.contains(name);

  /// Every value of the repeatable `--[name]` argument.
  List<String> all(String name) => _values[name] ?? const [];

  /// The single value of an optional repeatable argument, or null.
  String? optional(String name) {
    final values = all(name);
    if (values.length > 1) {
      throw AnalyzerUsageException('`--$name` may be given at most once');
    }
    return values.isEmpty ? null : values.single;
  }

  /// The single required value of `--[name]`.
  String single(String name) {
    final values = all(name);
    if (values.length != 1) {
      throw AnalyzerUsageException('`--$name` is required exactly once');
    }
    return values.single;
  }
}

/// A diagnostic ready to print, ordered most severe first.
final class AnalysisFinding implements Comparable<AnalysisFinding> {
  const AnalysisFinding({
    required this.level,
    required this.path,
    required this.code,
    required this.line,
    required this.column,
    required this.text,
  });

  /// The severity after overrides; null when an override ignores it.
  final Severity? level;

  /// The workspace-relative POSIX path the diagnostic names.
  final String path;

  /// The diagnostic code, lower case.
  final String code;

  /// The 1-based line number.
  final int line;

  /// The 1-based column number.
  final int column;

  /// The line as printed.
  final String text;

  @override
  int compareTo(AnalysisFinding other) {
    final byLevel = _rank(level).compareTo(_rank(other.level));
    if (byLevel != 0) return byLevel;
    final byPath = path.compareTo(other.path);
    if (byPath != 0) return byPath;
    final byLine = line.compareTo(other.line);
    if (byLine != 0) return byLine;
    return column.compareTo(other.column);
  }

  static int _rank(Severity? level) => switch (level) {
    Severity.error => 0,
    Severity.warning => 1,
    Severity.info => 2,
    null => 3,
  };
}
