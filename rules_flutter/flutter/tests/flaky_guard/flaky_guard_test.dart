/// Repo guard verifying that test retry attempts are pinned to 1 and cannot
/// hide flakes.
///
/// In rules_flutter, test retries paper over flaky tests instead of surfacing
/// defects. Gate 06 and Gate 11 require:
/// 1. Root `.bazelrc` pins `test --flaky_test_attempts=1` after importing
///    `tools/preset.bazelrc` and before `try-import %workspace%/.bazelrc.user`,
///    with a one-line comment explaining that retries hide flakes.
/// 2. `tools/preset.bazelrc` suppresses the generated retry preset
///    (`test:ci --flaky_test_attempts=2`).
/// 3. `tools/BUILD.bazel` passes `extra_presets = {"flaky_test_attempts": []}`
///    to `bazelrc_preset(name = "preset", ...)`.
///
/// Regenerate presets with `bazel run //tools:preset.update` and verify with
/// `bazel test //tools:preset.update_test`.
library;

import 'dart:io';

import 'package:test/test.dart';

/// Whether [root] is the rules_flutter workspace root.
bool _looksLikeRoot(String root) =>
    Directory('$root/flutter').existsSync() &&
    File('$root/MODULE.bazel').existsSync();

/// Resolves the rules_flutter workspace root directory.
String? _workspaceRoot() {
  final String? fromEnv = Platform.environment['BUILD_WORKSPACE_DIRECTORY'];
  if (fromEnv != null && fromEnv.isNotEmpty && _looksLikeRoot(fromEnv)) {
    return fromEnv;
  }
  final String? anchor = Platform.environment['GUARD_ROOT_ANCHOR'];
  final String? srcdir = Platform.environment['TEST_SRCDIR'];
  if (anchor != null && anchor.isNotEmpty && srcdir != null) {
    try {
      Directory dir = File(
        File('$srcdir/$anchor').resolveSymbolicLinksSync(),
      ).parent;
      for (var i = 0; i < 8; i++) {
        if (_looksLikeRoot(dir.path)) return dir.path;
        dir = dir.parent;
      }
    } on FileSystemException {
      // Fall through to fallback check when anchor fails to resolve.
    }
  }
  Directory dir = Directory.current;
  for (var i = 0; i < 8; i++) {
    if (_looksLikeRoot(dir.path)) return dir.path;
    dir = dir.parent;
  }
  return null;
}

/// A parsed flag entry for flaky_test_attempts from an rc file.
class _RcFlag {
  final int lineNumber;
  final int offset;
  final String rawLine;
  final int? attempts;

  const new({
    required this.lineNumber,
    required this.offset,
    required this.rawLine,
    required this.attempts,
  });
}

/// Strips inline and line comments from [text].
String _stripComments(String text) {
  final List<String> lines = text.split('\n');
  final result = <String>[];
  for (final line in lines) {
    final int idx = line.indexOf('#');
    result.add(idx >= 0 ? line.substring(0, idx) : line);
  }
  return result.join('\n');
}

/// Finds the index of the matching closing parenthesis for an opening
/// parenthesis at [openParenIdx] in [text], or -1 if unmatched.
int _findMatchingParen(String text, int openParenIdx) {
  var depth = 0;
  for (var i = openParenIdx; i < text.length; i++) {
    final String ch = text[i];
    if (ch == '(') depth++;
    if (ch == ')') {
      depth--;
      if (depth == 0) return i;
    }
  }
  return -1;
}

/// Parses all non-comment `--flaky_test_attempts` occurrences in [content].
List<_RcFlag> _parseFlakyFlags(String content) {
  final flags = <_RcFlag>[];
  final List<String> lines = content.split('\n');
  final pattern = RegExp(r'--flaky_test_attempts(?:=|\s+)(\S+)');
  var offset = 0;
  for (var i = 0; i < lines.length; i++) {
    final String raw = lines[i];
    final int commentIdx = raw.indexOf('#');
    final String code = (commentIdx >= 0 ? raw.substring(0, commentIdx) : raw)
        .trim();
    if (code.isNotEmpty && code.contains('--flaky_test_attempts')) {
      final RegExpMatch? match = pattern.firstMatch(code);
      int? attempts;
      if (match != null) {
        final String val = match
            .group(1)!
            .replaceAll('"', '')
            .replaceAll("'", '');
        attempts = int.tryParse(val);
      }
      flags.add(
        _RcFlag(
          lineNumber: i + 1,
          offset: offset,
          rawLine: raw,
          attempts: attempts,
        ),
      );
    }
    offset += raw.length + 1;
  }
  return flags;
}

/// Validates that root `.bazelrc` pins `test --flaky_test_attempts=1` and
/// does not set attempts to 2 or more (or anything other than 1).
List<String> _validateRootBazelrc(String text) {
  final errors = <String>[];
  final List<_RcFlag> flags = _parseFlakyFlags(text);

  if (flags.isEmpty) {
    errors.add('Root .bazelrc must pin test --flaky_test_attempts=1');
  }

  final RegExpMatch? presetMatch = RegExp(
    r'^[ \t]*import\s+%workspace%/tools/preset\.bazelrc',
    multiLine: true,
  ).firstMatch(text);
  if (presetMatch == null) {
    errors.add('Root .bazelrc missing import %workspace%/tools/preset.bazelrc');
  }

  final RegExpMatch? userMatch = RegExp(
    r'^[ \t]*try-import\s+%workspace%/\.bazelrc\.user',
    multiLine: true,
  ).firstMatch(text);

  final int presetIdx = presetMatch?.start ?? -1;
  final int userIdx = userMatch?.start ?? -1;

  var foundValidPin = false;
  for (final flag in flags) {
    if (flag.attempts == null || flag.attempts != 1) {
      errors.add(
        '.bazelrc:${flag.lineNumber}: flaky_test_attempts must be pinned to 1, '
        'found: ${flag.rawLine.trim()}',
      );
    }
    if (presetIdx != -1 && flag.offset < presetIdx) {
      errors.add(
        '.bazelrc:${flag.lineNumber}: flaky_test_attempts must appear after '
        'import %workspace%/tools/preset.bazelrc',
      );
    }
    if (userIdx != -1 && flag.offset > userIdx) {
      errors.add(
        '.bazelrc:${flag.lineNumber}: flaky_test_attempts must appear before '
        'try-import %workspace%/.bazelrc.user',
      );
    }

    final int commentIdx = flag.rawLine.indexOf('#');
    final String code =
        (commentIdx >= 0 ? flag.rawLine.substring(0, commentIdx) : flag.rawLine)
            .trim();
    if (RegExp(r'^[ \t]*test\s+(?:.*?\s+)?--flaky_test_attempts(?:=|\s+)1\b')
        .hasMatch(code)) {
      if (presetIdx != -1 && flag.offset > presetIdx) {
        if (userIdx == -1 || flag.offset < userIdx) {
          foundValidPin = true;
        }
      }
    }
  }

  if (!foundValidPin && flags.isNotEmpty) {
    errors.add(
      'Root .bazelrc missing valid pin: test --flaky_test_attempts=1 '
      'between preset import and user rc try-import',
    );
  }

  return errors;
}

/// Validates that `tools/preset.bazelrc` does not set flaky_test_attempts to
/// 2 or more.
List<String> _validatePresetBazelrc(String text) {
  final errors = <String>[];
  final List<_RcFlag> flags = _parseFlakyFlags(text);
  for (final flag in flags) {
    if (flag.attempts == null || flag.attempts! >= 2) {
      errors.add(
        'tools/preset.bazelrc:${flag.lineNumber}: preset sets flaky_test_attempts '
        'to ${flag.attempts ?? "invalid"} (>= 2). Regenerate with bazel run //tools:preset.update '
        'and verify with bazel test //tools:preset.update_test.',
      );
    }
  }
  return errors;
}

/// Validates that `tools/BUILD.bazel` passes the suppression to bazelrc_preset.
List<String> _validateToolsBuild(String text) {
  final errors = <String>[];
  final String stripped = _stripComments(text);
  final int callIdx = stripped.indexOf('bazelrc_preset(');
  if (callIdx == -1) {
    errors.add('tools/BUILD.bazel missing bazelrc_preset invocation');
    return errors;
  }

  final int openParenIdx = stripped.indexOf('(', callIdx);
  final int closeParenIdx = _findMatchingParen(stripped, openParenIdx);
  final String callBody = closeParenIdx != -1
      ? stripped.substring(openParenIdx + 1, closeParenIdx)
      : stripped.substring(openParenIdx + 1);

  final extraPresetRegex = RegExp(
    r'''extra_presets\s*=\s*\{[\s\S]*?['"]flaky_test_attempts['"]\s*:\s*\[\s*\][\s\S]*?\}''',
  );
  if (!extraPresetRegex.hasMatch(callBody)) {
    errors.add(
      'tools/BUILD.bazel must pass extra_presets = {"flaky_test_attempts": []} '
      'to bazelrc_preset to suppress dormant CI test retries. '
      'Regenerate preset with bazel run //tools:preset.update and verify with '
      'bazel test //tools:preset.update_test.',
    );
  }
  return errors;
}

void main() {
  final String? root = _workspaceRoot();
  if (root == null) {
    test('workspace root discovery', () {
      fail(
        'Could not locate rules_flutter workspace root; ensure GUARD_ROOT_ANCHOR '
        'or BUILD_WORKSPACE_DIRECTORY is set.',
      );
    });
    return;
  }

  final bazelrcFile = File('$root/.bazelrc');
  final presetFile = File('$root/tools/preset.bazelrc');
  final toolsBuildFile = File('$root/tools/BUILD.bazel');

  test('sanity: required repository files exist and are non-empty', () {
    expect(
      bazelrcFile.existsSync(),
      isTrue,
      reason: 'Root .bazelrc must exist at $root/.bazelrc',
    );
    expect(
      presetFile.existsSync(),
      isTrue,
      reason: 'Preset file must exist at $root/tools/preset.bazelrc',
    );
    expect(
      toolsBuildFile.existsSync(),
      isTrue,
      reason: 'Preset build file must exist at $root/tools/BUILD.bazel',
    );
    expect(bazelrcFile.readAsStringSync().trim(), isNotEmpty);
    expect(presetFile.readAsStringSync().trim(), isNotEmpty);
    expect(toolsBuildFile.readAsStringSync().trim(), isNotEmpty);
  });

  test('root .bazelrc pins flaky_test_attempts=1 without retries', () {
    final String text = bazelrcFile.readAsStringSync();
    final List<String> errors = _validateRootBazelrc(text);
    expect(errors, isEmpty, reason: errors.join('\n'));
  });

  test('tools/preset.bazelrc has no flaky_test_attempts >= 2', () {
    final String text = presetFile.readAsStringSync();
    final List<String> errors = _validatePresetBazelrc(text);
    expect(errors, isEmpty, reason: errors.join('\n'));
  });

  test(
    'tools/BUILD.bazel suppresses flaky_test_attempts in bazelrc_preset',
    () {
      final String text = toolsBuildFile.readAsStringSync();
      final List<String> errors = _validateToolsBuild(text);
      expect(errors, isEmpty, reason: errors.join('\n'));
    },
  );
}
