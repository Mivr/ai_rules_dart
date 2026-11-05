/// The fixture `ModuleInfo` protos, one violating and one passing per rule.
///
/// `write_fixtures` writes these bytes to `test/fixtures/`; `fixtures_test`
/// fails when a checked-in file drifts from them.
library;

import 'dart:typed_data';

import 'proto_builder.dart';

/// The label of the module every fixture documents.
const fixtureFile = '//fixture:defs.bzl';

const _moduleDoc = 'Fixture module that exercises one documentation rule.';
const _ruleDoc = 'Compiles the fixture sources into a library.';
const _attrDoc = 'Source files to compile into the library.';

Uint8List _fixture(String doc, List<Bytes> entries) =>
    module(fixtureFile, doc, entries);

Bytes _documentedRule({List<Bytes> attrs = const []}) =>
    rule('fixture_lib', doc: _ruleDoc, attrs: attrs);

/// Fixture name to serialized `ModuleInfo`, for every rule class.
final Map<String, Uint8List> fixtures = {
  'module_docstring_violates': _fixture('', [_documentedRule()]),
  'module_docstring_passes': _fixture(_moduleDoc, [_documentedRule()]),
  'symbol_doc_violates': _fixture(_moduleDoc, [
    rule('fixture_lib'),
    named(9, 'fixture_macro'),
    named(4, 'fixture_aspect'),
    named(8, 'fixture_repo_rule'),
    extension('fixture_ext', tags: [('fixture_tag', '')]),
    provider('FixtureInfo'),
    function('fixture_fn'),
  ]),
  'symbol_doc_passes': _fixture(_moduleDoc, [
    rule('fixture_lib', doc: _ruleDoc),
    named(9, 'fixture_macro', doc: 'Declares the fixture macro targets.'),
    named(4, 'fixture_aspect', doc: 'Collects fixture sources from deps.'),
    named(8, 'fixture_repo_rule', doc: 'Fetches the fixture archive.'),
    extension(
      'fixture_ext',
      doc: 'Module extension of the fixture.',
      tags: [('fixture_tag', 'Tag class that selects fixture inputs.')],
    ),
    provider('FixtureInfo', doc: 'Facts about the fixture library.'),
    function('fixture_fn', doc: 'Does the fixture work without params.'),
  ]),
  'attr_doc_violates': _fixture(_moduleDoc, [
    _documentedRule(
      attrs: [attribute(3, 'srcs'), attribute(3, 'name', native: true)],
    ),
    rule('_hidden_rule', doc: _ruleDoc, attrs: [attribute(3, 'data')]),
  ]),
  'attr_doc_passes': _fixture(_moduleDoc, [
    _documentedRule(
      attrs: [
        attribute(3, 'srcs', doc: _attrDoc, mandatory: true),
        attribute(3, 'name', native: true),
      ],
    ),
    rule(
      '_hidden_rule',
      doc: _ruleDoc,
      attrs: [attribute(3, 'data', doc: 'Runtime data files, default empty.')],
    ),
  ]),
  'provider_doc_violates': _fixture(_moduleDoc, [
    provider('FixtureInfo', fields: {'srcs': ''}),
    provider(
      'DocumentedInfo',
      doc: 'Facts about a library.',
      fields: {'srcs': ''},
    ),
  ]),
  'provider_doc_passes': _fixture(_moduleDoc, [
    provider(
      'FixtureInfo',
      doc: 'Facts about the fixture.',
      fields: {'srcs': 'The sources the library compiled.'},
    ),
  ]),
  'function_doc_violates': _fixture(_moduleDoc, [
    function(
      'fixture_fn',
      doc: 'Runs the fixture function.',
      params: [
        param('target'),
        param('args', role: 4),
        param('kwargs', role: 5),
      ],
    ),
  ]),
  'function_doc_passes': _fixture(_moduleDoc, [
    function(
      'fixture_fn',
      doc: 'Runs the fixture function.',
      params: [
        param('target', doc: 'The target the function works on.'),
        param(
          'args',
          doc: 'Extra positional arguments, passed through.',
          role: 4,
        ),
        param(
          'kwargs',
          doc: 'Extra keyword arguments, passed through.',
          role: 5,
        ),
      ],
    ),
  ]),
  'returns_violates': _fixture(_moduleDoc, [
    function(
      'fixture_fn',
      doc: 'Computes the fixture value.',
      params: [param('target', doc: 'The target the function works on.')],
    ),
  ]),
  'returns_passes': _fixture(_moduleDoc, [
    function(
      'fixture_fn',
      doc: 'Computes the fixture value.',
      params: [param('target', doc: 'The target the function works on.')],
      returns: 'The computed fixture value.',
    ),
  ]),
  'quality_short_violates': _fixture(_moduleDoc, [
    _documentedRule(attrs: [attribute(3, 'srcs', doc: 'Source files.')]),
  ]),
  'quality_restates_violates': _fixture(_moduleDoc, [
    rule('dart_library', doc: 'The Dart library rule.'),
  ]),
  'quality_forbidden_violates': _fixture(_moduleDoc, [
    _documentedRule(
      attrs: [
        attribute(3, 'srcs', doc: 'Source files to compile. TODO say more.'),
      ],
    ),
  ]),
  'quality_shared_violates': _fixture(_moduleDoc, [
    _documentedRule(
      attrs: [
        for (final name in ['a', 'b', 'c', 'd'])
          attribute(
            3,
            name,
            doc: 'Shared sentence repeated verbatim; defaults to empty.',
          ),
      ],
    ),
  ]),
  'quality_shared_passes': _fixture(_moduleDoc, [
    _documentedRule(
      attrs: [
        for (final name in ['a', 'b', 'c'])
          attribute(
            3,
            name,
            doc: 'Shared sentence repeated verbatim; defaults to empty.',
          ),
      ],
    ),
  ]),
  // Bazel supplies the text of the implicit `name` attribute, so four rules
  // carrying the same text are no authored repetition.
  'implicit_name_passes': _fixture(_moduleDoc, [
    for (final rule_ in ['a', 'b', 'c', 'd'])
      rule(
        'fixture_$rule_',
        doc: _ruleDoc,
        attrs: [
          attribute(
            3,
            'name',
            doc: 'A unique name for this target.',
            mandatory: true,
            type: 1,
          ),
        ],
      ),
  ]),
  'default_undocumented_violates': _fixture(_moduleDoc, [
    _documentedRule(attrs: [attribute(3, 'srcs', doc: _attrDoc)]),
  ]),
  'default_undocumented_passes': _fixture(_moduleDoc, [
    _documentedRule(
      attrs: [
        attribute(3, 'srcs', doc: 'Source files to compile; defaults to none.'),
        attribute(
          3,
          'main',
          doc: 'The entry point file of the library.',
          mandatory: true,
        ),
      ],
    ),
  ]),
};
