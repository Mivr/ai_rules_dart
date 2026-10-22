import 'dart:io';

import 'package:test/test.dart';

/// Fail-closed guard for every download in `//dart`.
///
/// `dart/private/download.bzl` is the single place that may touch
/// `ctx.download` / `ctx.download_and_extract`: every other `.bzl` under
/// `dart/` fetches through its `pinned_download` /
/// `pinned_download_and_extract`, which refuse a missing or malformed digest
/// before any bytes move. Likewise every `http_archive` / `http_file` /
/// `http_jar` instantiation — in `.bzl` files and in every `MODULE.bazel`,
/// including dev and e2e ones — carries a non-empty literal `sha256` or
/// `integrity`, no matter what local name it is called through: a load alias
/// (`_x = "http_archive"`), a plain re-binding (`_y = _x`), or a
/// `use_repo_rule` proxy (`_fetch = use_repo_rule(..., "http_archive")`).
///
/// The test discovers its inputs by itself: it walks the live source tree
/// from the workspace root (so a `.bzl` in a new package, with a new `BUILD`
/// file and no other change, is checked without re-listing anything) and
/// reports one `file:line` finding per violation. It runs unsandboxed and
/// local, so it always re-runs: a file it never declared cannot change
/// under a cached pass. The `guard unit tests` group pins the checker itself
/// against one inline source per evasion shape.
void main() {
  group('download digest guard', () {
    test('the workspace root resolves and sources are discovered', () {
      final root = _workspaceRoot();
      final bzl = _dartBzlFiles(root);
      final modules = _moduleFiles(root);
      expect(
        bzl.length,
        greaterThan(10),
        reason:
            'expected dozens of .bzl files under dart/, found ${bzl.length}',
      );
      expect(
        modules.length,
        greaterThan(1),
        reason:
            'expected every MODULE.bazel (root, dev, e2e), found ${modules.length}',
      );
      expect(
        modules.any((f) => _relative(root, f) == 'MODULE.bazel'),
        isTrue,
        reason:
            'the root MODULE.bazel must be among the discovered module files',
      );
    });

    test('the helpers are defined once, in dart/private/download.bzl', () {
      final root = _workspaceRoot();
      final helper = File('$root/dart/private/download.bzl');
      expect(
        helper.existsSync(),
        isTrue,
        reason: 'dart/private/download.bzl must exist',
      );
      final text = helper.readAsStringSync();
      for (final def in [
        'def pinned_download(',
        'def pinned_download_and_extract(',
      ]) {
        expect(
          text.contains(def),
          isTrue,
          reason: 'dart/private/download.bzl must define $def',
        );
      }
    });

    test('no context download outside dart/private/download.bzl', () {
      final root = _workspaceRoot();
      final findings = <String>[];
      var users = 0;
      for (final file in _dartBzlFiles(root)) {
        final rel = _relative(root, file);
        if (rel == 'dart/private/download.bzl') continue;
        final lines = file.readAsLinesSync();
        final code = _codeLines(lines);
        if (code.any((l) => l.contains('pinned_download('))) users++;
        for (var i = 0; i < lines.length; i++) {
          if (_directDownload.hasMatch(code[i])) {
            findings.add(
              '$rel:${i + 1}: context download outside dart/private/download.bzl; fetch through pinned_download/pinned_download_and_extract instead',
            );
          }
        }
      }
      expect(
        users,
        greaterThan(0),
        reason: 'no fetch through pinned_download found; the guard would pass vacuously',
      );
      expect(findings, isEmpty, reason: '\n${findings.join('\n')}');
    });

    test('no aliased or getattr download', () {
      final root = _workspaceRoot();
      final findings = <String>[];
      for (final file in _dartBzlFiles(root)) {
        final rel = _relative(root, file);
        if (rel == 'dart/private/download.bzl') continue;
        final lines = file.readAsLinesSync();
        final code = _codeLines(lines);
        for (var i = 0; i < lines.length; i++) {
          if (_directDownload.hasMatch(code[i])) continue;
          if (_aliasDownload.hasMatch(code[i])) {
            findings.add(
              '$rel:${i + 1}: aliased context download; fetch through pinned_download/pinned_download_and_extract instead',
            );
          } else if (_getattrDownload.hasMatch(lines[i])) {
            findings.add(
              '$rel:${i + 1}: getattr download; fetch through pinned_download/pinned_download_and_extract instead',
            );
          }
        }
      }
      expect(findings, isEmpty, reason: '\n${findings.join('\n')}');
    });

    test('every http rule carries a non-empty literal checksum', () {
      final root = _workspaceRoot();
      var calls = 0;
      final findings = <String>[];
      final files = [..._dartBzlFiles(root), ..._moduleFiles(root)];
      for (final file in files) {
        final scan = _scanHttp(_relative(root, file), file.readAsStringSync());
        calls += scan.calls;
        findings.addAll(scan.findings);
      }
      expect(
        calls,
        greaterThan(0),
        reason: 'no http_archive/http_file/http_jar instantiation found; the checksum check would pass vacuously',
      );
      expect(findings, isEmpty, reason: '\n${findings.join('\n')}');
    });
  });

  group('guard unit tests', () {
    test('a load alias without a checksum fails with file:line', () {
      const src =
          'load("@bazel_tools//tools/build_defs/repo:http.bzl", _my_archive = "http_archive")\n'
          '\n'
          '\n'
          'def x():\n'
          '    _my_archive(\n'
          '        name = "x",\n'
          '        urls = ["https://example.invalid/x.tgz"],\n'
          '    )\n';
      final scan = _scanHttp('probe.bzl', src);
      expect(scan.calls, 1);
      expect(scan.findings, hasLength(1));
      expect(
        scan.findings.single,
        startsWith(
          "probe.bzl:5: http_archive instantiation through '_my_archive' "
          'without sha256 or integrity',
        ),
      );
    });

    test('a load alias with a literal checksum passes', () {
      const src =
          'load("@bazel_tools//tools/build_defs/repo:http.bzl", _my_archive = "http_archive")\n'
          'def x():\n'
          '    _my_archive(\n'
          '        name = "x",\n'
          '        sha256 = "86bea300d6701fb6c1fddc33b21235231d108b44a9793db9dcd48940fa46a6a6",\n'
          '        urls = ["https://example.invalid/x.tgz"],\n'
          '    )\n';
      final scan = _scanHttp('probe.bzl', src);
      expect(scan.calls, 1);
      expect(scan.findings, isEmpty);
    });

    test('a re-binding chain without a checksum fails', () {
      const src =
          'load("@bazel_tools//tools/build_defs/repo:http.bzl", _my_archive = "http_archive")\n'
          '_mid = _my_archive\n'
          '_leaf = _mid\n'
          'def x():\n'
          '    _leaf(name = "x", urls = ["https://example.invalid/x.tgz"])\n';
      final scan = _scanHttp('probe.bzl', src);
      expect(scan.calls, 1);
      expect(scan.findings, hasLength(1));
      expect(
        scan.findings.single,
        startsWith(
          "probe.bzl:5: http_archive instantiation through '_leaf' "
          'without sha256 or integrity',
        ),
      );
    });

    test('a direct http_archive without a checksum still fails', () {
      const src =
          'http_archive(\n'
          '    name = "x",\n'
          '    urls = ["https://example.invalid/x.tgz"],\n'
          ')\n';
      final scan = _scanHttp('probe.bzl', src);
      expect(scan.calls, 1);
      expect(scan.findings, [
        'probe.bzl:1: http_archive rule without sha256 or integrity',
      ]);
    });

    test('a variable checksum through an alias pins nothing', () {
      const src =
          'load("@bazel_tools//tools/build_defs/repo:http.bzl", _my_archive = "http_archive")\n'
          'def x():\n'
          '    _my_archive(name = "x", sha256 = PIN, urls = ["https://example.invalid/x.tgz"])\n';
      final scan = _scanHttp('probe.bzl', src);
      expect(scan.calls, 1);
      expect(scan.findings, hasLength(1));
      expect(
        scan.findings.single,
        contains('without a non-empty literal sha256 or integrity'),
      );
    });

    test('a use_repo_rule proxy without a checksum fails', () {
      const src =
          'my_fetch = use_repo_rule("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")\n'
          '\n'
          'my_fetch(\n'
          '    name = "x",\n'
          '    urls = ["https://example.invalid/x.tgz"],\n'
          ')\n';
      final scan = _scanHttp('MODULE.bazel', src);
      expect(scan.calls, 1);
      expect(scan.findings, [
        "MODULE.bazel:3: http_archive instantiation through 'my_fetch' "
            'without sha256 or integrity',
      ]);
    });

    test('an http_file proxy with an empty integrity fails', () {
      const src =
          'my_file = use_repo_rule("@bazel_tools//tools/build_defs/repo:http.bzl", "http_file")\n'
          'my_file(\n'
          '    name = "x",\n'
          '    integrity = "",\n'
          '    urls = ["https://example.invalid/x.bin"],\n'
          ')\n';
      final scan = _scanHttp('MODULE.bazel', src);
      expect(scan.calls, 1);
      expect(scan.findings, hasLength(1));
      expect(
        scan.findings.single,
        startsWith(
          "MODULE.bazel:2: http_file instantiation through 'my_file' "
          'without a non-empty literal sha256 or integrity',
        ),
      );
    });

    test('a pinned use_repo_rule proxy passes', () {
      const src =
          'http_archive = use_repo_rule("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")\n'
          'http_archive(\n'
          '    name = "x",\n'
          '    sha256 = "86bea300d6701fb6c1fddc33b21235231d108b44a9793db9dcd48940fa46a6a6",\n'
          '    urls = ["https://example.invalid/x.tgz"],\n'
          ')\n';
      final scan = _scanHttp('MODULE.bazel', src);
      expect(scan.calls, 1);
      expect(scan.findings, isEmpty);
    });

    test('a proxy of a non-http rule is not an http instantiation', () {
      const src =
          'my_git = use_repo_rule("@bazel_tools//tools/build_defs/repo:git.bzl", "git_repository")\n'
          'my_git(\n'
          '    name = "x",\n'
          '    remote = "https://example.invalid/x.git",\n'
          ')\n';
      final scan = _scanHttp('MODULE.bazel', src);
      expect(scan.calls, 0);
      expect(scan.findings, isEmpty);
    });

    test('a load alias of another symbol is not checked', () {
      const src =
          'load("//dart/pub:extensions.bzl", _plan = "plan_scope_sccs")\n'
          'def x():\n'
          '    return _plan()\n';
      final scan = _scanHttp('probe.bzl', src);
      expect(scan.calls, 0);
      expect(scan.findings, isEmpty);
    });
  });
}

/// Direct `ctx.download(` / `repo.download_and_extract (` spellings, on one
/// code line (strings and comments blanked out). `pinned_download(` does not
/// match: there is no `.` before `download`.
final _directDownload = RegExp(r'\.download(_and_extract)?\s*\(');

/// An assignment binding a context download method, with or without a call:
/// `dl = ctx.download`, `dl = repo.download_and_extract(`. Direct calls
/// match too; callers dedupe by skipping lines the direct pattern caught.
final _aliasDownload = RegExp(
  r'=\s*[A-Za-z_][A-Za-z0-9_. ]*\.download(_and_extract)?\b',
);

/// `getattr(anything, "download")`, matched on the raw line because the
/// method name lives inside a string literal that blanking would erase.
final _getattrDownload = RegExp(
  'getattr\\s*\\([^()]*[\'"]download(_and_extract)?[\'"]',
);

/// One examined file's http instantiations: direct `http_archive(` /
/// `http_file(` / `http_jar(` calls, calls through load aliases and plain
/// re-bindings, and calls through `use_repo_rule` proxies — each checked for
/// a non-empty literal checksum, with one `file:line` finding per violation.
class _HttpScan {
  var calls = 0;
  final findings = <String>[];
}

_HttpScan _scanHttp(String rel, String original) {
  final scan = _HttpScan();
  final blanked = _blanked(original);
  final kinds = <String, String>{
    ..._httpLocalNames(blanked, original),
    ..._repoRuleProxies(blanked, original),
  };
  for (final entry in kinds.entries) {
    final local = entry.key;
    final kind = entry.value;
    final what = local == 'http_$kind'
        ? 'http_$kind rule'
        : 'http_$kind instantiation through \'$local\'';
    for (final match in RegExp(
      '\\b${RegExp.escape(local)}\\s*\\(',
    ).allMatches(blanked)) {
      scan.calls++;
      final open = match.end - 1;
      final close = _matchingParen(blanked, open);
      final line =
          '\n'.allMatches(blanked.substring(0, match.start)).length + 1;
      if (close == -1) {
        scan.findings.add('$rel:$line: $what never closes');
        continue;
      }
      final extent = original.substring(match.start, close + 1);
      final literal = _literalChecksum.firstMatch(extent);
      if (literal != null && literal.group(1)!.length > 2) continue;
      if (_checksumAttr.hasMatch(extent)) {
        scan.findings.add(
          '$rel:$line: $what without a non-empty literal sha256 or integrity; '
          'a variable, conditional or empty string pins nothing',
        );
      } else {
        scan.findings.add('$rel:$line: $what without sha256 or integrity');
      }
    }
  }
  return scan;
}

/// Local names that instantiate an http rule in one file, mapped to their
/// rule kind (`archive`, `file`, `jar`): the three rule names themselves,
/// every load alias bound to one of them (`_x = "http_archive"` in any
/// `load`, whatever file it loads from), and plain re-bindings (`_y = _x`)
/// closed to a fixpoint so chains resolve.
Map<String, String> _httpLocalNames(String blanked, String original) {
  const kinds = {
    'http_archive': 'archive',
    'http_file': 'file',
    'http_jar': 'jar',
  };
  final found = Map<String, String>.of(kinds);
  for (final load in RegExp(r'\bload\s*\(').allMatches(blanked)) {
    final close = _matchingParen(blanked, load.end - 1);
    if (close == -1) continue;
    final items = _loadItems
        .allMatches(original.substring(load.start, close + 1))
        .toList();
    for (final item in items.skip(1)) {
      final value = _unquote(item.group(2)!);
      final kind = kinds[value];
      if (kind != null) found[item.group(1) ?? value] = kind;
    }
  }
  var changed = true;
  while (changed) {
    changed = false;
    for (final m in _rebinding.allMatches(blanked)) {
      final kind = found[m.group(2)];
      if (kind != null && !found.containsKey(m.group(1))) {
        found[m.group(1)!] = kind;
        changed = true;
      }
    }
  }
  return found;
}

/// `use_repo_rule` proxies bound to an http rule in one module file, mapping
/// the bound name to its rule kind. A proxy of any other rule is not an http
/// instantiation and is ignored.
Map<String, String> _repoRuleProxies(String blanked, String original) {
  const kinds = {
    'http_archive': 'archive',
    'http_file': 'file',
    'http_jar': 'jar',
  };
  final proxies = <String, String>{};
  for (final m in RegExp(
    r'([A-Za-z_][A-Za-z0-9_]*)\s*=\s*use_repo_rule\s*\(',
  ).allMatches(blanked)) {
    final close = _matchingParen(blanked, m.end - 1);
    if (close == -1) continue;
    final literals = RegExp('"[^"]*"|\'[^\']*\'')
        .allMatches(original.substring(m.start, close + 1))
        .map((lit) => _unquote(lit.group(0)!))
        .toList();
    if (literals.length >= 2 && kinds.containsKey(literals[1])) {
      proxies[m.group(1)!] = kinds[literals[1]]!;
    }
  }
  return proxies;
}

/// One `load` item: an optional `alias =` and its quoted symbol. The first
/// item is the loaded file's label; the rest bind local names.
final _loadItems = RegExp(
  '(?:([A-Za-z_][A-Za-z0-9_]*)\\s*=\\s*)?("[^"]*"|\'[^\']*\')',
);

/// A plain re-binding: `name = other` with nothing else on the code line.
/// `==`, `+=`, calls and attribute paths never match.
final _rebinding = RegExp(
  r'^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*([A-Za-z_][A-Za-z0-9_]*)\s*$',
  multiLine: true,
);

/// The quoted string without its quotes.
String _unquote(String quoted) => quoted.substring(1, quoted.length - 1);

/// A `sha256` / `integrity` argument with a single quoted-string value.
/// Group 1 is the quotes plus their content; the caller requires content.
final _literalChecksum = RegExp(
  '(?:sha256|integrity)\\s*=\\s*("[^"]*"|\'[^\']*\')',
);

/// Any `sha256 =` / `integrity =` argument, literal or not.
final _checksumAttr = RegExp(r'(?:sha256|integrity)\s*=');

/// Locates the source-tree workspace root.
///
/// The test runs unsandboxed, but beside the tree, not in it: the current
/// directory is the test's runfiles tree, and no `BUILD_WORKSPACE_DIRECTORY`
/// is set. Build outputs mirror the tree through symlinks (the execroot maps
/// every source through a link, runfiles nest under `bazel-out`), so the
/// first ancestor holding `MODULE.bazel` may be a mirror. A mirror's
/// `MODULE.bazel` is itself a link into the real tree, so resolving it
/// lands on the sources whatever mirror the search starts from; a direct
/// `dart test` run from a source subdirectory resolves to itself.
String _workspaceRoot() {
  final env = Platform.environment;
  for (final start in [
    env['BUILD_WORKSPACE_DIRECTORY'],
    env['BUILD_WORKING_DIRECTORY'],
    Directory.current.path,
  ]) {
    final root = _sourceRootAbove(start);
    if (root != null) return root;
  }
  fail(
    'cannot locate the workspace root: no ancestor of the workspace '
    'directory, the invocation directory or the current directory holds a '
    'MODULE.bazel whose tree contains dart/. The guard must run unsandboxed '
    '(tags = ["no-sandbox"]) so it reads the live tree.',
  );
}

/// The source-tree workspace root at or above [start], or null when none.
///
/// A candidate directory qualifies only when its `dart/` is a real
/// directory: a mirror whose entries are all links (the execroot) never
/// qualifies itself, while resolving its linked `MODULE.bazel` still lands
/// on the real tree.
String? _sourceRootAbove(String? start) {
  var dir = start == null ? null : Directory(start);
  while (dir != null) {
    final module = File('${dir.path}/MODULE.bazel');
    if (module.existsSync()) {
      final root = File(module.resolveSymbolicLinksSync()).parent.path;
      if (FileSystemEntity.typeSync('$root/dart', followLinks: false) ==
          FileSystemEntityType.directory) {
        return root;
      }
    }
    final parent = dir.parent;
    if (parent.path == dir.path) return null;
    dir = parent;
  }
  return null;
}

/// Every `.bzl` file under `dart/`, sorted, skipping nothing.
List<File> _dartBzlFiles(String root) {
  final found = <File>[];
  _walk(Directory('$root/dart'), (f) {
    if (f.path.endsWith('.bzl')) found.add(f);
  });
  found.sort((a, b) => a.path.compareTo(b.path));
  return found;
}

/// Every file named exactly `MODULE.bazel` in the workspace, sorted.
/// Version-control metadata and Bazel output links are pruned, never
/// followed.
List<File> _moduleFiles(String root) {
  final found = <File>[];
  _walk(Directory(root), (f) {
    if (f.path.split(Platform.pathSeparator).last == 'MODULE.bazel') {
      found.add(f);
    }
  });
  found.sort((a, b) => a.path.compareTo(b.path));
  return found;
}

void _walk(Directory dir, void Function(File) visit) {
  List<FileSystemEntity> entries;
  try {
    entries = dir.listSync(followLinks: false);
  } on FileSystemException {
    return;
  }
  entries.sort((a, b) => a.path.compareTo(b.path));
  for (final entry in entries) {
    final name = entry.path.split(Platform.pathSeparator).last;
    if (name.startsWith('.') || name.startsWith('bazel-')) continue;
    if (entry is File) {
      visit(entry);
    } else if (entry is Directory) {
      _walk(entry, visit);
    }
  }
}

String _relative(String root, File file) {
  var rel = file.path;
  if (rel.startsWith(root)) rel = rel.substring(root.length);
  rel = rel.replaceAll('\\', '/');
  while (rel.startsWith('/')) {
    rel = rel.substring(1);
  }
  return rel;
}

/// Blanks string literals and comments with spaces, preserving every offset
/// and line number. Handles `'`, `"`, `'''`, `"""` with backslash escapes
/// and `r` prefixes; a `#` outside a string starts a comment; triple-quoted
/// state carries across lines because the whole file is scanned at once.
String _blanked(String text) {
  final out = StringBuffer();
  var i = 0;
  String? quote;
  var raw = false;
  var pendingRaw = false;
  while (i < text.length) {
    final c = text[i];
    if (quote == null) {
      if ((c == 'r' || c == 'R') &&
          i + 1 < text.length &&
          (text[i + 1] == "'" || text[i + 1] == '"')) {
        out.write(' ');
        pendingRaw = true;
        i++;
        continue;
      }
      if (c == "'" || c == '"') {
        final triple =
            i + 2 < text.length && text[i + 1] == c && text[i + 2] == c;
        quote = triple ? c * 3 : c;
        raw = pendingRaw;
        pendingRaw = false;
        out.write(' ' * quote.length);
        i += quote.length;
        continue;
      }
      pendingRaw = false;
      if (c == '#') {
        while (i < text.length && text[i] != '\n') {
          out.write(' ');
          i++;
        }
        continue;
      }
      out.write(c);
      i++;
      continue;
    }
    if (!raw && c == '\\' && quote.length == 1) {
      out.write('  ');
      i += 2;
      continue;
    }
    if (text.startsWith(quote, i)) {
      out.write(' ' * quote.length);
      i += quote.length;
      quote = null;
      continue;
    }
    out.write(c == '\n' ? '\n' : ' ');
    i++;
  }
  return out.toString();
}

/// The code lines of a file: the blanked text split back into lines, so one
/// line's match reports that line.
List<String> _codeLines(List<String> lines) =>
    _blanked('${lines.join('\n')}\n').split('\n');

/// The offset of the `)` closing the `(` at [open] in blanked text, or -1.
/// String contents and comments are already blank, so every paren is code.
int _matchingParen(String blanked, int open) {
  var depth = 0;
  for (var i = open; i < blanked.length; i++) {
    if (blanked[i] == '(') depth++;
    if (blanked[i] == ')') {
      depth--;
      if (depth == 0) return i;
    }
  }
  return -1;
}
