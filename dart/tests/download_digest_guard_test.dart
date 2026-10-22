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
/// `integrity`.
///
/// The test discovers its inputs by itself: it walks the live source tree
/// from the workspace root (so a `.bzl` in a new package, with a new `BUILD`
/// file and no other change, is checked without re-listing anything) and
/// reports one `file:line` finding per violation. It runs unsandboxed and
/// local, so it always re-runs: a file it never declared cannot change
/// under a cached pass.
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
      final findings = <String>[];
      var rules = 0;
      final files = [..._dartBzlFiles(root), ..._moduleFiles(root)];
      for (final file in files) {
        final rel = _relative(root, file);
        final original = file.readAsStringSync();
        final blanked = _blanked(original);
        for (final match in _httpRule.allMatches(blanked)) {
          rules++;
          final open = match.end - 1;
          final close = _matchingParen(blanked, open);
          final line =
              '\n'.allMatches(blanked.substring(0, match.start)).length + 1;
          if (close == -1) {
            findings.add('$rel:$line: http_${match.group(1)} never closes');
            continue;
          }
          final extent = original.substring(match.start, close + 1);
          final literal = _literalChecksum.firstMatch(extent);
          if (literal != null && literal.group(1)!.length > 2) continue;
          if (_checksumAttr.hasMatch(extent)) {
            findings.add(
              '$rel:$line: http_${match.group(1)} rule without a non-empty literal sha256 or integrity; a variable, conditional or empty string pins nothing',
            );
          } else {
            findings.add(
              '$rel:$line: http_${match.group(1)} rule without sha256 or integrity',
            );
          }
        }
      }
      expect(
        rules,
        greaterThan(0),
        reason: 'no http_archive/http_file/http_jar rule found; the checksum check would pass vacuously',
      );
      expect(findings, isEmpty, reason: '\n${findings.join('\n')}');
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

/// `http_archive(`, `http_file(`, `http_jar(` call starts.
final _httpRule = RegExp(r'\bhttp_(archive|file|jar)\s*\(');

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
