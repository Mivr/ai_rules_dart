import 'package:perf/src/stats.dart';
import 'package:test/test.dart';

void main() {
  test('the median of an odd and an even count', () {
    expect(medianOf([3, 1, 2]), 2);
    expect(medianOf([4, 1, 3, 2]), 2.5);
    expect(() => medianOf([]), throwsArgumentError);
  });

  test('a summary keeps the runs in order with their range', () {
    final s = Summary([0.5, 0.2, 0.9, 0.3, 0.4]);
    expect(s.runs, [0.5, 0.2, 0.9, 0.3, 0.4]);
    expect((s.median, s.min, s.max), (0.4, 0.2, 0.9));
    expect(s.contains(0.2), isTrue);
    expect(s.contains(0.95), isFalse);
  });

  test('two passes agree when a median lies in the other range', () {
    expect(agree(Summary([1, 1.1, 1.2]), Summary([1.05, 1.15, 1.4])), isTrue);
    expect(agree(Summary([1, 1.1, 1.2]), Summary([2, 2.1, 2.2])), isFalse);
  });

  test('round3 keeps three decimals', () {
    expect(round3(1.23456), 1.235);
  });
}
