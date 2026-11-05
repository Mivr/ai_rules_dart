/// A tiny protobuf encoder that builds `ModuleInfo` fixtures for the tests.
///
/// It mirrors the field numbers of the vendored `stardoc_output.proto` and
/// encodes only what the fixtures need.
library;

import 'dart:convert';
import 'dart:typed_data';

/// A serialized message or field, ready to concatenate.
typedef Bytes = List<int>;

Bytes _varint(int value) {
  final out = <int>[];
  var rest = value;
  while (rest > 0x7f) {
    out.add((rest & 0x7f) | 0x80);
    rest >>= 7;
  }
  return [...out, rest];
}

/// A string field; an empty string encodes as no bytes, like proto3.
Bytes str(int field, String value) {
  if (value.isEmpty) return const [];
  final Uint8List data = utf8.encode(value);
  return [..._varint(field << 3 | 2), ..._varint(data.length), ...data];
}

/// A varint field; zero encodes as no bytes, like proto3.
Bytes num(int field, int value) =>
    value == 0 ? const [] : [..._varint(field << 3), ..._varint(value)];

/// A nested message field built from [parts].
Bytes sub(int field, List<Bytes> parts) {
  final List<int> data = [for (final part in parts) ...part];
  return [..._varint(field << 3 | 2), ..._varint(data.length), ...data];
}

/// A message built from [parts].
Uint8List message(List<Bytes> parts) =>
    Uint8List.fromList([for (final part in parts) ...part]);

/// An `AttributeInfo` field of a rule, macro, aspect or tag class.
Bytes attribute(
  int field,
  String name, {
  String doc = '',
  bool native = false,
  bool mandatory = false,
  String defaultValue = '',
  int type = 4,
}) => sub(field, [
  str(1, name),
  str(2, doc),
  num(3, type),
  num(4, mandatory ? 1 : 0),
  str(6, defaultValue),
  num(8, native ? 1 : 0),
]);

/// A `FunctionParamInfo` field; [role] follows `FunctionParamRole`.
Bytes param(
  String name, {
  String doc = '',
  int role = 1,
  String defaultValue = '',
}) => sub(2, [
  str(1, name),
  str(2, doc),
  str(3, defaultValue),
  num(4, defaultValue.isEmpty ? 1 : 0),
  num(5, role),
]);

/// A `StarlarkFunctionInfo` field of a module.
Bytes function(
  String name, {
  String doc = '',
  List<Bytes> params = const [],
  String returns = '',
}) => sub(3, [
  str(1, name),
  ...params,
  str(3, doc),
  if (returns.isNotEmpty) sub(4, [str(1, returns)]),
]);

/// A `RuleInfo` field.
Bytes rule(
  String name, {
  String doc = '',
  List<Bytes> attrs = const [],
  bool test = false,
  bool executable = false,
}) => sub(1, [
  str(1, name),
  str(2, doc),
  ...attrs,
  num(6, test ? 1 : 0),
  num(7, executable ? 1 : 0),
]);

/// A `ProviderInfo` field; [fields] maps field name to docstring.
Bytes provider(
  String name, {
  String doc = '',
  Map<String, String> fields = const {},
}) => sub(2, [
  str(1, name),
  str(2, doc),
  for (final entry in fields.entries)
    sub(3, [str(1, entry.key), str(2, entry.value)]),
]);

/// A `MacroInfo`, `AspectInfo` or `RepositoryRuleInfo` style field.
Bytes named(
  int field,
  String name, {
  String doc = '',
  List<Bytes> attrs = const [],
}) => sub(field, [str(1, name), str(2, doc), ...attrs]);

/// A `ModuleExtensionInfo` field whose tag classes are `(name, doc)` pairs.
Bytes extension(
  String name, {
  String doc = '',
  List<(String, String)> tags = const [],
}) => sub(7, [
  str(1, name),
  str(2, doc),
  for (final (tag, tagDoc) in tags) sub(3, [str(1, tag), str(2, tagDoc)]),
]);

/// A whole `ModuleInfo` for [file] with the given top-level [entries].
Uint8List module(String file, String doc, List<Bytes> entries) =>
    message([str(5, doc), str(6, file), ...entries]);
