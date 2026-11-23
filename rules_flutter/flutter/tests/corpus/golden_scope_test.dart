/// Offline unit tests for the corpus golden scope validator.
library;

import 'package:test/test.dart';

import 'golden_scope.dart';

const String _build = '''
flutter_application(
    name = "app",
)

flutter_web_app(
    name = "web_app",
)

flutter_ios_app(
    name = "ios_app",
)

cc_library(
    name = "native_c",
)

dart_binary(
    name = "actions_golden",
)
''';

const String _goldenTargets = '''
# comment
//flutter/tests/corpus:__web_app_manifest
//flutter/tests/corpus:app
//flutter/tests/corpus:web_app
''';

const String _uncovered = 'ios_app: needs the Apple toolchain\n';

String _golden(List<String> targets) =>
    '{"actions": [${targets.map((String t) => '{"target": "$t"}').join(',')}]}';

final String _goldenJson = _golden(<String>[
  '//flutter/tests/corpus:app',
  '//flutter/tests/corpus:__web_app_manifest',
]);

List<String> _validate({
  String build = _build,
  String targets = _goldenTargets,
  String uncovered = _uncovered,
  String? json,
}) => validateGoldenScope(
  CorpusScopeInput(
    build: build,
    goldenTargets: targets,
    uncovered: uncovered,
    goldenJson: json ?? _goldenJson,
  ),
);

void main() {
  test('accepts a consistent corpus state', () {
    expect(_validate(), isEmpty);
  });

  test('rejects a fixture in neither list', () {
    final List<String> problems = _validate(uncovered: '');
    expect(problems.join('\n'), contains('ios_app: must be in exactly one'));
    expect(problems.join('\n'), contains('neither'));
  });

  test('rejects a fixture in both lists', () {
    final List<String> problems = _validate(
      uncovered: '$_uncovered\napp: also here\n',
    );
    expect(problems.join('\n'), contains('app: must be in exactly one'));
    expect(problems.join('\n'), contains('both'));
  });

  test('rejects tooling and cc helpers in actions.golden.json', () {
    for (final helper in <String>['native_c', 'actions_golden']) {
      final List<String> problems = _validate(
        json: _golden(<String>['//flutter/tests/corpus:$helper']),
      );
      expect(problems.join('\n'), contains('tooling or helper'));
      expect(problems.join('\n'), contains(helper));
    }
  });

  test('rejects an action target missing from golden_targets.txt', () {
    final List<String> problems = _validate(
      json: _golden(<String>['//flutter/tests/corpus:ios_app']),
    );
    expect(problems.join('\n'), contains('ios_app is not in golden_targets'));
  });

  test('rejects bad uncovered_golden.txt rows', () {
    expect(
      _validate(uncovered: 'ios_app: why\nbogus: why\n').join('\n'),
      contains('bogus is not a declared fixture'),
    );
    expect(
      _validate(uncovered: 'ios_app: why\nios_app: again\n').join('\n'),
      contains('duplicate target ios_app'),
    );
    expect(
      _validate(uncovered: 'ios_app:   \n').join('\n'),
      contains('empty target or reason'),
    );
    expect(
      _validate(uncovered: 'ios_app why\n').join('\n'),
      contains('missing ":"'),
    );
    expect(
      _validate(uncovered: 'ios_app: why\nnative_c: why\n').join('\n'),
      contains('corpus tooling or helper native_c'),
    );
  });

  test('rejects bad golden_targets.txt lines', () {
    const base = '//flutter/tests/corpus:app\n';
    expect(
      _validate(targets: '$base//flutter/tests/corpus:app\n').join('\n'),
      contains('duplicate label'),
    );
    expect(
      _validate(targets: '//flutter/tests/corpus:web_app\n$base').join('\n'),
      contains('not sorted'),
    );
    expect(
      _validate(targets: '${base}app2\n').join('\n'),
      contains('malformed label'),
    );
    expect(
      _validate(targets: '$base//flutter/tests/corpus:native_c\n').join('\n'),
      contains('tooling or helper'),
    );
    expect(
      _validate(targets: '$base//flutter/tests/corpus:zzz\n').join('\n'),
      contains('not a fixture or sub-target'),
    );
  });
}
