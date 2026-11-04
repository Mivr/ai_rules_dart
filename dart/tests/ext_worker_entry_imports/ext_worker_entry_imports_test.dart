import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

/// Guards the import style of `dart/ext/lib/worker_entry.dart`.
void main(List<String> args) {
  late final String source;
  setUpAll(() {
    final String path = Runfiles.create().rlocation(args.single);
    source = File(path).readAsStringSync();
  });

  test('imports builder_shim through its package URI', () {
    expect(
      source,
      contains("import 'package:rules_dart_ext/builder_shim.dart';"),
    );
  });

  test('every import directive uses a dart: or package: URI', () {
    final directive = RegExp(
      r'''^import\s+'([^']*)'|^import\s+"([^"]*)"''',
      multiLine: true,
    );
    final uris = <String>[
      for (final RegExpMatch m in directive.allMatches(source))
        (m.group(1) ?? m.group(2))!,
    ];
    expect(uris, isNotEmpty);
    for (final uri in uris) {
      expect(
        uri.startsWith('dart:') || uri.startsWith('package:'),
        isTrue,
        reason: 'relative import: $uri',
      );
    }
  });
}
