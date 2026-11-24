/// Builders for `ModuleInfo` fixtures: one well-documented module and a
/// helper per symbol kind, so a test breaks exactly one thing at a time.
library;

import 'dart:typed_data';

import 'proto_writer.dart';

/// Documentation text that satisfies every quality rule.
const goodDoc = 'Describes this symbol in a full sentence.';

/// An `AttributeInfo`.
ProtoWriter attr(
  String name, {
  String doc = goodDoc,
  bool native = false,
  bool mandatory = false,
  int type = 4,
  String defaultValue = '',
}) => ProtoWriter()
  ..str(1, name)
  ..str(2, doc)
  ..varint(3, type)
  ..varint(4, mandatory ? 1 : 0)
  ..str(6, defaultValue)
  ..varint(8, native ? 1 : 0);

ProtoWriter _origin(String file) => ProtoWriter()..str(2, file);

/// A `RuleInfo`; [test] and [executable] set the rule-kind flags.
ProtoWriter rule(
  String name, {
  String doc = goodDoc,
  List<ProtoWriter> attrs = const [],
  String file = '//pkg:lib.bzl',
  bool test = false,
  bool executable = false,
}) {
  final w = ProtoWriter()
    ..str(1, name)
    ..str(2, doc);
  for (final a in attrs) {
    w.msg(3, a);
  }
  return w
    ..msg(4, _origin(file))
    ..varint(6, test ? 1 : 0)
    ..varint(7, executable ? 1 : 0);
}

/// A `MacroInfo`.
ProtoWriter macro(
  String name, {
  String doc = goodDoc,
  List<ProtoWriter> attrs = const [],
}) {
  final w = ProtoWriter()
    ..str(1, name)
    ..str(2, doc);
  for (final a in attrs) {
    w.msg(3, a);
  }
  w.msg(4, _origin('//pkg:lib.bzl'));
  return w;
}

/// An `AspectInfo`.
ProtoWriter aspect(String name, {String doc = goodDoc}) => ProtoWriter()
  ..str(1, name)
  ..str(2, doc)
  ..msg(5, _origin('//pkg:lib.bzl'));

/// A `RepositoryRuleInfo`.
ProtoWriter repoRule(String name, {String doc = goodDoc}) => ProtoWriter()
  ..str(1, name)
  ..str(2, doc)
  ..msg(5, _origin('//pkg:lib.bzl'));

/// A `ModuleExtensionInfo` with tag classes built by [tagClass].
ProtoWriter extension(
  String name, {
  String doc = goodDoc,
  List<ProtoWriter> tags = const [],
}) {
  final w = ProtoWriter()
    ..str(1, name)
    ..str(2, doc);
  for (final t in tags) {
    w.msg(3, t);
  }
  w.msg(4, _origin('//pkg:lib.bzl'));
  return w;
}

/// A `ModuleExtensionTagClassInfo`.
ProtoWriter tagClass(
  String name, {
  String doc = goodDoc,
  List<ProtoWriter> attrs = const [],
}) {
  final w = ProtoWriter()
    ..str(1, name)
    ..str(2, doc);
  for (final a in attrs) {
    w.msg(3, a);
  }
  return w;
}

/// A `FunctionParamInfo`; [role] 4 is `*args`, 5 is `**kwargs`.
ProtoWriter param(
  String name, {
  String doc = goodDoc,
  int role = 1,
  String defaultValue = '',
}) => ProtoWriter()
  ..str(1, name)
  ..str(2, doc)
  ..str(3, defaultValue)
  ..varint(4, defaultValue.isEmpty ? 1 : 0)
  ..varint(5, role);

/// A `StarlarkFunctionInfo`; [returns] adds a `Returns:` section.
ProtoWriter func(
  String name, {
  String doc = goodDoc,
  List<ProtoWriter> params = const [],
  String returns = '',
}) {
  final w = ProtoWriter()..str(1, name);
  for (final p in params) {
    w.msg(2, p);
  }
  w.str(3, doc);
  if (returns.isNotEmpty) w.msg(4, ProtoWriter()..str(1, returns));
  w.msg(6, _origin('//pkg:lib.bzl'));
  return w;
}

/// A `ProviderInfo` whose fields are `(name, doc)` pairs.
ProtoWriter provider(
  String name, {
  String doc = goodDoc,
  List<(String, String)> fields = const [],
}) {
  final w = ProtoWriter()
    ..str(1, name)
    ..str(2, doc);
  for (final (field, fieldDoc) in fields) {
    w.msg(
      3,
      ProtoWriter()
        ..str(1, field)
        ..str(2, fieldDoc),
    );
  }
  w.msg(4, _origin('//pkg:lib.bzl'));
  return w;
}

/// The bytes of a `ModuleInfo` extract holding the given symbols.
Uint8List module({
  String file = '//pkg:lib.bzl',
  String doc = 'A fixture module that documents itself.',
  List<ProtoWriter> rules = const [],
  List<ProtoWriter> macros = const [],
  List<ProtoWriter> aspects = const [],
  List<ProtoWriter> repoRules = const [],
  List<ProtoWriter> extensions = const [],
  List<ProtoWriter> funcs = const [],
  List<ProtoWriter> providers = const [],
}) {
  final w = ProtoWriter();
  for (final (field, items) in [
    (1, rules),
    (2, providers),
    (3, funcs),
    (4, aspects),
    (7, extensions),
    (8, repoRules),
    (9, macros),
  ]) {
    for (final item in items) {
      w.msg(field, item);
    }
  }
  w
    ..str(5, doc)
    ..str(6, file);
  return w.bytes();
}
