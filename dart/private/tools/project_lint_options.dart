// Project lint rule keys (`rules_dart_project_lints`) in staged
// `analysis_options.yaml` files.
//
// Stock SDK `dart analyze` and `dart fix` do not know the wave-1 project
// rules: a staged options file enabling them makes the stock tools report
// `undefined_lint` for keys the hermetic `analyzer_summary` understands. The
// runners strip those keys from writable copies before invoking the stock
// tools, never through the symlinks into Bazel's read-only input tree.
import 'dart:io';

/// The `rules_dart_project_lints` rule keys the runners strip for stock tools.
const List<String> projectLintRuleKeys = <String>[
  'no_home_env_reads',
  'no_stdout_in_worker',
  'no_wall_clock_in_actions',
  'process_requires_environment',
];

/// Matches an `analysis_options.yaml` rule line enabling a project lint rule.
final RegExp _projectLintKeyLine = RegExp(
  '^[ \\t]*(?:${projectLintRuleKeys.join('|')})[ \\t]*:',
  multiLine: true,
);

/// Whether the `analysis_options.yaml` [content] enables any project lint
/// rule key.
bool projectOptionsContainLintKeys(String content) =>
    _projectLintKeyLine.hasMatch(content);

/// The `analysis_options.yaml` [content] with the project lint rule keys
/// removed, preserving every other byte.
String stripProjectLintKeys(String content) => content
    .split('\n')
    .where((line) => !_projectLintKeyLine.hasMatch(line))
    .join('\n');

/// The root-relative paths of staged `analysis_options.yaml` files under
/// [root] that enable project lint rule keys.
///
/// Reads through symlinks (never a write) so the read-only input tree is
/// never mutated. `.dart_tool` directories hold no options files and are not
/// descended into.
Set<String> findStagedProjectLintOptions(String root) {
  final found = <String>{};
  final queue = [Directory(root)];
  while (queue.isNotEmpty) {
    final Directory dir = queue.removeLast();
    for (final FileSystemEntity entity in dir.listSync(followLinks: false)) {
      if (FileSystemEntity.isDirectorySync(entity.path)) {
        if (_basename(entity.path) != '.dart_tool') {
          queue.add(Directory(entity.path));
        }
      } else if (FileSystemEntity.isFileSync(entity.path) &&
          _basename(entity.path) == 'analysis_options.yaml' &&
          projectOptionsContainLintKeys(File(entity.path).readAsStringSync())) {
        found.add(_relative(root, entity.path));
      }
    }
  }
  return found;
}

/// Strips the project lint rule keys from every staged options file under
/// [root], in place. Returns the stripped root-relative paths.
///
/// Only call on a writable copy (such as a fix scratch directory), never on
/// the staged tree itself: the staged options files may be symlinks into
/// Bazel's read-only input tree.
Set<String> stripStagedProjectLintOptions(String root) {
  final stripped = <String>{};
  for (final String relative in findStagedProjectLintOptions(root)) {
    final file = File('$root/$relative');
    file.writeAsStringSync(stripProjectLintKeys(file.readAsStringSync()));
    stripped.add(relative);
  }
  return stripped;
}

/// The last path segment of [path], across `/` and `\` separators.
String _basename(String path) {
  final int slash = path.lastIndexOf('/');
  final int backslash = path.lastIndexOf(r'\');
  final cut = slash > backslash ? slash : backslash;
  return cut < 0 ? path : path.substring(cut + 1);
}

/// The part of [path] below [root], in the `/`-separated form the runners
/// use for staged paths.
String _relative(String root, String path) {
  String relative = path.substring(root.length).replaceAll(r'\', '/');
  while (relative.startsWith('/')) {
    relative = relative.substring(1);
  }
  return relative;
}
