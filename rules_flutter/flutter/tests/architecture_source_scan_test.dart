/// Source half of the FF6 architecture invariants (Gate 13 section D).
///
/// Scans every production `.bzl` (everything under `flutter/` except
/// `flutter/tests/`) and fails on:
///
/// * a `DartInfo(` construction: only rules_dart's `dart_info()` family may
///   build one;
/// * a `FlutterInfo(` construction outside `flutter/private/flutter_info.bzl`;
/// * a `"deps": attr.label_list(...)` / `"deps": attr.label(...)` without a
///   top-level `providers = [DartInfo]`.
///
/// Comments and string literals are ignored, so docs that name `DartInfo(` stay
/// green. The tree is discovered at run time from the test's own runfiles
/// anchor (or `BUILD_WORKSPACE_DIRECTORY`), so an added or edited `.bzl` is
/// checked with no file list. That makes the target `external`, `local` and
/// `no-sandbox`: it re-runs on every invocation.
library;

import 'dart:io';

import 'package:test/test.dart';

/// Native Apple rules whose `deps` take `CcInfo` / `SwiftInfo`, not Dart
/// libraries, so they cannot require `DartInfo`. Never widen this list.
const _depsExempt = <String, String>{
  'flutter/private/flutter_apple_plugin_library.bzl':
      'deps are native CcInfo / SwiftInfo / ObjcProvider targets',
  'flutter/private/flutter_apple_plugins_aggregator.bzl':
      'deps are FlutterApplePluginInfo and native providers',
  'flutter/private/flutter_xtool_bundle.bzl': 'deps are native Swift / C',
  'flutter/private/flutter_apple_plugin_library_helpers.bzl':
      'split out of flutter_apple_plugin_library; its '
      'flutter_xtool_apple_plugin_library deps provide CcInfo or SwiftInfo',
};

const _flutterInfoHome = 'flutter/private/flutter_info.bzl';

/// A string literal found in source: `start` is the opening quote offset.
typedef _Literal = ({int start, int end, String value});

/// Source text with comments and string contents blanked to spaces
/// (newlines and offsets preserved) plus the literals that were blanked.
typedef _Scan = ({String code, List<_Literal> literals});

_Scan _scan(String text) {
  final out = StringBuffer();
  final literals = <_Literal>[];
  var i = 0;
  while (i < text.length) {
    final String ch = text[i];
    if (ch == '#') {
      while (i < text.length && text[i] != '\n') {
        out.write(' ');
        i++;
      }
    } else if (ch == '"' || ch == "'") {
      final String quote = text.startsWith(ch * 3, i) ? ch * 3 : ch;
      final start = i;
      i += quote.length;
      out.write(' ' * quote.length);
      while (i < text.length && !text.startsWith(quote, i)) {
        final width = text[i] == r'\' ? 2 : 1;
        for (var k = 0; k < width && i + k < text.length; k++) {
          out.write(text[i + k] == '\n' ? '\n' : ' ');
        }
        i += width;
      }
      final int end = i < text.length ? i : text.length;
      out.write(' ' * quote.length);
      i = end + quote.length;
      literals.add((
        start: start,
        end: end,
        value: text.substring(start + quote.length, end),
      ));
    } else {
      out.write(ch);
      i++;
    }
  }
  return (code: out.toString(), literals: literals);
}

int _lineOf(String text, int offset) =>
    '\n'.allMatches(text.substring(0, offset)).length + 1;

/// The `(...)` body opening at [open] with nested `(...)` and `{...}`
/// emptied, so only the call's own top-level keyword arguments remain.
String? _topLevelBody(String code, int open) {
  final kept = StringBuffer();
  var depth = 0;
  for (var i = open; i < code.length; i++) {
    final String ch = code[i];
    if (ch == '(' || ch == '{') {
      depth++;
    } else if (ch == ')' || ch == '}') {
      depth--;
      if (depth == 0) return kept.toString();
    } else if (depth == 1) {
      kept.write(ch);
    }
  }
  return null;
}

final _constructs = RegExp(r'(?<![A-Za-z0-9_])(DartInfo|FlutterInfo)\s*\(');
final _depsKey = RegExp(r'^\s*:\s*attr\.label(?:_list)?\s*\(');
final _dartInfoOnly = RegExp(r'providers\s*=\s*\[\s*DartInfo\s*,?\s*\]');

/// Violations of the provider-construction invariants in one `.bzl`.
List<String> checkConstruction(String rel, String text) {
  final String code = _scan(text).code;
  final errors = <String>[];
  for (final RegExpMatch m in _constructs.allMatches(code)) {
    final String name = m.group(1)!;
    if (name == 'FlutterInfo' && rel == _flutterInfoHome) continue;
    errors.add(
      '$rel:${_lineOf(text, m.start)}: $name( construction'
      '${name == 'DartInfo' ? "; build it with rules_dart's dart_info()" : ''}'
      '${name == 'FlutterInfo' ? ' outside $_flutterInfoHome' : ''}',
    );
  }
  return errors;
}

/// `deps` attributes in one `.bzl` that do not require `DartInfo`.
List<String> checkDeps(String rel, String text) {
  if (_depsExempt.containsKey(rel)) return <String>[];
  final _Scan scan = _scan(text);
  final errors = <String>[];
  for (final _Literal lit in scan.literals) {
    if (lit.value != 'deps') continue;
    final String after = scan.code.substring(lit.end + 1);
    final RegExpMatch? m = _depsKey.firstMatch(after);
    if (m == null) continue;
    final int open = lit.end + 1 + m.end - 1;
    final String? body = _topLevelBody(scan.code, open);
    if (body == null || !_dartInfoOnly.hasMatch(body)) {
      errors.add(
        '$rel:${_lineOf(text, lit.start)}: "deps" attribute without '
        'providers = [DartInfo]',
      );
    }
  }
  return errors;
}

/// Workspace root: `BUILD_WORKSPACE_DIRECTORY`, else the first ancestor of the
/// runfiles anchor that holds `flutter/` and `MODULE.bazel`. Null when neither
/// resolves, so the test fails loudly rather than scanning nothing.
String? _root() {
  bool isRoot(String d) =>
      Directory('$d/flutter').existsSync() &&
      File('$d/MODULE.bazel').existsSync();
  final Map<String, String> env = Platform.environment;
  final String? ws = env['BUILD_WORKSPACE_DIRECTORY'];
  if (ws != null && isRoot(ws)) return ws;
  final String? anchor = env['GUARD_ROOT_ANCHOR'];
  final String? srcdir = env['TEST_SRCDIR'];
  if (anchor == null || srcdir == null) return null;
  try {
    String dir = File('$srcdir/$anchor').resolveSymbolicLinksSync();
    for (var i = 0; i < 9; i++) {
      dir = File(dir).parent.path;
      if (isRoot(dir)) return dir;
    }
  } on FileSystemException {
    return null;
  }
  return null;
}

/// Production `.bzl` files: all of `flutter/` except `flutter/tests/`.
List<String> _productionBzl(String root) {
  final List<String> found =
      Directory('$root/flutter')
          .listSync(recursive: true, followLinks: false)
          .whereType<File>()
          .map((f) => f.path.substring(root.length + 1))
          .where((p) => p.endsWith('.bzl') && !p.startsWith('flutter/tests/'))
          .toList()
        ..sort();
  return found;
}

void main() {
  group('scanner (unit)', () {
    test('a DartInfo( construction in code fails, in docs and strings not', () {
      const probe = '''
"""Mentions DartInfo( in a docstring."""
# DartInfo( in a comment
x = "DartInfo("
y = DartInfo(package_name = "p")
''';
      final List<String> errors = checkConstruction(
        'flutter/private/x.bzl',
        probe,
      );
      expect(errors, hasLength(1));
      expect(errors.single, startsWith('flutter/private/x.bzl:4:'));
    });

    test('FlutterInfo( is allowed only in flutter_info.bzl', () {
      const probe = 'r = FlutterInfo(a = 1)\n';
      expect(checkConstruction(_flutterInfoHome, probe), isEmpty);
      expect(checkConstruction('flutter/private/x.bzl', probe), hasLength(1));
    });

    test('deps without DartInfo fails, with it passes', () {
      const bad = '''
A = {
    "deps": attr.label_list(doc = "d", aspects = [a]),
}
''';
      const good = '''
A = {
    "deps": attr.label_list(
        doc = "providers = [DartInfo] in a doc does not count",
        providers = [DartInfo],
        aspects = [a],
    ),
}
''';
      const docOnly = '''
A = {
    "deps": attr.label_list(doc = "providers = [DartInfo]"),
}
''';
      expect(checkDeps('flutter/private/x.bzl', bad), hasLength(1));
      expect(checkDeps('flutter/private/x.bzl', docOnly), hasLength(1));
      expect(checkDeps('flutter/private/x.bzl', good), isEmpty);
    });

    test('providers nested in another call do not count', () {
      const nested = '''
A = {
    "deps": attr.label(cfg = transition(providers = [DartInfo])),
}
''';
      expect(checkDeps('flutter/private/x.bzl', nested), hasLength(1));
    });

    test('a deps key inside a docstring is ignored', () {
      const probe = '"""\n"deps": attr.label_list()\n"""\n';
      expect(checkDeps('flutter/private/x.bzl', probe), isEmpty);
    });
  });

  final String? root = _root();
  if (root == null) {
    test('discovers the workspace', () {
      fail(
        'workspace root not found; run unsandboxed (tag no-sandbox) via '
        'bazel test //flutter/tests:architecture_source_scan_test',
      );
    });
    return;
  }
  final List<String> files = _productionBzl(root);

  test('discovers production .bzl files and the exempt files exist', () {
    expect(files, contains('flutter/private/flutter_asset_bundle.bzl'));
    expect(files.any((p) => p.startsWith('flutter/tests/')), isFalse);
    for (final String rel in _depsExempt.keys) {
      expect(files, contains(rel), reason: 'stale exemption: $rel');
    }
  });

  for (final rel in files) {
    test('$rel builds no provider it must not and requires DartInfo deps', () {
      final String text = File('$root/$rel').readAsStringSync();
      final List<String> problems = [
        ...checkConstruction(rel, text),
        ...checkDeps(rel, text),
      ];
      expect(problems, isEmpty, reason: problems.join('\n'));
    });
  }
}
