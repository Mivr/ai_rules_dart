/// The two listings other tools consume: rule kinds and the public API.
library;

import 'stardoc.dart';

const _attrTypes = [
  'UNKNOWN', 'NAME', 'INT', 'LABEL', 'STRING', 'STRING_LIST', 'INT_LIST', //
  'LABEL_LIST', 'BOOLEAN', 'LABEL_STRING_DICT', 'STRING_DICT',
  'STRING_LIST_DICT', 'OUTPUT', 'OUTPUT_LIST', 'LABEL_DICT_UNARY',
  'LABEL_LIST_DICT',
];

/// The extracts sorted by file label, so output does not depend on arguments.
List<ModuleDoc> _sorted(List<ModuleDoc> modules) =>
    [...modules]..sort((a, b) => a.file.compareTo(b.file));

/// One `file<TAB>kind<TAB>name` line per rule-like symbol of each extract.
///
/// The kind is `rule`, `test_rule`, `executable_rule`, `macro`, `aspect`,
/// `repository_rule` or `module_extension`.
String emitRuleKinds(List<ModuleDoc> modules) {
  final lines = <String>[];
  for (final ModuleDoc m in _sorted(modules)) {
    final List<String> rows = [
      for (final c in m.callables) '${m.file}\t${c.kind}\t${c.name}',
    ];
    lines.addAll(rows..sort());
  }
  return lines.isEmpty ? '' : '${lines.join('\n')}\n';
}

/// The public API surface of each extract, as indented text.
///
/// Each symbol is `symbol <kind> <name>`; its attributes list the type,
/// `mandatory`, `natively_defined` and default, provider fields are listed by
/// name, and function parameters carry their role and default.
String emitApi(List<ModuleDoc> modules) {
  final out = StringBuffer();
  for (final ModuleDoc m in _sorted(modules)) {
    out.writeln('file ${m.file}');
    for (final CallableDoc c in [
      ...m.callables,
    ]..sort((a, b) => a.name.compareTo(b.name))) {
      _callable(out, c, '  ');
    }
    for (final ProviderDoc p in [
      ...m.providers,
    ]..sort((a, b) => a.name.compareTo(b.name))) {
      out.writeln('  symbol provider ${p.name}');
      for (final FieldDoc f in p.fields) {
        out.writeln('    field ${f.name}');
      }
    }
    for (final FuncDoc f in [
      ...m.functions,
    ]..sort((a, b) => a.name.compareTo(b.name))) {
      out.writeln('  symbol function ${f.name}');
      for (final ParamDoc p in f.params) {
        out.writeln(
          '    param ${p.name} role=${p.roleName} mandatory=${p.mandatory} default=${p.defaultValue}',
        );
      }
    }
  }
  return out.toString();
}

void _callable(StringBuffer out, CallableDoc c, String indent) {
  out.writeln(
    '$indent'
    'symbol ${c.kind} ${c.name}',
  );
  for (final AttrDoc a in c.attrs) {
    final String type = a.type < _attrTypes.length
        ? _attrTypes[a.type]
        : 'UNKNOWN';
    out.writeln(
      '$indent  attr ${a.name} type=$type mandatory=${a.mandatory} '
      'natively_defined=${a.nativelyDefined} default=${a.defaultValue}',
    );
  }
  for (final CallableDoc child in c.children) {
    _callable(out, child, '$indent  ');
  }
}
