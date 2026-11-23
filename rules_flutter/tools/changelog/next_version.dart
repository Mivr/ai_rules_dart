// Decides whether a commit is worth releasing, and as which version, for
// auto-release.yaml.
//
//   bazel run //tools/changelog:next_version -- --since <tag> --to <rev>
//   (in rules_dart: cd tools && bazel run //changelog:next_version -- ...)
//
// Prints the next version (vMAJOR.MINOR.PATCH) when a commit in
// `<since>..<to>` carries a `Changelog:` entry other than `skip`, and prints
// nothing otherwise, or when `<to>` is already tagged. The version bumps the
// newest `v*.*.*` tag, which can be newer than `<since>` when a tag's release
// was refused: a `feat` or breaking (`!`) commit bumps the minor while the
// major is 0 (a breaking one bumps the major from 1.0 on), anything else the
// patch.
//
// Identical in rules_dart and rules_flutter.
import 'dart:convert';
import 'dart:io';

final _semver = RegExp(r'^v(\d+)\.(\d+)\.(\d+)$');
final _feature = RegExp(r'^feat(\([^)]+\))?!?: ');
final _breaking = RegExp(r'^[a-z]+(\([^)]+\))?!: ');

final String _repo =
    Platform.environment['BUILD_WORKSPACE_DIRECTORY'] ?? Directory.current.path;

/// One commit: its subject line and its `Changelog:` trailer values.
typedef Commit = ({String subject, List<String> entries});

/// The version to release after [latestTag] for [commits], or null when none
/// of them carries a `Changelog:` entry other than `skip`.
String? nextVersion(String latestTag, List<Commit> commits) {
  final RegExpMatch? m = _semver.firstMatch(latestTag);
  if (m == null) {
    throw FormatException('not a vMAJOR.MINOR.PATCH tag: $latestTag');
  }
  final bool notable = commits.any(
    (c) => c.entries.any((e) => e.isNotEmpty && e != 'skip'),
  );
  if (!notable) return null;
  int major = int.parse(m[1]!);
  int minor = int.parse(m[2]!);
  int patch = int.parse(m[3]!);
  final bool breaking = commits.any((c) => _breaking.hasMatch(c.subject));
  final bool feature = commits.any((c) => _feature.hasMatch(c.subject));
  if (breaking && major > 0) {
    major++;
    minor = 0;
    patch = 0;
  } else if (breaking || feature) {
    minor++;
    patch = 0;
  } else {
    patch++;
  }
  return 'v$major.$minor.$patch';
}

/// The newest of [tags] that is a vMAJOR.MINOR.PATCH tag, or null.
String? newestTag(Iterable<String> tags) {
  List<int>? best;
  String? bestTag;
  for (final tag in tags) {
    final RegExpMatch? m = _semver.firstMatch(tag.trim());
    if (m == null) continue;
    final List<int> v = [for (var i = 1; i <= 3; i++) int.parse(m[i]!)];
    if (best == null || _compare(v, best) > 0) {
      best = v;
      bestTag = tag.trim();
    }
  }
  return bestTag;
}

int _compare(List<int> a, List<int> b) {
  for (var i = 0; i < 3; i++) {
    if (a[i] != b[i]) return a[i] - b[i];
  }
  return 0;
}

Future<void> main(List<String> args) async {
  String? since;
  String? to;
  for (var i = 0; i + 1 < args.length; i += 2) {
    switch (args[i]) {
      case '--since':
        since = args[i + 1];
      case '--to':
        to = args[i + 1];
    }
  }
  if (since == null || to == null || args.length != 4) {
    stderr.writeln('usage: next_version --since <tag> --to <rev>');
    exit(2);
  }
  final String pointsAt = await _git(['tag', '--points-at', to]);
  if (pointsAt.split('\n').any((t) => _semver.hasMatch(t.trim()))) {
    stderr.writeln('next_version: $to is already tagged ($pointsAt)');
    return;
  }
  final String? latest = newestTag(
    (await _git(['tag', '--list', 'v*.*.*'])).split('\n'),
  );
  if (latest == null) {
    stderr.writeln('next_version: no vMAJOR.MINOR.PATCH tag to bump');
    exit(1);
  }
  final commits = <Commit>[];
  final Iterable<String> shas = (await _git([
    'rev-list',
    '--no-merges',
    '$since..$to',
  ])).split('\n').where((s) => s.isNotEmpty);
  for (final sha in shas) {
    final String message = await _git(['log', '-1', '--format=%B', sha]);
    final String trailers = await _git([
      'interpret-trailers',
      '--parse',
    ], stdin: message);
    commits.add((
      subject: message.split('\n').first,
      entries: [
        for (final line in trailers.split('\n'))
          if (line.startsWith('Changelog:')) line.substring(10).trim(),
      ],
    ));
  }
  final String? next = nextVersion(latest, commits);
  if (next == null) {
    stderr.writeln(
      'next_version: no Changelog entry in $since..$to (${commits.length} '
      'commits); nothing to release',
    );
    return;
  }
  stdout.writeln(next);
}

/// Runs git in the repo; [stdin] is piped in for `interpret-trailers`.
Future<String> _git(List<String> args, {String? stdin}) async {
  // git needs the runner's environment (HOME, PATH, safe.directory config).
  final Process process = await Process.start(
    'git',
    args,
    workingDirectory: _repo,
    environment: Platform.environment,
    includeParentEnvironment: false,
  );
  final Future<String> out = process.stdout.transform(utf8.decoder).join();
  final Future<String> err = process.stderr.transform(utf8.decoder).join();
  if (stdin != null) process.stdin.write(stdin);
  await process.stdin.close();
  if (await process.exitCode != 0) {
    stderr.write(await err);
    exit(2);
  }
  return (await out).trim();
}
