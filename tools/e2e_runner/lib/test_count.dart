/// Counts executed (non-skipped) test cases from Bazel's build event
/// protocol and from JUnit `test.xml` files.
///
/// The count the runner compares against `min_tests_executed` comes from the
/// `<testcase>` elements Bazel reports: primarily from the `test.xml` files a
/// `--build_event_json_file` stream names, and — when that stream names no
/// test — from the workspace's `test.xml` files directly. `<testcase>`
/// elements carrying a `<skipped>` child are not executed and do not count.
library;

import 'dart:convert';
import 'dart:io';

final RegExp _testcase = RegExp(
  r'<testcase\b(?:"[^"]*"|'
  "'"
  r"[^']*'"
  r'|[^>/]|/(?!>))*(?:/>|>.*?</testcase>)',
  dotAll: true,
);
final RegExp _skippedAttr = RegExp(
  r'''\b(?:status|result)\s*=\s*['"]skipped['"]''',
);
final RegExp _skippedChild = RegExp(r'<skipped\b');

/// The number of `<testcase>` elements without a `<skipped>` child in [xml].
int countNonSkippedTestcases(String xml) {
  var count = 0;
  for (final match in _testcase.allMatches(xml)) {
    final text = match.group(0)!;
    final openEnd = text.indexOf('>');
    final header = openEnd >= 0 ? text.substring(0, openEnd + 1) : text;
    final body = openEnd >= 0 && !text.endsWith('/>')
        ? text.substring(openEnd + 1)
        : '';
    if (_skippedAttr.hasMatch(header) || _skippedChild.hasMatch(body)) {
      continue;
    }
    count++;
  }
  return count;
}

final RegExp _twoSlashDriveUri = RegExp(r'^file://([A-Za-z]:[/\\].*)$');

/// Converts a `file://` URI to a local filesystem path.
String? fileUriToPath(String uri, {bool? windows}) {
  if (!uri.startsWith('file://')) return null;
  final isWindows = windows ?? Platform.isWindows;
  final driveMatch = _twoSlashDriveUri.firstMatch(uri);
  final normalized = driveMatch != null
      ? 'file:///${driveMatch.group(1)!.replaceAll(r'\', '/')}'
      : uri.replaceAll(r'\', '/');
  final parsed = Uri.tryParse(normalized);
  if (parsed == null ||
      parsed.scheme != 'file' ||
      parsed.hasQuery ||
      parsed.hasFragment ||
      (!isWindows && parsed.authority.isNotEmpty)) {
    return null;
  }
  return parsed.toFilePath(windows: isWindows);
}

Iterable<Map<Object?, Object?>> _bepEvents(String bepText) sync* {
  for (final line in const LineSplitter().convert(bepText)) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;
    final Object? event;
    try {
      event = jsonDecode(trimmed);
    } on FormatException {
      // Malformed BEP line; skip.
      continue;
    }
    if (event is Map) yield event;
  }
}

/// Whether any BEP `testResult` or `testSummary` event recorded a `TIMEOUT`.
bool hasTimedOutTestInBep(String bepText) {
  for (final event in _bepEvents(bepText)) {
    final result = event['testResult'];
    if (result is Map && result['status'] == 'TIMEOUT') return true;
    final summary = event['testSummary'];
    if (summary is Map && summary['overallStatus'] == 'TIMEOUT') return true;
  }
  return false;
}

/// The local paths of every file of the given [name] (`test.xml`, `test.log`)
/// named by a `testResult` event in the newline-delimited BEP stream.
List<String> outputPathsFromBep(String bepText, String name) {
  final paths = <String>[];
  for (final event in _bepEvents(bepText)) {
    final result = event['testResult'];
    if (result is! Map) continue;
    final outputs = result['testActionOutput'];
    if (outputs is! List) continue;
    for (final output in outputs) {
      if (output is! Map || output['name'] != name) continue;
      final path = fileUriToPath('${output['uri']}');
      if (path != null) paths.add(path);
    }
  }
  return paths;
}

/// The local paths of every `test.xml` file a `testResult` event names.
List<String> testXmlPathsFromBep(String bepText) =>
    outputPathsFromBep(bepText, 'test.xml');

/// The distinct, readable `test.xml` contents [bepText] names.
///
/// When the BEP stream names no `test.xml` file, falls back to scanning
/// [testLogsDir] and [workspaceDir] for `*/test.xml` files.
List<String> readTestXmlFiles(
  String bepText, {
  required String testLogsDir,
  String? workspaceDir,
}) {
  var paths = testXmlPathsFromBep(bepText);
  if (paths.isEmpty) {
    paths = _fallbackTestXmlPaths(testLogsDir, workspaceDir);
  }
  final seenCanonical = <String>{};
  final contents = <String>[];
  for (final path in paths) {
    final file = File(path);
    if (!file.existsSync()) continue;
    String canonical;
    try {
      canonical = file.resolveSymbolicLinksSync();
    } on FileSystemException {
      canonical = file.path;
    }
    if (!seenCanonical.add(canonical)) continue;
    try {
      contents.add(File(canonical).readAsStringSync());
    } on FileSystemException {
      // Ignored: unreadable test.xml file.
    }
  }
  return contents;
}

/// Counts non-skipped test cases from the `test.xml` files [bepText] names,
/// or from `<testcase>` elements in [bepText] itself when no file has any.
int countNonSkippedTests(
  String bepText, {
  required String testLogsDir,
  String? workspaceDir,
}) {
  var total = 0;
  for (final xml in readTestXmlFiles(
    bepText,
    testLogsDir: testLogsDir,
    workspaceDir: workspaceDir,
  )) {
    total += countNonSkippedTestcases(xml);
  }
  if (total == 0 && bepText.contains('<testcase')) {
    total = countNonSkippedTestcases(bepText);
  }
  return total;
}

List<String> _fallbackTestXmlPaths(String testLogsDir, String? workspaceDir) {
  final paths = <String>[..._testXmlFilesUnder(testLogsDir)];
  if (workspaceDir == null) return paths;
  paths.addAll(_testXmlFilesUnder(workspaceDir));
  final bazelLogs = Directory('$workspaceDir/bazel-testlogs');
  if (bazelLogs.existsSync()) {
    try {
      paths.addAll(_testXmlFilesUnder(bazelLogs.resolveSymbolicLinksSync()));
    } on FileSystemException {
      // Ignored: dangling bazel-testlogs link.
    }
  }
  return paths;
}

List<String> _testXmlFilesUnder(String dirPath) {
  final dir = Directory(dirPath);
  if (!dir.existsSync()) return const [];
  final result = <String>[];
  try {
    for (final entry in dir.listSync(recursive: true, followLinks: false)) {
      if (entry is File && entry.path.endsWith('test.xml')) {
        result.add(entry.path);
      }
    }
  } on FileSystemException catch (e) {
    stderr.writeln('test.xml scan skipped ($dirPath): ${e.message}');
  }
  return result;
}
