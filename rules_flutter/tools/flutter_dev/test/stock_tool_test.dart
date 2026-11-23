import 'dart:convert';
import 'dart:io';

import 'package:flutter_dev/src/options.dart';
import 'package:flutter_dev/src/stock_tool.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('stock_tool_test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  /// A directory shaped like a Flutter SDK, with [version] in its cache file.
  String sdk(String name, {String? version}) {
    final root = '${tmp.path}/$name';
    File('$root/bin/flutter').createSync(recursive: true);
    if (version != null) {
      File('$root/bin/cache/flutter.version.json')
        ..createSync(recursive: true)
        ..writeAsStringSync(
          jsonEncode(<String, Object?>{
            'flutterVersion': version,
            'frameworkVersion': version,
          }),
        );
    }
    return root;
  }

  test('found from the flag (executable or root), FLUTTER_ROOT, then PATH', () {
    final String a = sdk('a', version: '3.47.7');
    final String b = sdk('b');
    final String c = sdk('c');
    expect(
      StockTool.find(
        flag: '$a/bin/flutter',
        self: '/x',
        environment: const <String, String>{},
      ).root,
      a,
    );
    expect(
      StockTool.find(
        flag: a,
        self: '/x',
        environment: const <String, String>{},
      ).root,
      a,
    );
    expect(
      StockTool.find(
        self: '/x',
        environment: <String, String>{'FLUTTER_ROOT': b, 'PATH': '$c/bin'},
      ).root,
      b,
    );
    expect(
      StockTool.find(
        self: '/x',
        environment: <String, String>{'PATH': '/nowhere:$c/bin'},
      ).root,
      c,
    );
  });

  test('a missing tool is an error that says what to do', () {
    expect(
      () => StockTool.find(
        self: '/x',
        environment: const <String, String>{'PATH': '/nowhere'},
      ),
      throwsA(
        isA<UsageException>().having(
          (UsageException e) => e.message,
          'message',
          contains('--bazel-flutter'),
        ),
      ),
    );
  });

  test('version: equal passes, another fails unless allowed, an unknown wanted version passes', () {
    final tool = StockTool(sdk('a', version: '3.47.7'));
    expect(tool.version, '3.47.7');
    tool.checkVersion('3.47.7', allowMismatch: false);
    tool.checkVersion(null, allowMismatch: false);
    expect(
      () => tool.checkVersion('3.44.0', allowMismatch: false),
      throwsA(
        isA<UsageException>().having(
          (UsageException e) => e.message,
          'message',
          allOf(contains('3.47.7'), contains('3.44.0')),
        ),
      ),
    );
    tool.checkVersion('3.44.0', allowMismatch: true);
    expect(StockTool(sdk('b')).version, isNull);
  });

  test('an IDE shim names the real SDK, and a shim is never taken for one', () {
    final String real = sdk('real', version: '3.47.7');
    final String shim = sdk('shim');
    File('$shim/bin/$shimConfigName')
        .writeAsStringSync(jsonEncode(<String, Object?>{'flutterRoot': real}));
    expect(shimRoot('$shim/bin/flutter'), real);
    expect(shimRoot('$real/bin/flutter'), isNull);
    expect(
      StockTool.find(
        self: '$shim/bin/flutter',
        environment: const <String, String>{},
      ).root,
      real,
    );
    // Another process whose FLUTTER_ROOT or PATH leads to the shim still finds the real SDK.
    expect(
      StockTool.find(
        self: '/x',
        environment: <String, String>{
          'FLUTTER_ROOT': shim,
          'PATH': '$shim/bin:$real/bin',
        },
      ).root,
      real,
    );
  });
}
