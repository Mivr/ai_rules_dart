import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

/// Enumeration of every fetch call site in `//dart/pub` through the shared
/// pinned-source validation.
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
/// `pinned_sources.bzl` is the single validation entry point. It runs no
/// fetch itself — only a read-only `rev-parse` that verifies a checkout —
/// so the test additionally pins that no fetch-capable call (`ctx.download`,
/// `ctx.download_and_extract`, or a `git` invocation other than `rev-parse`)
/// ever appears there.

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
const _gitMarker = '["git",';
const _validatorMarker = 'pinned_source_error(';
const _verifyMarker = 'verify_git_checkout(';

bool _fetchesDownload(String text) => _downloadMarkers.any(text.contains);

bool _runsGit(String text) => text.contains(_gitMarker);

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
        } else {
          expect(
            text.contains('def pinned_source_error('),
            isFalse,
            reason:
                '${entry.key} must not redefine $_validatorMarker; '
                'call the single entry point instead',
          );
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

    test('the entry point itself fetches nothing', () {
      final sources = _bzlSources(args);
      final text = File(sources['pinned_sources.bzl']!).readAsStringSync();
      for (final marker in _downloadMarkers) {
        expect(
          text.contains(marker),
          isFalse,
          reason: 'pinned_sources.bzl must not fetch via $marker',
        );
      }
      // The only git invocation the entry point runs is the read-only
      // post-checkout verification.
      expect(_runsGit(text), isTrue);
      for (final subcommand in [
        '"clone"',
        '"checkout"',
        '"fetch"',
        '"archive"',
      ]) {
        expect(
          text.contains(subcommand),
          isFalse,
          reason:
              'pinned_sources.bzl must not run git $subcommand; '
              'only rev-parse verification belongs here',
        );
      }
      expect(text.contains('"rev-parse"'), isTrue);
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
