import 'package:conformance/by_design.dart';
import 'package:conformance/compare.dart';
import 'package:conformance/layout.dart';
import 'package:conformance/report.dart';
import 'package:test/test.dart';

void main() {
  test('globs match whole keys, * spanning slashes', () {
    final RegExp re = globToRegExp('entry:META-INF/*.version');
    expect(re.hasMatch('entry:META-INF/androidx.core.version'), isTrue);
    expect(re.hasMatch('entry:META-INF/a/b.version'), isTrue);
    expect(re.hasMatch('entry:META-INF/a.versionx'), isFalse);
    expect(globToRegExp('a.b').hasMatch('axb'), isFalse);
  });

  test('an entry without a reason is refused', () {
    expect(
      () => parseByDesign('{"entries": [{"kinds": ["web"], "item": "x"}]}'),
      throwsFormatException,
    );
  });

  test('entries mark matching differences and report unused ones', () {
    final List<ByDesignEntry> list = parseByDesign('''
{"entries": [
  {"kinds": ["apk"], "item": "entry:META-INF/*", "cause": "only in stock",
   "reason": "Gradle records library versions"},
  {"projects": ["counter"], "kinds": ["web"], "item": "asset:NOTICES*",
   "reason": "licences are compressed"},
  {"kinds": ["web"], "item": "bootstrap:never", "reason": "stale"}
]}''');
    final differences = [
      Difference('entry:META-INF/a.version', 'entry: only in stock', ''),
      Difference('entry:META-INF/b.version', 'entry: only in rules', ''),
    ];
    final used = applyByDesign('counter', Kind.apk, differences, list);
    expect(differences[0].byDesign, 'Gradle records library versions');
    expect(differences[1].byDesign, isNull, reason: 'cause does not match');

    final web = [Difference('asset:NOTICES', 'asset: only in stock', '')];
    used.addAll(applyByDesign('counter', Kind.web, web, list));
    expect(web.single.byDesign, isNotNull);
    expect(
      applyByDesign('large', Kind.web, [
        Difference('asset:NOTICES', 'asset: only in stock', ''),
      ], list),
      isEmpty,
      reason: 'the entry names one project',
    );

    final results = [
      KindResult(
        project: 'counter',
        kind: Kind.web,
        stock: Status(built: true),
        rules: Status(built: true),
      ),
    ];
    expect(
      [for (final e in staleEntries(list, used, results)) e.item],
      ['bootstrap:never'],
    );
  });
}
