/// The machine-readable reports behind `--emit-rule-kinds` and `--emit-api`.
library;

import 'dart:convert';

import 'package:doc_check/stardoc_model.dart';

const _attributeTypes = [
  'UNKNOWN',
  'NAME',
  'INT',
  'LABEL',
  'STRING',
  'STRING_LIST',
  'INT_LIST',
  'LABEL_LIST',
  'BOOLEAN',
  'LABEL_STRING_DICT',
  'STRING_DICT',
  'STRING_LIST_DICT',
  'OUTPUT',
  'OUTPUT_LIST',
  'LABEL_DICT_UNARY',
  'LABEL_LIST_DICT',
];

const _paramRoles = [
  'unspecified',
  'ordinary',
  'positional_only',
  'keyword_only',
  'varargs',
  'kwargs',
];

const _encoder = JsonEncoder.withIndent('  ');

/// JSON mapping each extract file to `{symbol: kind}` for its public symbols.
///
/// A rule's kind is `rule`, `test` or `executable`; the other symbols carry
/// their symbol kind (`macro`, `aspect`, `repository_rule`,
/// `module_extension`).
String emitRuleKinds(List<ModuleDoc> modules) {
  final result = <String, Map<String, String>>{};
  for (final module in modules) {
    final Map<String, String> kinds = result.putIfAbsent(module.file, () => {});
    for (final SymbolDoc symbol in module.symbols) {
      if (symbol.name.startsWith('_')) continue;
      kinds[symbol.name] = _ruleKind(symbol);
    }
  }
  return _encoder.convert(_sortedMap(result));
}

String _ruleKind(SymbolDoc symbol) {
  if (symbol.isTest) return 'test';
  if (symbol.isExecutable) return 'executable';
  return symbol.kind;
}

Map<String, T> _sortedMap<T>(Map<String, T> map) => {
  for (final key in map.keys.toList()..sort()) key: map[key] as T,
};

/// JSON of the public API surface of every extract, keyed by file.
///
/// Each symbol lists its kind and, as they apply, its attributes (type,
/// mandatory, default, `natively_defined`), tag classes, provider fields and
/// function parameters (default and kind).
String emitApi(List<ModuleDoc> modules) {
  final result = <String, Map<String, Object>>{};
  for (final module in modules) {
    final Map<String, Object> api = result.putIfAbsent(module.file, () => {});
    for (final SymbolDoc symbol in module.symbols.where(_isPublic)) {
      api[symbol.name] = _symbolApi(symbol);
    }
    for (final FunctionDoc function in module.functions.where(_isPublic)) {
      api[function.name] = {
        'kind': 'function',
        'parameters': [for (final p in function.params) _paramApi(p)],
      };
    }
    for (final ProviderDoc provider in module.providers.where(_isPublic)) {
      api[provider.name] = {
        'kind': 'provider',
        'fields': provider.fields.keys.toList(),
      };
    }
  }
  return _encoder.convert({
    for (final file in result.keys.toList()..sort())
      file: _sortedMap(result[file]!),
  });
}

bool _isPublic(Object symbol) => switch (symbol) {
  SymbolDoc(:final name) => !name.startsWith('_'),
  FunctionDoc(:final name) => !name.startsWith('_'),
  ProviderDoc(:final name) => !name.startsWith('_'),
  _ => false,
};

Map<String, Object> _symbolApi(SymbolDoc symbol) => {
  'kind': _ruleKind(symbol),
  if (symbol.kind != 'module_extension')
    'attributes': [for (final a in symbol.attributes) _attributeApi(a)],
  if (symbol.children.isNotEmpty)
    'tag_classes': {
      for (final child in symbol.children)
        child.name: [for (final a in child.attributes) _attributeApi(a)],
    },
};

Map<String, Object> _attributeApi(AttributeDoc attribute) => {
  'name': attribute.name,
  'type': attribute.type < _attributeTypes.length
      ? _attributeTypes[attribute.type]
      : 'UNKNOWN',
  'mandatory': attribute.mandatory,
  'default': attribute.defaultValue,
  'natively_defined': attribute.nativelyDefined,
};

Map<String, Object> _paramApi(ParamDoc param) => {
  'name': param.name,
  'kind': param.role < _paramRoles.length
      ? _paramRoles[param.role]
      : 'unspecified',
  'mandatory': param.mandatory,
  'default': param.defaultValue,
};
