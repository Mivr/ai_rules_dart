/// Guards that the per-edit host tools run as native executables.
///
/// `android_bundle`, `kernel_filter` and `macho_edit` run on every edit, so
/// each is built with `compile_mode = "exe"` and every action runs the
/// executable itself, never `dart <tool>.dill`. The checks read the tools'
/// `BUILD.bazel`, the rule sources and the corpus action golden from the
/// checkout this test runs against.
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

const List<String> _tools = <String>[
  'android_bundle',
  'kernel_filter',
  'macho_edit',
];

/// The rule attribute that names each tool, as read in the rule sources.
const Map<String, String> _toolAttrs = <String, String>{
  'android_bundle': '_android_bundle_tool',
  'macho_edit': '_macho_edit',
};

/// The checkout root: the nearest ancestor of this test's runfile holding a
/// `MODULE.bazel`, falling back to `BUILD_WORKSPACE_DIRECTORY`.
Directory _root() {
  final Map<String, String> env = Platform.environment;
  final String? workspace = env['BUILD_WORKSPACE_DIRECTORY'];
  if (workspace != null && workspace.isNotEmpty) return Directory(workspace);
  final anchor = '${env['TEST_SRCDIR']}/${env['GUARD_ROOT_ANCHOR']}';
  Directory dir = File(File(anchor).resolveSymbolicLinksSync()).parent;
  while (!File('${dir.path}/MODULE.bazel').existsSync()) {
    if (dir.parent.path == dir.path) fail('no MODULE.bazel above $anchor');
    dir = dir.parent;
  }
  return dir;
}

String _read(String relative) =>
    File('${_root().path}/$relative').readAsStringSync();

/// The text of the `dart_binary` named [name] in the tools `BUILD.bazel`.
String _binary(String name) {
  final String build = _read('flutter/private/tools/BUILD.bazel');
  final int at = build.indexOf('    name = "$name",');
  expect(at, isNonNegative, reason: 'no dart_binary $name');
  return build.substring(build.lastIndexOf('dart_binary(', at), at + 900);
}

/// The text of every `ctx.actions.run(...)` call in [source].
List<String> _runCalls(String source) {
  final calls = <String>[];
  var from = 0;
  while (true) {
    final int start = source.indexOf('ctx.actions.run(', from);
    if (start < 0) return calls;
    var depth = 0;
    int end = start + 'ctx.actions.run'.length;
    do {
      final String c = source[end++];
      depth += c == '(' ? 1 : (c == ')' ? -1 : 0);
    } while (depth > 0);
    calls.add(source.substring(start, end));
    from = end;
  }
}

void main() {
  group('tool targets', () {
    for (final String tool in _tools) {
      test('$tool is built as an exe', () {
        final String block = _binary(tool);
        final String own = block.substring(0, block.indexOf('\n)'));
        expect(own, contains('compile_mode = "exe"'));
        expect(own, isNot(contains('compile_mode = "kernel"')));
      });
    }
  });

  group('rule sources', () {
    final rules = Directory('${_root().path}/flutter/private');
    final sources = <String, String>{
      for (final f in rules.listSync().whereType<File>())
        if (f.path.endsWith('.bzl')) f.path: f.readAsStringSync(),
    };

    test('no action hands a tool to the Dart VM as its first argument', () {
      for (final MapEntry<String, String> e in sources.entries) {
        for (final String attr in _toolAttrs.values) {
          expect(
            e.value,
            isNot(contains('ctx.executable.$attr.path')),
            reason: '${e.key} passes $attr as a script path',
          );
        }
        expect(e.value, isNot(contains('run.kernel_filter_tool.path')));
      }
    });

    test('an action that executes a tool also declares it as an input', () {
      var seen = 0;
      for (final MapEntry<String, String> e in sources.entries) {
        for (final String call in _runCalls(e.value)) {
          for (final String attr in _toolAttrs.values) {
            final exe = 'executable = ctx.executable.$attr,';
            if (!call.contains(exe)) continue;
            seen++;
            // The input list is a literal naming the tool: inline or built
            // by a helper in the same file.
            expect(
              e.value,
              matches(RegExp('\\[[^\\]]*ctx\\.executable\\.$attr[^\\]]*\\]')),
              reason: '${e.key} runs $attr without declaring it as an input',
            );
          }
        }
      }
      expect(seen, greaterThan(10));
      final String compile = sources.entries
          .firstWhere((e) => e.key.endsWith('/flutter_compile.bzl'))
          .value;
      expect(compile, contains('executable = run.kernel_filter_tool,'));
      expect(compile, contains('run.dartaotruntime, run.kernel_filter_tool'));
    });
  });

  group('corpus action golden', () {
    final golden = <Map<String, dynamic>>[
      for (final a
          in (jsonDecode(_read('flutter/tests/corpus/actions.golden.json'))
                  as Map<String, dynamic>)['actions']
              as List<dynamic>)
        jsonDecode(a as String) as Map<String, dynamic>,
    ];

    test('tool actions run the executable and list it as an input', () {
      var seen = 0;
      for (final action in golden) {
        final List<String> args =
            (action['arguments'] as List<dynamic>? ?? <dynamic>[])
                .cast<String>();
        final List<String> inputs =
            (action['inputs'] as List<dynamic>? ?? <dynamic>[]).cast<String>();
        for (final String tool in _tools) {
          if (args.isEmpty || !args.first.endsWith('/private/tools/$tool')) {
            continue;
          }
          seen++;
          expect(inputs, contains(args.first), reason: '$tool is an input');
        }
        expect(
          args.where((a) => _tools.any((t) => a.endsWith('/tools/$t.dill'))),
          isEmpty,
          reason: '${action['mnemonic']} runs a tool kernel',
        );
      }
      expect(seen, greaterThan(10));
    });
  });
}
