import 'package:inventory/finding.dart';
import 'package:inventory/rules/download.dart';
import 'package:inventory/source_tree.dart';
import 'package:test/test.dart';

const String _sha =
    '9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08';

const List<DownloadScope> _scopes = [
  (module: 'm', bzlDir: 'pkg', helper: 'pkg/private/download.bzl'),
];

const String _helper =
    'def pinned_download(ctx):\n    ctx.download()\n'
    'def pinned_download_and_extract(ctx):\n    ctx.download_and_extract()\n';

List<Finding> _check({String bzl = '', String module = ''}) => checkDownloads(
  SourceTree.inMemory({
    'm/pkg/private/download.bzl': _helper,
    'm/pkg/probe.bzl': bzl,
    'm/MODULE.bazel': module,
  }),
  _scopes,
);

void main() {
  group('raw downloads', () {
    test('a direct call, an alias and a getattr lookup are found', () {
      final List<Finding> findings = _check(
        bzl:
            'def f(ctx):\n'
            '    ctx.download(url = u)\n'
            '    fetch = ctx.download_and_extract\n'
            '    getattr(ctx, "download")(url = u)\n',
      );
      expect(findings.map((f) => f.line), [2, 3, 4]);
    });

    test('a comment, a docstring and the pinned helper are not downloads', () {
      expect(
        _check(
          bzl:
              '"""Wraps ctx.download."""\n'
              '# ctx.download(url)\n'
              'def f(ctx):\n    pinned_download(ctx, url = u)\n    x = ctx.download_dir\n',
        ),
        isEmpty,
      );
    });

    test('the helper may download, and an allow comment with a reason works', () {
      expect(
        _check(
          bzl:
              '# lint-allow: download-unpinned reads a local file, no network\n'
              'x = ctx.download(url)\n',
        ),
        isEmpty,
      );
      expect(
        _check(bzl: '# lint-allow: download-unpinned\nx = ctx.download(url)\n'),
        hasLength(1),
      );
    });

    test('a missing helper definition is reported', () {
      final List<Finding> findings = checkDownloads(
        SourceTree.inMemory({
          'm/pkg/private/download.bzl': 'def pinned_download(ctx):\n    pass\n',
          'm/MODULE.bazel': '',
        }),
        _scopes,
      );
      expect(findings.single.message, contains('pinned_download_and_extract'));
    });
  });

  group('checksums', () {
    test('a direct http_archive without one fails, with one passes', () {
      expect(
        _check(bzl: 'http_archive(\n    name = "x",\n    urls = ["u"],\n)\n')
            .single
            .line,
        1,
      );
      expect(
        _check(bzl: 'http_archive(name = "x", sha256 = "$_sha")\n'),
        isEmpty,
      );
      expect(
        _check(bzl: 'http_file(name = "x", integrity = "sha256-abc")\n'),
        isEmpty,
      );
    });

    test('an empty, variable or conditional checksum pins nothing', () {
      for (final value in ['""', 'PIN', "''"]) {
        final List<Finding> findings = _check(
          bzl: 'http_jar(name = "x", sha256 = $value)\n',
        );
        expect(findings, hasLength(1), reason: value);
        expect(findings.single.message, contains('non-empty literal'));
      }
    });

    test('a load alias is checked', () {
      const load =
          'load("@bazel_tools//tools/build_defs/repo:http.bzl", _a = "http_archive")\n';
      expect(
        _check(bzl: '${load}_a(name = "x")\n').single.message,
        contains('through _a'),
      );
      expect(_check(bzl: '${load}_a(name = "x", sha256 = "$_sha")\n'), isEmpty);
    });

    test('a re-binding chain is checked', () {
      const src =
          'load("x.bzl", _a = "http_archive")\n_b = _a\n_c = _b\n_c(name = "x")\n';
      expect(_check(bzl: src).single.line, 4);
      expect(_check(bzl: 'h = http_file\nh(name = "x")\n').single.line, 2);
    });

    test('a use_repo_rule proxy is checked, and another rule is not', () {
      const proxy =
          'f = use_repo_rule("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")\n';
      expect(
        _check(module: '${proxy}f(name = "x")\n').single.file,
        'm/MODULE.bazel',
      );
      expect(
        _check(module: '${proxy}f(name = "x", sha256 = "$_sha")\n'),
        isEmpty,
      );
      expect(
        _check(
          module: 'g = use_repo_rule("//:r.bzl", "git_repository")\ng(name = "x")\n',
        ),
        isEmpty,
      );
    });

    test('a canonical name bound to another http rule is still checked', () {
      expect(
        _check(
          module:
              'http_archive = use_repo_rule("http.bzl", "http_file")\n'
              'http_archive(name = "x")\n',
        ).single.message,
        contains('file'),
      );
    });

    test('a longer identifier and a commented call are not calls', () {
      expect(
        _check(
          bzl: 'my_http_archive(name = "x")\n# http_archive(name = "x")\n',
        ),
        isEmpty,
      );
    });
  });

  test('a scope without .bzl or MODULE.bazel files is a setup error', () {
    expect(
      () => checkDownloads(SourceTree.inMemory({}), _scopes),
      throwsA(isA<SetupException>()),
    );
  });
}
