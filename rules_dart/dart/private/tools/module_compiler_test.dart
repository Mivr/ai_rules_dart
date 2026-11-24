// Behaviour tests of the module compiler: what it writes for a set of small
// packages, compared byte for byte and by running the linked program. Nothing
// here reads a kernel: the files are compared whole, concatenated in link
// order and run by the SDK's VM.
//
// The tool under test is the one module actions run: the exec SDK's module
// compiler, built from the pinned sources of that SDK's tag (see
// `//dart/private:module_compiler_tools.bzl`).

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

import 'worker_test_encode.dart';

late String _tool;
late String _dartaotruntime;
late String _platform;
late String _dart;
late Directory _ws;

void _write(String path, String text) => File('${_ws.path}/$path')
  ..parent.createSync(recursive: true)
  ..writeAsStringSync(text);

Uint8List _read(String path) => File('${_ws.path}/$path').readAsBytesSync();

String _text(String path) => File('${_ws.path}/$path').readAsStringSync();

List<String> _dills(String dir) => [
  for (final FileSystemEntity entity in Directory(
    '${_ws.path}/$dir',
  ).listSync()..sort((a, b) => a.path.compareTo(b.path)))
    if (entity.path.endsWith('.dill')) entity.path.split('/').last,
];

/// The request that compiles package [name] (every file below `<name>/lib`)
/// against the outlines of [deps], into `<out>/<name>.kmod` and
/// `<out>/<name>.koutline`. [inputs] maps a dependency to the directory it
/// is read from, when that is not its outline.
List<String> _moduleArgs(
  String name, {
  List<String> deps = const [],
  String out = 'out',
  Map<String, String> inputs = const {},
  List<String> extra = const [],
  Set<String> undeclared = const {},
}) {
  final List<String> files = [
    for (final FileSystemEntity entity in Directory(
      '${_ws.path}/$name/lib',
    ).listSync(recursive: true))
      if (entity.path.endsWith('.dart'))
        entity.path.substring('${_ws.path}/$name/lib/'.length),
  ]..sort();
  return [
    ..._common('$out/$name.package_config.json', [name, ...deps]),
    for (final String dep in deps) ...[
      '--input-kmod',
      inputs[dep] ?? '$out/$dep.koutline',
    ],
    for (final String file in files) ...[
      '--source',
      'package:$name/$file',
      if (!undeclared.contains(file)) ...['--input-source', '$name/lib/$file'],
    ],
    '--output',
    '$out/$name.kmod',
    '--output-outline',
    '$out/$name.koutline',
    '--excluded-output',
    '$out/$name.excluded',
    '--unused-inputs-list',
    '$out/$name.unused',
    ...extra,
  ];
}

/// The request that compiles the entry [main] against the outlines of [deps].
List<String> _entryArgs(
  String main, {
  required List<String> deps,
  String out = 'out',
  List<String> extra = const [],
}) => [
  ..._common('$out/entry.package_config.json', deps),
  for (final String dep in deps) ...['--input-kmod', '$out/$dep.koutline'],
  '--source',
  'org-dartlang-root:///$main',
  '--input-source',
  main,
  '--own-source-file',
  main,
  '--no-drop',
  '--output',
  '$out/entry.kmod',
  '--excluded-output',
  '$out/entry.excluded',
  '--unused-inputs-list',
  '$out/entry.unused',
  ...extra,
];

List<String> _common(String packageConfig, List<String> packages) => [
  '--target',
  'vm',
  '--dart-sdk-summary',
  _platform,
  '--packages-file',
  packageConfig,
  for (final String package in packages) ...['--record', '$package|$package|'],
  '--multi-root',
  '.',
  '--multi-root-scheme',
  'org-dartlang-root',
  '-Ddart.vm.product=false',
];

ProcessResult _run(List<String> args) {
  final int out = args.indexOf('--output');
  Directory('${_ws.path}/${args[out + 1]}').parent.createSync(recursive: true);
  return Process.runSync(_dartaotruntime, [
    _tool,
    ...args,
  ], workingDirectory: _ws.path);
}

void _compile(List<String> args) {
  final ProcessResult result = _run(args);
  expect(result.exitCode, 0, reason: '${result.stderr}');
}

/// Runs the program linked from [entry] and the kernels of [modules], the
/// entry first, as `kernel_link` orders them.
ProcessResult _runLinked(String entry, List<String> modules) {
  final bytes = BytesBuilder()..add(_read('$entry/entry.dill'));
  for (final module in modules) {
    for (final String dill in _dills(module)) {
      bytes.add(_read('$module/$dill'));
    }
  }
  File('${_ws.path}/app.dill').writeAsBytesSync(bytes.takeBytes());
  return Process.runSync(_dart, ['app.dill'], workingDirectory: _ws.path);
}

const _leaf = r'''
import 'src/shapes.dart';

export 'src/shapes.dart';

/// Greets [name].
String greet(String name, {String punctuation = '!'}) {
  return 'hello $name$punctuation ${_twice(defaultSides)}';
}

int _twice(int n) => n * 2;

const int defaultSides = 4;

final List<int> cache = [1, 2, 3];

class Counter {
  int count = 0;

  int next() {
    count += 1;
    return count;
  }
}
''';

const _shapes = '''
class Point {
  const Point(this.x, this.y);

  final int x;
  final int y;
}
''';

const _mixins = '''
mixin Loud {
  String shout(String text) {
    if (text.isEmpty) throw StateError('nothing to shout');
    return text.toUpperCase();
  }
}
''';

const _mid = r'''
import 'package:leaf/leaf.dart';
import 'package:leaf/mixins.dart';

class Speaker with Loud {
  const Speaker();
}

const origin = Point(0, 0);

String announce(String name) =>
    const Speaker().shout(greet(name)) + ' ${origin.x} ${Counter().next()}';
''';

const _top = '''
import 'package:mid/mid.dart';

String headline() => announce('top');
''';

const _main = r'''
import 'package:mid/mid.dart';
import 'package:top/top.dart';

void main() {
  print(headline());
  try {
    const Speaker().shout('');
  } on StateError catch (error, stack) {
    print(error.message);
    print(stack.toString().split('\n').first);
  }
}
''';

/// A persistent worker of the module compiler, driven as Bazel drives one:
/// one request at a time, each answered with its exit code and output.
/// [log] is what the worker wrote to stderr, which Bazel keeps as the
/// worker's log.
class _Worker {
  new _(this._process) {
    _process.stdout.listen(_bytes.addAll);
    _process.stderr.transform(utf8.decoder).listen(_log.write);
  }

  static Future<_Worker> start() async => _Worker._(
    await Process.start(_dartaotruntime, [
      _tool,
      '--persistent_worker',
    ], workingDirectory: _ws.path),
  );

  final Process _process;
  final List<int> _bytes = [];
  final StringBuffer _log = StringBuffer();

  String get log => '$_log';

  Future<({int exitCode, String output})> request(List<String> args) async {
    final int out = args.indexOf('--output');
    Directory('${_ws.path}/${args[out + 1]}').parent
        .createSync(recursive: true);
    final Uint8List payload = encodeWorkRequestForTest(
      arguments: args,
      inputs: const {},
    );
    _process.stdin
      ..add(encodeVarintForTest(payload.length))
      ..add(payload);
    await _process.stdin.flush();
    while (true) {
      final ({int at, int value})? length = _varint(_bytes, 0);
      if (length != null && _bytes.length >= length.at + length.value) {
        final List<int> frame = _bytes.sublist(
          length.at,
          length.at + length.value,
        );
        _bytes.removeRange(0, length.at + length.value);
        return _response(frame);
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  Future<int> close() async {
    await _process.stdin.close();
    return await _process.exitCode;
  }

  static ({int at, int value})? _varint(List<int> bytes, int start) {
    var value = 0;
    var at = start;
    for (var shift = 0; at < bytes.length; shift += 7) {
      final int byte = bytes[at++];
      value |= (byte & 0x7f) << shift;
      if (byte < 0x80) return (at: at, value: value);
    }
    return null;
  }

  /// The exit code (field 1) and output (field 2) of a `WorkResponse`.
  static ({int exitCode, String output}) _response(List<int> frame) {
    var exitCode = 0;
    var output = '';
    var at = 0;
    while (at < frame.length) {
      final ({int at, int value}) tag = _varint(frame, at)!;
      final ({int at, int value}) value = _varint(frame, tag.at)!;
      at = value.at;
      if (tag.value & 7 == 2) {
        if (tag.value >> 3 == 2) {
          output = utf8.decode(frame.sublist(at, at + value.value));
        }
        at += value.value;
      } else if (tag.value >> 3 == 1) {
        exitCode = value.value;
      }
    }
    return (exitCode: exitCode, output: output);
  }
}

/// A plugin's platform interface, as `package:plugin_platform_interface`
/// shapes one: the class every implementation extends, with a named token.
const _pluginInterface = '''
abstract class PlatformInterface {
  PlatformInterface({required Object token}) : _token = token;

  final Object _token;

  Object get token => _token;
}
''';

/// A package that extends it with a `super(...)` initializer, as every
/// `*_platform_interface` package does.
const _pluginPlatform = '''
import 'package:plugin/plugin.dart';

abstract class CookiePlatform extends PlatformInterface {
  CookiePlatform() : super(token: _token);

  static final Object _token = Object();
}
''';

void _writeClosure() {
  _write('leaf/lib/leaf.dart', _leaf);
  _write('leaf/lib/src/shapes.dart', _shapes);
  _write('leaf/lib/mixins.dart', _mixins);
  _write('mid/lib/mid.dart', _mid);
  _write('top/lib/top.dart', _top);
  _write('app/main.dart', _main);
}

void main(List<String> args) {
  final runfiles = Runfiles.create();
  final tools = jsonDecode(
    File(runfiles.rlocation(args.single)).readAsStringSync(),
  ) as Map<String, dynamic>;
  String tool(String key) =>
      File(runfiles.rlocation(tools[key] as String)).absolute.path;
  _tool = tool('module_compiler');
  _dartaotruntime = tool('dartaotruntime');
  _platform = tool('platform');
  _dart = tool('dart');

  setUp(() {
    _ws = Directory.systemTemp.createTempSync('module_compiler_test_');
    _writeClosure();
  });

  tearDown(() {
    _ws.deleteSync(recursive: true);
  });

  group('an outline', () {
    // What an edit to `leaf.dart` does to the module's outline: only an edit
    // a dependant can observe changes it, so only that edit recompiles the
    // dependants. The kernel changes with every one of them.
    final edits = <String, (String Function(String), bool)>{
      'a body edit of a function': (
        (s) => s.replaceFirst("'hello ", "'good day "),
        false,
      ),
      'a body edit of a method': (
        (s) => s.replaceFirst('count += 1;', 'count += 2;'),
        false,
      ),
      'a body edit of a private function': (
        (s) => s.replaceFirst('n * 2', 'n + n'),
        false,
      ),
      'a comment that moves every line': (
        (s) => '// A comment.\n// And another.\n$s',
        false,
      ),
      'a doc comment': (
        (s) =>
            s.replaceFirst('/// Greets [name].', '/// Says hello to [name].'),
        false,
      ),
      'an initializer of the same type': (
        (s) => s.replaceFirst('[1, 2, 3]', '[4, 5]'),
        false,
      ),
      'a changed signature': (
        (s) => s.replaceFirst(
          'String greet(String name,',
          'String greet(Object name,',
        ),
        true,
      ),
      'a changed default value': (
        (s) => s.replaceFirst("punctuation = '!'", "punctuation = '?'"),
        true,
      ),
      'a changed const value': (
        (s) => s.replaceFirst('defaultSides = 4', 'defaultSides = 5'),
        true,
      ),
      'an initializer that changes the inferred type': (
        (s) => s
            .replaceFirst('[1, 2, 3]', '[1.5]')
            .replaceFirst('List<int> cache', 'var cache'),
        true,
      ),
      'a new public function': ((s) => '$s\nint added() => 1;\n', true),
      // Private members are part of the outline: a dependant's classes can
      // inherit them.
      'a new private function': ((s) => '$s\nint _added() => 1;\n', true),
    };
    for (final MapEntry<String, (String Function(String), bool)> edit
        in edits.entries) {
      final (String Function(String) apply, bool changes) = edit.value;
      test(
        '${changes ? 'changes' : 'is byte-identical'} after ${edit.key}',
        () {
          _compile(_moduleArgs('leaf'));
          final Uint8List outline = _read('out/leaf.koutline/outline.dill');
          final Uint8List kernel = _read('out/leaf.kmod/1.dill');
          final String edited = apply(_leaf);
          expect(edited, isNot(_leaf), reason: 'the edit must apply');
          _write('leaf/lib/leaf.dart', edited);
          _compile(_moduleArgs('leaf', out: 'edited'));
          expect(
            _read('edited/leaf.koutline/outline.dill'),
            changes ? isNot(outline) : outline,
          );
          expect(_read('edited/leaf.kmod/1.dill'), isNot(kernel));
        },
      );
    }

    test('keeps a mixin whole, so a body edit of one changes it', () {
      _compile(_moduleArgs('leaf'));
      final Uint8List outline = _read('out/leaf.koutline/outline.dill');
      _write(
        'leaf/lib/mixins.dart',
        _mixins.replaceFirst('toUpperCase', 'toLowerCase'),
      );
      _compile(_moduleArgs('leaf', out: 'edited'));
      expect(_read('edited/leaf.koutline/outline.dill'), isNot(outline));
    });
  });

  test('kernels are byte-identical compiled against outlines and against '
      'full kernels', () {
    _compile(_moduleArgs('leaf'));
    _compile(_moduleArgs('mid', deps: ['leaf']));
    _compile(_moduleArgs('top', deps: ['leaf', 'mid']));
    // Each dependency once more as its whole kernels in one file, named by an
    // index as an outline is.
    for (final name in ['leaf', 'mid']) {
      final bytes = BytesBuilder();
      for (final String dill in _dills('out/$name.kmod')) {
        bytes.add(_read('out/$name.kmod/$dill'));
      }
      File('${_ws.path}/out/$name.full/full.dill')
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(bytes.takeBytes());
      _write(
        'out/$name.full/index.json',
        jsonEncode({
          'version': 2,
          'outline': 'full.dill',
          'excluded': <String>[],
        }),
      );
    }
    const full = {'leaf': 'out/leaf.full', 'mid': 'out/mid.full'};
    _compile(_moduleArgs('mid', deps: ['leaf'], out: 'full', inputs: full));
    _compile(
      _moduleArgs('top', deps: ['leaf', 'mid'], out: 'full', inputs: full),
    );
    for (final name in ['mid', 'top']) {
      expect(_dills('full/$name.kmod'), _dills('out/$name.kmod'));
      for (final String dill in _dills('out/$name.kmod')) {
        expect(
          _read('full/$name.kmod/$dill'),
          _read('out/$name.kmod/$dill'),
          reason: '$name $dill',
        );
      }
      expect(
        _read('full/$name.koutline/outline.dill'),
        _read('out/$name.koutline/outline.dill'),
      );
    }
  });

  test('a linked closure runs, with the position of a mixed-in member', () {
    _compile(_moduleArgs('leaf'));
    _compile(_moduleArgs('mid', deps: ['leaf']));
    _compile(_moduleArgs('top', deps: ['leaf', 'mid']));
    _compile(_entryArgs('app/main.dart', deps: ['leaf', 'mid', 'top']));
    final ProcessResult result = _runLinked('out/entry.kmod', [
      'out/leaf.kmod',
      'out/mid.kmod',
      'out/top.kmod',
    ]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    final List<String> lines = const LineSplitter().convert(
      result.stdout as String,
    );
    expect(lines[0], 'HELLO TOP! 8 0 1');
    expect(lines[1], 'nothing to shout');
    // The frame of the member `Speaker` took from `Loud`, in another module.
    expect(lines[2], contains('package:leaf/mixins.dart:3:23'));
  });

  group('an entry point a dependency module defines', () {
    // An app's `lib/main.dart` that its library lists: the entry names it by
    // its `package:` URI and declares no file for it.
    List<String> linkedEntry(List<String> deps) => [
      ..._common('out/entry.package_config.json', deps),
      for (final String dep in deps) ...['--input-kmod', 'out/$dep.koutline'],
      '--source',
      'package:app/main.dart',
      '--no-drop',
      '--output',
      'out/entry.kmod',
      '--excluded-output',
      'out/entry.excluded',
      '--unused-inputs-list',
      'out/entry.unused',
    ];

    setUp(() {
      _write(
        'app/lib/main.dart',
        _main.replaceFirst(
          'void main() {',
          "void main() {\n  print(StackTrace.current.toString().split('\\n').first);",
        ),
      );
    });

    test("runs that library's main, under its package: URI, compiled once", () {
      _compile(_moduleArgs('leaf'));
      _compile(_moduleArgs('mid', deps: ['leaf']));
      _compile(_moduleArgs('top', deps: ['leaf', 'mid']));
      _compile(_moduleArgs('app', deps: ['leaf', 'mid', 'top']));
      _compile(linkedEntry(['leaf', 'mid', 'top', 'app']));
      // The entry defines no library: `main.dart` is the app module's.
      final index = jsonDecode(_text('out/entry.kmod/index.json')) as Map;
      final kernel = (index['sccs'] as List).single as Map;
      expect(kernel['imports'], ['app/lib/main.dart']);
      // The app module is used: the program's `main` is there.
      expect(_text('out/entry.unused'), isNot(contains('app.koutline')));
      final ProcessResult result = _runLinked('out/entry.kmod', [
        'out/app.kmod',
        'out/leaf.kmod',
        'out/mid.kmod',
        'out/top.kmod',
      ]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      final List<String> lines = const LineSplitter().convert(
        result.stdout as String,
      );
      expect(lines[0], contains('main (package:app/main.dart:5:'));
      expect(lines[1], 'HELLO TOP! 8 0 1');
    });

    test('fails when the library declares no main', () {
      _write('app/lib/main.dart', "String notMain() => 'x';\n");
      _compile(_moduleArgs('leaf'));
      _compile(_moduleArgs('app', deps: ['leaf']));
      final ProcessResult result = _run(linkedEntry(['leaf', 'app']));
      expect(result.exitCode, 1);
      expect(
        result.stderr,
        contains(
          'the entry point package:app/main.dart declares no '
          'top-level `main`',
        ),
      );
    });

    test('fails when no dependency module defines it', () {
      _compile(_moduleArgs('leaf'));
      final ProcessResult result = _run(linkedEntry(['leaf']));
      expect(result.exitCode, isNot(0));
    });
  });

  test('the same request gives the same bytes in a worker and by itself, '
      'whatever order names the inputs', () async {
    _compile(_moduleArgs('leaf'));
    _compile(_moduleArgs('mid', deps: ['leaf']));
    _compile(_moduleArgs('top', deps: ['leaf', 'mid']));
    final Process worker = await Process.start(_dartaotruntime, [
      _tool,
      '--persistent_worker',
    ], workingDirectory: _ws.path);
    final responses = <int>[];
    worker.stdout.listen(responses.addAll);
    Future<void> request(List<String> args) async {
      final int out = args.indexOf('--output');
      Directory('${_ws.path}/${args[out + 1]}').parent
          .createSync(recursive: true);
      final Uint8List payload = encodeWorkRequestForTest(
        arguments: args,
        inputs: const {},
      );
      final int before = responses.length;
      worker.stdin
        ..add(encodeVarintForTest(payload.length))
        ..add(payload);
      await worker.stdin.flush();
      while (responses.length == before) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }

    await request(_moduleArgs('leaf', out: 'warm'));
    await request(_moduleArgs('mid', deps: ['leaf'], out: 'warm'));
    // The dependencies named in the other order.
    await request(_moduleArgs('top', deps: ['mid', 'leaf'], out: 'warm'));
    await worker.stdin.close();
    expect(await worker.exitCode, 0);
    for (final name in ['leaf', 'mid', 'top']) {
      for (final String dill in _dills('out/$name.kmod')) {
        expect(
          _read('warm/$name.kmod/$dill'),
          _read('out/$name.kmod/$dill'),
          reason: '$name $dill',
        );
      }
      expect(
        _read('warm/$name.koutline/outline.dill'),
        _read('out/$name.koutline/outline.dill'),
      );
    }
  });

  group('a worker that keeps the front end state', () {
    setUp(() {
      _write('plugin/lib/plugin.dart', _pluginInterface);
      _write('platform/lib/platform.dart', _pluginPlatform);
      // One module in two configurations, as `bazel-out/k8-dbg` and
      // `bazel-out/k8-dbg-ST-<hash>` hold it in one build: the same
      // libraries, in outlines under two paths.
      _compile(_moduleArgs('plugin', out: 'x'));
      _compile(_moduleArgs('plugin', out: 'y'));
      _compile(_moduleArgs('platform', deps: ['plugin'], out: 'x'));
    });

    // The shortest sequence of the crash that `e2e/android_plugins` showed
    // in a worker (`Null check operator used on a null value` in
    // `InferenceVisitorImpl.visitInternalSuperInitializer`): each
    // configuration's outline loaded twice, alternating. The last request
    // reused the first outline of `x` while the library's references pointed
    // into the outline of `y` loaded after it.
    test('compiles a module against one configuration after the other, '
        'alternating, as by itself', () async {
      final _Worker worker = await _Worker.start();
      for (final (int i, String config) in ['y', 'x', 'y', 'x'].indexed) {
        final ({int exitCode, String output}) result = await worker.request(
          _moduleArgs(
            'platform',
            deps: ['plugin'],
            out: 'w$i',
            inputs: {'plugin': '$config/plugin.koutline'},
          ),
        );
        expect(result.exitCode, 0, reason: 'request $i: ${result.output}');
        for (final String dill in _dills('x/platform.kmod')) {
          expect(
            _read('w$i/platform.kmod/$dill'),
            _read('x/platform.kmod/$dill'),
            reason: 'request $i, $dill',
          );
        }
      }
      expect(await worker.close(), 0);
      expect(worker.log, isNot(contains('module_compiler:')));
    });
  });

  group('a library the target cannot compile', () {
    setUp(() {
      _write('leaf/lib/web.dart', '''
import 'dart:html';

String location() => window.location.href;
''');
      _write('leaf/lib/uses_web.dart', '''
import 'web.dart';

String where() => location();
''');
      _write('mid/lib/mid_web.dart', '''
import 'package:leaf/uses_web.dart';

String midWhere() => where();
''');
    });

    test('is left out with its importers, and the rest is as if it were '
        'never listed', () {
      _compile(_moduleArgs('leaf'));
      final String sidecar = _text('out/leaf.excluded');
      expect(sidecar, contains('package:leaf/web.dart\tcompile error:'));
      expect(sidecar, contains("'dart:html' is not available"));
      expect(
        sidecar,
        contains('package:leaf/uses_web.dart\timports package:leaf/web.dart'),
      );
      final index =
          jsonDecode(_text('out/leaf.kmod/index.json')) as Map<String, dynamic>;
      final List<String> defined = [
        for (final Map<String, dynamic> scc
            in (index['sccs'] as List).cast<Map<String, dynamic>>())
          ...(scc['defines'] as List).cast<String>(),
      ];
      expect(defined, isNot(contains('leaf/lib/web.dart')));
      expect(defined, isNot(contains('leaf/lib/uses_web.dart')));
      expect(defined, contains('leaf/lib/leaf.dart'));

      // Without the two files, the same module.
      File('${_ws.path}/leaf/lib/web.dart').deleteSync();
      File('${_ws.path}/leaf/lib/uses_web.dart').deleteSync();
      _compile(_moduleArgs('leaf', out: 'clean'));
      expect(_dills('clean/leaf.kmod'), _dills('out/leaf.kmod'));
      for (final String dill in _dills('out/leaf.kmod')) {
        expect(_read('clean/leaf.kmod/$dill'), _read('out/leaf.kmod/$dill'));
      }
      expect(
        _read('clean/leaf.koutline/outline.dill'),
        _read('out/leaf.koutline/outline.dill'),
      );
    });

    test('leaves out a dependant library that imports it', () {
      _compile(_moduleArgs('leaf'));
      _compile(_moduleArgs('mid', deps: ['leaf']));
      expect(
        _text('out/mid.excluded'),
        contains(
          'package:mid/mid_web.dart\timports package:leaf/uses_web.dart',
        ),
      );
    });

    test("fails an entry that reaches it, with the front end's own error "
        'and the reason its module gave', () {
      _compile(_moduleArgs('leaf'));
      _write('app/main.dart', '''
import 'package:leaf/uses_web.dart';

void main() => print(where());
''');
      final ProcessResult result = _run(
        _entryArgs('app/main.dart', deps: ['leaf']),
      );
      expect(result.exitCode, 1);
      expect(result.stderr, contains("'dart:html' is not available"));
      expect(
        result.stderr,
        contains(
          'leaf/lib/web.dart is not in the module of out/leaf.koutline, which '
          'left it out: compile error:',
        ),
      );
    });

    test('names the reason in the outline, for the modules that import it', () {
      _compile(_moduleArgs('leaf'));
      final index = jsonDecode(
        _text('out/leaf.koutline/index.json'),
      ) as Map<String, dynamic>;
      expect(index['excluded'], [
        'leaf/lib/uses_web.dart',
        'leaf/lib/web.dart',
      ]);
      final reasons = index['reasons'] as Map<String, dynamic>;
      expect(reasons['leaf/lib/web.dart'], contains("'dart:html'"));
      _compile(_moduleArgs('mid', deps: ['leaf']));
      expect(
        _text('out/mid.excluded'),
        contains(
          'package:mid/mid_web.dart\timports package:leaf/uses_web.dart, '
          'which its module left out (imports package:leaf/web.dart',
        ),
      );
    });
  });

  test('an entry with an error fails, and names it', () {
    _compile(_moduleArgs('leaf'));
    _write('app/main.dart', "int main() => 'not an int';\n");
    final ProcessResult result = _run(
      _entryArgs('app/main.dart', deps: ['leaf']),
    );
    expect(result.exitCode, 1);
    expect(result.stderr, contains("can't be returned"));
  });

  group('an import of a file the request does not declare', () {
    test('leaves the library out of a library module, naming the import, '
        'and fails an entry that reaches it', () {
      _write('leaf/lib/lost.dart', '''
import 'gone.dart';

String lost() => gone();
''');
      _compile(_moduleArgs('leaf'));
      expect(
        _text('out/leaf.excluded'),
        contains(
          "package:leaf/lost.dart\timport 'gone.dart' names "
          'leaf/lib/gone.dart, which is not an input of this compile.',
        ),
      );
      _write('app/main.dart', '''
import 'package:leaf/lost.dart';

void main() => print(lost());
''');
      final ProcessResult result = _run(
        _entryArgs('app/main.dart', deps: ['leaf']),
      );
      expect(result.exitCode, 1);
      expect(
        result.stderr,
        allOf(
          contains(
            "cannot compile package:leaf/lost.dart: import 'gone.dart' names "
            'leaf/lib/gone.dart, which is not an input of this compile.',
          ),
          contains(
            'The module of out/leaf.koutline left it out; this program '
            'reaches it.',
          ),
        ),
      );
    });

    test('fails an entry once per missing file, however many libraries '
        'reach it', () {
      for (final name in ['lost', 'also_lost']) {
        _write('leaf/lib/$name.dart', '''
import 'gone.dart';

String $name() => gone();
''');
      }
      _compile(_moduleArgs('leaf'));
      _write('app/main.dart', '''
import 'package:leaf/also_lost.dart';
import 'package:leaf/lost.dart';

void main() => print(lost() + also_lost());
''');
      final ProcessResult result = _run(
        _entryArgs('app/main.dart', deps: ['leaf']),
      );
      expect(result.exitCode, 1);
      final stderr = result.stderr as String;
      expect(
        stderr,
        contains(
          "cannot compile package:leaf/also_lost.dart: import 'gone.dart' "
          'names leaf/lib/gone.dart, which is not an input of this compile.',
        ),
      );
      expect(
        stderr,
        contains('1 more library reaches leaf/lib/gone.dart the same way.'),
      );
      expect(stderr, isNot(contains('cannot compile package:leaf/lost.dart')));
      expect(
        stderr,
        contains('a directory with a BUILD file of its own is a package'),
      );
    });

    test("leaves out a library naming a file a dependency's package does "
        'not have', () {
      _compile(_moduleArgs('leaf'));
      _write('mid/lib/mid.dart', '''
import 'package:leaf/absent.dart';

String announce(String name) => name;
''');
      _compile(_moduleArgs('mid', deps: ['leaf']));
      expect(
        _text('out/mid.excluded'),
        contains(
          "package:mid/mid.dart\timport 'package:leaf/absent.dart' names "
          'leaf/lib/absent.dart, which is not an input of this compile.',
        ),
      );
    });

    test('fails an entry whose own source imports it, naming the source and '
        'the import', () {
      _compile(_moduleArgs('leaf'));
      _write('app/main.dart', '''
import 'package:leaf/absent.dart';

void main() {}
''');
      final ProcessResult result = _run(
        _entryArgs('app/main.dart', deps: ['leaf']),
      );
      expect(result.exitCode, 1);
      expect(
        result.stderr,
        contains(
          'cannot compile org-dartlang-root:///app/main.dart: import '
          "'package:leaf/absent.dart' names leaf/lib/absent.dart, which is "
          'not an input of this compile.',
        ),
      );
    });

    test('fails the module when its package is not in the package config, '
        "with the front end's own error", () {
      _write('leaf/lib/stray.dart', '''
import 'package:nowhere/nowhere.dart';

String stray() => nowhere();
''');
      final ProcessResult result = _run(_moduleArgs('leaf'));
      expect(result.exitCode, 1);
      expect(result.stderr, contains("Couldn't resolve the package 'nowhere'"));
    });
  });

  group("an import that reaches a dependency's source by another URI", () {
    test('is refused in a library, naming the URI to use', () {
      _compile(_moduleArgs('leaf'));
      _write('mid/lib/mid.dart', '''
import 'org-dartlang-root:///leaf/lib/leaf.dart';

String announce(String name) => greet(name);
''');
      final ProcessResult result = _run(_moduleArgs('mid', deps: ['leaf']));
      expect(result.exitCode, 1);
      expect(
        result.stderr,
        contains(
          'cannot compile package:mid/mid.dart: import '
          "'org-dartlang-root:///leaf/lib/leaf.dart' reaches a source its "
          "dependencies define under 'package:leaf/leaf.dart'; import that "
          'instead.',
        ),
      );
    });

    test('is refused in an entry, naming the URI as written', () {
      _compile(_moduleArgs('leaf'));
      _write('app/main.dart', '''
import '../leaf/lib/leaf.dart';

void main() => print(greet('entry'));
''');
      final ProcessResult result = _run(
        _entryArgs('app/main.dart', deps: ['leaf']),
      );
      expect(result.exitCode, 1);
      expect(
        result.stderr,
        contains(
          'cannot compile org-dartlang-root:///app/main.dart: import '
          "'../leaf/lib/leaf.dart' reaches a source its dependencies define "
          "under 'package:leaf/leaf.dart'; import that instead.",
        ),
      );
    });
  });

  test('a define keeps its commas, from the request and from a file', () {
    _write('leaf/lib/leaf.dart', '''
const String fromRequest = String.fromEnvironment('greeting');
const String fromFile = String.fromEnvironment('farewell');
const String overridden = String.fromEnvironment('both');
''');
    _write('app/main.dart', r'''
import 'package:leaf/leaf.dart';

void main() => print('$fromRequest|$fromFile|$overridden');
''');
    _write('defines.txt', '-Dfarewell=bye, now\n-Dboth=file\n');
    const defines = [
      '--define-file',
      'defines.txt',
      '-Dgreeting=a,b=c, d',
      '-Dboth=request',
    ];
    _compile(_moduleArgs('leaf', extra: defines));
    _compile(_entryArgs('app/main.dart', deps: ['leaf'], extra: defines));
    final ProcessResult result = _runLinked('out/entry.kmod', [
      'out/leaf.kmod',
    ]);
    expect(result.stdout, 'a,b=c, d|bye, now|request\n');
  });

  test('a module that imports a package it does not depend on directly is '
      'refused under the layering check', () {
    _compile(_moduleArgs('leaf'));
    _compile(_moduleArgs('mid', deps: ['leaf']));
    final ProcessResult result = _run(
      _moduleArgs(
        'top',
        deps: ['leaf', 'mid'],
        extra: [
          '--check-imports',
          '--target-label',
          '//top',
          '--own-package',
          'top',
          '--direct-package',
          'leaf',
        ],
      ),
    );
    expect(result.exitCode, 1);
    expect(
      result.stderr,
      contains(
        "//top: top/lib/top.dart imports 'package:mid/mid.dart', but package "
        "'mid' is not a direct dependency of //top",
      ),
    );
  });

  test('the layering check reads the branch of a conditional import the '
      'target does not take', () {
    _compile(_moduleArgs('leaf'));
    _compile(_moduleArgs('mid', deps: ['leaf']));
    _write('top/lib/top.dart', '''
import 'package:leaf/leaf.dart'
    if (dart.library.html) 'package:mid/mid.dart';

String headline() => greet('top');
''');
    final ProcessResult result = _run(
      _moduleArgs(
        'top',
        deps: ['leaf', 'mid'],
        extra: [
          '--check-imports',
          '--target-label',
          '//top',
          '--own-package',
          'top',
          '--direct-package',
          'leaf',
        ],
      ),
    );
    expect(result.exitCode, 1);
    expect(
      result.stderr,
      contains(
        "//top: top/lib/top.dart imports 'package:mid/mid.dart', but package "
        "'mid' is not a direct dependency of //top",
      ),
    );
    // With `mid` a direct dependency, the module compiles.
    _compile(
      _moduleArgs(
        'top',
        deps: ['leaf', 'mid'],
        out: 'allowed',
        inputs: {'leaf': 'out/leaf.koutline', 'mid': 'out/mid.koutline'},
        extra: [
          '--check-imports',
          '--target-label',
          '//top',
          '--own-package',
          'top',
          '--direct-package',
          'leaf',
          '--direct-package',
          'mid',
        ],
      ),
    );
  });

  test('a module whose own source imports a refused dart: library is '
      'refused under the layering check', () {
    _write('leaf/lib/reflect.dart', "import 'dart:mirrors';\n");
    final ProcessResult result = _run(
      _moduleArgs(
        'leaf',
        extra: [
          '--check-imports',
          '--target-label',
          '//leaf',
          '--own-package',
          'leaf',
          '--refused-library',
          'dart:mirrors',
        ],
      ),
    );
    expect(result.exitCode, 1);
    expect(
      result.stderr,
      contains(
        "//leaf: leaf/lib/reflect.dart imports 'dart:mirrors', which "
        '//dart:refused_dart_libraries refuses.',
      ),
    );
    // Without the setting the module compiles.
    _compile(
      _moduleArgs('leaf', extra: ['--check-imports', '--own-package', 'leaf']),
    );
  });

  test('a source directory compiles every file under it, named by its '
      'path under the URI prefix', () {
    final List<String> args = _moduleArgs('leaf');
    final request = <String>[
      for (var i = 0; i < args.length; i++)
        if (args[i] == '--source' || args[i] == '--input-source')
          ...[]
        else if (i > 0 &&
            (args[i - 1] == '--source' || args[i - 1] == '--input-source'))
          ...[]
        else
          args[i],
      '--source-dir',
      'package:leaf/',
      'leaf/lib',
    ];
    _compile(request);
    _compile(_moduleArgs('mid', deps: ['leaf']));
    _compile(_moduleArgs('top', deps: ['leaf', 'mid']));
    _compile(_entryArgs('app/main.dart', deps: ['leaf', 'mid', 'top']));
    final ProcessResult result = _runLinked('out/entry.kmod', [
      'out/leaf.kmod',
      'out/mid.kmod',
      'out/top.kmod',
    ]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect(
      const LineSplitter().convert(result.stdout as String).first,
      'HELLO TOP! 8 0 1',
    );
  });

  test('an entry embeds its native-assets mapping, which the linked program '
      'resolves an @Native function by', () {
    _write('app/main.dart', '''
import 'dart:ffi';

@Native<Int32 Function()>(symbol: 'getpid', assetId: 'package:app/pid')
external int getpid();

void main() => print(getpid() > 0 ? 'resolved' : 'zero');
''');
    _write(
      'abi.dart',
      'import "dart:ffi";\nvoid main() => print(Abi.current());\n',
    );
    final String abi =
        (Process.runSync(_dart, ['abi.dart'], workingDirectory: _ws.path).stdout
                as String)
            .trim();
    // The asset names a library that is nowhere: the VM only looks for it
    // when the mapping is in the program. Without one it finds the symbol in
    // the process.
    final lost = '${_ws.path}/nowhere/libpid.so';
    _write('native_assets.yaml', '''
format-version: [1, 0, 0]
native-assets:
  $abi:
    'package:app/pid': [absolute, '$lost']
''');
    _compile(_moduleArgs('leaf'));
    _compile(_entryArgs('app/main.dart', deps: ['leaf']));
    final ProcessResult unmapped = _runLinked('out/entry.kmod', []);
    expect(unmapped.exitCode, 0, reason: '${unmapped.stderr}');
    expect(unmapped.stdout, 'resolved\n');
    _compile(_moduleArgs('leaf', out: 'mapped'));
    _compile(
      _entryArgs(
        'app/main.dart',
        deps: ['leaf'],
        out: 'mapped',
        extra: ['--native-assets', 'native_assets.yaml'],
      ),
    );
    final ProcessResult mapped = _runLinked('mapped/entry.kmod', []);
    expect(mapped.exitCode, isNot(0));
    expect(mapped.stderr, contains(lost));
  });

  test('a library module refuses a native-assets mapping', () {
    _write(
      'native_assets.yaml',
      'format-version: [1, 0, 0]\nnative-assets: {}\n',
    );
    final ProcessResult result = _run(
      _moduleArgs('leaf', extra: ['--native-assets', 'native_assets.yaml']),
    );
    expect(result.exitCode, 64);
    expect(result.stderr, contains('--native-assets is an entry option'));
  });

  test('the unused-inputs list names the dependencies the front end did '
      'not need', () {
    _write('top/lib/top.dart', "String headline() => 'alone';\n");
    _compile(_moduleArgs('leaf'));
    _compile(_moduleArgs('mid', deps: ['leaf']));
    _compile(_moduleArgs('top', deps: ['leaf', 'mid']));
    expect(_text('out/top.unused'), 'out/leaf.koutline\nout/mid.koutline\n');
    expect(_text('out/mid.unused'), '');
  });
}
