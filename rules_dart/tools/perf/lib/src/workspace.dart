/// Workspaces the flows run in (copies of the repository's e2e workspaces,
/// corpus projects, generated graphs) and the edits made to them.
library;

import 'dart:io';

/// Copies [from] to [to], leaving out Bazel's convenience links and build
/// output. An existing [to] is replaced.
void copyTree(String from, String to) {
  final dst = Directory(to);
  if (dst.existsSync()) dst.deleteSync(recursive: true);
  _copy(Directory(from), dst);
}

const _skip = {'.dart_tool', 'build', '.gradle', '.idea', '.kotlin'};

void _copy(Directory src, Directory dst) {
  dst.createSync(recursive: true);
  for (final e in src.listSync(followLinks: false)) {
    final name = e.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
    if (name.startsWith('bazel-') || _skip.contains(name)) continue;
    final target = '${dst.path}/$name';
    if (e is Directory) {
      _copy(e, Directory(target));
    } else if (e is File) {
      e.copySync(target);
    } else if (e is Link) {
      Link(target).createSync(e.targetSync());
    }
  }
}

/// Writes `.bazelrc.user` in [workspace]: the rule modules overridden to
/// [repo]'s (rules_flutter only for a [flutter] workspace), then [lines].
void writeBazelrcUser(
  String workspace,
  String repo,
  List<String> lines, {
  required bool flutter,
}) {
  File('$workspace/.bazelrc.user').writeAsStringSync(
    [
      'common --override_module=ai_rules_dart=$repo/rules_dart',
      if (flutter)
        'common --override_module=ai_rules_flutter=$repo/rules_flutter',
      ...lines,
      '',
    ].join('\n'),
  );
}

/// A copy of a repository workspace (`rules_dart/e2e/dart_test`, say) in the
/// scratch directory, pointed at the repository's rules. The copy is made
/// once and kept, so its Bazel output base is reused between harness runs;
/// [refresh] makes it again.
String e2eCopy(
  String repo,
  String scratch,
  String relPath, {
  List<String> rcLines = const [],
  bool refresh = false,
  String? as,
}) {
  final flutter = relPath.startsWith('rules_flutter/');
  final name = as ?? relPath.replaceAll('/', '_');
  final dir = '$scratch/ws/$name';
  final stamp = File('$dir/.bench-copied');
  if (refresh || !stamp.existsSync()) {
    copyTree('$repo/$relPath', dir);
    stamp.writeAsStringSync(relPath);
  }
  writeBazelrcUser(dir, repo, rcLines, flutter: flutter);
  // A workspace whose .bazelrc does not import the user file gets it here.
  final rc = File('$dir/.bazelrc');
  final text = rc.existsSync() ? rc.readAsStringSync() : '';
  if (!text.contains('.bazelrc.user')) {
    rc.writeAsStringSync('$text\ntry-import %workspace%/.bazelrc.user\n');
  }
  return dir;
}

/// One file of a workspace that a flow edits; [restore] puts the original
/// bytes back.
final class Edited {
  /// The file at [path], read now.
  Edited(this.path) : original = File(path).readAsStringSync();

  /// The file.
  final String path;

  /// Its content before any edit.
  final String original;

  /// Writes the original with [line] inserted after the first line that
  /// contains [anchor] (a body edit when the anchor opens a body).
  void insertAfter(String anchor, String line) {
    final lines = original.split('\n');
    final at = lines.indexWhere((l) => l.contains(anchor));
    if (at < 0) throw StateError('$path has no line containing "$anchor"');
    lines.insert(at + 1, line);
    File(path).writeAsStringSync(lines.join('\n'));
  }

  /// Writes the original with [text] appended.
  void append(String text) {
    final sep = original.endsWith('\n') ? '' : '\n';
    File(path).writeAsStringSync('$original$sep$text\n');
  }

  /// Writes the original with the first [from] replaced by [to].
  void replace(String from, String to) {
    if (!original.contains(from)) throw StateError('$path has no "$from"');
    File(path).writeAsStringSync(original.replaceFirst(from, to));
  }

  /// Writes the original back.
  void restore() => File(path).writeAsStringSync(original);
}

/// A Dart body edit: a local whose initialiser is [n], so the kernel
/// changes and the outline does not.
String dartBodyLine(int n) =>
    '  // ignore: unused_local_variable\n  final benchEdit = $n;';

/// A Dart API edit: a public top-level function whose default value is [n],
/// so the outline changes and every importer recompiles.
String dartApiDecl(int n) =>
    '/// Bench API edit.\nint benchApi([int a = $n]) => a;';

/// A Kotlin edit: a private top-level function returning [n].
String kotlinDecl(int n) => 'private fun benchEdit(): Long = ${n}L';
