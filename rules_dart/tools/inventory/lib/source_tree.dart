/// The files of the repository, listed once and read on demand.
library;

import 'dart:convert';
import 'dart:io';

/// The tracked files of a repository: relative paths and a way to read them.
///
/// The lint and the inventory both read through this class, so their tests
/// build a tree from a map of paths to text and never touch the disk.
class SourceTree {
  /// A tree over [files], a map from repository-relative path to its text.
  new inMemory(Map<String, String> files)
    : paths = (files.keys.toList()..sort()),
      _read = ((path) => files[path] ?? '');

  /// A tree over the files of the checkout at [root].
  ///
  /// Lists `git ls-files` when [root] is a git checkout, so untracked build
  /// output never counts, and walks the directory otherwise (a scratch copy).
  factory onDisk(String root) {
    final isGit =
        FileSystemEntity.typeSync('$root/.git') !=
        FileSystemEntityType.notFound;
    final List<String> paths = isGit ? _gitFiles(root) : _walk(root);
    paths.sort();
    return SourceTree._(
      paths,
      (path) => File('$root/$path').readAsStringSync(encoding: latin1),
    );
  }

  new _(this.paths, this._read);

  /// Repository-relative paths, sorted.
  final List<String> paths;

  final String Function(String path) _read;

  /// The text of [path]. Bytes are read as Latin-1 so that no file can fail
  /// to decode and every line count is exact.
  String read(String path) => _read(path);
}

List<String> _gitFiles(String root) {
  final ProcessResult result = Process.runSync(
    'git',
    ['-C', root, 'ls-files', '-z'],
    environment: Platform.environment,
    includeParentEnvironment: false,
    stdoutEncoding: utf8,
  );
  if (result.exitCode != 0) {
    throw FormatException('git ls-files failed in $root: ${result.stderr}');
  }
  return [
    for (final String path in (result.stdout as String).split('\u0000'))
      // A tracked symlink or a submodule is not a source file.
      if (path.isNotEmpty && FileSystemEntity.isFileSync('$root/$path')) path,
  ];
}

List<String> _walk(String root) {
  final found = <String>[];
  final stack = <Directory>[Directory(root)];
  while (stack.isNotEmpty) {
    for (final FileSystemEntity entry in stack.removeLast().listSync(
      followLinks: false,
    )) {
      final String name = entry.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
      if (name.startsWith('.') || name.startsWith('bazel-')) continue;
      if (entry is Directory) {
        stack.add(entry);
      } else if (entry is File) {
        found.add(entry.path.substring(root.length + 1));
      }
    }
  }
  return found;
}

/// The number of lines in [text], counting an unterminated last line.
int countLines(String text) {
  if (text.isEmpty) return 0;
  var lines = 0;
  for (int i = text.indexOf('\n'); i >= 0; i = text.indexOf('\n', i + 1)) {
    lines++;
  }
  return text.endsWith('\n') ? lines : lines + 1;
}
