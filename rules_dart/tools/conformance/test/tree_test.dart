import 'dart:io';

import 'package:conformance/compare.dart';
import 'package:conformance/normalise.dart';
import 'package:conformance/tree.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('tree_test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  Directory build(String name, Map<String, String> files) {
    final dir = Directory('${tmp.path}/$name');
    for (final MapEntry(:key, :value) in files.entries) {
      File('${dir.path}/$key')
        ..createSync(recursive: true)
        ..writeAsStringSync(value);
    }
    return dir;
  }

  const base = {
    'index.html': '<html></html>',
    'flutter_bootstrap.js':
        '_flutter.loader.load({serviceWorkerVersion: "123"});',
    'version.json': '{"app_name":"a","version":"1.0.0"}',
    'main.dart.js': 'main(){}',
    'assets/fonts/a.otf': 'font',
    'canvaskit/canvaskit.wasm': 'wasm',
    'icons/i.png': 'png',
  };

  test('categories follow what the file is for', () {
    final Items items = webItems(build('s', base), Applied());
    expect(items.keys.toList()..sort(), [
      'asset:assets/fonts/a.otf',
      'bootstrap:flutter_bootstrap.js',
      'bootstrap:index.html',
      'bootstrap:version.json',
      'compiled:main.dart.js',
      'engine:canvaskit/canvaskit.wasm',
      'web:icons/i.png',
    ]);
  });

  test('JSON layout, the service worker version and the build id are '
      'normalised away', () {
    final applied = Applied();
    final Items s = webItems(
      build('s', {...base, '.last_build_id': 'abc'}),
      applied,
    );
    final Items r = webItems(
      build('r', {
        ...base,
        'flutter_bootstrap.js':
            '_flutter.loader.load({serviceWorkerVersion: "rules_9"});',
        'version.json': '{\n  "version": "1.0.0",\n  "app_name": "a"\n}\n',
      }),
      applied,
    );
    final diff = diffItems(s, r);
    expect(diff.differences, isEmpty);
    expect(diff.equal, base.length);
    expect(
      applied.counts.keys,
      containsAll(['json-format', 'last-build-id', 'service-worker-version']),
    );
  });

  test('one changed asset is exactly one difference', () {
    final Items s = webItems(build('s', base), Applied());
    final Items r = webItems(
      build('r', {...base, 'assets/fonts/a.otf': 'other font'}),
      Applied(),
    );
    final diff = diffItems(s, r);
    expect(
      [for (final d in diff.differences) d.item],
      ['asset:assets/fonts/a.otf'],
    );
    expect(diff.differences.single.detail, 'stock 4 B, rules 10 B');
  });

  test('linuxItems reads ELF files through the given export reader', () {
    final dir = build('l', {
      'data/flutter_assets/a.txt': 'a',
      'lib/x.txt': 'x',
    });
    File('${dir.path}/lib/libapp.so')
        .writeAsBytesSync([0x7f, 0x45, 0x4c, 0x46, 1]);
    final Items items = linuxItems(dir, Applied(), exports: (_) => ['f', 'g']);
    expect(items.keys.toList()..sort(), [
      'asset:data/flutter_assets/a.txt',
      'bundle:lib/x.txt',
      'elf:lib/libapp.so',
    ]);
    expect(items['elf:lib/libapp.so']!.note, '2 exported symbols');
  });

  test('canonicalJson sorts keys and refuses non-JSON', () {
    expect(
      canonicalJson('{"b":1, "a":[2, {"d":1,"c":2}]}'),
      '{"a":[2,{"c":2,"d":1}],"b":1}',
    );
    expect(canonicalJson('not json'), isNull);
  });
}
