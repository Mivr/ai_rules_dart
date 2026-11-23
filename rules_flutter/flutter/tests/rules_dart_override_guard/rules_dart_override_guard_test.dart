/// Guard for the `ai_rules_dart` development pin.
///
/// Root `MODULE.bazel` and the development `git_override` snippet in
/// `README.md` must pin `ai_rules_dart` to the same 40-hex commit on
/// `https://github.com/Mivr/ai_rules_dart.git`, and that commit must not be
/// one of the pre-#68 pins, whose `DartKernel` actions write empty
/// `.unused_inputs` files under sandboxing. The README must also keep its
/// `archive_override` release-pair block.
///
/// The files come from `data`, so the inputs are the tracked files.
library;

import 'dart:io';

import 'package:test/test.dart';

const _remote = 'https://github.com/Mivr/ai_rules_dart.git';

/// Pins that predate the `FD-gates-unused-inputs-sandbox` fix.
const _rejected = {
  '3da688c1b905b0d2c807f2b18bbd86c5634276ad',
  'a52341d1a87c8443e32cf4d688bed7f32175848d',
};

final _block = RegExp(
  r'git_override\(\s*module_name\s*=\s*"ai_rules_dart"\s*,([^)]*)\)',
);
final _commit = RegExp(r'commit\s*=\s*"([^"]*)"');
final _remoteAttr = RegExp(r'remote\s*=\s*"([^"]*)"');
final _sha = RegExp(r'^[0-9a-f]{40}$');

/// Return the commit of the `ai_rules_dart` `git_override` in [text].
///
/// Throws a [FormatException] when there is no such block, when its remote is
/// not [_remote], or when the commit is not 40 lowercase hex digits.
String pinnedCommit(String text) {
  final RegExpMatch? block = _block.firstMatch(text);
  if (block == null) {
    throw const FormatException('no git_override for ai_rules_dart');
  }
  final String body = block.group(1)!;
  final String? remote = _remoteAttr.firstMatch(body)?.group(1);
  if (remote != _remote) {
    throw FormatException('unexpected remote: $remote');
  }
  final String? commit = _commit.firstMatch(body)?.group(1);
  if (commit == null || !_sha.hasMatch(commit)) {
    throw FormatException('commit is not a 40-hex lowercase SHA: $commit');
  }
  if (_rejected.contains(commit)) {
    throw FormatException('commit $commit is a pre-#68 pin');
  }
  return commit;
}

String _readData(String variable) {
  final String? path = Platform.environment[variable];
  final String? runfiles = Platform.environment['TEST_SRCDIR'];
  if (path == null || path.isEmpty || runfiles == null) {
    throw StateError(
      '$variable or TEST_SRCDIR is unset; the test target needs that data file',
    );
  }
  return File('$runfiles/$path').readAsStringSync();
}

String _snippet(String commit, {String remote = _remote}) =>
    '''
git_override(
    module_name = "ai_rules_dart",
    commit = "$commit",
    remote = "$remote",
)
''';

void main() {
  const good = '3315296db3a357f8655e4b8075b7ebf95f4fdc4f';

  group('pinnedCommit', () {
    test('accepts a valid pin', () {
      expect(pinnedCommit(_snippet(good)), good);
    });

    test('two snippets with different SHAs do not match', () {
      final other = '${good.substring(0, 39)}0';
      expect(
        pinnedCommit(_snippet(other)),
        isNot(pinnedCommit(_snippet(good))),
      );
    });

    test('rejects pre-#68 SHAs', () {
      for (final String sha in _rejected) {
        expect(() => pinnedCommit(_snippet(sha)), throwsFormatException);
      }
    });

    test('rejects a missing git_override', () {
      expect(
        () => pinnedCommit('bazel_dep(name = "ai_rules_dart")'),
        throwsFormatException,
      );
    });

    test('rejects a short, uppercase or foreign pin', () {
      expect(() => pinnedCommit(_snippet('abc123')), throwsFormatException);
      expect(
        () => pinnedCommit(_snippet(good.toUpperCase())),
        throwsFormatException,
      );
      expect(
        () => pinnedCommit(_snippet(good, remote: 'https://example.com/x.git')),
        throwsFormatException,
      );
    });
  });

  group('checked-in files', () {
    late final String module;
    late final String readme;

    setUpAll(() {
      module = _readData('MODULE_BZL');
      readme = _readData('README_MD');
    });

    test('MODULE.bazel and README.md pin the same commit', () {
      expect(pinnedCommit(readme), pinnedCommit(module));
    });

    test('README.md keeps the archive_override release pair', () {
      for (final name in ['ai_rules_flutter', 'ai_rules_dart']) {
        expect(
          RegExp('archive_override\\(\\s*module_name\\s*=\\s*"$name"')
              .hasMatch(readme),
          isTrue,
          reason: 'archive_override for $name is missing',
        );
      }
    });
  });
}
