import 'dart:convert';
import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

const List<String> _workspaces = [
  'analysis',
  'analysis_failure',
  'hello_world',
  'isolated_hub',
  'pub_deps',
  'pub_lock_cross_module',
  'pub_lock_dedup',
  'pub_lock_upgrade',
  'root_sdk_pin',
];

const String _pubExtension = '//dart/pub:extensions.bzl%pub';
const String _pubExtensionInModule = '@@ai_rules_dart+$_pubExtension';

final RegExp _lockfileOff = RegExp(
  r'''--lockfile_mode(?:=|\s+)["']?off["']?(?:\s|$)''',
);

void main(List<String> args) {
  group('e2e lockfile guard', () {
    test(
      'exemptions are real, lock-free and actually set lockfile_mode=off',
      () => expect(_checkExemptions(_workspaceRoot(args)), isEmpty),
    );

    test(
      'no unlisted e2e .bazelrc sets --lockfile_mode=off',
      () => expect(_scanBazelrcs(_workspaceRoot(args)), isEmpty),
    );

    test('isolated_hub and root_sdk_pin have no .bazelrc', () {
      final String root = _workspaceRoot(args);
      for (final name in ['isolated_hub', 'root_sdk_pin']) {
        expect(File('$root/e2e/$name/.bazelrc').existsSync(), isFalse);
      }
    });

    test(
      'the nine workspace locks are populated and match the root digest',
      () => expect(_checkLocks(_workspaceRoot(args)), isEmpty),
    );
  });

  group('guard helpers', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('lockguard'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('parses exemptions and ignores (none)', () {
      _writeChores(tmp, '(none)');
      expect(_parseExemptions(tmp.path), isEmpty);
      _writeChores(tmp, '- `e2e/foo` — needs it\n- `e2e/bar` — too');
      expect(_parseExemptions(tmp.path), ['foo', 'bar']);
    });

    test('missing subsection is reported', () {
      Directory('${tmp.path}/docs').createSync();
      File('${tmp.path}/docs/CHORES.md').writeAsStringSync('# x\n');
      expect(_checkExemptions(tmp.path), isNotEmpty);
    });

    test('flags unlisted and quoted lockfile_mode=off', () {
      _writeRc(tmp, 'a', 'common --lockfile_mode=off\n');
      _writeRc(tmp, 'b', 'build --lockfile_mode="off"\n');
      _writeRc(tmp, 'c', "common --lockfile_mode 'off'\n");
      _writeRc(tmp, 'd', '# common --lockfile_mode=off\ncommon --x=y\n');
      _writeChores(tmp, '(none)');
      final List<String> found = _scanBazelrcs(tmp.path);
      expect(found, hasLength(3));
      expect(found.join('\n'), isNot(contains('e2e/d')));
    });

    test('exempted workspace keeping a lock is reported', () {
      _writeRc(tmp, 'a', 'common --lockfile_mode=off\n');
      File('${tmp.path}/e2e/a/MODULE.bazel.lock').writeAsStringSync('{}');
      _writeChores(tmp, '- `e2e/a` — reason');
      expect(_checkExemptions(tmp.path).join(), contains('MODULE.bazel.lock'));
      expect(_scanBazelrcs(tmp.path), isEmpty);
    });

    test('stale exemption without lockfile_mode=off is reported', () {
      _writeRc(tmp, 'a', 'common --x=y\n');
      _writeChores(tmp, '- `e2e/a` — reason');
      expect(_checkExemptions(tmp.path).join(), contains('does not set'));
    });

    test('exemption for a missing workspace is reported', () {
      _writeChores(tmp, '- `e2e/ghost` — reason');
      expect(_checkExemptions(tmp.path).join(), contains('not an existing'));
    });
  });
}

void _writeChores(Directory root, String exemptions) {
  Directory('${root.path}/docs').createSync(recursive: true);
  File('${root.path}/docs/CHORES.md').writeAsStringSync(
    '## Lock File Refresh\n\n### Lockfile-off Exemptions\n\n$exemptions\n\n'
    '---\n',
  );
}

void _writeRc(Directory root, String name, String content) {
  Directory('${root.path}/e2e/$name').createSync(recursive: true);
  File('${root.path}/e2e/$name/.bazelrc').writeAsStringSync(content);
}

/// Workspace names listed under `### Lockfile-off Exemptions`, or null when
/// the subsection is missing.
List<String>? _readExemptions(String root) {
  final chores = File('$root/docs/CHORES.md');
  if (!chores.existsSync()) return null;
  final List<String> lines = chores.readAsLinesSync();
  final int start = lines.indexOf('### Lockfile-off Exemptions');
  if (start < 0) return null;
  final entry = RegExp('^- `e2e/([^`/]+)`');
  final List<String> names = [];
  for (final String line in lines.skip(start + 1)) {
    if (line.startsWith('#') || line.startsWith('---')) break;
    final RegExpMatch? m = entry.firstMatch(line);
    if (m != null) names.add(m.group(1)!);
  }
  return names;
}

List<String> _parseExemptions(String root) => _readExemptions(root) ?? [];

bool _setsLockfileOff(File rc) => rc
    .readAsLinesSync()
    .where((String l) => !l.trimLeft().startsWith('#'))
    .any(_lockfileOff.hasMatch);

List<String> _checkExemptions(String root) {
  final List<String>? names = _readExemptions(root);
  if (names == null) {
    return ['docs/CHORES.md has no "### Lockfile-off Exemptions" subsection'];
  }
  final List<String> problems = [];
  for (final String name in names) {
    final dir = '$root/e2e/$name';
    if (!Directory(dir).existsSync()) {
      problems.add('e2e/$name is not an existing e2e workspace');
      continue;
    }
    if (File('$dir/MODULE.bazel.lock').existsSync()) {
      problems.add('exempt e2e/$name still has a MODULE.bazel.lock');
    }
    final rc = File('$dir/.bazelrc');
    if (!rc.existsSync() || !_setsLockfileOff(rc)) {
      problems.add('exempt e2e/$name .bazelrc does not set lockfile_mode=off');
    }
  }
  return problems;
}

List<String> _scanBazelrcs(String root) {
  final e2e = Directory('$root/e2e');
  if (!e2e.existsSync()) return [];
  final Set<String> exempt = _parseExemptions(root).toSet();
  final List<String> found = [];
  for (final Directory ws in e2e.listSync().whereType<Directory>()) {
    final String name = ws.uri.pathSegments
        .where((String s) => s.isNotEmpty)
        .last;
    if (name.startsWith('bazel-') || exempt.contains(name)) continue;
    for (final File rc in _bazelrcFiles(ws)) {
      if (_setsLockfileOff(rc)) {
        found.add('e2e/$name: ${rc.path} sets --lockfile_mode=off');
      }
    }
  }
  return found;
}

Iterable<File> _bazelrcFiles(Directory dir) sync* {
  for (final FileSystemEntity e in dir.listSync(followLinks: false)) {
    final String base = e.uri.pathSegments
        .where((String s) => s.isNotEmpty)
        .last;
    if (base.startsWith('bazel-')) continue;
    if (e is Directory) {
      yield* _bazelrcFiles(e);
    } else if (e is File && base == '.bazelrc') {
      yield e;
    }
  }
}

Object? _digest(Map<String, dynamic> lock, String ext) {
  final Object? exts = lock['moduleExtensions'];
  if (exts is! Map) return null;
  final Object? general = (exts[ext] as Map?)?['general'];
  return general is Map ? general['bzlTransitiveDigest'] : null;
}

Map<String, dynamic> _readLock(String path) =>
    jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;

List<String> _checkLocks(String root) {
  final Object? expected = _digest(
    _readLock('$root/MODULE.bazel.lock'),
    _pubExtension,
  );
  final List<String> problems = [];
  if (expected == null) problems.add('root lock has no pub digest');
  for (final String name in _workspaces) {
    final f = File('$root/e2e/$name/MODULE.bazel.lock');
    if (!f.existsSync()) {
      problems.add('e2e/$name has no MODULE.bazel.lock');
      continue;
    }
    problems.addAll(_lockProblems(name, _readLock(f.path), expected));
  }
  return problems;
}

List<String> _lockProblems(
  String name,
  Map<String, dynamic> lock,
  Object? expected,
) {
  final List<String> problems = [];
  final Object? hashes = lock['registryFileHashes'];
  if (hashes is! Map || hashes.isEmpty) {
    problems.add('e2e/$name has empty registryFileHashes');
  }
  final Object? facts = lock['facts'];
  if (facts is! Map || !facts.containsKey(_pubExtensionInModule)) {
    problems.add('e2e/$name records no pub facts');
  }
  if (_digest(lock, _pubExtensionInModule) != expected) {
    problems.add('e2e/$name pub bzlTransitiveDigest is stale');
  }
  return problems;
}

String _workspaceRoot(List<String> args) {
  final String located = Runfiles.create().rlocation(args.first);
  Directory dir = Directory(File(located).resolveSymbolicLinksSync()).parent;
  while (dir.path != dir.parent.path) {
    if (File('${dir.path}/MODULE.bazel').existsSync() &&
        Directory('${dir.path}/dart').existsSync()) {
      return dir.path;
    }
    dir = dir.parent;
  }
  throw StateError('workspace root not found above $located');
}
