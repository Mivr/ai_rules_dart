/// `MODULE.bazel` parsing for the Maven pin guard.
///
/// Extracts every `<ext>.install(...)` block on a `rules_jvm_external` `maven`
/// extension receiver, groups the blocks by install name, and collects the
/// coordinates each install declares (inline `artifacts = [...]` entries and
/// standalone `<ext>.artifact(...)` tags).
library;

/// One coordinate declared in `MODULE.bazel`.
///
/// Missing parts are empty strings; `text` is the display form used in
/// error messages.
typedef DeclaredCoordinate = ({
  String group,
  String artifact,
  String version,
  String text,
});

/// All `maven.install` blocks sharing one install name, plus the coordinates
/// declared for that name.
///
/// `name` is `maven` when unnamed, `lockFiles` holds the `lock_file` of every
/// block (empty when a block has none), and `coordinates` the entries of
/// `artifacts = [...]` and the matching `artifact` tags.
typedef MavenInstall = ({
  String name,
  List<String> lockFiles,
  List<DeclaredCoordinate> coordinates,
});

final RegExp _mavenExtPattern = RegExp(
  r'''(\w+)\s*=\s*use_extension\([^)]*(['"])maven\2''',
);
final RegExp _quotedStringPattern = RegExp(r'''(['"])([^'"]*)\1''');

/// The install name used when a tag has no `name` attribute.
const String defaultInstallName = 'maven';

typedef _ScanState = ({String? quote, bool escaped});

_ScanState _stepScan(_ScanState state, String ch) {
  if (state.escaped) return (quote: state.quote, escaped: false);
  if (state.quote != null) {
    if (ch == r'\') return (quote: state.quote, escaped: true);
    if (ch == state.quote) return (quote: null, escaped: false);
    return state;
  }
  if (ch == '"' || ch == "'") return (quote: ch, escaped: false);
  return state;
}

String _stripLineComment(String line) {
  _ScanState state = (quote: null, escaped: false);
  for (var i = 0; i < line.length; i++) {
    final String ch = line[i];
    if (state.quote == null && ch == '#') {
      return line.substring(0, i);
    }
    state = _stepScan(state, ch);
  }
  return line;
}

/// Drops `#` comments outside single- or double-quoted string literals.
String stripComments(String text) =>
    text.split('\n').map(_stripLineComment).join('\n');

int _findMatchingClose(
  String text,
  int openIndex,
  String openChar,
  String closeChar,
) {
  var depth = 0;
  _ScanState state = (quote: null, escaped: false);
  for (var i = openIndex; i < text.length; i++) {
    final String ch = text[i];
    if (state.quote == null) {
      if (ch == openChar) {
        depth++;
      } else if (ch == closeChar) {
        depth--;
        if (depth == 0) return i;
      }
    }
    state = _stepScan(state, ch);
  }
  return -1;
}

/// Drops everything nested more than one bracket deep, so attribute lookups
/// only see the call's own keyword arguments.
String _flattenNested(String call) {
  final out = StringBuffer();
  var depth = 0;
  _ScanState state = (quote: null, escaped: false);
  for (var i = 0; i < call.length; i++) {
    final String ch = call[i];
    final outsideString = state.quote == null;
    if (outsideString && '([{'.contains(ch)) {
      depth++;
      if (depth == 1) out.write(ch);
    } else if (outsideString && ')]}'.contains(ch)) {
      if (depth == 1) out.write(ch);
      depth--;
    } else if (depth <= 1) {
      out.write(ch);
    }
    state = _stepScan(state, ch);
  }
  return out.toString();
}

String? _stringAttr(String flatCall, String attr) {
  final pattern = RegExp('\\b$attr\\s*=\\s*([\'"])([^\'"]*)\\1');
  return pattern.firstMatch(flatCall)?.group(2);
}

Set<String> _findMavenExtensionNames(String cleanText) {
  final names = <String>{defaultInstallName};
  for (final RegExpMatch match in _mavenExtPattern.allMatches(cleanText)) {
    names.add(match.group(1)!);
  }
  return names;
}

List<String> _extractMethodBlocks(
  String cleanText,
  Set<String> receivers,
  String method,
) {
  final pattern = RegExp(
    '\\b(?:${receivers.join('|')})\\s*\\.\\s*$method\\s*\\(',
  );
  final blocks = <String>[];
  var searchFrom = 0;
  while (searchFrom < cleanText.length) {
    final RegExpMatch? match = pattern.firstMatch(
      cleanText.substring(searchFrom),
    );
    if (match == null) break;
    final int callStart = searchFrom + match.start;
    final int openParen = searchFrom + match.end - 1;
    final int closeParen = _findMatchingClose(cleanText, openParen, '(', ')');
    if (closeParen == -1) break;
    blocks.add(cleanText.substring(callStart, closeParen + 1));
    searchFrom = closeParen + 1;
  }
  return blocks;
}

DeclaredCoordinate _coordinateFromTag(String tagBlock) {
  final String flat = _flattenNested(tagBlock);
  final String group = _stringAttr(flat, 'group') ?? '';
  final String artifact = _stringAttr(flat, 'artifact') ?? '';
  final String version = _stringAttr(flat, 'version') ?? '';
  final String text = <String>[
    group,
    artifact,
    version,
  ].where((String part) => part.isNotEmpty).join(':');
  return (group: group, artifact: artifact, version: version, text: text);
}

DeclaredCoordinate _coordinateFromString(String coordinate) {
  final List<String> parts = coordinate.split(':');
  final bool complete =
      parts.length >= 3 && parts.every((String part) => part.isNotEmpty);
  return (
    group: parts.isNotEmpty ? parts[0] : '',
    artifact: parts.length >= 2 ? parts[1] : '',
    version: complete ? parts.last : '',
    text: coordinate,
  );
}

List<DeclaredCoordinate> _parseArtifactsAttribute(
  String installBlock,
  Set<String> exts,
) {
  final coords = <DeclaredCoordinate>[];
  final RegExpMatch? firstMatch = RegExp(
    r'\bartifacts\s*=\s*\[',
  ).firstMatch(installBlock);
  if (firstMatch == null) return coords;

  int listOpen = firstMatch.end - 1;
  final plusNextList = RegExp(r'^\s*\+\s*\[');
  while (listOpen >= 0 && listOpen < installBlock.length) {
    final int listClose = _findMatchingClose(installBlock, listOpen, '[', ']');
    if (listClose == -1) break;
    String body = installBlock.substring(listOpen + 1, listClose);
    for (final String tag in _extractMethodBlocks(body, exts, 'artifact')) {
      coords.add(_coordinateFromTag(tag));
      body = body.replaceFirst(tag, '');
    }
    for (final RegExpMatch m in _quotedStringPattern.allMatches(body)) {
      coords.add(_coordinateFromString(m.group(2)!));
    }
    final RegExpMatch? next = plusNextList.firstMatch(
      installBlock.substring(listClose + 1),
    );
    if (next == null) break;
    listOpen = listClose + 1 + next.end - 1;
  }
  return coords;
}

/// Parses every `maven.install` in [moduleContent], grouped by install name
/// in declaration order. Empty when the module declares none.
List<MavenInstall> parseMavenInstalls(String moduleContent) {
  final String clean = stripComments(moduleContent);
  final Set<String> exts = _findMavenExtensionNames(clean);
  final installs = <String, MavenInstall>{};
  final List<String> installBlocks = _extractMethodBlocks(
    clean,
    exts,
    'install',
  );

  for (final block in installBlocks) {
    final String flat = _flattenNested(block);
    final String name = _stringAttr(flat, 'name') ?? defaultInstallName;
    final MavenInstall install = installs.putIfAbsent(
      name,
      () => (
        name: name,
        lockFiles: <String>[],
        coordinates: <DeclaredCoordinate>[],
      ),
    );
    install.lockFiles.add(_stringAttr(flat, 'lock_file') ?? '');
    install.coordinates.addAll(_parseArtifactsAttribute(block, exts));
  }

  var outsideInstalls = clean;
  for (final block in installBlocks) {
    outsideInstalls = outsideInstalls.replaceFirst(block, '');
  }
  for (final String tag in _extractMethodBlocks(
    outsideInstalls,
    exts,
    'artifact',
  )) {
    final String name =
        _stringAttr(_flattenNested(tag), 'name') ?? defaultInstallName;
    installs[name]?.coordinates.add(_coordinateFromTag(tag));
  }
  return installs.values.toList();
}
