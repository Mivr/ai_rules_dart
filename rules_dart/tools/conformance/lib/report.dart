/// Reads both sides of the layout, compares each project and kind, and
/// prints and records the scores.
library;

import 'dart:io';

import 'package:conformance/apk.dart';
import 'package:conformance/by_design.dart';
import 'package:conformance/compare.dart';
import 'package:conformance/items.dart';
import 'package:conformance/layout.dart';
import 'package:conformance/normalise.dart';
import 'package:conformance/records.dart';
import 'package:conformance/tree.dart';

/// Compares one project and kind as the layout under [work] holds it.
KindResult compareKind({
  required String work,
  required String project,
  required Kind kind,
  required List<ByDesignEntry> byDesign,
  required Set<ByDesignEntry> used,
  AndroidTools? tools,
}) {
  final stockDir = KindDir(work, Side.stock, project, kind);
  final rulesDir = KindDir(work, Side.rules, project, kind);
  final Status? stock = stockDir.readStatus();
  final Status? rules = rulesDir.readStatus();
  String? missing;
  if (stock == null || rules == null) {
    missing =
        'not run on ${stock == null ? 'the stock side' : 'the rules side'}';
  } else if (!stock.built || !rules.built) {
    missing = [
      if (!stock.built) 'stock: ${stock.reason}',
      if (!rules.built) 'rules: ${rules.reason}',
    ].join('; ');
  } else if (kind == Kind.apk && tools == null) {
    missing =
        'no Android tools (set JAVA_HOME, ANDROID_HOME, ANDROID_NDK_HOME)';
  }
  if (missing != null) {
    return KindResult(
      project: project,
      kind: kind,
      stock: stock,
      rules: rules,
      notCompared: missing,
    );
  }
  final applied = Applied();
  Items read(KindDir d, Side side) {
    final roots = _roots('$work/${side.name}/$project/src');
    switch (kind) {
      case Kind.tests:
        final records = [
          for (final t in readJson(d.tests) as List)
            TestRecord.fromJson(t as Map<String, Object?>),
        ];
        return testItems(records, roots, applied);
      case Kind.analysis:
        final json = readJson(d.diagnostics) as Map<String, Object?>;
        return analysisItems(
          [for (final f in json['files'] as List) f as String],
          [
            for (final x in json['diagnostics'] as List)
              Diagnostic.fromJson(x as Map<String, Object?>),
          ],
          roots,
          applied,
        );
      case Kind.exe:
        return exeItems([
          for (final r in readJson(d.runs) as List)
            ExeRun.fromJson(r as Map<String, Object?>),
        ]);
      case Kind.web:
        return webItems(d.tree, applied);
      case Kind.linux:
        return linuxItems(
          d.tree,
          applied,
          exports: (f) => tools == null ? null : readElfExports(tools.nm, f),
        );
      case Kind.apk:
        return apkItems(
          d.apk,
          tools!,
          Directory('$work/.scratch/${side.name}-$project'),
          applied,
        );
    }
  }

  final Items s = read(stockDir, Side.stock);
  final Items r = read(rulesDir, Side.rules);
  final diff = diffItems(s, r);
  used.addAll(applyByDesign(project, kind, diff.differences, byDesign));
  return KindResult(
    project: project,
    kind: kind,
    stock: stock,
    rules: rules,
    compared: diff.compared,
    equal: diff.equal,
    differences: diff.differences,
    applied: applied.counts,
  );
}

List<String> _roots(String copy) {
  final roots = [copy];
  try {
    final String real = Directory(copy).resolveSymbolicLinksSync();
    if (real != copy) roots.add(real);
  } on FileSystemException {
    // The copy is gone; recorded paths still start with its name.
  }
  return roots;
}

String _yesNo(Status? s) => s == null ? '-' : (s.built ? 'yes' : 'no');

/// The score table, one row per project and kind.
String scoreTable(List<KindResult> results) {
  final rows = <List<String>>[
    [
      'project',
      'kind',
      'stock',
      'rules',
      'compared',
      'equal',
      'by design',
      'differ',
      'parity',
    ],
    for (final r in results)
      [
        r.project,
        r.kind.name,
        _yesNo(r.stock),
        _yesNo(r.rules),
        '${r.compared}',
        '${r.equal}',
        '${r.byDesign}',
        '${r.counted}',
        r.score == null ? 'n/a' : '${(r.score! * 100).toStringAsFixed(1)}%',
      ],
  ];
  final widths = [
    for (var c = 0; c < rows.first.length; c++)
      rows.map((row) => row[c].length).reduce((a, b) => a > b ? a : b),
  ];
  return [
    for (final row in rows)
      [for (var c = 0; c < row.length; c++) row[c].padRight(widths[c])]
          .join('  ')
          .trimRight(),
  ].join('\n');
}

/// The full text report: the table, then per project and kind what was not
/// compared and the differences grouped by cause, with up to [examples]
/// items each.
String textReport(
  List<KindResult> results,
  List<ByDesignEntry> stale, {
  int examples = 5,
}) {
  final out = StringBuffer()
    ..writeln(scoreTable(results))
    ..writeln();
  for (final r in results) {
    out.writeln('## ${r.project} ${r.kind.name}');
    if (r.notCompared != null) out.writeln('  not compared: ${r.notCompared}');
    for (final (side, s) in [('stock', r.stock), ('rules', r.rules)]) {
      if (s != null && s.built && s.reason != null) {
        out.writeln('  $side partial: ${s.reason}');
      }
      for (final n in s?.notes ?? const <String>[]) {
        out.writeln('  $side: $n');
      }
    }
    for (final g in r.groups()) {
      out.writeln('  ${g.items.length} x ${g.cause}');
      for (final d in g.items.take(examples)) {
        out.writeln(
          '      ${d.item}${d.detail.isEmpty ? '' : '  (${d.detail})'}',
        );
      }
      if (g.items.length > examples) {
        out.writeln('      ... ${g.items.length - examples} more');
      }
    }
    if (r.applied.isNotEmpty) {
      final String names = (r.applied.keys.toList()..sort())
          .map((k) => '$k x${r.applied[k]}')
          .join(', ');
      out.writeln('  normalised: $names');
    }
  }
  if (stale.isNotEmpty) {
    out.writeln();
    out.writeln('By-design entries that matched nothing (remove them):');
    for (final e in stale) {
      out.writeln('  ${e.display}');
    }
  }
  return out.toString();
}

/// The by-design entries for the projects and kinds of [results] that
/// matched no difference.
List<ByDesignEntry> staleEntries(
  List<ByDesignEntry> list,
  Set<ByDesignEntry> used,
  List<KindResult> results,
) => [
  for (final e in list)
    if (!used.contains(e) &&
        results.any(
          (r) =>
              r.notCompared == null &&
              e.kinds.contains(r.kind) &&
              e.projects.any((p) => p == '*' || p == r.project),
        ))
      e,
];

/// One ledger row per project and kind.
List<Map<String, Object?>> ledgerRows(
  List<KindResult> results, {
  required String date,
  required String commit,
  required String? next,
}) => [
  for (final r in results)
    {
      'date': date,
      'commit': commit,
      'next': next,
      'project': r.project,
      'kind': r.kind.name,
      'built_stock': r.stock?.built ?? false,
      'built_rules': r.rules?.built ?? false,
      'compared': r.compared,
      'equal': r.equal,
      'by_design': r.byDesign,
      'differ': r.counted,
      'parity': r.score == null
          ? null
          : double.parse(r.score!.toStringAsFixed(4)),
      if (r.notCompared != null) 'not_compared': r.notCompared,
      'causes': {for (final g in r.groups()) g.cause: g.items.length},
    },
];

/// The whole result as JSON, for `report.json` beside the layout.
Map<String, Object?> jsonReport(List<KindResult> results) => {
  'normalisers': [
    for (final n in allNormalisers)
      {
        'name': n.name,
        'kinds': [for (final k in n.kinds) k.name],
        'reason': n.reason,
      },
  ],
  'results': [
    for (final r in results)
      {
        'project': r.project,
        'kind': r.kind.name,
        'stock': r.stock?.toJson(),
        'rules': r.rules?.toJson(),
        'compared': r.compared,
        'equal': r.equal,
        'by_design': r.byDesign,
        'differ': r.counted,
        if (r.notCompared != null) 'not_compared': r.notCompared,
        'applied': r.applied,
        'differences': [for (final d in r.differences) d.toJson()],
      },
  ],
};
