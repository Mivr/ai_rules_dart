import 'package:inventory/starlark.dart';
import 'package:test/test.dart';

void main() {
  test('blank keeps every offset and newline', () {
    const source = 'a = "x(#" # y)\nb = """\nq)\n"""\nc = r"\\"("\nd()\n';
    final String code = blank(source);
    expect(code.length, source.length);
    expect(code.split('\n')[5], 'd()');
    expect(code, isNot(contains('#')));
    expect(code, isNot(contains('q')));
  });

  test('blank can keep strings and still drop comments', () {
    expect(blank('a = "x" # c', blankStrings: false), 'a = "x"    ');
  });

  test('closingParen skips nested calls', () {
    const code = 'f(a, g(b), c) + h()';
    expect(closingParen(code, 1), 12);
    expect(closingParen('f(', 1), -1);
  });

  test('topLevel hides nested brackets only', () {
    final String top = topLevel('a = 1, b = f(c = 2), d = [e = 3]');
    expect(top, contains('a = 1'));
    expect(top, contains('b = f'));
    expect(top, isNot(contains('c = 2')));
    expect(top, isNot(contains('e = 3')));
    expect(top.length, 'a = 1, b = f(c = 2), d = [e = 3]'.length);
  });

  test('Lines maps offsets to lines and returns trimmed text', () {
    final lines = Lines('one\n  two\nthree');
    expect(lines.of(0), 1);
    expect(lines.of(4), 2);
    expect(lines.of(14), 3);
    expect(lines.trimmed(2), 'two');
    expect(lines.raw(0), '');
  });
}
