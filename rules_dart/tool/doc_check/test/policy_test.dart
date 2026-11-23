/// The allowlist and shared-phrasings lists: parsing and shrink-only behaviour,
/// on lists the tests write themselves.
library;

import 'package:doc_check/doc_rules.dart';
import 'package:doc_check/policy.dart';
import 'package:test/test.dart';

const _gap = Gap(
  file: '//a:b.bzl',
  symbol: 'rule.attr',
  rule: 'missing-attr-doc',
);

void main() {
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
