/// The documentation rules applied to every extract and its load closure.
///
/// Each violation is a [Gap] printed as `file:symbol[.attr]: rule`. Rules:
///
/// * `module-docstring`: a `.bzl` file without a module docstring.
/// * `missing-doc`: a rule, macro, aspect, repository rule, module
///   extension, tag class, provider or function without a docstring.
/// * `missing-attr-doc`: a non-native attribute without a docstring.
/// * `missing-field-doc`: a provider field without a docstring.
/// * `missing-param-doc`: a function parameter (`*args` and `**kwargs`
///   included) without a docstring entry.
/// * `missing-returns`: a function that returns a value but has no
///   `Returns:` section.
/// * `too-short`: a doc under 3 words or 15 characters.
/// * `restates-name`: a doc that only repeats the symbol's name.
/// * `forbidden-phrase`: a doc holding `TODO`, `TBD`, `FIXME`, `XXX` or
///   `See above`.
/// * `shared-doc`: one doc string on more than 3 distinct attributes that is
///   not on the approved shared-phrasings list.
/// * `stale-shared-phrasing`: an approved shared phrasing that no group of
///   more than 3 attributes uses any more; the list may only shrink.
/// * `source-unavailable`: a `.bzl` file of the load closure that the check
///   could not read, so its checks cannot run.
/// * `default-undocumented` (warning): a public optional attribute whose doc
///   does not mention its default.
library;

import 'package:doc_check/quality.dart';
import 'package:doc_check/stardoc_model.dart';
import 'package:doc_check/starlark_source.dart';

/// The `AttributeType.NAME` enum number: the implicit `name` attribute, whose
/// text Bazel supplies and so is no authored phrasing to compare.
const int _nameType = 1;

/// One documentation violation.
class Gap {
  /// Creates a gap.
  const new({
    required this.file,
    required this.symbol,
    required this.rule,
    this.warning = false,
  });

  /// The `.bzl` file label that defines the symbol.
  final String file;

  /// `symbol` or `symbol.attr`; the allowlist key.
  final String symbol;

  /// The rule identifier.
  final String rule;

  /// Whether the gap is advisory and does not fail the check.
  final bool warning;

  /// The report line `file:symbol[.attr]: rule`.
  String get line => '$file:$symbol: $rule';
}

/// The `.bzl` sources of a load closure, by label, resolved on demand.
typedef SourceReader = String? Function(String label);

/// Checks [modules] and the load closure they reach through [read].
///
/// [sharedPhrasings] is the approved list of docs that may sit on more than 3
/// attributes. The result is sorted and free of duplicates.
List<Gap> checkDocs(
  List<ModuleDoc> modules,
  SourceReader read,
  Set<String> sharedPhrasings,
) {
  final gaps = <Gap>[];
  final attributeDocs = <String, List<String>>{};
  final seen = <String>{};
  for (final module in modules) {
    if (module.doc.trim().isEmpty) {
      gaps.add(
        Gap(file: module.file, symbol: '(module)', rule: 'module-docstring'),
      );
    }
    for (final SymbolDoc symbol in module.symbols) {
      if (!seen.add(_identity(module, 'symbol', symbol.name, symbol.origin))) {
        continue;
      }
      _checkSymbol(_fileOf(module, symbol.origin), symbol, gaps, attributeDocs);
    }
    for (final FunctionDoc function in module.functions) {
      if (seen.add(
        _identity(module, 'function', function.name, function.origin),
      )) {
        _checkFunction(_fileOf(module, function.origin), function, gaps);
      }
    }
    for (final ProviderDoc provider in module.providers) {
      if (seen.add(
        _identity(module, 'provider', provider.name, provider.origin),
      )) {
        _checkProvider(_fileOf(module, provider.origin), provider, gaps);
      }
    }
  }
  gaps.addAll(_sharedGaps(attributeDocs, sharedPhrasings));
  gaps.addAll(_checkClosure(modules, read));
  return _sorted(gaps);
}

String _fileOf(ModuleDoc module, OriginKey? origin) =>
    origin != null && origin.file.isNotEmpty ? origin.file : module.file;

String _identity(
  ModuleDoc module,
  String kind,
  String name,
  OriginKey? origin,
) =>
    '$kind|${_fileOf(module, origin)}|${origin?.name.isNotEmpty == true ? origin!.name : name}';

List<Gap> _sorted(List<Gap> gaps) {
  final byLine = <String, Gap>{
    for (final gap in gaps)
      '${gap.file}\u0000${gap.symbol}\u0000${gap.rule}': gap,
  };
  return [for (final key in byLine.keys.toList()..sort()) byLine[key]!];
}

void _checkText(
  String file,
  String symbol,
  String doc,
  String name,
  List<Gap> gaps,
) {
  final String? rule = doc.trim().isEmpty ? null : docQualityRule(doc, name);
  if (rule != null) gaps.add(Gap(file: file, symbol: symbol, rule: rule));
}

void _checkSymbol(
  String file,
  SymbolDoc symbol,
  List<Gap> gaps,
  Map<String, List<String>> attributeDocs,
) {
  if (symbol.doc.trim().isEmpty) {
    gaps.add(Gap(file: file, symbol: symbol.name, rule: 'missing-doc'));
  } else {
    _checkText(file, symbol.name, symbol.doc, symbol.name, gaps);
  }
  final bool isPublic = !symbol.name.startsWith('_');
  for (final AttributeDoc attribute in symbol.attributes) {
    if (attribute.nativelyDefined) continue;
    final key = '${symbol.name}.${attribute.name}';
    _checkAttribute(file, key, attribute, isPublic, gaps);
    if (attribute.doc.trim().isNotEmpty && attribute.type != _nameType) {
      attributeDocs
          .putIfAbsent(attribute.doc.trim(), () => [])
          .add('$file\n$key');
    }
  }
  for (final SymbolDoc child in symbol.children) {
    _checkSymbol(file, _qualified(symbol, child), gaps, attributeDocs);
  }
}

SymbolDoc _qualified(SymbolDoc parent, SymbolDoc child) => SymbolDoc(
  kind: child.kind,
  name: '${parent.name}.${child.name}',
  doc: child.doc,
  attributes: child.attributes,
  origin: null,
);

void _checkAttribute(
  String file,
  String key,
  AttributeDoc attribute,
  bool isPublic,
  List<Gap> gaps,
) {
  if (attribute.doc.trim().isEmpty) {
    gaps.add(Gap(file: file, symbol: key, rule: 'missing-attr-doc'));
    return;
  }
  _checkText(file, key, attribute.doc, attribute.name, gaps);
  final bool isPublicAttribute = isPublic && !attribute.name.startsWith('_');
  if (isPublicAttribute &&
      !attribute.mandatory &&
      !RegExp('default', caseSensitive: false).hasMatch(attribute.doc)) {
    gaps.add(
      Gap(file: file, symbol: key, rule: 'default-undocumented', warning: true),
    );
  }
}

void _checkProvider(String file, ProviderDoc provider, List<Gap> gaps) {
  if (provider.doc.trim().isEmpty) {
    gaps.add(Gap(file: file, symbol: provider.name, rule: 'missing-doc'));
  } else {
    _checkText(file, provider.name, provider.doc, provider.name, gaps);
  }
  provider.fields.forEach((name, doc) {
    final key = '${provider.name}.$name';
    if (doc.trim().isEmpty) {
      gaps.add(Gap(file: file, symbol: key, rule: 'missing-field-doc'));
    } else {
      _checkText(file, key, doc, name, gaps);
    }
  });
}

void _checkFunction(String file, FunctionDoc function, List<Gap> gaps) {
  if (function.doc.trim().isEmpty) {
    gaps.add(Gap(file: file, symbol: function.name, rule: 'missing-doc'));
  } else {
    _checkText(file, function.name, function.doc, function.name, gaps);
  }
  for (final ParamDoc param in function.params) {
    final key = '${function.name}.${param.name}';
    if (param.doc.trim().isEmpty) {
      gaps.add(Gap(file: file, symbol: key, rule: 'missing-param-doc'));
    } else {
      _checkText(file, key, param.doc, param.name, gaps);
    }
  }
}

List<Gap> _sharedGaps(Map<String, List<String>> docs, Set<String> approved) {
  final gaps = <Gap>[];
  final used = <String>{};
  docs.forEach((doc, owners) {
    final Set<String> distinct = owners.toSet();
    if (distinct.length <= 3) return;
    if (approved.contains(doc)) {
      used.add(doc);
      return;
    }
    for (final owner in distinct) {
      final List<String> parts = owner.split('\n');
      gaps.add(Gap(file: parts[0], symbol: parts[1], rule: 'shared-doc'));
    }
  });
  for (final String phrasing in approved.difference(used)) {
    gaps.add(
      Gap(
        file: '(shared-phrasings)',
        symbol: phrasing.length > 60 ? phrasing.substring(0, 60) : phrasing,
        rule: 'stale-shared-phrasing',
      ),
    );
  }
  return gaps;
}

/// Walks the `load()` closure of the extracts and checks each file's source.
///
/// The functions the extracts list are matched to their source defs to learn
/// whether they return a value; every other top-level def, private or not, is
/// checked from source alone.
List<Gap> _checkClosure(List<ModuleDoc> modules, SourceReader read) {
  final result = <Gap>[];
  final List<String> queue = [for (final module in modules) module.file];
  final visited = <String>{};
  while (queue.isNotEmpty) {
    final String label = queue.removeLast();
    if (!visited.add(label)) continue;
    final String? text = read(label);
    if (text == null) {
      result.add(
        Gap(file: label, symbol: '(module)', rule: 'source-unavailable'),
      );
      continue;
    }
    final source = SourceFile.parse(label, text);
    queue.addAll(source.loads);
    if (!source.hasModuleDoc) {
      result.add(
        Gap(file: label, symbol: '(module)', rule: 'module-docstring'),
      );
    }
    for (final SourceDef def in source.defs) {
      _checkDef(label, def, result);
    }
  }
  return result;
}

/// Public defs are checked in full. A private def is checked only when its
/// docstring opted into the structured form with an `Args:` or `Returns:`
/// section, which must then be complete; a prose-only private helper, or one
/// with no docstring at all, is exempt.
void _checkDef(String file, SourceDef def, List<Gap> gaps) {
  if (def.function.name.startsWith('_') && !def.structured) return;
  _checkFunction(file, def.function, gaps);
  if (def.returnsValue && def.function.returnDoc.isEmpty) {
    gaps.add(
      Gap(file: file, symbol: def.function.name, rule: 'missing-returns'),
    );
  }
}
