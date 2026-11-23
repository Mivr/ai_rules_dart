/// The documentation rules applied to every extract.
library;

import 'stardoc.dart';

/// One finding: a rule broken by a symbol, or a non-blocking warning.
class Violation {
  /// Creates a finding for [symbol] (`name` or `name.attr`) in [file].
  const new({
    required this.file,
    required this.symbol,
    required this.rule,
    this.warning = false,
  });

  /// The label of the defining `.bzl` file.
  final String file;

  /// The symbol, `symbol` or `symbol.attr`: the allowlist key.
  final String symbol;

  /// The short name of the rule that was broken.
  final String rule;

  /// Whether the finding is advisory and never fails the check.
  final bool warning;

  /// The report line: `file:symbol[.attr]: rule`.
  String format() => '$file:$symbol: $rule';
}

/// Whether the function [name] defined in [file] returns a value.
typedef ReturnsValue = bool Function(String file, String name);

/// The `AttributeType` enum number of `NAME`.
const _nameType = 1;

/// Words that carry no information when a doc only restates a name.
const _fillerWords = {
  'the', 'a', 'an', 'of', 'for', 'this', 'to', 'is', 'rule', 'attribute', //
  'macro', 'function', 'provider', 'field', 'parameter', 'param', 'aspect',
};

final _placeholder = RegExp(
  r'\b(TODO|TBD|FIXME|XXX)\b|see above',
  caseSensitive: false,
);

/// The lower-case alphanumeric words of [text], camelCase split apart.
List<String> _words(String text) => RegExp('[A-Za-z0-9]+')
    .allMatches(
      text.replaceAllMapped(
        RegExp('([a-z])([A-Z])'),
        (m) => '${m[1]} ${m[2]}',
      ),
    )
    .map((m) => m[0]!.toLowerCase())
    .toList();

/// Collects findings, de-duplicated by file, symbol and rule.
class _Findings {
  final Map<String, Violation> _seen = {};

  /// Attribute docs seen so far: normalised doc -> keys of the attributes.
  final Map<String, Map<String, String>> attrDocs = {};

  void add(String file, String symbol, String rule, {bool warning = false}) {
    _seen.putIfAbsent(
      '$file|$symbol|$rule',
      () => Violation(file: file, symbol: symbol, rule: rule, warning: warning),
    );
  }

  List<Violation> get all => _seen.values.toList();
}

/// What [DocChecker.check] found.
class CheckReport {
  /// Creates a report.
  const new({required this.findings, required this.docUsage});

  /// Every finding, blocking and advisory.
  final List<Violation> findings;

  /// How many distinct attributes carry each normalised attribute doc.
  final Map<String, int> docUsage;
}

/// Applies the documentation rules to a set of extracts.
class DocChecker {
  /// Creates a checker; [sharedPhrasings] may repeat on more than 3 attributes.
  new({required this.returnsValue, this.sharedPhrasings = const {}});

  /// Tells whether a function returns a value, which needs a `Returns:` doc.
  final ReturnsValue returnsValue;

  /// Normalised phrasings approved to appear on many attributes.
  final Set<String> sharedPhrasings;

  /// The shared-phrasing key of [doc]: whitespace collapsed.
  static String normalise(String doc) =>
      doc.trim().replaceAll(RegExp(r'\s+'), ' ');

  /// Every finding for [modules], blocking and advisory.
  CheckReport check(List<ModuleDoc> modules) {
    final out = _Findings();
    for (final m in modules) {
      _module(out, m);
    }
    _duplicates(out);
    return CheckReport(
      findings: out.all,
      docUsage: {for (final e in out.attrDocs.entries) e.key: e.value.length},
    );
  }

  void _module(_Findings out, ModuleDoc m) {
    _text(
      out,
      m.file,
      '<module>',
      m.doc,
      'module-docstring-missing',
      name: m.file.split(':').last.replaceAll('.bzl', ''),
    );
    for (final CallableDoc c in m.callables) {
      _callable(out, m.file, c, c.name);
    }
    for (final FuncDoc f in m.functions) {
      _function(out, f.file.isEmpty ? m.file : f.file, f);
    }
    for (final ProviderDoc p in m.providers) {
      _provider(out, p.file.isEmpty ? m.file : p.file, p);
    }
  }

  /// Checks [doc]: missing under [missing], else the quality rules.
  void _text(
    _Findings out,
    String file,
    String symbol,
    String doc,
    String missing, {
    required String name,
  }) {
    final String text = doc.trim();
    if (text.isEmpty) {
      out.add(file, symbol, missing);
      return;
    }
    if (text.split(RegExp(r'\s+')).length < 3 || text.length < 15) {
      out.add(file, symbol, 'doc-too-short');
    }
    if (_restates(text, name)) out.add(file, symbol, 'doc-restates-name');
    if (_placeholder.hasMatch(text)) out.add(file, symbol, 'doc-placeholder');
  }

  bool _restates(String doc, String name) {
    final Set<String> spoken = _words(name).toSet();
    final Iterable<String> rest = _words(doc)
        .where((w) => !_fillerWords.contains(w));
    return rest.every(spoken.contains);
  }

  void _callable(_Findings out, String module, CallableDoc c, String symbol) {
    final String file = c.file.isEmpty ? module : c.file;
    _text(out, file, symbol, c.doc, 'symbol-doc-missing', name: c.name);
    for (final AttrDoc a in c.attrs) {
      _attr(out, file, '$symbol.${a.name}', a);
    }
    for (final CallableDoc child in c.children) {
      _callable(out, module, child, '$symbol.${child.name}');
    }
  }

  void _attr(_Findings out, String file, String symbol, AttrDoc a) {
    if (a.nativelyDefined) return;
    _text(out, file, symbol, a.doc, 'attr-doc-missing', name: a.name);
    final String doc = normalise(a.doc);
    // Bazel writes the doc of every rule's implicit `name` (type NAME), so
    // it is one sentence on all of them and never counts as a duplicate.
    if (doc.isNotEmpty && a.type != _nameType) {
      out.attrDocs.putIfAbsent(doc, () => {})['$file|$symbol'] = symbol;
    }
    if (!a.mandatory && doc.isNotEmpty && !_mentionsDefault(a)) {
      out.add(file, symbol, 'attr-default-undocumented', warning: true);
    }
  }

  bool _mentionsDefault(AttrDoc a) {
    final String doc = a.doc.toLowerCase();
    final String literal = a.defaultValue.replaceAll('"', '').toLowerCase();
    return doc.contains('default') ||
        (literal.length > 1 && doc.contains(literal));
  }

  void _function(_Findings out, String file, FuncDoc f) {
    _text(out, file, f.name, f.doc, 'symbol-doc-missing', name: f.name);
    for (final ParamDoc p in f.params) {
      _text(
        out,
        file,
        '${f.name}.${p.name}',
        p.doc,
        'param-doc-missing',
        name: p.name,
      );
    }
    if (f.returnDoc.trim().isEmpty) {
      if (returnsValue(file, f.name)) out.add(file, f.name, 'returns-missing');
    } else {
      final symbol = '${f.name}.<returns>';
      _text(out, file, symbol, f.returnDoc, 'returns-missing', name: f.name);
    }
  }

  void _provider(_Findings out, String file, ProviderDoc p) {
    _text(out, file, p.name, p.doc, 'symbol-doc-missing', name: p.name);
    for (final FieldDoc f in p.fields) {
      _text(
        out,
        file,
        '${p.name}.${f.name}',
        f.doc,
        'provider-field-doc-missing',
        name: f.name,
      );
    }
  }

  /// A doc on more than 3 distinct attributes must be an approved phrasing.
  void _duplicates(_Findings out) {
    out.attrDocs.forEach((doc, users) {
      if (users.length <= 3 || sharedPhrasings.contains(doc)) return;
      for (final String key in users.keys) {
        final int cut = key.indexOf('|');
        out.add(key.substring(0, cut), users[key]!, 'doc-duplicate');
      }
    });
  }
}
