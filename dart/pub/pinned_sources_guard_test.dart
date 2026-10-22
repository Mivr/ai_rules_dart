import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

/// Enumeration of every fetch call site in `//dart/pub` through the shared
/// pinned-source validation and the shared two-phase host-git helpers.
///
/// A package source that stops going through `pinned_source_error` before it
/// fetches — or a git checkout that stops going through both
/// `git_transport_fetch` and `git_materialize` — must fail the
/// `every fetch goes through the shared validation` test below: each
/// Starlark file in `//dart/pub` is passed as a test argument (see
/// BUILD.bazel) and any file that fetches must contain the enforcement
/// markers. Files that never fetch (`defs.bzl`, `pub_lock_hub.bzl`,
/// `yaml_parser.bzl`, the `private` helpers other than `pub_repository.bzl`)
/// are deliberately absent from the markers: they download nothing.
///
/// `pinned_sources.bzl` is the single validation entry point and the single
/// place that runs host `git`, split into exactly two phases:
/// `git_transport_fetch` (bare-repository transport fetch assembled without
/// `git init`, which may inherit the host's transport configuration) and
/// `git_materialize` (fully isolated verification and archive). A new `git`
/// invocation that bypasses the helpers — spelling the `git` binary, a git
/// subcommand, or `ctx.execute` in any other file — fails the `only the
/// shared helpers run git` tests below, and a git call inside the helper
/// that leaves either phase (a subcommand outside transport/materialization,
/// an `execute` without `--no-replace-objects`, a reintroduced `git init`)
/// fails the phase-boundary tests: every argv list is spelled out at its
/// call site precisely so the boundary is greppable.

/// The test's Starlark sources by file name, from the `rlocationpath`
/// arguments under Bazel or from the source tree for a direct `dart test`
/// run.
Map<String, String> _bzlSources(List<String> args) {
  const names = [
    'defs.bzl',
    'extensions.bzl',
    'pinned_sources.bzl',
    'pub_lock_hub.bzl',
    'pub_lock_package.bzl',
    'pub_lock_scc.bzl',
    'yaml_parser.bzl',
    'build_content.bzl',
    'language_version.bzl',
    'pub_repository.bzl',
    'pub_symlink.bzl',
    'scc.bzl',
    'version.bzl',
    'yaml_subset.bzl',
  ];
  if (args.isEmpty) {
    return {
      for (final name in names)
        name: File.fromUri(
          Platform.script.resolve(
            _topLevel.contains(name) ? name : 'private/$name',
          ),
        ).path,
    };
  }
  final runfiles = Runfiles.create();
  final sources = <String, String>{};
  for (final arg in args) {
    sources[arg.split('/').last] = runfiles.rlocation(arg);
  }
  return sources;
}

const _topLevel = {
  'defs.bzl',
  'extensions.bzl',
  'pinned_sources.bzl',
  'pub_lock_hub.bzl',
  'pub_lock_package.bzl',
  'pub_lock_scc.bzl',
  'yaml_parser.bzl',
};

/// Every fetch call site in `//dart/pub` and the marker proving it goes
/// through the shared validation entry point. A file without its marker
/// fails. A download counts as a fetch whether it spells the Bazel primitive
/// or the fail-closed digest helper: `pinned_download(` refuses a missing or
/// malformed digest before any bytes move and passes the digest to
/// `ctx.download`, so calling it is the validated path.
/// (`pinned_download_and_extract(` does not contain the `pinned_download(`
/// prefix — the `_and_extract` infix sits between them — so both spellings
/// are listed.)
const _downloadMarkers = [
  'ctx.download(',
  'ctx.download_and_extract(',
  'pinned_download(',
  'pinned_download_and_extract(',
];

/// The `git` binary spelled as a `ctx.execute` argument list. Only the shared
/// helpers in `pinned_sources.bzl` may contain it: every other file fetches
/// git packages through `git_transport_fetch(` and `git_materialize(`.
const _gitMarker = '["git"';

/// The two phases. Every git call site runs both: transport first, then
/// materialization. A call site that runs one without the other fails.
const _gitHelpers = ['git_transport_fetch(', 'git_materialize('];

/// Helpers that predated the two-phase design. A reintroduction fails.
const _retiredHelpers = [
  'git_clone(',
  'git_fetch(',
  'git_checkout(',
  'git_archive(',
  'verify_git_checkout(',
];
const _validatorMarker = 'pinned_source_error(';

/// Git subcommands and flags that only the two phases may spell. A new git
/// operation anywhere else — or a new phase operation that leaves the two
/// helpers — fails. (`git init` is deliberately absent: transport assembles
/// the bare repository without it, and a separate test fails any
/// reintroduction.)
const _phaseMarkers = [
  '"fetch"',
  '"rev-parse"',
  '"archive"',
  '"cat-file"',
  '"count-objects"',
  '--git-dir=',
  '--no-replace-objects',
];

bool _fetchesDownload(String text) => _downloadMarkers.any(text.contains);

/// Whether the file runs host `git`: either by spelling the binary (only the
/// helpers may) or by calling one of the shared two-phase helpers.
bool _runsGit(String text) =>
    text.contains(_gitMarker) || _gitHelpers.any(text.contains);

void main(List<String> args) {
  group('every fetch goes through the shared validation', () {
    test('the enumerated sources are exactly the tested files', () {
      final sources = _bzlSources(args);
      expect(sources.keys, unorderedEquals([..._topLevel, ..._private]));
    });

    test('the single entry point is defined once, in pinned_sources.bzl', () {
      final sources = _bzlSources(args);
      for (final entry in sources.entries) {
        final text = File(entry.value).readAsStringSync();
        if (entry.key == 'pinned_sources.bzl') {
          expect(
            text.contains('def pinned_source_error('),
            isTrue,
            reason: 'pinned_sources.bzl must define $_validatorMarker',
          );
          for (final helper in _gitHelpers) {
            expect(
              text.contains('def $helper'),
              isTrue,
              reason: 'pinned_sources.bzl must define $helper',
            );
          }
          for (final retired in _retiredHelpers) {
            expect(
              text.contains('def $retired'),
              isFalse,
              reason:
                  'pinned_sources.bzl must not reintroduce $retired; '
                  'fetch through the two phases instead',
            );
          }
        } else {
          expect(
            text.contains('def pinned_source_error('),
            isFalse,
            reason:
                '${entry.key} must not redefine $_validatorMarker; '
                'call the single entry point instead',
          );
          for (final helper in [..._gitHelpers, ..._retiredHelpers]) {
            expect(
              text.contains('def $helper'),
              isFalse,
              reason:
                  '${entry.key} must not redefine $helper; '
                  'call the shared helpers instead',
            );
          }
        }
      }
    });

    test('every download is validated before it fetches', () {
      final sources = _bzlSources(args);
      var gated = 0;
      for (final entry in sources.entries) {
        final text = File(entry.value).readAsStringSync();
        if (!_fetchesDownload(text)) continue;
        gated++;
        expect(
          text.contains(_validatorMarker),
          isTrue,
          reason:
              '${entry.key} downloads a package but never calls '
              '$_validatorMarker',
        );
      }
      expect(
        gated,
        greaterThan(0),
        reason: 'no download call site found; the test would pass vacuously',
      );
    });

    test('every git checkout is validated and runs both phases', () {
      final sources = _bzlSources(args);
      var gated = 0;
      for (final entry in sources.entries) {
        if (entry.key == 'pinned_sources.bzl') continue;
        final text = File(entry.value).readAsStringSync();
        if (!_runsGit(text)) continue;
        gated++;
        expect(
          text.contains(_validatorMarker),
          isTrue,
          reason: '${entry.key} runs git but never calls $_validatorMarker',
        );
        for (final helper in _gitHelpers) {
          expect(
            text.contains(helper),
            isTrue,
            reason:
                '${entry.key} runs git but never calls $helper; '
                'a fetch that skips either phase is unverified',
          );
        }
      }
      expect(
        gated,
        greaterThan(0),
        reason: 'no git call site found; the test would pass vacuously',
      );
    });

    test('only the shared helpers spell the git binary', () {
      final sources = _bzlSources(args);
      final spelling = [
        for (final entry in sources.entries)
          if (File(entry.value).readAsStringSync().contains(_gitMarker))
            entry.key,
      ];
      expect(
        spelling,
        equals(['pinned_sources.bzl']),
        reason:
            'only pinned_sources.bzl may spell $_gitMarker; '
            'fetch through git_transport_fetch( and git_materialize( '
            'instead (offenders: $spelling)',
      );
    });

    test('only the shared helpers run git commands', () {
      final sources = _bzlSources(args);
      // The phase boundary: every git subcommand, flag and executor lives
      // in the two helpers. A git call anywhere else — a new fetch path
      // that bypasses the phases, or a new operation inside a call site —
      // spells one of these markers outside pinned_sources.bzl and fails.
      for (final marker in [..._phaseMarkers, 'ctx.execute(']) {
        final spelling = [
          for (final entry in sources.entries)
            if (File(entry.value).readAsStringSync().contains(marker))
              entry.key,
        ];
        expect(
          spelling,
          equals(['pinned_sources.bzl']),
          reason:
              'only pinned_sources.bzl may spell $marker; '
              'a git call outside git_transport_fetch( and git_materialize( '
              'runs unverified (offenders: $spelling)',
        );
      }
    });

    test('every git invocation disables replace refs', () {
      // `--no-replace-objects` is spelled out at every `ctx.execute` call
      // (not hidden in a shared list) so a new invocation without it fails
      // here: a host `refs/replace/*` ref must never change the archived
      // tree while verification still sees the pinned commit.
      final sources = _bzlSources(args);
      final text = File(sources['pinned_sources.bzl']!).readAsStringSync();
      final calls = text.split('ctx.execute(');
      expect(
        calls.length,
        greaterThan(1),
        reason: 'no git invocation found; the test would pass vacuously',
      );
      for (var i = 1; i < calls.length; i++) {
        expect(
          calls[i].contains('--no-replace-objects'),
          isTrue,
          reason:
              'git invocation $i in pinned_sources.bzl spells no '
              '--no-replace-objects; every phase command must disable '
              'replace refs',
        );
      }
    });

    test('every git call site uses the shared helpers', () {
      final sources = _bzlSources(args);
      var gated = 0;
      for (final entry in sources.entries) {
        if (entry.key == 'pinned_sources.bzl') continue;
        final text = File(entry.value).readAsStringSync();
        if (!_gitHelpers.any(text.contains)) continue;
        gated++;
        expect(
          text.contains('pinned_sources.bzl'),
          isTrue,
          reason:
              '${entry.key} calls the shared git helpers but never loads '
              'pinned_sources.bzl',
        );
      }
      expect(
        gated,
        greaterThan(0),
        reason: 'no git helper call site found; the test would pass vacuously',
      );
    });

    test('transport keeps working while hooks and fsmonitor stay off', () {
      final sources = _bzlSources(args);
      final text = File(sources['pinned_sources.bzl']!).readAsStringSync();
      // The transport phase inherits the host's transport configuration
      // (credentials, insteadOf, proxies) from its config files and the
      // allowlisted transport variables, while every code-executing and
      // resolution knob is pinned on the command line or unset (`None`,
      // never empty) in the environment. The bare repository is assembled
      // without `git init`, so host templates have no channel at all.
      for (final marker in [
        '"fetch"',
        '_TRANSPORT_PASSTHROUGH',
        'GIT_WORK_TREE',
        'GIT_CONFIG_COUNT',
        'core.hooksPath=',
        'core.fsmonitor=false',
        'core.untrackedCache=false',
        'GIT_OBJECT_DIRECTORY',
        'GIT_COMMON_DIR',
        'GIT_ALLOW_PROTOCOL',
        'repositoryformatversion',
        'info/attributes',
      ]) {
        expect(
          text.contains(marker),
          isTrue,
          reason:
              'pinned_sources.bzl must apply $marker on the transport '
              'phase, so host templates, hooks, fsmonitor and object '
              'redirection cannot change bytes or run code while '
              'transport configuration keeps working',
        );
      }
    });

    test('transport never runs git init', () {
      // `git init` is the one command a stray `GIT_WORK_TREE` breaks (git
      // refuses it while that variable is set, even empty) and the only
      // channel a host template enters through. Transport assembles the
      // bare skeleton with `ctx.file` instead; reintroducing an init
      // subcommand in any enumerated file fails here.
      final sources = _bzlSources(args);
      final spelling = [
        for (final entry in sources.entries)
          if (File(entry.value).readAsStringSync().contains('"init"'))
            entry.key,
      ];
      expect(
        spelling,
        isEmpty,
        reason:
            'no enumerated file may spell "init"; transport assembles the '
            'bare repository without running git (offenders: $spelling)',
      );
    });

    test('the materialization helper neutralizes host git configuration', () {
      final sources = _bzlSources(args);
      final text = File(sources['pinned_sources.bzl']!).readAsStringSync();
      // The conversion knobs pinned on the `git archive` command line: `-c`
      // beats both config files and environment on every git version.
      for (final pin in [
        'core.autocrlf=false',
        'core.eol=lf',
        'core.attributesfile=',
        'core.hooksPath=',
        'core.fsmonitor=false',
        'tar.umask=',
      ]) {
        expect(
          text.contains(pin),
          isTrue,
          reason: 'pinned_sources.bzl must pin $pin for git archive',
        );
      }
      // The isolated materialization environment: an explicit `--git-dir`
      // of the bare repository, replacements disabled twice (flag and
      // variable), every config source pointed at empty files or emptied,
      // alternates refused and the commit, its type and its tree verified
      // before the archive streams from the same repository.
      for (final name in [
        '--git-dir=',
        'GIT_NO_REPLACE_OBJECTS',
        'GIT_CONFIG_NOSYSTEM',
        'GIT_CONFIG_COUNT',
        'GIT_CONFIG_PARAMETERS',
        'GIT_CONFIG_GLOBAL',
        'GIT_CONFIG_SYSTEM',
        'XDG_CONFIG_HOME',
        'GIT_ALTERNATE_OBJECT_DIRECTORIES',
        'GIT_OBJECT_DIRECTORY',
        'GIT_COMMON_DIR',
        'count-objects',
        'alternate:',
        'cat-file',
        '^{commit}',
        '^{tree}',
      ]) {
        expect(
          text.contains(name),
          isTrue,
          reason: 'pinned_sources.bzl must apply $name for git materialization',
        );
      }
    });

    test('no git step consults host templates', () {
      final sources = _bzlSources(args);
      final text = File(sources['pinned_sources.bzl']!).readAsStringSync();
      // No `init` runs and no `--template` flag is spelled anywhere, so a
      // hostile `init.templateDir` has nothing to act on; the template
      // directory variable is still scrubbed, and the hook pin and the
      // repository-local attributes truncation stay as defense in depth.
      for (final marker in ['--template', '"init"']) {
        expect(
          text.contains(marker),
          isFalse,
          reason:
              'pinned_sources.bzl must not spell $marker: templates enter '
              'only through init, which transport no longer runs',
        );
      }
      for (final marker in [
        'GIT_TEMPLATE_DIR',
        'core.hooksPath=',
        'info/attributes',
      ]) {
        expect(
          text.contains(marker),
          isTrue,
          reason:
              'pinned_sources.bzl must apply $marker on every git step, '
              'so host hooks cannot run code',
        );
      }
    });
  });
}

const _private = {
  'build_content.bzl',
  'language_version.bzl',
  'pub_repository.bzl',
  'pub_symlink.bzl',
  'scc.bzl',
  'version.bzl',
  'yaml_subset.bzl',
};
