import 'package:inventory/finding.dart';
import 'package:inventory/rules/pub_fetch.dart';
import 'package:inventory/source_tree.dart';
import 'package:test/test.dart';

import 'trees.dart';

const PubFetchScope _scope = (
  dir: 'rules_dart/dart/pub',
  entry: 'private/pinned_sources.bzl',
  executors: {'private/scan.bzl': 'runs the scanner'},
  notPackageFetches: {'private/yq.bzl': 'downloads yq'},
);

const String _entry = 'rules_dart/dart/pub/private/pinned_sources.bzl';

List<Finding> _check(Map<String, String?> overrides) {
  final Map<String, String> files = {
    for (final MapEntry<String, String> e in cleanFiles().entries)
      if (e.key.startsWith('rules_dart/dart/pub/')) e.key: e.value,
  };
  for (final MapEntry<String, String?> e in overrides.entries) {
    final String? text = e.value;
    if (text == null) {
      files.remove(e.key);
    } else {
      files[e.key] = text;
    }
  }
  return checkPubFetch(SourceTree.inMemory(files), _scope);
}

Finding _only(List<Finding> findings, String text) {
  expect(
    findings,
    hasLength(1),
    reason: findings.map((f) => f.display).join('\n'),
  );
  expect(findings.single.message, contains(text));
  return findings.single;
}

void main() {
  test('the clean tree passes', () {
    expect(_check({}), isEmpty);
  });

  test('a download that never calls the validator is found', () {
    final Finding f = _only(
      _check({
        'rules_dart/dart/pub/private/new.bzl':
            'def f(ctx):\n    ctx.download(url = u)\n',
      }),
      'pinned_source_error',
    );
    expect(f.line, 2);
    _only(
      _check({
        'rules_dart/dart/pub/private/new.bzl':
            'pinned_download_and_extract(ctx)\n',
      }),
      'pinned_source_error',
    );
  });

  test('a download that is not a package fetch may be exempt', () {
    expect(
      _check({'rules_dart/dart/pub/private/yq.bzl': 'pinned_download(ctx)\n'}),
      isEmpty,
    );
  });

  test('a git call outside the entry file is found', () {
    final List<Finding> findings = _check({
      'rules_dart/dart/pub/private/new.bzl':
          'load("//dart/pub:pinned_sources.bzl", "pinned_source_error")\n'
          'pinned_source_error(x)\n'
          'def f(ctx):\n    ctx.execute(["git", "log"])\n',
    });
    expect(findings.map((f) => f.message), contains(contains('["git"')));
    expect(findings.map((f) => f.message), contains(contains('ctx.execute(')));
  });

  test('a call site that runs one phase and not the other is found', () {
    _only(
      _check({
        'rules_dart/dart/pub/private/new.bzl':
            'load("//dart/pub:pinned_sources.bzl", "git_transport_fetch")\n'
            'pinned_source_error(x)\n'
            'git_transport_fetch(ctx)\n',
      }),
      'git_materialize(',
    );
  });

  test('a call site that runs git without the validator is found', () {
    final List<Finding> findings = _check({
      'rules_dart/dart/pub/private/new.bzl':
          'load("//dart/pub:pinned_sources.bzl", "git_materialize")\n'
          'git_transport_fetch(ctx)\ngit_materialize(ctx)\n',
    });
    _only(findings, 'pinned_source_error');
  });

  test('a git subcommand or flag outside the entry file is found', () {
    for (final marker in [
      '"fetch"',
      '"archive"',
      '--git-dir=',
      '--no-replace-objects',
    ]) {
      expect(
        _check({'rules_dart/dart/pub/private/new.bzl': 'x = [$marker]\n'}),
        hasLength(1),
        reason: marker,
      );
    }
  });

  test('an executor may call ctx.execute but still not spell git', () {
    expect(
      _check({
        'rules_dart/dart/pub/private/scan.bzl': 'ctx.execute([scanner])\n',
      }),
      isEmpty,
    );
    expect(
      _check({
        'rules_dart/dart/pub/private/scan.bzl': 'ctx.execute(["git", "log"])\n',
      }),
      isNotEmpty,
    );
  });

  group('the entry file', () {
    test('an invocation without the replace-refs flag is found', () {
      final String text = cleanFiles()[_entry]!;
      _only(
        _check({
          _entry: '$text\ndef g(ctx):\n    ctx.execute(["git", "status"])\n',
        }),
        '--no-replace-objects',
      );
    });

    test('a missing validator or helper definition is found', () {
      _only(
        _check({
          _entry: cleanFiles()[_entry]!.replaceAll(
            'def pinned_source_error(',
            'def other(',
          ),
        }),
        'must define def pinned_source_error(',
      );
    });

    test('a retired helper and a git init are found', () {
      final String text = cleanFiles()[_entry]!;
      _only(
        _check({_entry: '${text}def git_clone(ctx):\n    pass\n'}),
        'retired helper',
      );
      _only(
        _check({
          _entry: '${text}x = ["init"]\n'.replaceAll('["init"]', '"init"'),
        }),
        'git init',
      );
    });
  });

  test('another file redefining the validator is found', () {
    _only(
      _check({
        'rules_dart/dart/pub/private/new.bzl':
            'def pinned_source_error(x):\n    pass\n',
      }),
      'must not define',
    );
  });

  test('tests of the package are not scanned', () {
    expect(
      _check({'rules_dart/dart/pub/tests/x.bzl': 'ctx.execute(["git"])\n'}),
      isEmpty,
    );
  });
}
