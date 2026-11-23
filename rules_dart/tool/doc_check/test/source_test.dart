/// The line-based `.bzl` reader behind the closure checks.
library;

import 'package:doc_check/starlark_source.dart';
import 'package:test/test.dart';

SourceFile _parse(String text) => SourceFile.parse('//pkg:f.bzl', text);

SourceDef _only(String text) => _parse('"""Doc."""\n$text').defs.single;

void main() {
  group('module docstring', () {
    test('a leading docstring counts, even after comments', () {
      expect(_parse('# lic\n\n"""Doc."""\n').hasModuleDoc, isTrue);
    });
    test('a load first, or an empty docstring, does not count', () {
      expect(
        _parse('load("//a:b.bzl", "x")\n"""Doc."""\n').hasModuleDoc,
        isFalse,
      );
      expect(_parse('""""""\nx = 1\n').hasModuleDoc, isFalse);
    });
  });

  group('load edges', () {
    test('absolute and package-relative labels are followed, others not', () {
      final SourceFile file = _parse(
        'load("//a/b:c.bzl", "x")\nload(":d.bzl", "y")\n'
        'load("@skylib//lib:paths.bzl", "paths")\n',
      );
      expect(file.loads, ['//a/b:c.bzl', '//pkg:d.bzl']);
    });
  });

  group('returns', () {
    test('a value return counts; bare and None returns do not', () {
      expect(_only('def f():\n    return 1\n').returnsValue, isTrue);
      expect(_only('def f():\n    return\n').returnsValue, isFalse);
      expect(_only('def f():\n    return None\n').returnsValue, isFalse);
    });
    test('a return inside a nested def does not count', () {
      const body = 'def f():\n    def g():\n        return 1\n    g()\n';
      expect(_only(body).returnsValue, isFalse);
    });
    test('the word return inside a string does not count', () {
      const body =
          'def f():\n    x = """\n    return y\n    """\n    print(x)\n';
      expect(_only(body).returnsValue, isFalse);
    });
    test('a one-line conditional return counts', () {
      expect(_only('def f(a):\n    if a: return a\n').returnsValue, isTrue);
    });
  });

  group('signature and docstring', () {
    test('parameters keep order, defaults and kinds', () {
      final SourceDef def = _only(
        'def f(a, b = "x,y", *args, c = [1, 2], **kwargs):\n    pass\n',
      );
      expect(
        [for (final p in def.function.params) p.name],
        ['a', 'b', 'args', 'c', 'kwargs'],
      );
      expect([for (final p in def.function.params) p.role], [1, 1, 4, 1, 5]);
      expect(def.function.params[1].defaultValue, '"x,y"');
      expect(def.function.params[0].mandatory, isTrue);
    });
    test('a multi-line signature is read whole', () {
      final SourceDef def = _only(
        'def f(\n    a,\n    b = 1,\n):\n    """Doc here."""\n',
      );
      expect(def.function.params.length, 2);
      expect(def.function.doc, 'Doc here.');
    });
    test('Args entries, wrapped lines and Returns are split out', () {
      final SourceDef def = _only(
        'def f(a, *rest):\n'
        '    """Summary line\n'
        '    continues here.\n\n'
        '    Args:\n'
        '        a: First\n'
        '            wrapped.\n'
        '        *rest: Everything else.\n\n'
        '    Returns:\n'
        '        The result\n'
        '        value.\n'
        '    """\n'
        '    return a\n',
      );
      expect(def.function.doc, 'Summary line continues here.');
      expect(def.function.params[0].doc, 'First wrapped.');
      expect(def.function.params[1].doc, 'Everything else.');
      expect(def.function.returnDoc, 'The result value.');
    });
    test('a def without a docstring has an empty doc', () {
      expect(_only('def f(a):\n    return a\n').function.doc, isEmpty);
    });
  });
}
