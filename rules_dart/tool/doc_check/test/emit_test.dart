/// `--emit-rule-kinds` and `--emit-api` over a fixture.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:doc_check/checker.dart';
import 'package:doc_check/emit.dart';
import 'package:doc_check/stardoc_model.dart';
import 'package:test/test.dart';

import 'support/proto_builder.dart';

final Uint8List _module = module('//pkg:defs.bzl', 'Fixture module.', [
  rule(
    'fixture_lib',
    doc: 'Compiles a library.',
    attrs: [
      attribute(3, 'srcs', doc: 'Sources.', defaultValue: '[]'),
      attribute(3, 'name', native: true, mandatory: true),
    ],
  ),
  rule('fixture_test', doc: 'Runs a test.', test: true),
  rule('fixture_bin', doc: 'Runs a binary.', executable: true),
  rule('_private_rule', doc: 'Hidden rule.'),
  named(9, 'fixture_macro', doc: 'A macro.'),
  provider(
    'FixtureInfo',
    doc: 'Facts.',
    fields: {'srcs': 'Sources.', 'deps': 'Deps.'},
  ),
  function(
    'fixture_fn',
    doc: 'Does work.',
    params: [
      param('target'),
      param('mode', defaultValue: '"fast"'),
      param('args', role: 4),
      param('kwargs', role: 5),
    ],
  ),
  extension('fixture_ext', doc: 'Ext.', tags: [('tag', 'A tag.')]),
]);

Object? _json(String text) => jsonDecode(text);

Map<String, Object?> _map(Object? value) => value! as Map<String, Object?>;

void main() {
  final List<ModuleDoc> modules = decodeExtracts([_module]);

  test('--emit-rule-kinds lists the kind of each public symbol per file', () {
    expect(_json(emitRuleKinds(modules)), {
      '//pkg:defs.bzl': {
        'fixture_lib': 'rule',
        'fixture_test': 'test',
        'fixture_bin': 'executable',
        'fixture_macro': 'macro',
        'fixture_ext': 'module_extension',
      },
    });
  });

  test('--emit-api lists attributes with natively_defined', () {
    final Map<String, Object?> api = _map(_json(emitApi(modules)));
    final Map<String, Object?> lib = _map(
      _map(api['//pkg:defs.bzl'])['fixture_lib'],
    );
    expect(lib['kind'], 'rule');
    expect(lib['attributes'], [
      {
        'name': 'srcs',
        'type': 'STRING',
        'mandatory': false,
        'default': '[]',
        'natively_defined': false,
      },
      {
        'name': 'name',
        'type': 'STRING',
        'mandatory': true,
        'default': '',
        'natively_defined': true,
      },
    ]);
  });

  test('--emit-api lists provider fields and parameters with kinds', () {
    final Map<String, Object?> api = _map(_json(emitApi(modules)));
    final Map<String, Object?> file = _map(api['//pkg:defs.bzl']);
    expect(file['FixtureInfo'], {
      'kind': 'provider',
      'fields': ['srcs', 'deps'],
    });
    expect(_map(file['fixture_fn'])['parameters'], [
      {'name': 'target', 'kind': 'ordinary', 'mandatory': true, 'default': ''},
      {
        'name': 'mode',
        'kind': 'ordinary',
        'mandatory': false,
        'default': '"fast"',
      },
      {'name': 'args', 'kind': 'varargs', 'mandatory': true, 'default': ''},
      {'name': 'kwargs', 'kind': 'kwargs', 'mandatory': true, 'default': ''},
    ]);
    expect(_map(file['fixture_ext'])['tag_classes'], {'tag': <Object>[]});
    expect(file.containsKey('_private_rule'), isFalse);
  });
}
