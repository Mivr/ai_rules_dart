/// The subsystem table and the line counts taken against it.
library;

import 'dart:convert';

import 'package:inventory/glob.dart';
import 'package:inventory/source_tree.dart';

/// One subsystem: a name and the paths it owns.
class Subsystem {
  new _(this.name, this.globs);

  /// The subsystem's name in the ledger.
  final String name;

  /// The paths it owns; the first subsystem to match a file takes it.
  final List<Glob> globs;
}

/// What a row of the ledger holds for one subsystem.
typedef Count = ({int production, int test, int files});

/// The checked-in table: which files are source, which are tests, and which
/// subsystem owns each source file.
class SubsystemTable {
  /// Parses `subsystems.json`.
  factory parse(String json) {
    final Object? decoded = jsonDecode(json);
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('the subsystem table must be a JSON object');
    }
    List<String> strings(Object? value, String what) {
      if (value is! List<Object?> || value.any((v) => v is! String)) {
        throw FormatException('"$what" must be a list of strings');
      }
      return value.cast<String>();
    }

    final Object? subsystems = decoded['subsystems'];
    if (subsystems is! List<Object?>) {
      throw const FormatException('"subsystems" must be a list');
    }
    return SubsystemTable._(
      sourceExtensions: strings(
        decoded['source_extensions'],
        'source_extensions',
      ).toSet(),
      testPaths: [
        for (final p in strings(decoded['test_paths'], 'test_paths')) Glob(p),
      ],
      subsystems: [
        for (final Object? s in subsystems)
          if (s is Map<String, Object?>)
            Subsystem._(s['name']! as String, [
              for (final p in strings(s['paths'], 'paths')) Glob(p),
            ]),
      ],
    );
  }

  new _({
    required this.sourceExtensions,
    required this.testPaths,
    required this.subsystems,
  });

  /// File extensions that count as source, without the dot.
  final Set<String> sourceExtensions;

  /// Paths that are tests, fixtures or test support.
  final List<Glob> testPaths;

  /// The named subsystems, in matching order.
  final List<Subsystem> subsystems;

  /// Whether [path] is a source file by extension.
  bool isSource(String path) {
    final String name = path.substring(path.lastIndexOf('/') + 1);
    final int dot = name.lastIndexOf('.');
    return dot > 0 && sourceExtensions.contains(name.substring(dot + 1));
  }

  /// Whether [path] is a test, a fixture or test support.
  bool isTest(String path) => matchesAny(testPaths, path);

  /// Whether [path] is a source file that is not a test.
  bool isProductionSource(String path) => isSource(path) && !isTest(path);

  /// The subsystem that owns [path], or `other:<module>` for the rest.
  String subsystemOf(String path) {
    for (final Subsystem s in subsystems) {
      if (matchesAny(s.globs, path)) return s.name;
    }
    final String top = path.split('/').first;
    return 'other:${top.startsWith('rules_') ? top : 'repo'}';
  }
}

/// Production and test lines per subsystem, in table order and then the
/// `other:` rows by name. A subsystem with no file still has a row.
Map<String, Count> countSubsystems(SourceTree tree, SubsystemTable table) {
  final totals = <String, List<int>>{
    for (final Subsystem s in table.subsystems) s.name: [0, 0, 0],
  };
  for (final String path in tree.paths.where(table.isSource)) {
    final List<int> total = totals.putIfAbsent(
      table.subsystemOf(path),
      () => [0, 0, 0],
    );
    total[table.isTest(path) ? 1 : 0] += countLines(tree.read(path));
    total[2]++;
  }
  final List<String> others =
      totals.keys.where((k) => k.startsWith('other:')).toList()..sort();
  return {
    for (final String name in [
      ...totals.keys.where((k) => !k.startsWith('other:')),
      ...others,
    ])
      name: (
        production: totals[name]![0],
        test: totals[name]![1],
        files: totals[name]![2],
      ),
  };
}

/// One JSON-lines ledger row.
Map<String, Object?> ledgerRow({
  required Map<String, Count> counts,
  required String date,
  required String? commit,
  required String? branch,
}) {
  var production = 0;
  var test = 0;
  var files = 0;
  for (final Count c in counts.values) {
    production += c.production;
    test += c.test;
    files += c.files;
  }
  return {
    'date': date,
    'commit': commit,
    'branch': branch,
    'total': {'production': production, 'test': test, 'files': files},
    'subsystems': {
      for (final MapEntry<String, Count> e in counts.entries)
        e.key: {
          'production': e.value.production,
          'test': e.value.test,
          'files': e.value.files,
        },
    },
  };
}
