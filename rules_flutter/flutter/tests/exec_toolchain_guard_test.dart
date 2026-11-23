/// Static guard: every `ctx.actions.run` / `ctx.actions.run_shell` call under
/// `flutter/` declares `toolchain =`.
///
/// With auto exec groups (`--incompatible_auto_exec_groups`) an action with no
/// `toolchain` cannot be matched to the toolchain that supplies its
/// executable. Actions that run the host `dart` must name
/// `@rules_dart//dart:exec_tools_toolchain_type`, as every other caller of
/// `resolve_exec_dart_vm` already does. Comments and string literals are
/// ignored. A call that spreads a dict (`ctx.actions.run(**kwargs)`) is not
/// checked here: its `toolchain` comes from the dict literal, which the guard
/// cannot follow, so the dict's author is responsible for it. Inputs are
/// discovered at runtime from the workspace root, so a `.bzl` added anywhere
/// under `flutter/` is checked with no other change; the target is tagged
/// `external` so it re-runs on every invocation.
library;

import 'dart:io';

import 'package:test/test.dart';

/// Whether [root] is the rules_flutter workspace root.
bool _looksLikeRoot(String root) =>
    Directory('$root/flutter').existsSync() &&
    File('$root/MODULE.bazel').existsSync();

/// Workspace root: `BUILD_WORKSPACE_DIRECTORY` when set, otherwise the first
/// ancestor of the test's own anchor in `data` that looks like the workspace.
String? _workspaceRoot() {
  final String? fromEnv = Platform.environment['BUILD_WORKSPACE_DIRECTORY'];
  if (fromEnv != null && fromEnv.isNotEmpty && _looksLikeRoot(fromEnv)) {
    return fromEnv;
  }
  final String? anchor = Platform.environment['GUARD_ROOT_ANCHOR'];
  final String? srcdir = Platform.environment['TEST_SRCDIR'];
  if (anchor != null && anchor.isNotEmpty && srcdir != null) {
    final String resolved = File('$srcdir/$anchor').resolveSymbolicLinksSync();
    Directory dir = File(resolved).parent;
    for (var i = 0; i < 8; i++) {
      if (_looksLikeRoot(dir.path)) return dir.path;
      dir = dir.parent;
    }
  }
  return null;
}

/// Relative paths of every `.bzl` file under `flutter/`, sorted.
List<String> _findBzl(String root) {
  final found = <String>[];
  final stack = <Directory>[Directory('$root/flutter')];
  while (stack.isNotEmpty) {
    for (final FileSystemEntity child in stack.removeLast().listSync(
      followLinks: false,
    )) {
      if (child is Directory) {
        stack.add(child);
      } else if (child is File && child.path.endsWith('.bzl')) {
        found.add(child.path.substring(root.length + 1));
      }
    }
  }
  found.sort();
  return found;
}

/// [text] with every `#` comment and string literal replaced by spaces.
/// Newlines are kept, so offsets and line numbers still match the original.
String _blankNonCode(String text) {
  final out = StringBuffer();
  var i = 0;
  while (i < text.length) {
    final String ch = text[i];
    if (ch == '#') {
      while (i < text.length && text[i] != '\n') {
        out.write(' ');
        i++;
      }
    } else if (ch == '"' || ch == "'") {
      final bool triple =
          i + 2 < text.length && text[i + 1] == ch && text[i + 2] == ch;
      final String quote = triple ? ch * 3 : ch;
      out.write(' ' * quote.length);
      i += quote.length;
      while (i < text.length && !text.startsWith(quote, i)) {
        if (text[i] == r'\') i++;
        if (i < text.length) out.write(text[i] == '\n' ? '\n' : ' ');
        i++;
      }
      if (i < text.length) {
        out.write(' ' * quote.length);
        i += quote.length;
      }
    } else {
      out.write(ch);
      i++;
    }
  }
  return out.toString();
}

/// Index of the `)` closing the `(` at [open], in blanked text, or null.
int? _callEnd(String blanked, int open) {
  var depth = 0;
  for (var i = open; i < blanked.length; i++) {
    if (blanked[i] == '(') depth++;
    if (blanked[i] == ')' && --depth == 0) return i;
  }
  return null;
}

/// `file:line` of every `ctx.actions.run(` or `ctx.actions.run_shell(` call in
/// [text] whose argument list has no `toolchain =` keyword and no `**` spread.
List<String> _missingToolchain(String rel, String text) {
  final String blanked = _blankNonCode(text);
  final call = RegExp(r'\bctx\.actions\.run(_shell)?\(');
  final keyword = RegExp(r'\btoolchain\s*=');
  final problems = <String>[];
  for (final RegExpMatch m in call.allMatches(blanked)) {
    final int end = _callEnd(blanked, m.end - 1) ?? blanked.length;
    final String args = blanked.substring(m.end, end);
    if (args.contains('**')) continue;
    if (!keyword.hasMatch(args)) {
      final int line =
          '\n'.allMatches(blanked.substring(0, m.start)).length + 1;
      problems.add('$rel:$line: ${m.group(0)} has no toolchain = argument');
    }
  }
  return problems;
}

void main() {
  final String? root = _workspaceRoot();

  test('the workspace root is discoverable', () {
    expect(
      root,
      isNotNull,
      reason: 'neither BUILD_WORKSPACE_DIRECTORY nor GUARD_ROOT_ANCHOR resolves the root',
    );
  });

  if (root == null) return;

  test('every ctx.actions.run call under flutter/ declares toolchain', () {
    final List<String> bzl = _findBzl(root);
    expect(bzl, isNotEmpty, reason: 'no .bzl files found under flutter/');
    final problems = <String>[];
    for (final rel in bzl) {
      problems.addAll(
        _missingToolchain(rel, File('$root/$rel').readAsStringSync()),
      );
    }
    expect(problems, isEmpty, reason: problems.join('\n'));
  });
}
