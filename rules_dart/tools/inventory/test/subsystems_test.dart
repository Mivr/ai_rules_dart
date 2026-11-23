import 'package:inventory/glob.dart';
import 'package:inventory/source_tree.dart';
import 'package:inventory/subsystems.dart';
import 'package:test/test.dart';

final SubsystemTable _table = SubsystemTable.parse('''
{
  "source_extensions": ["dart", "bzl"],
  "test_paths": ["**/tests/**", "**/*_test.dart"],
  "subsystems": [
    {"name": "yaml", "paths": ["m/pub/**/yaml_*.bzl"]},
    {"name": "tool", "paths": ["m/tool"]}
  ]
}
''');

void main() {
  group('Glob', () {
    test('star stays inside a segment, double star crosses them', () {
      expect(Glob('a/*.bzl').matches('a/x.bzl'), isTrue);
      expect(Glob('a/*.bzl').matches('a/b/x.bzl'), isFalse);
      expect(Glob('**/tests/**').matches('m/dart/tests/x/y.bzl'), isTrue);
      expect(Glob('**/tests/**').matches('tests/y.bzl'), isTrue);
      expect(Glob('**/*_test.dart').matches('a/b_test.dart'), isTrue);
    });

    test('a directory glob matches the files below it', () {
      expect(Glob('m/tool').matches('m/tool/lib/x.dart'), isTrue);
      expect(Glob('m/tool').matches('m/tools/x.dart'), isFalse);
    });
  });

  group('SubsystemTable', () {
    test('sorts a file into production or test by path', () {
      expect(_table.isProductionSource('m/tool/lib/x.dart'), isTrue);
      expect(_table.isProductionSource('m/tool/lib/x_test.dart'), isFalse);
      expect(_table.isProductionSource('m/tests/x.bzl'), isFalse);
      expect(_table.isSource('m/tool/README.md'), isFalse);
      expect(_table.isSource('m/tool/Makefile'), isFalse);
    });

    test(
      'the first matching subsystem owns a file, the rest go per module',
      () {
        expect(_table.subsystemOf('m/pub/yaml_x.bzl'), 'yaml');
        expect(_table.subsystemOf('m/pub/tests/yaml_x.bzl'), 'yaml');
        expect(_table.subsystemOf('m/tool/a.dart'), 'tool');
        expect(_table.subsystemOf('rules_dart/dart/a.bzl'), 'other:rules_dart');
        expect(_table.subsystemOf('top.bzl'), 'other:repo');
      },
    );

    test('a malformed table is refused', () {
      expect(() => SubsystemTable.parse('[]'), throwsFormatException);
      expect(
        () => SubsystemTable.parse('{"subsystems": 1}'),
        throwsFormatException,
      );
    });
  });

  group('countSubsystems', () {
    final tree = SourceTree.inMemory({
      'm/pub/yaml_a.bzl': 'a\nb\nc\n',
      'm/pub/tests/yaml_a_test.bzl': 'a\nb\n',
      'm/tool/x.dart': 'a\nb',
      'm/tool/x_test.dart': 'a\n',
      'm/tool/notes.md': 'ignored\nignored\n',
      'rules_flutter/f.bzl': 'a\n',
    });

    test('counts production and test lines, and files, per subsystem', () {
      final Map<String, Count> counts = countSubsystems(tree, _table);
      expect(counts['yaml'], (production: 3, test: 2, files: 2));
      expect(counts['tool'], (production: 2, test: 1, files: 2));
      expect(counts['other:rules_flutter'], (production: 1, test: 0, files: 1));
      expect(counts.keys.toList(), ['yaml', 'tool', 'other:rules_flutter']);
    });

    test('a ledger row holds the totals and every subsystem', () {
      final Map<String, Object?> row = ledgerRow(
        counts: countSubsystems(tree, _table),
        date: 'D',
        commit: 'abc',
        branch: 'b',
      );
      expect(row['total'], {'production': 6, 'test': 3, 'files': 5});
      expect((row['subsystems']! as Map<String, Object?>).keys, [
        'yaml',
        'tool',
        'other:rules_flutter',
      ]);
      expect(row['commit'], 'abc');
    });
  });

  test('countLines counts an unterminated last line', () {
    expect(countLines(''), 0);
    expect(countLines('a\n'), 1);
    expect(countLines('a\nb'), 2);
  });
}
