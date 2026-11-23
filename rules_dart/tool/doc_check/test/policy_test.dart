/// The allowlist and shared-phrasings lists: parsing, shrink-only behaviour,
/// and the checked-in files themselves.
library;

import 'dart:io';

import 'package:doc_check/doc_rules.dart';
import 'package:doc_check/policy.dart';
import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

/// The most entries the checked-in allowlist may hold; it may only shrink.
const _maxAllowlistEntries = 0;

/// The most phrasings the checked-in shared list may hold; it may only shrink.
const _maxSharedPhrasings = 3;

String _read(String name) {
  final String path = Runfiles.create().rlocation('_main/tool/doc_check/$name');
  final file = File(path);
  if (!file.existsSync()) fail('$name is missing at $path');
  return file.readAsStringSync();
}

const _gap = Gap(
  file: '//a:b.bzl',
  symbol: 'rule.attr',
  rule: 'missing-attr-doc',
);

void main() {
  group('checked-in lists', () {
    test('the allowlist holds no more than its pinned size', () {
      expect(
        parseAllowlist(_read('allowlist.txt')).length,
        lessThanOrEqualTo(_maxAllowlistEntries),
      );
    });
    test('the shared-phrasings list holds no more than its pinned size', () {
      expect(
        parseSharedPhrasings(_read('shared_phrasings.txt')).length,
        lessThanOrEqualTo(_maxSharedPhrasings),
      );
    });
  });

  group('allowlist', () {
    test('an entry suppresses the gaps of its key', () {
      final Filtered filtered = applyAllowlist([
        _gap,
      ], parseAllowlist('rule.attr legacy reason'));
      expect(filtered.errors, isEmpty);
      expect(filtered.staleEntries, isEmpty);
    });
    test('an entry that covers nothing is stale', () {
      final Filtered filtered = applyAllowlist([
        _gap,
      ], parseAllowlist('other.attr legacy reason'));
      expect(filtered.errors, [_gap]);
      expect(filtered.staleEntries, ['other.attr']);
    });
    test('an entry for a fixed gap is stale', () {
      final Filtered filtered = applyAllowlist(
        const [],
        parseAllowlist('rule.attr legacy reason'),
      );
      expect(filtered.staleEntries, ['rule.attr']);
    });
    test('an entry needs a reason', () {
      expect(() => parseAllowlist('rule.attr'), throwsFormatException);
    });
    test('a warning is never covered, listed or not', () {
      const warning = Gap(
        file: '//a:b.bzl',
        symbol: 'rule.attr',
        rule: 'default-undocumented',
        warning: true,
      );
      final Filtered filtered = applyAllowlist([warning], const {});
      expect(filtered.errors, isEmpty);
      expect(filtered.warnings, [warning]);
    });
  });

  group('shared phrasings', () {
    test('a phrasing needs a reason', () {
      expect(
        () => parseSharedPhrasings('Some phrasing'),
        throwsFormatException,
      );
      expect(
        () => parseSharedPhrasings('Some phrasing => '),
        throwsFormatException,
      );
    });
    test('comments and blank lines are ignored', () {
      expect(parseSharedPhrasings('# c\n\nThe doc => same sentence fits\n'), {
        'The doc',
      });
    });
  });
}
