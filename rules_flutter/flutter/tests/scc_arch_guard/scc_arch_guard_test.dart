/// Architecture guard for the merged pub SCC spoke generators: `deps` must
/// demand `DartInfo`, the internal `.bzl` load graph stays within the Starlark
/// depth limit, and the generator docstrings document every parameter.
library;

import 'dart:io';
import 'dart:math';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

const int _maxLoadDepthLimit = 10;
const String _targetBzl = 'flutter/private/flutter_pub_scc_target.bzl';
const String _buildBzl = 'flutter/private/flutter_pub_scc_build.bzl';
const String _helpersBzl = 'flutter/private/flutter_pub_package_helpers.bzl';

final RegExp _token = RegExp(
  r'"""[\s\S]*?"""'
  r"|'''[\s\S]*?'''"
  r'|"(?:\\.|[^"\\\n])*"'
  r"|'(?:\\.|[^'\\\n])*'"
  r'|#[^\n]*',
);

String _mask(String text) => text.replaceAll(RegExp(r'[^\n]'), ' ');

/// Removes `#` comments; with [blankStrings] also blanks string contents.
///
/// Replacements keep every offset, so the two views of one source line up.
String _strip(String src, {required bool blankStrings}) {
  return src.replaceAllMapped(_token, (Match match) {
    final String token = match[0]!;
    if (token.startsWith('#')) {
      return _mask(token);
    }
    if (!blankStrings) {
      return token;
    }
    final quote = token.startsWith('"""') || token.startsWith("'''") ? 3 : 1;
    final String inner = token.substring(quote, token.length - quote);
    return token.substring(0, quote) +
        _mask(inner) +
        token.substring(token.length - quote);
  });
}

int _matchingParen(String text, int open) {
  var depth = 0;
  for (var i = open; i < text.length; i++) {
    if (text[i] == '(') {
      depth++;
    } else if (text[i] == ')' && --depth == 0) {
      return i;
    }
  }
  throw FormatException('Unbalanced parenthesis at offset $open');
}

/// Problems with the `deps` attribute of `flutter_pub_scc_member_target`.
List<String> _depsProviderProblems(String src) {
  final String keyed = _strip(src, blankStrings: false);
  final String masked = _strip(src, blankStrings: true);
  final int ruleStart = keyed.indexOf('flutter_pub_scc_member_target = rule(');
  final RegExpMatch? deps = RegExp(
    r'"deps"\s*:\s*attr\.label_list\(',
  ).firstMatch(ruleStart < 0 ? '' : keyed.substring(ruleStart));
  if (deps == null) {
    return const <String>['no "deps": attr.label_list in the member rule'];
  }
  final int open = ruleStart + deps.end - 1;
  final String body = masked.substring(open, _matchingParen(masked, open));
  final bool typed = RegExp(
    r'providers\s*=\s*\[[^\]]*\bDartInfo\b',
  ).hasMatch(body);
  return typed
      ? const <String>[]
      : const <String>['deps lacks providers = [DartInfo]'];
}

/// Resolves a `load()` label to a repository-relative path, or null if the
/// label is external.
String? _resolveLabel(String label, String fromPath) {
  final RegExpMatch? absolute = RegExp(
    r'^(?:@rules_flutter)?//([^:]*):(.+)$',
  ).firstMatch(label);
  if (absolute != null) {
    final String pkg = absolute[1]!;
    return pkg.isEmpty ? absolute[2]! : '$pkg/${absolute[2]}';
  }
  if (label.startsWith(':')) {
    final int slash = fromPath.lastIndexOf('/');
    final String dir = slash < 0 ? '' : fromPath.substring(0, slash + 1);
    return '$dir${label.substring(1)}';
  }
  return null;
}

/// The repository-relative `.bzl` paths that [src] (at [path]) loads.
List<String> _loadsOf(String src, String path) {
  final String keyed = _strip(src, blankStrings: false);
  final String masked = _strip(src, blankStrings: true);
  final loads = <String>[];
  for (final RegExpMatch m in RegExp(
    '\\bload\\(\\s*(["\'])',
  ).allMatches(masked)) {
    final String quote = m[1]!;
    final String label = keyed.substring(
      m.end,
      keyed.indexOf(quote, m.end),
    );
    final String? resolved = _resolveLabel(label, path);
    if (resolved != null) {
      loads.add(resolved);
    }
  }
  return loads;
}

/// The longest chain of internal loads, counted in edges.
int _maxLoadDepth(Map<String, List<String>> graph) {
  final memo = <String, int>{};
  final stack = <String>{};
  int depth(String node) {
    final int? known = memo[node];
    if (known != null || !stack.add(node)) {
      return known ?? 0;
    }
    var best = 0;
    for (final String next in graph[node] ?? const <String>[]) {
      if (graph.containsKey(next)) {
        best = max(best, 1 + depth(next));
      }
    }
    stack.remove(node);
    return memo[node] = best;
  }

  return graph.keys.fold(0, (int top, String node) => max(top, depth(node)));
}

Map<String, List<String>> _loadGraph(String root) {
  final graph = <String, List<String>>{};
  for (final top in const <String>['flutter', 'dart']) {
    final dir = Directory('$root/$top');
    if (!dir.existsSync()) {
      continue;
    }
    for (final FileSystemEntity file in dir.listSync(recursive: true)) {
      final String path = file.path.substring(root.length + 1);
      if (file is File && path.endsWith('.bzl') && !path.contains('/tests/')) {
        graph[path] = _loadsOf(file.readAsStringSync(), path);
      }
    }
  }
  return graph;
}

List<String> _paramNames(String masked, int open, int close) {
  final names = <String>[];
  var depth = 0;
  int start = open + 1;
  for (int i = open + 1; i <= close; i++) {
    final String c = masked[i];
    if ('([{'.contains(c)) {
      depth++;
    } else if (')]}'.contains(c) && i < close) {
      depth--;
    } else if ((c == ',' && depth == 0) || i == close) {
      final String name = masked
          .substring(start, i)
          .split('=')
          .first
          .replaceAll('*', '')
          .trim();
      if (name.isNotEmpty) {
        names.add(name);
      }
      start = i + 1;
    }
  }
  return names;
}

bool _trivialReturns(String doc, String fn) {
  final RegExpMatch? returns = RegExp(r'Returns:\s*\n\s+(.+)').firstMatch(doc);
  if (returns == null) {
    return true;
  }
  final String text = returns[1]!;
  final String squashed = text.toLowerCase().replaceAll(
    RegExp('[^a-z0-9]'),
    '',
  );
  return text.trim().split(RegExp(r'\s+')).length < 3 ||
      squashed == fn.replaceAll('_', '').toLowerCase();
}

/// Problems with the Google-style docstring of `def [fn]` in [src].
List<String> _docProblems(String src, String fn) {
  final String masked = _strip(src, blankStrings: true);
  final int def = masked.indexOf('def $fn(');
  if (def < 0) {
    return <String>['$fn is not defined'];
  }
  final int open = def + 'def $fn'.length;
  final int close = _matchingParen(masked, open);
  final RegExpMatch? start = RegExp(r':\s*"""')
      .firstMatch(masked.substring(close));
  if (start == null) {
    return <String>['$fn has no docstring'];
  }
  final int from = close + start.end;
  final String doc = src.substring(from, masked.indexOf('"""', from));
  final problems = <String>[];
  final List<String> params = _paramNames(masked, open, close);
  for (final param in params) {
    if (!RegExp('(^|\\n)\\s+\\*{0,2}$param\\s*:')
            .hasMatch(doc.split('Returns:').first) ||
        !doc.contains('Args:')) {
      problems.add('$fn: Args lacks $param');
    }
  }
  if (_trivialReturns(doc, fn)) {
    problems.add('$fn: Returns is missing or trivial');
  }
  return problems;
}

String _repoRoot(List<String> args) {
  final String? env = Platform.environment['BUILD_WORKSPACE_DIRECTORY'];
  if (env != null && File('$env/MODULE.bazel').existsSync()) {
    return env;
  }
  final String anchor = Runfiles.create().rlocation(args.first);
  final String resolved = File(anchor).resolveSymbolicLinksSync();
  return File(resolved).parent.parent.parent.parent.path;
}

void _expectProblems(List<String> problems, {required bool clean}) {
  expect(problems.isEmpty, clean, reason: problems.join('; '));
}

String _readRel(String root, String path) =>
    File('$root/$path').readAsStringSync();

void _repoTests(List<String> args) {
  late String root;
  setUpAll(() => root = _repoRoot(args));

  test('scc member target deps require DartInfo', () {
    _expectProblems(
      _depsProviderProblems(_readRel(root, _targetBzl)),
      clean: true,
    );
  });
  test('scc build does not load flutter_pub_package.bzl', () {
    final List<String> loads = _loadsOf(_readRel(root, _buildBzl), _buildBzl);
    expect(loads, isNot(contains('flutter/private/flutter_pub_package.bzl')));
  });
  test('internal load depth stays within the limit', () {
    expect(
      _maxLoadDepth(_loadGraph(root)),
      lessThanOrEqualTo(_maxLoadDepthLimit),
    );
  });
  test('generator docstrings document every parameter', () {
    const functions = <String, List<String>>{
      _buildBzl: <String>[
        'scc_flutter_test_package_bzl_content',
        'adapt_scc_member_android_overlay_content',
      ],
      _helpersBzl: <String>[
        'scoped_shader_includes_block',
        'format_pub_asset_attrs_with_shaders',
      ],
    };
    for (final MapEntry<String, List<String>> entry in functions.entries) {
      final String src = _readRel(root, entry.key);
      for (final String fn in entry.value) {
        _expectProblems(_docProblems(src, fn), clean: true);
      }
    }
  });
}

void _negativeTests() {
  test('missing deps providers is reported', () {
    const src = '''
flutter_pub_scc_member_target = rule(
    attrs = {
        "deps": attr.label_list(default = []),  # providers = [DartInfo]
        "x": attr.label(providers = [DartInfo]),
    },
)
''';
    _expectProblems(_depsProviderProblems(src), clean: false);
    _expectProblems(
      _depsProviderProblems(
        src.replaceFirst('default = []', 'providers = [DartInfo]'),
      ),
      clean: true,
    );
  });
  test('an eleven-edge load chain is deeper than the limit', () {
    final chain = <String, List<String>>{
      for (var i = 0; i <= 11; i++)
        'f$i.bzl': <String>[if (i < 11) 'f${i + 1}.bzl'],
    };
    expect(_maxLoadDepth(chain), 11);
    chain.remove('f0.bzl');
    expect(_maxLoadDepth(chain), lessThanOrEqualTo(_maxLoadDepthLimit));
  });
  test('load labels resolve and comments are ignored', () {
    const src = '''
# load("//a:commented.bzl", "x")
load(":sibling.bzl", "y")
load("//flutter/private:other.bzl", "z")
load("@rules_dart//dart:defs.bzl", "w")
''';
    expect(_loadsOf(src, 'flutter/private/me.bzl'), <String>[
      'flutter/private/sibling.bzl',
      'flutter/private/other.bzl',
    ]);
  });
  test('missing Args and Returns are reported', () {
    const bad = '''
def f(a, b = 1):
    """Does it."""
    return a
''';
    const good = '''
def f(a, b = 1):
    """Does it.

    Args:
        a: The first value.
        b: The second value.

    Returns:
        The first value, unchanged.
    """
    return a
''';
    expect(_docProblems(bad, 'f'), hasLength(3));
    _expectProblems(_docProblems(good, 'f'), clean: true);
    expect(
      _docProblems(
        good.replaceFirst('        b: The second value.\n', ''),
        'f',
      ),
      hasLength(1),
    );
  });
}

/// Runs the repository checks and their negative counterparts.
void main(List<String> args) {
  group('repository', () => _repoTests(args));
  group('negative', _negativeTests);
}
