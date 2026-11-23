/// XML property-list parsing and variable substitution.
///
/// Reads the top-level `<dict>` entries of an XML plist and substitutes
/// Xcode-style `$(VAR)` / `${VAR}` placeholders. Shared by the `Info.plist`
/// merger in `plist_info.dart` and the `CodeResources` renderer in
/// `code_resources.dart`.

// ---------------------------------------------------------------------------
// XML plist parsing and variable substitution
// ---------------------------------------------------------------------------

/// A root `<dict>` entry in an XML property list.
class PlistEntry {
  final String key;
  final String rawValue;

  const new(this.key, this.rawValue);
}

/// Cursor over an XML plist string while its top-level `<dict>` entries are
/// read. Holds the mutable scan position that the nested readers share.
class _PlistReader {
  final String xml;
  final String source;
  var pos = 0;

  new(this.xml, {required this.source});

  void skipTrivia() {
    while (pos < xml.length) {
      final String c = xml[pos];
      if (c == ' ' || c == '\t' || c == '\r' || c == '\n') {
        pos++;
      } else if (xml.startsWith('<!--', pos)) {
        final int end = xml.indexOf('-->', pos + 4);
        if (end == -1) {
          throw FormatException('Unterminated comment in $source.');
        }
        pos = end + 3;
      } else {
        break;
      }
    }
  }

  (String, bool, bool) readTag() {
    if (pos >= xml.length || xml[pos] != '<') {
      throw FormatException('Expected tag at offset $pos in $source.');
    }
    pos++;
    var isEnd = false;
    if (pos < xml.length && xml[pos] == '/') {
      isEnd = true;
      pos++;
    }
    final String name = _readTagName();
    return _readTagClose(name, isEnd);
  }

  String _readTagName() {
    final int nameStart = pos;
    while (pos < xml.length && RegExp(r'[A-Za-z0-9_.:-]').hasMatch(xml[pos])) {
      pos++;
    }
    return xml.substring(nameStart, pos);
  }

  (String, bool, bool) _readTagClose(String name, bool isEnd) {
    var inQuote = '';
    while (pos < xml.length) {
      final String c = xml[pos];
      if (inQuote.isNotEmpty) {
        if (c == inQuote) inQuote = '';
        pos++;
      } else if (c == '"' || c == "'") {
        inQuote = c;
        pos++;
      } else if (c == '>') {
        pos++;
        return (name, false, isEnd);
      } else if (xml.startsWith('/>', pos)) {
        pos += 2;
        return (name, true, isEnd);
      } else {
        pos++;
      }
    }
    throw FormatException('Unterminated tag <$name in $source.');
  }

  String readElement() {
    final int start = pos;
    final (String name, bool selfClosing, bool isEnd) = readTag();
    if (isEnd) {
      throw FormatException('Unexpected closing tag </$name> in $source.');
    }
    if (selfClosing) return xml.substring(start, pos);
    var depth = 1;
    while (depth > 0) {
      final int next = xml.indexOf('<', pos);
      if (next == -1) {
        throw FormatException('Unterminated <$name> in $source.');
      }
      pos = next;
      if (!_skipCommentOrStep()) {
        final (_, bool nestedSelfClosing, bool nestedEnd) = readTag();
        if (nestedEnd) {
          depth--;
        } else if (!nestedSelfClosing) {
          depth++;
        }
      }
    }
    return xml.substring(start, pos);
  }

  /// Skips an XML comment at the cursor; returns false when the cursor is on
  /// a real tag that the caller must read.
  bool _skipCommentOrStep() {
    if (!xml.startsWith('<!--', pos)) return false;
    final int end = xml.indexOf('-->', pos + 4);
    if (end == -1) {
      throw FormatException('Unterminated comment in $source.');
    }
    pos = end + 3;
    return true;
  }
}

/// Parses the top-level `<dict>` entries of an XML plist.
List<PlistEntry> parsePlistEntries(String xml, {String source = '<memory>'}) {
  final int dictStart = xml.indexOf('<dict');
  if (dictStart == -1) {
    if (xml.contains('<dict/>')) return const [];
    throw FormatException('Plist $source does not contain a root <dict>.');
  }
  final int openEnd = xml.indexOf('>', dictStart);
  if (openEnd == -1) {
    throw FormatException('Malformed <dict> tag in $source.');
  }
  if (xml[openEnd - 1] == '/') {
    return const [];
  }

  final reader = _PlistReader(xml, source: source)..pos = openEnd + 1;
  final entries = <PlistEntry>[];
  while (true) {
    reader.skipTrivia();
    if (reader.pos >= xml.length) {
      throw FormatException('Root <dict> not closed in $source.');
    }
    final (String tagName, bool selfClosing, bool isEnd) = reader.readTag();
    if (isEnd) {
      if (tagName != 'dict') {
        throw FormatException('Unexpected </$tagName> in $source.');
      }
      return entries;
    }
    if (tagName != 'key' || selfClosing) {
      throw FormatException('Expected <key> in $source, found <$tagName>.');
    }
    entries.add(_readPlistEntry(xml, reader, source));
  }
}

PlistEntry _readPlistEntry(String xml, _PlistReader reader, String source) {
  final int keyClose = xml.indexOf('</key>', reader.pos);
  if (keyClose == -1) {
    throw FormatException('Unclosed <key> in $source.');
  }
  final String keyName = xml.substring(reader.pos, keyClose).trim();
  reader.pos = keyClose + '</key>'.length;
  reader.skipTrivia();
  final String valueXml = reader.readElement();
  return PlistEntry(keyName, valueXml);
}

/// Substitutes `$(VAR)` and `${VAR}` placeholders in [text] using [variables].
String substitutePlistVariables(String text, Map<String, String> variables) {
  return text.replaceAllMapped(
    RegExp(r'\$\(([A-Za-z0-9_]+)\)|\$\{([A-Za-z0-9_]+)\}'),
    (match) {
      final String name = match.group(1) ?? match.group(2)!;
      return variables[name] ?? '';
    },
  );
}

/// Escapes `&`, `<` and `>` in [text] for embedding in XML output.
String escapeXml(String text) => text
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');
