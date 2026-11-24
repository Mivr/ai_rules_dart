/// Checks that repositories are shared through the repo contents cache.
///
/// In two fresh `--output_base`s that share the repository cache and one
/// temporary `--repo_contents_cache`, runs `bazel fetch` for each repo and
/// asserts both `external/<repo>` entries are symlinks to the same cache entry
/// holding one extraction, with no absolute or repository-escaping symlink in
/// it. `--expect=real` asserts the opposite for repos that must stay unmarked
/// (the `local_path` repos in `e2e/smoke`): each is a real directory.
///
/// Run from the repo root: `bazel run //tools/repo_contents_cache -- @@+flutter+flutter_sky_engine`.
library;

import 'dart:io';

import 'bazel_fetch.dart';
import 'cache_check.dart';

const String _usage =
    'usage: check_repo_contents_cache [--workspace=DIR] [--expect=cached|real]\n'
    '       [--bazel=CMD] [--repository_cache=DIR] repo...\n'
    '  repo is an apparent name (@name) or canonical name (@@name).';

/// What the run was asked to check.
typedef CheckRequest = ({
  FetchConfig config,
  List<String> repos,
  bool expectReal,
});

String? _option(List<String> args, String name) {
  for (final arg in args) {
    if (arg.startsWith('--$name=')) return arg.substring(name.length + 3);
  }
  return null;
}

/// Parses [args] into a request whose cache lives under [tempRoot].
CheckRequest? parseRequest(List<String> args, String tempRoot) {
  final List<String> repos = args
      .where((String a) => !a.startsWith('--'))
      .toList();
  final String? root = Platform.environment['BUILD_WORKSPACE_DIRECTORY'];
  final String? given = _option(args, 'workspace');
  final String? workspace =
      given == null || root == null || given.startsWith('/')
      ? given ?? root
      : '$root/$given';
  final String expect = _option(args, 'expect') ?? 'cached';
  if (repos.isEmpty ||
      workspace == null ||
      !<String>['cached', 'real'].contains(expect)) {
    return null;
  }
  return (
    config: (
      bazel: _option(args, 'bazel') ?? 'bazel',
      workspace: workspace,
      contentsCache: '$tempRoot/repo_contents_cache',
      repositoryCache: _option(args, 'repository_cache'),
    ),
    repos: repos,
    expectReal: expect == 'real',
  );
}

/// Fetches into two fresh output bases and returns every problem found.
List<String> runCheck(CheckRequest request, String tempRoot) {
  final bases = <String>['$tempRoot/base_a', '$tempRoot/base_b'];
  final problems = <String>[];
  try {
    for (final base in bases) {
      final String? failure = fetchInto(request.config, base, request.repos);
      if (failure != null) return <String>[failure];
    }
    final ResolvedRepos resolved = resolveRepos(
      request.config,
      bases.first,
      request.repos,
    );
    if (resolved.error != null) return <String>[resolved.error!];
    for (final String canonical in resolved.canonical.values) {
      problems.addAll(
        request.expectReal
            ? checkRealDirectory((outputBase: bases.first, repo: canonical))
            : _checkShared(bases, canonical),
      );
    }
  } finally {
    for (final base in bases) {
      shutdownBase(request.config, base);
    }
  }
  return problems;
}

List<String> _checkShared(List<String> bases, String canonical) {
  final problems = <String>[];
  final entries = <String>{};
  for (final base in bases) {
    final CachedCheck checked = checkCachedRepo((
      outputBase: base,
      repo: canonical,
    ));
    problems.addAll(checked.problems);
    if (checked.entry != null) entries.add(checked.entry!);
  }
  if (entries.length > 1) {
    problems.add('$canonical: the output bases hold different cache entries');
  }
  return problems;
}

/// CLI entry point.
void main(List<String> args) {
  final Directory temp = Directory.systemTemp.createTempSync('repo_cache_');
  try {
    final CheckRequest? request = parseRequest(args, temp.path);
    if (request == null) {
      stderr.writeln(_usage);
      exitCode = 2;
      return;
    }
    final List<String> problems = runCheck(request, temp.path);
    if (problems.isNotEmpty) {
      for (final problem in problems) {
        stderr.writeln('error: $problem');
      }
      exitCode = 1;
      return;
    }
    stdout.writeln(
      'ok: ${request.repos.length} repos '
      '${request.expectReal ? "are real directories" : "share one cache entry"}',
    );
  } finally {
    temp.deleteSync(recursive: true);
  }
}
