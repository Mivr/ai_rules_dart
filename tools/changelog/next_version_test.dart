import 'package:test/test.dart';

import 'next_version.dart';

Commit c(String subject, [List<String> entries = const []]) =>
    (subject: subject, entries: entries);

void main() {
  group('nextVersion', () {
    test('a fix with an entry bumps the patch', () {
      expect(
        nextVersion('v0.30.0', [
          c('fix(kernel): x', ['Fixed thing']),
        ]),
        'v0.30.1',
      );
    });
    test('a feat bumps the minor and resets the patch', () {
      expect(
        nextVersion('v0.29.4', [
          c('fix: a', ['A']),
          c('feat(web): b', ['B']),
        ]),
        'v0.30.0',
      );
    });
    test('a breaking commit bumps the minor while the major is 0', () {
      expect(
        nextVersion('v0.28.3', [
          c('fix(herm)!: require x', ['Requires x']),
        ]),
        'v0.29.0',
      );
    });
    test('a breaking commit bumps the major from 1.0 on', () {
      expect(
        nextVersion('v1.4.2', [
          c('feat!: drop y', ['Removed y']),
        ]),
        'v2.0.0',
      );
    });
    test('a feat after 1.0 bumps the minor', () {
      expect(
        nextVersion('v1.4.2', [
          c('feat: z', ['Z']),
        ]),
        'v1.5.0',
      );
    });
    test('only skip entries, or none, release nothing', () {
      expect(
        nextVersion('v0.30.0', [
          c('ci: a', ['skip']),
          c('docs: b'),
        ]),
        isNull,
      );
      expect(nextVersion('v0.30.0', []), isNull);
    });
    test('a feat without an entry still decides the bump of a release', () {
      expect(
        nextVersion('v0.30.0', [
          c('feat: hidden', ['skip']),
          c('fix: shown', ['Shown']),
        ]),
        'v0.31.0',
      );
    });
    test('a non-semver tag is refused', () {
      expect(() => nextVersion('pre-squash-backup', []), throwsFormatException);
    });
  });
  group('newestTag', () {
    test('compares numerically and ignores other tags', () {
      expect(
        newestTag(['v0.9.0', 'v0.10.0', 'pre-squash-backup', 'v0.10.0-rc1']),
        'v0.10.0',
      );
      expect(newestTag(['nope']), isNull);
    });
  });
}
