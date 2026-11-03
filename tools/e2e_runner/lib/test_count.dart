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

/// Converts a `file://` URI to a local filesystem path.
String? fileUriToPath(String uri) {
  if (!uri.startsWith('file://')) return null;
  return Uri.parse(uri).toFilePath();
}

/// The local paths of every file of the given [name] (`test.xml`, `test.log`)
/// named by a `testResult` event in the newline-delimited BEP stream.
List<String> outputPathsFromBep(String bepText, String name) {
  final paths = <String>[];
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
    if (event is! Map) continue;
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

/// Counts non-skipped test cases from the `test.xml` files [bepText] names.
///
/// When the BEP stream names no `test.xml` file, falls back to scanning
/// [testLogsDir] and [workspaceDir] for `*/test.xml` files, or counting
/// `<testcase>` elements directly from [bepText].
int countNonSkippedTests(
  String bepText, {
  required String testLogsDir,
  String? workspaceDir,
}) {
  var paths = testXmlPathsFromBep(bepText);
  if (paths.isEmpty) {
    paths = _fallbackTestXmlPaths(testLogsDir, workspaceDir);
  }
  final seenCanonical = <String>{};
  var total = 0;
  for (final path in paths) {
    final file = File(path);
    if (!file.existsSync()) continue;
    String canonical;
    try {
      canonical = file.resolveSymbolicLinksSync();
    } on FileSystemException {
      canonical = file.path;
    }
    if (seenCanonical.add(canonical)) {
      try {
        total += countNonSkippedTestcases(File(canonical).readAsStringSync());
      } on FileSystemException {
        // Ignored: unreadable test.xml file.
      }
    }
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
