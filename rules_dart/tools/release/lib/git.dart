/// The git facts a release decision needs.
library;

import 'dart:convert';
import 'dart:io';

import 'package:release/release.dart';

/// Runs git in [root] and returns its trimmed standard output; [stdin] is
/// piped in (for `interpret-trailers`). Throws a [StateError] carrying git's
/// standard error when git fails.
Future<String> git(String root, List<String> args, {String? stdin}) async {
  // git needs the runner's environment (HOME, PATH, safe.directory config).
  final Process process = await Process.start(
    'git',
    args,
    workingDirectory: root,
    environment: Platform.environment,
    includeParentEnvironment: false,
  );
  final Future<String> out = process.stdout.transform(utf8.decoder).join();
  final Future<String> err = process.stderr.transform(utf8.decoder).join();
  if (stdin != null) process.stdin.write(stdin);
  await process.stdin.close();
  final int code = await process.exitCode;
  if (code != 0) {
    throw StateError('git ${args.join(' ')} failed ($code): ${await err}');
  }
  return (await out).trim();
}

/// The commits of `since..to` that touch [path] (a directory from [root]),
/// oldest last, without merges: a commit that touches two modules is in the
/// list of both.
Future<List<Commit>> commitsTouching(
  String root,
  String since,
  String to,
  String path,
) async {
  final Iterable<String> shas = (await git(root, [
    'rev-list',
    '--no-merges',
    '$since..$to',
    '--',
    path,
  ])).split('\n').where((s) => s.isNotEmpty);
  final commits = <Commit>[];
  for (final sha in shas) {
    final String message = await git(root, ['log', '-1', '--format=%B', sha]);
    final String trailers = await git(root, [
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
  return commits;
}
