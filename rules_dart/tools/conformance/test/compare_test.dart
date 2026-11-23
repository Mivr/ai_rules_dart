import 'package:conformance/compare.dart';
import 'package:conformance/layout.dart';
import 'package:test/test.dart';

void main() {
  group('diffItems', () {
    test('counts equal items and names each difference by cause', () {
      final result = diffItems(
        {
          'asset:a': const Value('1', '1 B'),
          'asset:b': const Value('2', '2 B'),
          'dex:Lx;': const Value('present'),
        },
        {
          'asset:a': const Value('1', '1 B'),
          'asset:b': const Value('3', '3 B'),
          'native:lib.so': const Value('9'),
        },
      );
      expect(result.compared, 4);
      expect(result.equal, 1);
      expect(
        [
          for (final d in result.differences)
            '${d.item} | ${d.cause} | ${d.detail}',
        ],
        [
          'asset:b | asset: differs | stock 2 B, rules 3 B',
          'dex:Lx; | dex: only in stock | ',
          'native:lib.so | native: only in rules | ',
        ],
      );
    });

    test('one changed value is exactly one difference', () {
      final Items stock = {
        for (var i = 0; i < 50; i++) 'test:t :: $i': Value('success'),
      };
      final Items rules = {...stock, 'test:t :: 7': const Value('failure')};
      final result = diffItems(stock, rules);
      expect(result.differences, hasLength(1));
      expect(result.differences.single.item, 'test:t :: 7');
      expect(result.equal, 49);
    });

    test('is deterministic whatever the map order', () {
      final a = {'b:1': const Value('x'), 'a:1': const Value('y')};
      final b = {'a:1': const Value('z'), 'b:1': const Value('x')};
      final r1 = diffItems(a, b);
      final r2 = diffItems(
        Map.fromEntries(a.entries.toList().reversed),
        Map.fromEntries(b.entries.toList().reversed),
      );
      expect(
        [for (final d in r1.differences) d.item],
        [for (final d in r2.differences) d.item],
      );
    });
  });

  group('KindResult', () {
    test('scores equal and by-design items over compared', () {
      final differences = [
        Difference('a:1', 'a: differs', ''),
        Difference('a:2', 'a: differs', '')..byDesign = 'why',
        Difference('b:1', 'b: only in stock', ''),
      ];
      final r = KindResult(
        project: 'p',
        kind: Kind.web,
        stock: Status(built: true),
        rules: Status(built: true),
        compared: 10,
        equal: 7,
        differences: differences,
      );
      expect(r.byDesign, 1);
      expect(r.counted, 2);
      expect(r.score, closeTo(0.8, 1e-9));
      expect(
        [for (final g in r.groups()) '${g.cause} ${g.items.length}'],
        ['a: differs 1', 'b: only in stock 1', 'by design: a: differs 1'],
      );
    });

    test('has no score when nothing was compared', () {
      final r = KindResult(
        project: 'p',
        kind: Kind.linux,
        stock: Status(built: false, reason: 'gtk+-3.0 not found'),
        rules: Status(built: true),
        notCompared: 'stock: gtk+-3.0 not found',
      );
      expect(r.score, isNull);
    });
  });

  test('categoryOf takes the part before the first colon', () {
    expect(categoryOf('manifest:a/b@android:name'), 'manifest');
    expect(categoryOf('plain'), 'plain');
  });
}
