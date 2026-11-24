/// The decisions of a release of one module of this repository.
///
///     cd rules_dart/tools
///     bazel run //release:release -- <command> [options]
///
/// See `--help`.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:release/floor.dart';
import 'package:release/git.dart';
import 'package:release/modules.dart';
import 'package:release/release.dart';

const _usage = '''
The decisions of a release of one module of this repository.

  bazel run //release:release -- <command> [options]

Commands (each takes --module=rules_dart|rules_flutter)
  latest                 Print the newest released version (`v0.28.3`): the
                         module's baseline, or its newest tag.
  tag --version=vX.Y.Z   Print the tag for that version (`rules_dart-v0.29.0`)
                         when it may be created: a new, newer one. Else exit 1.
  next --to=REV [--published=FILE] [--since=REF]
                         Print the version REV should be released as, when a
                         commit since the newest published release that
                         touches the module carries a `Changelog:` entry other
                         than `skip`. Print nothing when there is none, or
                         when REV is already tagged.
  base --tag=TAG --published=FILE
                         Print the git ref the release notes of TAG start at.
  floor check            Fail, listing the places, when the floor of
                         rules_flutter on ai_rules_dart differs between
                         MODULE.bazel files, tables, docs and README.
  floor set X.Y.Z        Write that floor at all of them.

Options
  --published=FILE       The tags that have a published release, one per line;
                         `-` reads them from standard input.
  --root=DIR             The repository root (default: found from the current
                         directory or \$BUILD_WORKING_DIRECTORY).

A commit is the module's when it touches the module's directory; one that
touches both modules belongs to both. The modules are listed in
.github/release.json.
''';

Future<void> main(List<String> args) async {
  if (args.isEmpty || args.first == '--help' || args.first == '-h') {
    stdout.write(_usage);
    return;
  }
  final String command = args.first;
  final rest = <String>[];
  final options = <String, String>{};
  for (final a in args.skip(1)) {
    if (a.startsWith('--') && a.contains('=')) {
      final int i = a.indexOf('=');
      options[a.substring(2, i)] = a.substring(i + 1);
    } else {
      rest.add(a);
    }
  }

  final String root =
      options['root'] ??
      await _gitRoot(
        Platform.environment['BUILD_WORKING_DIRECTORY'] ??
            Platform.environment['BUILD_WORKSPACE_DIRECTORY'] ??
            Directory.current.path,
      );
  try {
    switch (command) {
      case 'floor':
        _floor(root, rest);
      default:
        await _moduleCommand(command, root, options);
    }
  } on FormatException catch (e) {
    stderr.writeln('release: ${e.message}');
    exit(1);
  } on StateError catch (e) {
    stderr.writeln('release: ${e.message}');
    exit(1);
  }
}

void _floor(String root, List<String> rest) {
  if (rest.length == 1 && rest.first == 'check') {
    final List<String> problems = checkFloor(root);
    if (problems.isEmpty) {
      stdout.writeln(declaredFloor(root));
      return;
    }
    problems.forEach(stderr.writeln);
    stderr.writeln(
      'release: ${problems.length} place(s) disagree; '
      '`bazel run //release:release -- floor set X.Y.Z` writes one floor',
    );
    exit(1);
  }
  if (rest.length == 2 && rest.first == 'set') {
    final List<String> changed = setFloor(root, rest.last);
    stdout.writeln('floor ${rest.last}: changed ${changed.length} file(s)');
    changed.forEach((f) => stdout.writeln('  $f'));
    return;
  }
  stderr.write('usage: floor check | floor set X.Y.Z\n');
  exit(2);
}

Future<void> _moduleCommand(
  String command,
  String root,
  Map<String, String> options,
) async {
  final Map<String, ReleaseModule> modules = parseModules(
    File(p.join(root, '.github', 'release.json')).readAsStringSync(),
  );
  final String? name = options['module'];
  final ReleaseModule? module = modules[name];
  if (module == null) {
    stderr.writeln(
      'release: --module must be one of ${modules.keys.join(', ')}',
    );
    exit(2);
  }
  final List<String> tags = (await git(root, [
    'tag',
    '--list',
  ])).split('\n').where((t) => t.isNotEmpty).toList();

  switch (command) {
    case 'latest':
      stdout.writeln(showVersion(latestVersion(module, tags)));
    case 'tag':
      final String version = options['version'] ?? '';
      final String? problem = tagProblem(module, version, tags);
      if (problem != null) {
        stderr.writeln('release: $problem');
        exit(1);
      }
      stdout.writeln(module.tagOf(parseVersion(version)!));
    case 'base':
      final Version? target = parseVersion(
        _versionOfTag(module, options['tag']),
      );
      if (target == null) {
        stderr.writeln('release: --tag must be a tag of ${module.name}');
        exit(2);
      }
      stdout.writeln(notesBase(module, _published(options), before: target));
    case 'next':
      await _next(root, module, tags, options);
    default:
      stderr.write('release: unknown command "$command"\n$_usage');
      exit(2);
  }
}

String _versionOfTag(ReleaseModule module, String? tag) {
  final Version? v = tag == null ? null : module.versionOfTag(tag);
  return v == null ? '' : showVersion(v);
}

Future<void> _next(
  String root,
  ReleaseModule module,
  List<String> tags,
  Map<String, String> options,
) async {
  final String? to = options['to'];
  if (to == null) {
    stderr.writeln('release: next needs --to=REV');
    exit(2);
  }
  final String pointsAt = await git(root, ['tag', '--points-at', to]);
  if (pointsAt.split('\n').any((t) => module.versionOfTag(t) != null)) {
    stderr.writeln('release: $to is already tagged ($pointsAt)');
    return;
  }
  final String since =
      options['since'] ??
      notesBase(
        module,
        options.containsKey('published') ? _published(options) : tags,
      );
  final List<Commit> commits = await commitsTouching(
    root,
    since,
    to,
    module.name,
  );
  final Version? next = nextVersion(latestVersion(module, tags), commits);
  if (next == null) {
    stderr.writeln(
      'release: no Changelog entry in $since..$to that touches '
      '${module.name} (${commits.length} commits); nothing to release',
    );
    return;
  }
  stdout.writeln(showVersion(next));
}

List<String> _published(Map<String, String> options) {
  final String? file = options['published'];
  if (file == null) {
    stderr.writeln('release: this command needs --published=FILE');
    exit(2);
  }
  final String text = file == '-'
      ? _readStdin()
      : File(file).readAsStringSync();
  return const LineSplitter().convert(text).where((l) => l.isNotEmpty).toList();
}

String _readStdin() {
  final buffer = StringBuffer();
  String? line;
  while ((line = stdin.readLineSync()) != null) {
    buffer.writeln(line);
  }
  return buffer.toString();
}

Future<String> _gitRoot(String from) async {
  final ProcessResult r = await Process.run('git', [
    'rev-parse',
    '--show-toplevel',
  ], workingDirectory: from);
  if (r.exitCode != 0) {
    stderr.writeln('release: $from is not inside a git repository');
    exit(2);
  }
  return (r.stdout as String).trim();
}
