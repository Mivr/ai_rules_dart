/// Path globs for the subsystem table.
library;

/// A `/`-separated path glob: `*` and `?` stay inside one segment and `**/`
/// matches any number of leading segments. A glob that matches a directory
/// matches every file below it, as in a `.gitignore`.
class Glob {
  /// Compiles [pattern].
  new(String pattern) : _regExp = _compile(pattern);

  final RegExp _regExp;

  /// Whether the repository-relative [path] matches.
  bool matches(String path) => _regExp.hasMatch(path);

  static RegExp _compile(String pattern) {
    final out = StringBuffer('^');
    var i = 0;
    while (i < pattern.length) {
      final String c = pattern[i];
      if (pattern.startsWith('**/', i)) {
        out.write('(?:.*/)?');
        i += 3;
      } else if (pattern.startsWith('**', i)) {
        out.write('.*');
        i += 2;
      } else if (c == '*') {
        out.write('[^/]*');
        i++;
      } else if (c == '?') {
        out.write('[^/]');
        i++;
      } else {
        out.write(RegExp.escape(c));
        i++;
      }
    }
    return RegExp('$out(?:/.*)?\$');
  }
}

/// Whether any glob in [globs] matches [path].
bool matchesAny(List<Glob> globs, String path) =>
    globs.any((glob) => glob.matches(path));
