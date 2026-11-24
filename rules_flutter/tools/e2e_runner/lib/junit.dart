/// BEP (`--build_event_json_file`) and JUnit `test.xml` / `test.log` readers.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

typedef _XmlTag = ({
  String name,
  bool isClosing,
  bool isSelfClosing,
  int end,
});

/// Extracted test artifacts referenced by a Bazel Build Event Protocol file.
typedef BepTestArtifacts = ({
  List<String> xmlFiles,
  List<String> inlineXmls,
  List<String> logFiles,
});

/// Summary of `<testcase>` counts for a single `bazel test` invocation.
typedef TestCaseCount = ({
  int total,
  int executed,
  String source,
});

/// Counts total and non-skipped `<testcase>` elements in [xmlContent].
///
/// Every `<testcase>` element contributes `1` to `total`, and `1` to
/// `executed` unless it carries a direct `<skipped>` child element.
({int total, int executed}) countExecutedTestsInXml(String xmlContent) {
  var total = 0;
  var executed = 0;
  var cursor = 0;
  while (cursor < xmlContent.length) {
    final _XmlTag? tag = _readNextXmlTag(xmlContent, cursor);
    if (tag == null) break;
    cursor = tag.end;
    if (tag.isClosing || tag.name != 'testcase') continue;
    total++;
    if (tag.isSelfClosing) {
      executed++;
      continue;
    }
    final ({bool skipped, int end}) body = _consumeTestcaseBody(
      xmlContent,
      cursor,
    );
    cursor = body.end;
    if (!body.skipped) {
      executed++;
    }
  }
  return (total: total, executed: executed);
}

({bool skipped, int end}) _consumeTestcaseBody(String xml, int start) {
  var depth = 1;
  var skipped = false;
  var cursor = start;
  while (cursor < xml.length && depth > 0) {
    final _XmlTag? tag = _readNextXmlTag(xml, cursor);
    if (tag == null) {
      return (skipped: skipped, end: xml.length);
    }
    cursor = tag.end;
    if (tag.isClosing) {
      if (tag.name == 'testcase' && depth == 1) {
        return (skipped: skipped, end: cursor);
      }
      if (depth > 1) depth--;
      continue;
    }
    if (depth == 1 && tag.name == 'skipped') {
      skipped = true;
    }
    if (!tag.isSelfClosing) {
      depth++;
    }
  }
  return (skipped: skipped, end: cursor);
}

_XmlTag? _readNextXmlTag(String xml, int start) {
  var i = start;
  while (i < xml.length) {
    final int lt = xml.indexOf('<', i);
    if (lt < 0 || lt + 1 >= xml.length) return null;
    final int? skippedEnd = _skipXmlSpecialConstruct(xml, lt);
    if (skippedEnd != null) {
      i = skippedEnd;
      continue;
    }
    final int gt = _findTagClose(xml, lt + 1);
    if (gt < 0) return null;
    final _XmlTag? parsed = _parseSimpleTag(xml, lt: lt, gt: gt);
    if (parsed != null) return parsed;
    i = gt + 1;
  }
  return null;
}

int? _skipXmlSpecialConstruct(String xml, int lt) {
  if (xml.startsWith('<!--', lt)) {
    final int close = xml.indexOf('-->', lt + 4);
    return close < 0 ? xml.length : close + 3;
  }
  if (xml.startsWith('<![CDATA[', lt)) {
    final int close = xml.indexOf(']]>', lt + 9);
    return close < 0 ? xml.length : close + 3;
  }
  if (xml.startsWith('<?', lt)) {
    final int close = xml.indexOf('?>', lt + 2);
    return close < 0 ? xml.length : close + 2;
  }
  if (xml.startsWith('<!', lt)) {
    final int close = _findTagClose(xml, lt + 2);
    return close < 0 ? xml.length : close + 1;
  }
  return null;
}

int _findTagClose(String xml, int start) {
  String? quote;
  for (var i = start; i < xml.length; i++) {
    final String ch = xml[i];
    if (quote != null) {
      if (ch == quote) quote = null;
      continue;
    }
    if (ch == '"' || ch == "'") {
      quote = ch;
      continue;
    }
    if (ch == '>') return i;
  }
  return -1;
}

_XmlTag? _parseSimpleTag(String xml, {required int lt, required int gt}) {
  int pos = lt + 1;
  var isClosing = false;
  if (pos < gt && xml[pos] == '/') {
    isClosing = true;
    pos++;
  }
  final nameStart = pos;
  while (pos < gt && !_isXmlTagDelimiter(xml[pos])) {
    pos++;
  }
  if (pos == nameStart) return null;
  final String name = xml.substring(nameStart, pos);
  int slashCheck = gt - 1;
  while (slashCheck > pos && xml[slashCheck].trim().isEmpty) {
    slashCheck--;
  }
  final bool isSelfClosing = !isClosing && xml[slashCheck] == '/';
  return (
    name: name,
    isClosing: isClosing,
    isSelfClosing: isSelfClosing,
    end: gt + 1,
  );
}

bool _isXmlTagDelimiter(String ch) =>
    ch == '/' || ch == '>' || ch.trim().isEmpty;

class _BepAccumulator {
  final List<String> xmlFiles = <String>[];
  final Set<String> seenXml = <String>{};
  final List<String> inlineXmls = <String>[];
  final List<String> logFiles = <String>[];
  final Set<String> seenLogs = <String>{};
}

class _FileWalkState {
  new(this.fileName);

  final String fileName;
  final List<String> found = <String>[];
  final Set<String> seenFiles = <String>{};
  final Set<String> visitedDirs = <String>{};
}

/// Parses a Bazel BEP JSON file at [bepJsonPath] and collects referenced
/// `test.xml` and `test.log` outputs.
BepTestArtifacts extractBepTestArtifacts(String bepJsonPath) {
  final file = File(bepJsonPath);
  if (!file.existsSync()) {
    return (xmlFiles: const [], inlineXmls: const [], logFiles: const []);
  }
  final String rawContent = file.readAsStringSync();
  final acc = _BepAccumulator();
  var parsedAnyJson = false;
  for (final String line in const LineSplitter().convert(rawContent)) {
    final String trimmed = line.trim();
    if (trimmed.isEmpty) continue;
    final Object? decoded = _tryDecodeJsonObject(trimmed);
    if (decoded is! Map<String, Object?>) continue;
    parsedAnyJson = true;
    _collectOutputsFromBepEvent(decoded, acc);
  }
  if (!parsedAnyJson && rawContent.contains('<testcase')) {
    acc.inlineXmls.add(rawContent);
  }
  return (
    xmlFiles: acc.xmlFiles,
    inlineXmls: acc.inlineXmls,
    logFiles: acc.logFiles,
  );
}

Object? _tryDecodeJsonObject(String line) {
  try {
    return jsonDecode(line);
  } on FormatException {
    // Non-JSON line (for example truncated trailing output or raw XML fixture).
    return null;
  }
}

void _collectOutputsFromBepEvent(
  Map<String, Object?> event,
  _BepAccumulator acc,
) {
  final Object? testResult = event['testResult'];
  if (testResult is! Map<String, Object?>) return;
  final Object? outputs = testResult['testActionOutput'];
  if (outputs is! List<Object?>) return;
  for (final Object? entry in outputs) {
    if (entry is! Map<String, Object?>) continue;
    final Object? name = entry['name'];
    if (name is! String) continue;
    final bool isXml = name == 'test.xml' || name.endsWith('/test.xml');
    final bool isLog = name == 'test.log' || name.endsWith('/test.log');
    if (!isXml && !isLog) continue;
    final String? filePath = _resolveBepEntryPath(entry['uri']);
    if (filePath != null) {
      if (isXml && acc.seenXml.add(filePath)) acc.xmlFiles.add(filePath);
      if (isLog && acc.seenLogs.add(filePath)) acc.logFiles.add(filePath);
      continue;
    }
    final String? inline = _decodeInlineBepContents(entry['contents']);
    if (inline != null && isXml) {
      acc.inlineXmls.add(inline);
    }
  }
}

String? _resolveBepEntryPath(Object? rawUri) {
  if (rawUri is! String || rawUri.isEmpty) return null;
  if (rawUri.startsWith('file:')) {
    return Uri.parse(rawUri).toFilePath();
  }
  return rawUri;
}

String? _decodeInlineBepContents(Object? rawContents) {
  if (rawContents is! String || rawContents.isEmpty) return null;
  if (rawContents.trimLeft().startsWith('<')) return rawContents;
  try {
    return utf8.decode(base64.decode(rawContents), allowMalformed: true);
  } on FormatException {
    // Fallback to literal text when synthetic fixtures pass unencoded strings.
    return rawContents;
  }
}

/// Counts `<testcase>` elements from [bepJsonPath], falling back to JUnit
/// `test.xml` files under [stagedWorkspace] and [scratchOutputBase] when BEP
/// names no test.
TestCaseCount countCommandTestCases({
  required String? bepJsonPath,
  required String stagedWorkspace,
  required String scratchOutputBase,
}) {
  if (bepJsonPath != null) {
    final BepTestArtifacts bep = extractBepTestArtifacts(bepJsonPath);
    var bepTotal = 0;
    var bepExecuted = 0;
    for (final String inline in bep.inlineXmls) {
      final ({int total, int executed}) c = countExecutedTestsInXml(inline);
      bepTotal += c.total;
      bepExecuted += c.executed;
    }
    for (final String xmlPath in bep.xmlFiles) {
      final file = File(xmlPath);
      if (!file.existsSync()) continue;
      final ({int total, int executed}) c = countExecutedTestsInXml(
        file.readAsStringSync(),
      );
      bepTotal += c.total;
      bepExecuted += c.executed;
    }
    if (bepTotal > 0) {
      return (total: bepTotal, executed: bepExecuted, source: 'BEP');
    }
  }
  final List<String> fallbackXmls = findWorkspaceFilesByName(
    fileName: 'test.xml',
    stagedWorkspace: stagedWorkspace,
    scratchOutputBase: scratchOutputBase,
  );
  var fbTotal = 0;
  var fbExecuted = 0;
  for (final xmlPath in fallbackXmls) {
    final ({int total, int executed}) c = countExecutedTestsInXml(
      File(xmlPath).readAsStringSync(),
    );
    fbTotal += c.total;
    fbExecuted += c.executed;
  }
  return (total: fbTotal, executed: fbExecuted, source: 'JUnit test.xml');
}

/// Reads concatenated JUnit `test.xml` text from [bepJsonPath] (`inlineXmls`
/// and `xmlFiles`), or falls back to `test.xml` files in [stagedWorkspace] and
/// [scratchOutputBase] only when BEP yields none.
String collectCommandTestXml({
  required String? bepJsonPath,
  required String stagedWorkspace,
  required String scratchOutputBase,
}) {
  final buffer = StringBuffer();
  if (bepJsonPath != null) {
    final BepTestArtifacts bep = extractBepTestArtifacts(bepJsonPath);
    var foundAny = false;
    for (final String inline in bep.inlineXmls) {
      foundAny = true;
      buffer.writeln(inline);
    }
    for (final String xmlPath in bep.xmlFiles) {
      final file = File(xmlPath);
      if (!file.existsSync()) continue;
      foundAny = true;
      buffer.writeln(file.readAsStringSync());
    }
    if (foundAny) return buffer.toString();
  }
  for (final String xmlPath in findWorkspaceFilesByName(
    fileName: 'test.xml',
    stagedWorkspace: stagedWorkspace,
    scratchOutputBase: scratchOutputBase,
  )) {
    buffer.writeln(File(xmlPath).readAsStringSync());
  }
  return buffer.toString();
}

/// Reads concatenated `test.log` outputs from [bepJsonPath], or falls back to
/// `test.log` files in [stagedWorkspace] and [scratchOutputBase].
String collectCommandTestLogs({
  required String? bepJsonPath,
  required String stagedWorkspace,
  required String scratchOutputBase,
}) {
  final buffer = StringBuffer();
  if (bepJsonPath != null) {
    final BepTestArtifacts bep = extractBepTestArtifacts(bepJsonPath);
    var foundAny = false;
    for (final String logPath in bep.logFiles) {
      final file = File(logPath);
      if (!file.existsSync()) continue;
      foundAny = true;
      buffer.writeln(file.readAsStringSync());
    }
    if (foundAny) return buffer.toString();
  }
  final List<String> fallbackLogs = findWorkspaceFilesByName(
    fileName: 'test.log',
    stagedWorkspace: stagedWorkspace,
    scratchOutputBase: scratchOutputBase,
  );
  for (final logPath in fallbackLogs) {
    buffer.writeln(File(logPath).readAsStringSync());
  }
  return buffer.toString();
}

/// Finds all files named [fileName] under [stagedWorkspace] and
/// `<scratchOutputBase>/execroot`, deduplicated by canonical resolved path.
List<String> findWorkspaceFilesByName({
  required String fileName,
  required String stagedWorkspace,
  required String scratchOutputBase,
}) {
  final state = _FileWalkState(fileName);
  _walkForFileName(Directory(stagedWorkspace), state);
  _walkForFileName(Directory(p.join(scratchOutputBase, 'execroot')), state);
  state.found.sort();
  return state.found;
}

void _walkForFileName(Directory dir, _FileWalkState state) {
  if (!dir.existsSync()) return;
  final String? realDir = _tryResolveLinks(dir.path);
  if (realDir == null || !state.visitedDirs.add(realDir)) return;
  final List<FileSystemEntity> entries;
  try {
    entries = dir.listSync(followLinks: false);
  } on FileSystemException {
    // Unreadable or vanished transient Bazel directory; skip safely.
    return;
  }
  for (final entry in entries) {
    final FileSystemEntityType type = FileSystemEntity.typeSync(entry.path);
    if (type == FileSystemEntityType.directory) {
      _walkForFileName(Directory(entry.path), state);
    } else if (type == FileSystemEntityType.file &&
        p.basename(entry.path) == state.fileName) {
      final String? realFile = _tryResolveLinks(entry.path);
      if (realFile != null && state.seenFiles.add(realFile)) {
        state.found.add(realFile);
      }
    }
  }
}

String? _tryResolveLinks(String path) {
  try {
    return FileSystemEntity.isDirectorySync(path)
        ? Directory(path).resolveSymbolicLinksSync()
        : File(path).resolveSymbolicLinksSync();
  } on FileSystemException {
    // Dangling symlink (such as bazel-testlogs when no tests ran); ignore.
    return null;
  }
}
