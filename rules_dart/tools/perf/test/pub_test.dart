import 'dart:convert';
import 'dart:io';

import 'package:perf/src/flows/pub.dart';
import 'package:test/test.dart';

const _lock = '''
# a comment
packages:
  after_layout:
    dependency: "direct main"
    description:
      name: after_layout
      sha256: "aaaa"
      url: "https://localhost:38522"
    source: hosted
    version: "1.2.0"
  local:
    dependency: "direct main"
    description:
      path: "../local"
      relative: true
    source: path
    version: "0.0.1"
  zeta:
    dependency: transitive
    description:
      name: zeta
      sha256: "bbbb"
      url: "https://localhost:38522"
    source: hosted
    version: "2.0.0"
sdks:
  dart: ">=3.13.0 <4.0.0"
''';

void main() {
  test('the hosted entries of a lock', () {
    expect(hostedEntries(_lock), [
      (name: 'after_layout', version: '1.2.0', sha256: 'aaaa'),
      (name: 'zeta', version: '2.0.0', sha256: 'bbbb'),
    ]);
  });

  test('a lock without one package keeps every other entry', () {
    final cut = lockWithout(_lock, 'after_layout');
    expect(hostedEntries(cut).map((e) => e.name), ['zeta']);
    expect(cut, contains('  local:'));
    expect(cut, startsWith('# a comment\npackages:\n  local:'));
    expect(lockWithout(_lock, 'zeta'), contains('sdks:'));
    expect(() => lockWithout(_lock, 'nope'), throwsArgumentError);
  });

  test('the facts of the named packages and the extension entry are dropped', () {
    final dir = Directory.systemTemp.createTempSync('facts');
    addTearDown(() => dir.deleteSync(recursive: true));
    final f = File('${dir.path}/MODULE.bazel.lock')
      ..writeAsStringSync(
        jsonEncode({
          'moduleExtensions': {
            '@@x//dart/pub:extensions.bzl%pub': {},
            'other%go': {},
          },
          'facts': {
            '@@x//dart/pub:extensions.bzl%pub': {
              'pub.scc.v2.ab/hosted/zeta/2.0.0/bbbb': 1,
              'pub.plan.v1/hosted/after_layout/1.2.0/aaaa/https://localhost:38522':
                  3,
              'pub.scc.v2.ab/hosted/kept/1.0.0/cccc': 2,
            },
          },
        }),
      );
    dropPubFacts(f.path, hostedEntries(_lock));
    final doc = jsonDecode(f.readAsStringSync()) as Map;
    expect((doc['moduleExtensions'] as Map).keys, ['other%go']);
    expect(((doc['facts'] as Map).values.single as Map).keys, [
      'pub.scc.v2.ab/hosted/kept/1.0.0/cccc',
    ]);
  });
}
