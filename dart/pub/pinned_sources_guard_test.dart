import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

/// Enumeration of every fetch call site in `//dart/pub` through the shared
/// pinned-source validation and the shared host-git helper.
///
/// A package source that stops going through `pinned_source_error` before it
/// fetches — or a git checkout that stops being verified with
/// `verify_git_checkout` afterwards — must fail the
/// `every fetch goes through the shared validation` test below: each
/// Starlark file in `//dart/pub` is passed as a test argument (see
/// BUILD.bazel) and any file that fetches must contain the enforcement
/// markers. Files that never fetch (`defs.bzl`, `pub_lock_hub.bzl`,
/// `yaml_parser.bzl`, the `private` helpers other than `pub_repository.bzl`)
/// are deliberately absent from the markers: they download nothing.
///
/// `pinned_sources.bzl` is the single validation entry point and the single
/// place that runs host `git` (`git_clone`, `git_fetch`, `git_checkout`,
/// `git_archive`). It performs no fetch itself besides the read-only
/// `rev-parse` checkout verification and the host-independent `git archive`
/// materialization, so a new `git` invocation that bypasses the helper —
/// spelling the `git` binary in any other file — fails the `only the shared
/// helper spells the git binary` test below, and a new clone that bypasses
/// the template isolation fails the `only the shared helper clones` test.

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
/// fails.
const _downloadMarkers = ['ctx.download(', 'ctx.download_and_extract('];

/// The `git` binary spelled as a `ctx.execute` argument list. Only the shared
/// helper in `pinned_sources.bzl` may contain it: every other file runs git
/// through `git_clone(`, `git_fetch(`, `git_checkout(` or `git_archive(`.
const _gitMarker = '["git"';
const _gitHelpers = [
  'git_clone(',
  'git_fetch(',
  'git_checkout(',
  'git_archive(',
];
const _validatorMarker = 'pinned_source_error(';
const _verifyMarker = 'verify_git_checkout(';

bool _fetchesDownload(String text) => _downloadMarkers.any(text.contains);

/// Whether the file runs host `git`: either by spelling the binary (only the
/// helper may) or by calling one of the shared helpers.
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
        } else {
          expect(
            text.contains('def pinned_source_error('),
            isFalse,
            reason:
                '${entry.key} must not redefine $_validatorMarker; '
                'call the single entry point instead',
          );
          for (final helper in _gitHelpers) {
            expect(
              text.contains('def $helper'),
              isFalse,
              reason:
                  '${entry.key} must not redefine $helper; '
                  'call the shared helper instead',
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

    test('every git checkout is validated and verified', () {
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
        expect(
          text.contains(_verifyMarker),
          isTrue,
          reason: '${entry.key} checks out git but never calls $_verifyMarker',
        );
      }
      expect(
        gated,
        greaterThan(0),
        reason: 'no git call site found; the test would pass vacuously',
      );
    });

    test('only the shared helper spells the git binary', () {
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
            'run git through git_clone(, git_fetch(, git_checkout( or git_archive( '
            'instead (offenders: $spelling)',
      );
    });

    test('only the shared helper clones without host templates', () {
      final sources = _bzlSources(args);
      // The clone operation and its template isolation: a call site that
      // clones with its own arguments bypasses `--template=`, the
      // `GIT_TEMPLATE_DIR` override and the `.git/info/attributes`
      // truncation, so both markers live only in the shared helper.
      for (final marker in ['"clone"', '--template=']) {
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
              'clone through git_clone( instead (offenders: $spelling)',
        );
      }
    });

    test('every git call site uses the shared helper', () {
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
              '${entry.key} calls the shared git helper but never loads '
              'pinned_sources.bzl',
        );
      }
      expect(
        gated,
        greaterThan(0),
        reason: 'no git helper call site found; the test would pass vacuously',
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
        'tar.umask=',
      ]) {
        expect(
          text.contains(pin),
          isTrue,
          reason: 'pinned_sources.bzl must pin $pin for git archive',
        );
      }
      // The host configuration selectors scrubbed from the archive's
      // environment, pointed at the helper's empty file where they name one.
      for (final name in [
        'GIT_CONFIG_COUNT',
        'GIT_CONFIG_PARAMETERS',
        'GIT_CONFIG_GLOBAL',
        'GIT_CONFIG_SYSTEM',
      ]) {
        expect(
          text.contains(name),
          isTrue,
          reason: 'pinned_sources.bzl must scrub $name for git archive',
        );
      }
    });

    test('every git step ignores host templates, hooks and attributes', () {
      final sources = _bzlSources(args);
      final text = File(sources['pinned_sources.bzl']!).readAsStringSync();
      // `--template=` (backed by `GIT_TEMPLATE_DIR` at the same empty
      // directory) beats `init.templateDir` from every config file, so a host
      // template's `info/attributes` and `hooks/` never reach the clone.
      for (final marker in [
        '--template=',
        'GIT_TEMPLATE_DIR',
        'core.hooksPath=',
        'info/attributes',
      ]) {
        expect(
          text.contains(marker),
          isTrue,
          reason:
              'pinned_sources.bzl must apply $marker on every git step, '
              'so host templates and hooks cannot change bytes or run code',
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
