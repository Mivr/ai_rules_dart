/// `pub-fetch-unvalidated`: a package fetch in `dart/pub` that does not go
/// through the shared validation, or a `git` call outside the shared helpers.
library;

import 'package:inventory/finding.dart';
import 'package:inventory/source_tree.dart';

/// The rule's name in debt files.
const String pubFetchRule = 'pub-fetch-unvalidated';

/// Where the shared validation lives and which files may do what.
typedef PubFetchScope = ({
  /// The package directory, such as `rules_dart/dart/pub`.
  String dir,

  /// The file, relative to [dir], that defines the validator and the git
  /// helpers and is the only one that spells the `git` binary.
  String entry,

  /// Files, relative to [dir], that may call `ctx.execute(` because what they
  /// run is not `git`, each with the reason.
  Map<String, String> executors,

  /// Files, relative to [dir], that download something that is not a package,
  /// each with the reason.
  Map<String, String> notPackageFetches,
});

const String _validator = 'pinned_source_error(';
const List<String> _gitHelpers = ['git_transport_fetch(', 'git_materialize('];
const List<String> _retiredHelpers = [
  'git_clone(',
  'git_fetch(',
  'git_checkout(',
  'git_archive(',
  'verify_git_checkout(',
];
const List<String> _downloadMarkers = [
  'ctx.download(',
  'ctx.download_and_extract(',
  'pinned_download(',
  'pinned_download_and_extract(',
];

/// Git subcommands and flags that only the two shared phases may spell.
const List<String> _phaseMarkers = [
  '"fetch"',
  '"rev-parse"',
  '"archive"',
  '"cat-file"',
  '"count-objects"',
  '--git-dir=',
  '--no-replace-objects',
];

/// The package fetches of [scope]: every file that downloads a package calls
/// `pinned_source_error`; the only file that spells `git`, a git subcommand or
/// `ctx.execute(` is the entry (and the executors); a file that calls the git
/// helpers calls both and the validator; every `ctx.execute(` of the entry
/// spells `["git", "--no-replace-objects"`; and nobody runs `git init`.
List<Finding> checkPubFetch(SourceTree tree, PubFetchScope scope) {
  final prefix = '${scope.dir}/';
  final sources = <String, String>{
    for (final String p in tree.paths)
      if (p.startsWith(prefix) &&
          p.endsWith('.bzl') &&
          !p.substring(prefix.length).startsWith('tests/'))
        p.substring(prefix.length): tree.read(p),
  };
  if (!sources.containsKey(scope.entry)) {
    throw SetupException('${scope.dir}/${scope.entry} not found');
  }
  final findings = <Finding>[];
  void add(String file, String text, String needle, String message) {
    final int at = needle.isEmpty ? -1 : text.indexOf(needle);
    findings.add(
      Finding(
        rule: pubFetchRule,
        file: prefix + file,
        line: at < 0 ? 1 : '\n'.allMatches(text.substring(0, at)).length + 1,
        message: message,
        key: message,
      ),
    );
  }

  for (final MapEntry<String, String> source in sources.entries) {
    final String file = source.key;
    final String text = source.value;
    final isEntry = file == scope.entry;
    if (isEntry) {
      for (final String def in [
        'def pinned_source_error(',
        ..._gitHelpers.map((h) => 'def $h'),
      ]) {
        if (!text.contains(def)) add(file, text, '', 'must define $def');
      }
      for (final String retired in _retiredHelpers) {
        if (text.contains('def $retired')) {
          add(
            file,
            text,
            'def $retired',
            'must not define the retired helper $retired',
          );
        }
      }
      _checkExecutes(file, text, add);
      continue;
    }
    for (final String def in [
      'def pinned_source_error(',
      ..._gitHelpers.map((h) => 'def $h'),
      ..._retiredHelpers.map((h) => 'def $h'),
    ]) {
      if (text.contains(def)) {
        add(
          file,
          text,
          def,
          'must not define $def; call the shared one in ${scope.entry}',
        );
      }
    }
    final bool downloads = _downloadMarkers.any(text.contains);
    if (downloads &&
        !scope.notPackageFetches.containsKey(file) &&
        !text.contains(_validator)) {
      add(
        file,
        text,
        _firstOf(text, _downloadMarkers),
        'downloads without calling $_validator',
      );
    }
    final bool runsGit =
        text.contains('["git"') || _gitHelpers.any(text.contains);
    if (runsGit) {
      if (!text.contains(_validator)) {
        add(
          file,
          text,
          _firstOf(text, ['["git"', ..._gitHelpers]),
          'runs git without calling $_validator',
        );
      }
      for (final String helper in _gitHelpers) {
        if (!text.contains(helper)) {
          add(
            file,
            text,
            _firstOf(text, ['["git"', ..._gitHelpers]),
            'runs git without calling $helper; a fetch that skips a phase is unverified',
          );
        }
      }
      if (!text.contains('pinned_sources.bzl')) {
        add(
          file,
          text,
          _firstOf(text, _gitHelpers),
          'calls the git helpers without loading pinned_sources.bzl',
        );
      }
    }
    for (final String marker in ['["git"', ..._phaseMarkers]) {
      if (text.contains(marker)) {
        add(
          file,
          text,
          marker,
          'spells $marker outside ${scope.entry}; a git call outside the shared helpers runs unverified',
        );
      }
    }
    if (text.contains('ctx.execute(') && !scope.executors.containsKey(file)) {
      add(
        file,
        text,
        'ctx.execute(',
        'calls ctx.execute( outside ${scope.entry}; run git through the shared helpers',
      );
    }
    for (final marker in ['"init"', '--template']) {
      if (text.contains(marker)) {
        add(
          file,
          text,
          marker,
          'spells $marker; the bare repository is assembled without running git init',
        );
      }
    }
  }
  return findings;
}

/// Every `ctx.execute(` of the entry file spells the `git` binary with
/// replace refs disabled where it runs, so that a host `refs/replace/*` ref
/// cannot change the archived tree while verification sees the pinned commit.
void _checkExecutes(
  String file,
  String text,
  void Function(String, String, String, String) add,
) {
  final List<String> calls = text.split('ctx.execute(');
  for (var i = 1; i < calls.length; i++) {
    if (!calls[i].contains('["git", "--no-replace-objects"')) {
      add(
        file,
        text,
        'ctx.execute(',
        'git invocation $i does not spell ["git", "--no-replace-objects"] at its call site',
      );
    }
  }
  for (final marker in ['"init"', '--template']) {
    if (text.contains(marker)) {
      add(
        file,
        text,
        marker,
        'spells $marker; the bare repository is assembled without running git init',
      );
    }
  }
}

String _firstOf(String text, List<String> needles) {
  var best = '';
  int bestAt = text.length;
  for (final needle in needles) {
    final int at = text.indexOf(needle);
    if (at >= 0 && at < bestAt) {
      best = needle;
      bestAt = at;
    }
  }
  return best;
}
