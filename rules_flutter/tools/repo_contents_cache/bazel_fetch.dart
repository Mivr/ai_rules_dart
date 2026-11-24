/// Runs Bazel for the repo contents cache check: fetches into fresh output bases.
library;

import 'dart:convert';
import 'dart:io';

/// How to reach Bazel and which caches the fetches share.
typedef FetchConfig = ({
  String bazel,
  String workspace,
  String contentsCache,
  String? repositoryCache,
});

/// Runs `bazel` with [args] in the workspace and returns the process result.
ProcessResult runBazel(FetchConfig config, List<String> args) {
  return Process.runSync(
    config.bazel,
    args,
    workingDirectory: config.workspace,
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
}

/// The Bazel startup options that pin [outputBase] and let its server idle out.
List<String> startupOptions(String outputBase) => <String>[
  '--output_base=$outputBase',
  '--max_idle_secs=30',
];

/// Fetches [repos] (apparent `@name` or canonical `@@name`) into [outputBase].
///
/// Returns an error message when the fetch fails, `null` on success.
String? fetchInto(FetchConfig config, String outputBase, List<String> repos) {
  final ProcessResult result = runBazel(config, <String>[
    ...startupOptions(outputBase),
    'fetch',
    for (final String repo in repos) '--repo=$repo',
    '--repo_contents_cache=${config.contentsCache}',
    if (config.repositoryCache != null)
      '--repository_cache=${config.repositoryCache}',
  ]);
  if (result.exitCode == 0) return null;
  return 'bazel fetch failed in $outputBase (exit ${result.exitCode}):\n'
      '${result.stderr}';
}

/// The canonical repo names for the requested ones, or the first failure.
typedef ResolvedRepos = ({Map<String, String> canonical, String? error});

/// Maps each name in [repos] to its canonical repo directory name.
///
/// A name written `@@canonical` is taken as is; an apparent name is looked up
/// in the main repository's mapping (`bazel mod dump_repo_mapping ""`).
/// Returns the error text for the first name it cannot resolve in `error`.
ResolvedRepos resolveRepos(
  FetchConfig config,
  String outputBase,
  List<String> repos,
) {
  Map<String, Object?>? mapping;
  final canonical = <String, String>{};
  for (final repo in repos) {
    if (repo.startsWith('@@')) {
      canonical[repo] = repo.substring(2);
      continue;
    }
    mapping ??= _dumpMapping(config, outputBase);
    final Object? name = mapping?[repo.replaceFirst('@', '')];
    if (name is! String) {
      return (canonical: canonical, error: 'cannot resolve repo $repo');
    }
    canonical[repo] = name;
  }
  return (canonical: canonical, error: null);
}

Map<String, Object?>? _dumpMapping(FetchConfig config, String outputBase) {
  final ProcessResult result = runBazel(config, <String>[
    ...startupOptions(outputBase),
    'mod',
    'dump_repo_mapping',
    '',
  ]);
  if (result.exitCode != 0) return null;
  for (final String line in const LineSplitter().convert(
    result.stdout as String,
  )) {
    if (line.startsWith('{')) {
      return jsonDecode(line) as Map<String, Object?>;
    }
  }
  return null;
}

/// Shuts down the Bazel server that belongs to [outputBase].
void shutdownBase(FetchConfig config, String outputBase) {
  runBazel(config, <String>[...startupOptions(outputBase), 'shutdown']);
}
