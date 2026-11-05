/// One violating and one passing fixture per documentation rule.
///
/// Each violating fixture trips exactly the rule of its class; each passing
/// fixture is clean, warnings included.
library;

import 'package:doc_check/checker.dart';
import 'package:doc_check/doc_rules.dart';
import 'package:doc_check/stardoc_model.dart';
import 'package:test/test.dart';

import 'support/fixture_defs.dart';

const _cleanSource = '"""Fixture source."""\n';

const _returnsSource = '''
"""Fixture source."""

def fixture_fn(target):
    """Computes the fixture value.

    Args:
        target: The target the function works on.
    """
    return target
''';

const _returnsDocumentedSource = '''
"""Fixture source."""

def fixture_fn(target):
    """Computes the fixture value.

    Args:
        target: The target the function works on.

    Returns:
        The computed fixture value.
    """
    return target
''';

List<Gap> _check(
  String fixture, {
  String source = _cleanSource,
  Set<String> shared = const {},
}) {
  final List<ModuleDoc> modules = decodeExtracts([fixtures[fixture]!]);
  return checkDocs(
    modules,
    (label) => label == fixtureFile ? source : null,
    shared,
  );
}

List<String> _lines(List<Gap> gaps) => [for (final gap in gaps) gap.line];

Set<String> _rules(List<Gap> gaps) => {
  for (final gap in gaps.where((g) => !g.warning)) gap.rule,
};

void _expectPair(
  String name,
  Set<String> rules, {
  String? violatesSource,
  String? passesSource,
}) {
  test('$name: the violating fixture trips only $rules', () {
    final List<Gap> gaps = _check(
      '${name}_violates',
      source: violatesSource ?? _cleanSource,
    );
    expect(_rules(gaps), rules, reason: _lines(gaps).join('\n'));
  });
  test('$name: the passing fixture is clean', () {
    final List<Gap> gaps = _check(
      '${name}_passes',
      source: passesSource ?? _cleanSource,
    );
    expect(_lines(gaps), isEmpty);
  });
}

void main() {
  group('rule 1, module docstring', () {
    _expectPair('module_docstring', {'module-docstring'});
    test('the report names the module', () {
      expect(_lines(_check('module_docstring_violates')), [
        '$fixtureFile:(module): module-docstring',
      ]);
    });
  });

  group('rule 2, symbol docs', () {
    _expectPair('symbol_doc', {'missing-doc'});
    test('every symbol kind is reported', () {
      expect(_lines(_check('symbol_doc_violates')), [
        for (final symbol in [
          'FixtureInfo',
          'fixture_aspect',
          'fixture_ext',
          'fixture_ext.fixture_tag',
          'fixture_fn',
          'fixture_lib',
          'fixture_macro',
          'fixture_repo_rule',
        ])
          '$fixtureFile:$symbol: missing-doc',
      ]);
    });
  });

  group('rule 3, attribute docs', () {
    _expectPair('attr_doc', {'missing-attr-doc'});
    test('public and private rules are checked, native attributes are not', () {
      expect(_lines(_check('attr_doc_violates')), [
        '$fixtureFile:_hidden_rule.data: missing-attr-doc',
        '$fixtureFile:fixture_lib.srcs: missing-attr-doc',
      ]);
    });
  });

  group('rule 4, provider docs', () {
    _expectPair('provider_doc', {'missing-doc', 'missing-field-doc'});
    test('providers and fields are reported separately', () {
      expect(_lines(_check('provider_doc_violates')), [
        '$fixtureFile:DocumentedInfo.srcs: missing-field-doc',
        '$fixtureFile:FixtureInfo: missing-doc',
        '$fixtureFile:FixtureInfo.srcs: missing-field-doc',
      ]);
    });
  });

  group('rule 5, function docs', () {
    _expectPair('function_doc', {'missing-param-doc'});
    test('*args and **kwargs need an entry like any parameter', () {
      expect(_lines(_check('function_doc_violates')), [
        '$fixtureFile:fixture_fn.args: missing-param-doc',
        '$fixtureFile:fixture_fn.kwargs: missing-param-doc',
        '$fixtureFile:fixture_fn.target: missing-param-doc',
      ]);
    });
    _expectPair(
      'returns',
      {'missing-returns'},
      violatesSource: _returnsSource,
      passesSource: _returnsDocumentedSource,
    );
    test('a function without a value return needs no Returns section', () {
      const noValue =
          '"""Fixture source."""\n\n'
          'def fixture_fn(target):\n'
          '    """Computes the fixture value.\n\n'
          '    Args:\n'
          '        target: The target the function works on.\n'
          '    """\n'
          '    return\n';
      final List<Gap> gaps = _check('returns_violates', source: noValue);
      expect(_lines(gaps), isEmpty);
    });
  });

  group('rule 6, quality', () {
    test('a doc under 3 words or 15 characters is too-short', () {
      expect(_rules(_check('quality_short_violates')), {'too-short'});
    });
    test('a doc that restates the name is restates-name', () {
      expect(_rules(_check('quality_restates_violates')), {'restates-name'});
    });
    test('TODO and friends are forbidden-phrase', () {
      expect(_rules(_check('quality_forbidden_violates')), {
        'forbidden-phrase',
      });
    });
    _expectPair('quality_shared', {'shared-doc'});
    test('an approved phrasing that no attribute group needs is stale', () {
      final List<Gap> gaps = _check(
        'quality_shared_passes',
        shared: {'Shared sentence repeated verbatim; defaults to empty.'},
      );
      expect(gaps.map((g) => g.rule), ['stale-shared-phrasing']);
    });
    test('the implicit name attribute is not a shared phrasing', () {
      expect(_lines(_check('implicit_name_passes')), isEmpty);
    });
    test('an approved shared phrasing is allowed on many attributes', () {
      final List<Gap> gaps = _check(
        'quality_shared_violates',
        shared: {'Shared sentence repeated verbatim; defaults to empty.'},
      );
      expect(_lines(gaps), isEmpty);
    });
    test('an optional attribute whose doc omits the default only warns', () {
      final List<Gap> gaps = _check('default_undocumented_violates');
      expect(_lines(gaps), [
        '$fixtureFile:fixture_lib.srcs: default-undocumented',
      ]);
      expect(gaps.single.warning, isTrue);
      expect(_check('default_undocumented_passes'), isEmpty);
    });
  });

  group('closure', () {
    test('an unreadable source is a failure that names the file', () {
      final List<ModuleDoc> modules = decodeExtracts([
        fixtures['module_docstring_passes']!,
      ]);
      final List<Gap> gaps = checkDocs(modules, (_) => null, const {});
      expect(_lines(gaps), ['$fixtureFile:(module): source-unavailable']);
    });
    test('a loaded file without a module docstring is reported', () {
      final List<ModuleDoc> modules = decodeExtracts([
        fixtures['module_docstring_passes']!,
      ]);
      final List<Gap> gaps = checkDocs(
        modules,
        (label) => label == fixtureFile
            ? '"""Doc."""\nload("//fixture:other.bzl", "x")\n'
            : 'x = 1\n',
        const {},
      );
      expect(_lines(gaps), ['//fixture:other.bzl:(module): module-docstring']);
    });
    List<String> checkSource(String source) => _lines(
      checkDocs(
        decodeExtracts([fixtures['module_docstring_passes']!]),
        (_) => source,
        const {},
      ),
    );

    test('a private function without a structured docstring is exempt', () {
      const prose =
          '"""Doc."""\ndef _helper(a):\n    """Helps with the work."""\n    return a\n';
      expect(
        checkSource('"""Doc."""\ndef _helper(a):\n    return a\n'),
        isEmpty,
      );
      expect(checkSource(prose), isEmpty);
    });
    test('a private function with an Args section must be complete', () {
      const source =
          '"""Doc."""\ndef _helper(a, b):\n    """Helps with the work.\n\n'
          '    Args:\n        a: The first value to combine.\n    """\n    return a\n';
      expect(checkSource(source), [
        '$fixtureFile:_helper: missing-returns',
        '$fixtureFile:_helper.b: missing-param-doc',
      ]);
    });
    test('a public function without a docstring is reported', () {
      expect(checkSource('"""Doc."""\ndef helper():\n    pass\n'), [
        '$fixtureFile:helper: missing-doc',
      ]);
    });
  });

  group('reporting', () {
    test('a symbol re-exported by two extracts is reported once', () {
      final List<ModuleDoc> once = decodeExtracts([
        fixtures['function_doc_violates']!,
      ]);
      final List<ModuleDoc> twice = decodeExtracts([
        fixtures['function_doc_violates']!,
        fixtures['function_doc_violates']!,
      ]);
      String read(String label) => _cleanSource;
      expect(
        _lines(checkDocs(twice, read, const {})),
        _lines(checkDocs(once, read, const {})),
      );
    });
  });
}
