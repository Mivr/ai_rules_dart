import 'package:inventory/finding.dart';
import 'package:inventory/rules/floors.dart';
import 'package:test/test.dart';

import 'trees.dart';

const String _module = 'rules_flutter/MODULE.bazel';
const String _table = 'rules_flutter/flutter/tests/dependency_floors.json';

List<Finding> _check({String? module, String? table}) => checkBazelDepFloors(
  cleanTree({_module: ?module, _table: ?table}),
  (module: 'rules_flutter', table: 'flutter/tests/dependency_floors.json'),
);

String _row(
  String name,
  String floor,
  String current,
  String resolved, [
  String lifted = '',
]) =>
    '"$name": {"floor": "$floor", "current": "$current", "resolved": "$resolved", '
    '"lifted_by": [$lifted], "symbol": "s"}';

void main() {
  test('declared floors, a root override and a sound table pass', () {
    expect(_check(), isEmpty);
  });

  test('a declaration above its floor is found, on its line', () {
    final List<Finding> findings = _check(
      module: cleanFiles()[_module]!.replaceFirst('"0.2.20"', '"0.2.26"'),
    );
    expect(findings.single.line, 1);
    expect(findings.single.message, contains('force-upgraded'));
  });

  test('a dependency missing from the table, and a stale row, are found', () {
    final module =
        '${cleanFiles()[_module]!}bazel_dep(name = "new", version = "1")\n';
    expect(_check(module: module).single.message, contains('new has no entry'));
    final table =
        '{${_row('platforms', '1.1.0', '1.1.0', '1.1.0')}, '
        '${_row('rules_cc', '0.2.20', '0.2.26', '0.2.26', '"platforms"')}, '
        '${_row('gone', '1', '1', '1')}}';
    expect(_check(table: table).single.message, contains('gone'));
  });

  test('a dev dependency needs no row', () {
    expect(_check(), isEmpty);
  });

  test('a current release needs a root-only override, and only then', () {
    final String noOverride = cleanFiles()[_module]!.replaceAll(
      RegExp(r'single_version_override.*\n'),
      '',
    );
    expect(
      _check(module: noOverride).single.message,
      contains('needs a root-only single_version_override'),
    );
    final extra =
        '${cleanFiles()[_module]!}single_version_override(module_name = "platforms", version = "1.2.0")\n';
    expect(
      _check(module: extra).single.message,
      contains('already current at its floor'),
    );
  });

  test('a lift must name a known module, no lift must resolve at the floor', () {
    expect(
      _check(
        table:
            '{${_row('platforms', '1.1.0', '1.1.0', '1.1.0')}, '
            '${_row('rules_cc', '0.2.20', '0.2.26', '0.2.26', '"ghost"')}}',
      ).single.message,
      contains('unknown lifting module ghost'),
    );
    expect(
      _check(
        table:
            '{${_row('platforms', '1.1.0', '1.1.0', '1.3.0')}, '
            '${_row('rules_cc', '0.2.20', '0.2.26', '0.2.26', '"platforms"')}}',
      ).single.message,
      contains('no lift'),
    );
  });

  test('a comment is not a declaration, and an allow comment works', () {
    expect(
      _check(
        module:
            '# bazel_dep(name = "x", version = "9")\n${cleanFiles()[_module]!}',
      ),
      isEmpty,
    );
    expect(
      _check(
        module:
            '# lint-allow: bazel-dep-floor lifted for a bug fix\n'
            '${cleanFiles()[_module]!.replaceFirst('"0.2.20"', '"0.2.26"')}',
      ),
      isEmpty,
    );
  });

  test('a table row without a field is refused', () {
    expect(
      () => _check(table: '{"platforms": {"floor": "1"}}'),
      throwsFormatException,
    );
  });
}
