/// Guard: `e2e/min_versions`' Android leg stays Linux-only.
///
/// The floor workspace builds `//:app_android` against a pinned Linux NDK. On
/// macOS the NDK repository is empty and no C++ toolchain is registered, so
/// the leg must report itself incompatible there instead of failing analysis.
/// This test reads `e2e/min_versions/BUILD.bazel` and fails unless
/// `android_build_test` still builds `:app_android` and is compatible with
/// exactly `@platforms//os:linux`; Linux therefore still builds the leg while
/// macOS skips it. Like the other static guards it reads an undetected file
/// from the workspace root, so it is tagged `external` and never replays a
/// cached pass.
library;

import 'dart:io';

import 'package:test/test.dart';

/// Whether [root] is the rules_flutter workspace root.
bool _looksLikeRoot(String root) =>
    File('$root/e2e/min_versions/BUILD.bazel').existsSync();

/// Workspace root: `BUILD_WORKSPACE_DIRECTORY` when set, otherwise the source
/// tree behind the test's own anchor in `data`. Null when neither resolves, so
/// the test fails loudly instead of reading another tree.
String? _workspaceRoot() {
  final Map<String, String> env = Platform.environment;
  final String? fromEnv = env['BUILD_WORKSPACE_DIRECTORY'];
  if (fromEnv != null && _looksLikeRoot(fromEnv)) return fromEnv;
  final String? anchor = env['GUARD_ROOT_ANCHOR'];
  final String? srcdir = env['TEST_SRCDIR'];
  if (anchor == null || srcdir == null) return null;
  final String source = File('$srcdir/$anchor').resolveSymbolicLinksSync();
  Directory dir = File(source).parent;
  for (var i = 0; i < 8; i++) {
    if (_looksLikeRoot(dir.path)) return dir.path;
    dir = dir.parent;
  }
  return null;
}

/// [text] with every `#` comment replaced by spaces, keeping string literals
/// and newlines so a commented-out attribute cannot satisfy the guard.
String _withoutComments(String text) {
  final out = StringBuffer();
  String? quote;
  for (var i = 0; i < text.length; i++) {
    final String ch = text[i];
    if (quote != null) {
      out.write(ch);
      if (ch == r'\' && i + 1 < text.length) {
        out.write(text[++i]);
      } else if (ch == quote) {
        quote = null;
      }
      continue;
    }
    if (ch == '#') {
      while (i < text.length && text[i] != '\n') {
        out.write(' ');
        i++;
      }
      if (i < text.length) out.write('\n');
      continue;
    }
    if (ch == '"' || ch == "'") quote = ch;
    out.write(ch);
  }
  return out.toString();
}

/// The text of the call whose opening `(` is at [open], with nested brackets
/// and string literals skipped so a `)` inside an attribute cannot end it
/// early. Null when the text ends inside the call.
String? _callText(String text, int open) {
  String? quote;
  var depth = 0;
  for (var i = open; i < text.length; i++) {
    final String ch = text[i];
    if (quote != null) {
      if (ch == r'\') {
        i++;
      } else if (text.startsWith(quote, i)) {
        i += quote.length - 1;
        quote = null;
      }
      continue;
    }
    if (ch == '#') {
      while (i < text.length && text[i] != '\n') {
        i++;
      }
      continue;
    }
    if (ch == '"' || ch == "'") {
      quote = text.startsWith('$ch$ch$ch', i) ? '$ch$ch$ch' : ch;
      i += quote.length - 1;
    } else if (ch == '(' || ch == '[' || ch == '{') {
      depth++;
    } else if (ch == ')' || ch == ']' || ch == '}') {
      depth--;
      if (depth == 0) return text.substring(open, i + 1);
    }
  }
  return null;
}

/// The single `build_test` call naming [target], or null when it is absent or
/// named more than once.
String? _targetBlock(String text, String target) {
  String? block;
  final names = RegExp(r'''\bname\s*=\s*(["'])(.*?)\1''');
  for (final RegExpMatch match in RegExp(
    r'\bbuild_test\s*\(',
  ).allMatches(text)) {
    final String? call = _callText(text, match.end - 1);
    if (call == null) continue;
    final List<RegExpMatch> found = names.allMatches(call).toList();
    if (found.length != 1 || found.single.group(2) != target) continue;
    if (block != null) return null;
    block = call;
  }
  return block;
}

/// String elements of the list-valued attribute [attribute] in [block].
List<String> _strings(String block, String attribute) {
  final RegExpMatch? match = RegExp(
    '\\b$attribute\\s*=\\s*\\[([^\\]]*)\\]',
  ).firstMatch(block);
  if (match == null) return <String>[];
  return RegExp(
    r'''(["'])(.*?)\1''',
  ).allMatches(match.group(1)!).map((item) => item.group(2)!).toList();
}

void main() {
  const path = 'e2e/min_versions/BUILD.bazel';
  const target = 'android_build_test';
  final String? root = _workspaceRoot();
  if (root == null) {
    test('the workspace root is discoverable', () {
      fail(
        '$path: cannot find the rules_flutter workspace root; run this test '
        'unsandboxed through bazel test //flutter/tests/...',
      );
    });
    return;
  }
  test('$target builds :app_android on Linux only', () {
    final String text = _withoutComments(
      File('$root/$path').readAsStringSync(),
    );
    final String? block = _targetBlock(text, target);
    if (block == null) {
      fail('$path: no single build_test target named $target');
    }
    final List<String> targets = _strings(block, 'targets');
    if (targets.length != 1 || targets.single != ':app_android') {
      fail(
        '$path: $target targets $targets, expected exactly [":app_android"]',
      );
    }
    final List<String> compatible = _strings(block, 'target_compatible_with');
    if (compatible.length != 1 || compatible.single != '@platforms//os:linux') {
      fail(
        '$path: $target target_compatible_with is $compatible, expected '
        'exactly ["@platforms//os:linux"]',
      );
    }
    if (_strings(block, 'tags').contains('manual')) {
      fail('$path: $target is tagged manual, so Linux would skip it too');
    }
  });
}
