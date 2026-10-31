// Minimal command-line flag reader shared by hermetic tool binaries that take
// no `package:args` dependency.
import 'dart:io';

/// Parsed command-line options for a tool binary.
final class ToolFlags {
  ToolFlags._(this._tool, this._values, this._lists, this._booleans);

  final String _tool;
  final Map<String, String> _values;
  final Map<String, List<String>> _lists;
  final Set<String> _booleans;

  /// Parses [args] against [valueFlags], [listFlags], and [boolFlags], exiting
  /// 64 on an unknown flag or a missing flag value.
  factory ToolFlags.parse(
    String tool,
    List<String> args, {
    Set<String> valueFlags = const {},
    Set<String> listFlags = const {},
    Set<String> boolFlags = const {},
  }) {
    final values = <String, String>{};
    final lists = <String, List<String>>{};
    final booleans = <String>{};
    for (var i = 0; i < args.length; i++) {
      final flag = args[i];
      if (valueFlags.contains(flag)) {
        values[flag] = _nextValue(tool, args, ++i, flag);
      } else if (listFlags.contains(flag)) {
        lists
            .putIfAbsent(flag, () => <String>[])
            .add(_nextValue(tool, args, ++i, flag));
      } else if (boolFlags.contains(flag)) {
        booleans.add(flag);
      } else {
        _exitUsage(tool, 'unknown argument $flag');
      }
    }
    return ToolFlags._(tool, values, lists, booleans);
  }

  /// Returns an optional single-value flag, or `null` if absent.
  String? optional(String flag) => _values[flag];

  /// Returns a required single-value flag, or exits 64 naming [requiredSummary].
  String require(String flag, String requiredSummary) {
    final value = _values[flag];
    if (value == null) _exitUsage(_tool, requiredSummary);
    return value;
  }

  /// Returns all values passed to a repeatable flag.
  List<String> values(String flag) => _lists[flag] ?? const [];

  /// Returns whether a boolean flag was set.
  bool flag(String name) => _booleans.contains(name);

  static String _nextValue(
    String tool,
    List<String> args,
    int index,
    String flag,
  ) {
    if (index >= args.length) _exitUsage(tool, '$flag requires a value');
    return args[index];
  }

  static Never _exitUsage(String tool, String message) {
    stderr.writeln('$tool: $message');
    exit(64);
  }
}
