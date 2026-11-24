/// Typed views over the `stardoc_output.proto` messages the checker needs.
///
/// Field numbers follow Bazel 9.3.0's `stardoc_output.proto`, the copy
/// vendored beside this package and pinned by its sha256 in the tests.
library;

import 'dart:typed_data';

import 'package:doc_check/wire.dart';

/// Where a symbol was defined: its name and the label of its `.bzl` file.
class OriginKey {
  /// Creates an origin from [name] and [file].
  const new(this.name, this.file);

  /// The symbol's name in the defining file.
  final String name;

  /// The defining file's label, e.g. `//dart/private:common.bzl`.
  final String file;
}

/// One attribute of a rule, macro, aspect, repository rule or tag class.
class AttributeDoc {
  /// Creates an attribute record.
  const new({
    required this.name,
    required this.doc,
    required this.type,
    required this.mandatory,
    required this.defaultValue,
    required this.nativelyDefined,
  });

  /// The attribute name.
  final String name;

  /// The attribute docstring, empty when undocumented.
  final String doc;

  /// The `AttributeType` enum number.
  final int type;

  /// Whether the attribute must be set.
  final bool mandatory;

  /// The default value as Starlark source text.
  final String defaultValue;

  /// Whether Bazel itself, not the rule author, defines the attribute.
  final bool nativelyDefined;
}

/// One parameter of a function.
class ParamDoc {
  /// Creates a parameter record.
  const new({
    required this.name,
    required this.doc,
    required this.defaultValue,
    required this.mandatory,
    required this.role,
  });

  /// The parameter name, without any `*` prefix.
  final String name;

  /// The parameter docstring, empty when undocumented.
  final String doc;

  /// The default as Starlark source text, empty when there is none.
  final String defaultValue;

  /// Whether the caller must pass the parameter.
  final bool mandatory;

  /// The `FunctionParamRole` enum number.
  final int role;
}

/// A function and its documented parameters and return value.
class FunctionDoc {
  /// Creates a function record.
  const new({
    required this.name,
    required this.doc,
    required this.params,
    required this.returnDoc,
    required this.origin,
  });

  /// The function name.
  final String name;

  /// The function docstring.
  final String doc;

  /// The parameters in declaration order.
  final List<ParamDoc> params;

  /// The `Returns:` text, empty when the docstring has no such section.
  final String returnDoc;

  /// The defining file, null when the extractor did not record one.
  final OriginKey? origin;
}

/// A provider with its documented fields.
class ProviderDoc {
  /// Creates a provider record.
  const new({
    required this.name,
    required this.doc,
    required this.fields,
    required this.origin,
  });

  /// The provider name.
  final String name;

  /// The provider docstring.
  final String doc;

  /// Field name to field docstring, in declaration order.
  final Map<String, String> fields;

  /// The defining file, null when the extractor did not record one.
  final OriginKey? origin;
}

/// A documented symbol that owns attributes: rule, macro, aspect, repository
/// rule, module extension (whose tag classes are [children]) or tag class.
class SymbolDoc {
  /// Creates a symbol record.
  const new({
    required this.kind,
    required this.name,
    required this.doc,
    required this.attributes,
    required this.origin,
    this.children = const [],
    this.isTest = false,
    this.isExecutable = false,
  });

  /// One of `rule`, `macro`, `aspect`, `repository_rule`,
  /// `module_extension` or `tag_class`.
  final String kind;

  /// The symbol name.
  final String name;

  /// The symbol docstring.
  final String doc;

  /// The symbol's attributes, native ones included.
  final List<AttributeDoc> attributes;

  /// The defining file, null when the extractor did not record one.
  final OriginKey? origin;

  /// The tag classes of a module extension.
  final List<SymbolDoc> children;

  /// Whether a rule is a test rule.
  final bool isTest;

  /// Whether a rule produces an executable.
  final bool isExecutable;
}

/// Everything one `starlark_doc_extract` wrote for one `.bzl` file.
class ModuleDoc {
  /// Creates a module record.
  const new({
    required this.file,
    required this.doc,
    required this.symbols,
    required this.functions,
    required this.providers,
  });

  /// Decodes a serialized `ModuleInfo`.
  factory decode(Uint8List data) {
    final List<WireField> fields = readFields(data);
    return ModuleDoc(
      file: _text(fields, 6),
      doc: _text(fields, 5),
      symbols: [
        ..._all(fields, 1, (b) => _symbol('rule', b, 1, 2, 3, 4)),
        ..._all(fields, 4, (b) => _symbol('aspect', b, 1, 2, 4, 5)),
        ..._all(fields, 8, (b) => _symbol('repository_rule', b, 1, 2, 3, 5)),
        ..._all(fields, 9, (b) => _symbol('macro', b, 1, 2, 3, 4)),
        ..._all(fields, 7, _extension),
      ],
      functions: _all(fields, 3, _function),
      providers: _all(fields, 2, _provider),
    );
  }

  /// The `.bzl` file label this extract documents.
  final String file;

  /// The module docstring.
  final String doc;

  /// Rules, aspects, repository rules, macros and module extensions.
  final List<SymbolDoc> symbols;

  /// The public functions.
  final List<FunctionDoc> functions;

  /// The providers.
  final List<ProviderDoc> providers;
}

String _text(List<WireField> fields, int number) {
  for (final field in fields) {
    if (field.number == number) return field.text;
  }
  return '';
}

int _int(List<WireField> fields, int number) {
  for (final field in fields) {
    if (field.number == number) return field.value;
  }
  return 0;
}

List<T> _all<T>(List<WireField> fields, int number, T Function(Uint8List) f) =>
    [
      for (final field in fields)
        if (field.number == number && field.bytes != null) f(field.bytes!),
    ];

OriginKey? _origin(List<WireField> fields, int number) {
  final List<List<WireField>> nested = _all(fields, number, readFields);
  if (nested.isEmpty) return null;
  return OriginKey(_text(nested.first, 1), _text(nested.first, 2));
}

AttributeDoc _attribute(Uint8List data) {
  final List<WireField> f = readFields(data);
  return AttributeDoc(
    name: _text(f, 1),
    doc: _text(f, 2),
    type: _int(f, 3),
    mandatory: _int(f, 4) != 0,
    defaultValue: _text(f, 6),
    nativelyDefined: _int(f, 8) != 0,
  );
}

SymbolDoc _symbol(
  String kind,
  Uint8List data,
  int nameField,
  int docField,
  int attrField,
  int originField,
) {
  final List<WireField> f = readFields(data);
  return SymbolDoc(
    kind: kind,
    name: _text(f, nameField),
    doc: _text(f, docField),
    attributes: _all(f, attrField, _attribute),
    origin: _origin(f, originField),
    isTest: kind == 'rule' && _int(f, 6) != 0,
    isExecutable: kind == 'rule' && _int(f, 7) != 0,
  );
}

SymbolDoc _extension(Uint8List data) {
  final List<WireField> f = readFields(data);
  return SymbolDoc(
    kind: 'module_extension',
    name: _text(f, 1),
    doc: _text(f, 2),
    attributes: const [],
    origin: _origin(f, 4),
    children: _all(f, 3, (b) => _symbol('tag_class', b, 1, 2, 3, 99)),
  );
}

ParamDoc _param(Uint8List data) {
  final List<WireField> f = readFields(data);
  return ParamDoc(
    name: _text(f, 1),
    doc: _text(f, 2),
    defaultValue: _text(f, 3),
    mandatory: _int(f, 4) != 0,
    role: _int(f, 5),
  );
}

FunctionDoc _function(Uint8List data) {
  final List<WireField> f = readFields(data);
  final List<List<WireField>> returns = _all(f, 4, readFields);
  return FunctionDoc(
    name: _text(f, 1),
    doc: _text(f, 3),
    params: _all(f, 2, _param),
    returnDoc: returns.isEmpty ? '' : _text(returns.first, 1),
    origin: _origin(f, 6),
  );
}

ProviderDoc _provider(Uint8List data) {
  final List<WireField> f = readFields(data);
  return ProviderDoc(
    name: _text(f, 1),
    doc: _text(f, 2),
    fields: {
      for (final field in _all(f, 3, readFields))
        _text(field, 1): _text(field, 2),
    },
    origin: _origin(f, 4),
  );
}
