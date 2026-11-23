/// Just enough Starlark scanning for the lint: blank comments and strings,
/// find a call's parentheses, and give a line number.
library;

/// [text] with every `#` comment, and with [blankStrings] every string
/// literal too, replaced by spaces. Newlines stay, so an offset in the result
/// is the same offset, and the same line, in [text].
String blank(String text, {bool blankStrings = true}) {
  final out = StringBuffer();
  var i = 0;
  while (i < text.length) {
    final String c = text[i];
    if (c == '#') {
      final int end = _lineEnd(text, i);
      out.write(' ' * (end - i));
      i = end;
    } else if (c == '"' || c == "'") {
      final int end = _stringEnd(text, i, raw: _isRawPrefix(text, i));
      final String piece = text.substring(i, end);
      out.write(blankStrings ? piece.replaceAll(RegExp('[^\n]'), ' ') : piece);
      i = end;
    } else {
      out.write(c);
      i++;
    }
  }
  return out.toString();
}

bool _isRawPrefix(String text, int quote) =>
    quote > 0 && (text[quote - 1] == 'r' || text[quote - 1] == 'R');

int _lineEnd(String text, int from) {
  final int newline = text.indexOf('\n', from);
  return newline < 0 ? text.length : newline;
}

/// The offset just past the string literal opening at [start]. An unclosed
/// one-line string ends with its line.
int _stringEnd(String text, int start, {required bool raw}) {
  final String quote = text[start];
  final String close = text.startsWith(quote * 3, start) ? quote * 3 : quote;
  int i = start + close.length;
  while (i < text.length) {
    if (text[i] == r'\' && !raw) {
      i += 2;
    } else if (text.startsWith(close, i)) {
      return i + close.length;
    } else if (close.length == 1 && text[i] == '\n') {
      return i;
    } else {
      i++;
    }
  }
  return text.length;
}

/// The offset of the `)` closing the `(` at [open] in [blanked], or -1.
int closingParen(String blanked, int open) => closing(blanked, open, '(', ')');

/// The offset of the [close] bracket matching the [opener] at [open] in
/// [blanked], or -1. Strings and comments must already be blank.
int closing(String blanked, int open, String opener, String close) {
  var depth = 0;
  for (var i = open; i < blanked.length; i++) {
    if (blanked[i] == opener) depth++;
    if (blanked[i] == close && --depth == 0) return i;
  }
  return -1;
}

/// [arguments] with everything inside a nested bracket replaced by spaces, so
/// that only the call's own keyword arguments remain.
String topLevel(String arguments) {
  final out = StringBuffer();
  var depth = 0;
  for (var i = 0; i < arguments.length; i++) {
    final String c = arguments[i];
    if ('([{'.contains(c)) depth++;
    out.write(depth == 0 || c == '\n' ? c : ' ');
    if (')]}'.contains(c)) depth--;
  }
  return out.toString();
}

/// Maps offsets of one text to 1-based line numbers.
class Lines {
  /// Indexes the line starts of [text].
  new(String text) {
    for (int i = text.indexOf('\n'); i >= 0; i = text.indexOf('\n', i + 1)) {
      _starts.add(i + 1);
    }
    _text = text.split('\n');
  }

  final List<int> _starts = [0];
  late final List<String> _text;

  /// The 1-based line of [offset].
  int of(int offset) {
    var low = 0;
    int high = _starts.length - 1;
    while (low < high) {
      final int mid = (low + high + 1) ~/ 2;
      if (_starts[mid] <= offset) {
        low = mid;
      } else {
        high = mid - 1;
      }
    }
    return low + 1;
  }

  /// The trimmed text of the 1-based [line].
  String trimmed(int line) => _text[line - 1].trim();

  /// The raw text of the 1-based [line], or empty when there is none.
  String raw(int line) =>
      line >= 1 && line <= _text.length ? _text[line - 1] : '';
}
