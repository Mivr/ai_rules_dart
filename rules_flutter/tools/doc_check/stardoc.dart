/// Typed views over the `stardoc_output.proto` `ModuleInfo` message, the
/// binaryproto `starlark_doc_extract` writes. Field numbers follow the
/// vendored `stardoc_output.proto`.
library;

import 'dart:typed_data';

import 'wire.dart';

/// A rule or macro attribute, or a module-extension tag attribute.
class AttrDoc {
  /// Creates an attribute entry.
  const new({
    required this.name,
    this.doc = '',
    this.type = 0,
    this.mandatory = false,
    this.defaultValue = '',
    this.nativelyDefined = false,
  });

  /// Decodes an `AttributeInfo`.
  factory fromWire(WireMessage m) => AttrDoc(
    name: m.string(1),
    doc: m.string(2),
    type: m.integer(3),
    mandatory: m.flag(4),
    defaultValue: m.string(6),
    nativelyDefined: m.flag(8),
  );

  /// The attribute name.
  final String name;

  /// The attribute docstring.
  final String doc;

  /// The `AttributeType` enum number.
  final int type;

  /// Whether the attribute must be set.
  final bool mandatory;

  /// The default rendered as a Starlark expression, empty when none.
  final String defaultValue;

  /// Whether Bazel itself defines the attribute (`name`, `visibility`, ...).
  final bool nativelyDefined;
}

/// A function parameter.
class ParamDoc {
  /// Creates a parameter entry.
  const new({
    required this.name,
    this.doc = '',
    this.defaultValue = '',
    this.mandatory = false,
    this.role = 0,
  });

  /// Decodes a `FunctionParamInfo`.
  factory fromWire(WireMessage m) => ParamDoc(
    name: m.string(1),
    doc: m.string(2),
    defaultValue: m.string(3),
    mandatory: m.flag(4),
    role: m.integer(5),
  );

  /// The parameter name.
  final String name;

  /// The parameter docstring.
  final String doc;

  /// The default rendered as a Starlark expression, empty when none.
  final String defaultValue;

  /// Whether the caller must pass it.
  final bool mandatory;

  /// The `FunctionParamRole` enum number.
  final int role;

  /// A readable role name for the API listing.
  String get roleName => const [
    'unspecified',
    'ordinary',
    'positional-only',
    'keyword-only',
    'varargs',
    'kwargs',
  ][role.clamp(0, 5)];
}

/// A Starlark function, or a provider's `init` callback.
class FuncDoc {
  /// Creates a function entry.
  const new({
    required this.name,
    this.doc = '',
    this.params = const [],
    this.returnDoc = '',
    this.file = '',
  });

  /// Decodes a `StarlarkFunctionInfo`.
  factory fromWire(WireMessage m) => FuncDoc(
    name: m.string(1),
    params: m.messages(2).map(ParamDoc.fromWire).toList(),
    doc: m.string(3),
    returnDoc: m.message(4)?.string(1) ?? '',
    file: m.message(6)?.string(2) ?? '',
  );

  /// The function name.
  final String name;

  /// The docstring summary and description.
  final String doc;

  /// The parameters in declaration order.
  final List<ParamDoc> params;

  /// The `Returns:` section text, empty when there is none.
  final String returnDoc;

  /// The label of the file that defines the function, empty when unknown.
  final String file;
}

/// A provider field.
class FieldDoc {
  /// Creates a provider field entry.
  const new({required this.name, this.doc = ''});

  /// The field name.
  final String name;

  /// The field docstring.
  final String doc;
}

/// A provider.
class ProviderDoc {
  /// Creates a provider entry.
  const new({
    required this.name,
    this.doc = '',
    this.fields = const [],
    this.file = '',
  });

  /// Decodes a `ProviderInfo`.
  factory fromWire(WireMessage m) => ProviderDoc(
    name: m.string(1),
    doc: m.string(2),
    fields: [
      for (final f in m.messages(3))
        FieldDoc(name: f.string(1), doc: f.string(2)),
    ],
    file: m.message(4)?.string(2) ?? '',
  );

  /// The provider name.
  final String name;

  /// The provider docstring.
  final String doc;

  /// The documented fields.
  final List<FieldDoc> fields;

  /// The label of the file that defines the provider, empty when unknown.
  final String file;
}

/// A rule, macro, aspect, repository rule, module extension or tag class.
class CallableDoc {
  /// Creates a callable entry.
  const new({
    required this.kind,
    required this.name,
    this.doc = '',
    this.attrs = const [],
    this.children = const [],
    this.file = '',
  });

  /// The kind: `rule`, `test_rule`, `executable_rule`, `macro`, `aspect`, `repository_rule`,
  /// `module_extension` or `tag_class`.
  final String kind;

  /// The symbol name.
  final String name;

  /// The docstring.
  final String doc;

  /// The attributes.
  final List<AttrDoc> attrs;

  /// Nested entries: the tag classes of a module extension.
  final List<CallableDoc> children;

  /// The label of the file that defines the symbol, empty when unknown.
  final String file;
}

/// One extract: everything a public `.bzl` entry file exports.
class ModuleDoc {
  /// Creates a module entry.
  const new({
    required this.file,
    this.doc = '',
    this.callables = const [],
    this.functions = const [],
    this.providers = const [],
  });

  /// Decodes the bytes of one `.binaryproto` extract.
  factory parse(Uint8List bytes) {
    final m = WireMessage.parse(bytes);
    return ModuleDoc(
      file: m.string(6),
      doc: m.string(5),
      callables: [
        ..._callables(m.messages(1), _ruleKind, 4, 3),
        ..._callables(m.messages(9), (_) => 'macro', 4, 3),
        ..._callables(m.messages(4), (_) => 'aspect', 5, 4),
        ..._callables(m.messages(8), (_) => 'repository_rule', 5, 3),
        ..._extensions(m.messages(7)),
      ],
      functions: m.messages(3).map(FuncDoc.fromWire).toList(),
      providers: m.messages(2).map(ProviderDoc.fromWire).toList(),
    );
  }

  /// The label of the `.bzl` file the extract describes.
  final String file;

  /// The module docstring.
  final String doc;

  /// Rules, macros, aspects, repository rules and module extensions.
  final List<CallableDoc> callables;

  /// Public functions.
  final List<FuncDoc> functions;

  /// Providers.
  final List<ProviderDoc> providers;
}

/// The kind of a `RuleInfo`: a test or executable rule, else a plain `rule`.
String _ruleKind(WireMessage m) => m.flag(6)
    ? 'test_rule'
    : m.flag(7)
    ? 'executable_rule'
    : 'rule';

/// Decodes `RuleInfo`/`MacroInfo`/`AspectInfo`/`RepositoryRuleInfo` messages.
///
/// All four put the name in field 1, the docstring in field 2 and the
/// attributes in [attrField]; the origin key sits in [originField]. [kindOf]
/// names the kind of each message.
List<CallableDoc> _callables(
  List<WireMessage> messages,
  String Function(WireMessage) kindOf,
  int originField,
  int attrField,
) => [
  for (final m in messages)
    CallableDoc(
      kind: kindOf(m),
      name: m.string(1),
      doc: m.string(2),
      attrs: m.messages(attrField).map(AttrDoc.fromWire).toList(),
      file: m.message(originField)?.string(2) ?? '',
    ),
];

/// Decodes `ModuleExtensionInfo` messages with their tag classes.
List<CallableDoc> _extensions(List<WireMessage> messages) => [
  for (final m in messages)
    CallableDoc(
      kind: 'module_extension',
      name: m.string(1),
      doc: m.string(2),
      children: [
        for (final t in m.messages(3))
          CallableDoc(
            kind: 'tag_class',
            name: t.string(1),
            doc: t.string(2),
            attrs: t.messages(3).map(AttrDoc.fromWire).toList(),
          ),
      ],
      file: m.message(4)?.string(2) ?? '',
    ),
];
