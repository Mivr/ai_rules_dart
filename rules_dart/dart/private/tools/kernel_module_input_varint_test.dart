/// Tests that `WorkRequest.inputs` paths of 128 bytes or more, whose protobuf
/// length is a multi-byte varint, are decoded and enforced by
/// `kernel_module.dart`, and that `kernel_module_test.dart` keeps framing its
/// `Input` messages with the shared varint encoder.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

import 'kernel_module.dart'
    show
        ModuleCompiler,
        ModuleOutcome,
        compileModule,
        decodeKernelModuleWorkRequestInputs;
import 'worker_test_encode.dart'
    show encodeInputForTest, encodeWorkRequestForTest;

const String _prefix = 'org-dartlang-root:///';
const String _testName =
    'WorkRequest.inputs restricts which declared sources may be read and '
    'compiled';

/// A compiler that records each request's arguments and succeeds.
class _Recorder implements ModuleCompiler {
  final List<List<String>> calls = <List<String>>[];

  @override
  Future<ModuleOutcome> run(List<String> args, List<Uint8List> inputs) async {
    calls.add(args);
    return const ModuleOutcome(0, '');
  }

  @override
  Future<void> close() async {}
}

/// The outcome of one [compileModule] call.
class _Outcome {
  new(this.code, this.log, this.calls);

  final int code;
  final String log;
  final List<List<String>> calls;
}

/// Creates a temporary directory whose `pkg/test/main_test.dart` path is at
/// least 140 UTF-8 bytes, nesting short segments however long the temp root is.
Directory _longRoot() {
  final Directory top = Directory.systemTemp.createTempSync('kmod_varint_');
  addTearDown(() => top.deleteSync(recursive: true));
  final int missing =
      140 - utf8.encode('${top.path}/pkg/test/main_test.dart').length;
  final String path = <String>[
    top.path,
    for (var i = 0; i * 41 < missing; i++) 'd' * 40,
  ].join('/');
  return Directory(path)..createSync(recursive: true);
}

void _write(Directory root, String relative, String text) {
  final file = File('${root.path}/$relative');
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(text);
}

/// Writes the module fixture under [root] and compiles `main_test.dart` with
/// `web.dart` declared on the command line and [inputs] as the request inputs.
Future<_Outcome> _compile(Directory root, List<Uint8List> inputs) async {
  _write(
    root,
    'package_config.json',
    jsonEncode(<String, Object>{
      'configVersion': 2,
      'packages': <Object>[
        <String, String>{
          'name': 'pkg',
          'rootUri': '${_prefix}pkg',
          'packageUri': 'lib/',
        },
      ],
    }),
  );
  _write(
    root,
    'libraries.json',
    jsonEncode(<String, Object>{
      'vm': <String, Object>{
        'libraries': <String, Object>{'core': <String, Object>{}},
      },
    }),
  );
  _write(root, 'pkg/lib/web.dart', 'class Web {}\n');
  _write(root, 'pkg/test/main_test.dart', "import 'package:pkg/web.dart';\n");
  _write(
    root,
    'excludes/index.json',
    jsonEncode(<String, Object>{'version': 1, 'sccs': <Object>[]}),
  );
  _write(
    root,
    'excludes.vm_excluded.txt',
    '${_prefix}pkg/lib/web.dart\tdart:html is not a VM library\n',
  );
  final String base = root.path;
  final recorder = _Recorder();
  final log = StringBuffer();
  final int code = await compileModule(
    <String>[
      '--source', '${_prefix}pkg/test/main_test.dart', //
      '--own-source-file', '$base/pkg/test/main_test.dart',
      '--input-source', 'pkg/lib/web.dart',
      '--output', '$base/out/m',
      '--excluded-output', '$base/out/m.vm_excluded.txt',
      '--packages-file', '$base/package_config.json',
      '--libraries-json', '$base/libraries.json',
      '--multi-root', base,
      '--target', 'vm',
      '--no-drop',
      '--input-kmod', '$base/excludes',
      '--closure-excluded', '$base/excludes.vm_excluded.txt',
    ],
    recorder,
    log,
    inputs,
  );
  return _Outcome(code, log.toString(), recorder.calls);
}

/// The `path` of one encoded `blaze.worker.Input`: tag, varint length, bytes.
String _pathOf(Uint8List input) {
  var offset = 1;
  var length = 0;
  for (var shift = 0; ; shift += 7) {
    final int byte = input[offset++];
    length |= (byte & 0x7f) << shift;
    if (byte < 0x80) {
      break;
    }
  }
  return utf8.decode(input.sublist(offset, offset + length));
}

/// Whether [source] has no raw one-byte `Input` length framing and its
/// [_testName] test delegates `encodeInput` to `encodeInputForTest`.
bool _framesInputsWithVarint(String source) {
  final int start = source.indexOf(_testName);
  if (start < 0 || RegExp(r'\[\s*0x0a\s*,\s*\w+\.length').hasMatch(source)) {
    return false;
  }
  final int end = source.indexOf('\n  test(', start);
  final String body = source.substring(start, end < 0 ? source.length : end);
  return RegExp(r'encodeInput\(String \w+\)\s*=>\s*encodeInputForTest\(')
      .hasMatch(body);
}

void main(List<String> args) {
  test(
    'declared inputs with 2-byte varint path lengths are enforced',
    () async {
      final Directory root = _longRoot();
      final mainPath = '${root.path}/pkg/test/main_test.dart';
      final webPath = '${root.path}/pkg/lib/web.dart';
      expect(utf8.encode(mainPath).length, greaterThanOrEqualTo(140));
      expect(utf8.encode(webPath).length, greaterThanOrEqualTo(140));
      Uint8List input(String p) => encodeInputForTest(p, Uint8List(0));

      final _Outcome missing = await _compile(root, <Uint8List>[
        input(mainPath),
      ]);
      expect(missing.code, 1);
      expect(missing.log, contains('source is not a declared input.'));

      final _Outcome declared = await _compile(root, <Uint8List>[
        input(mainPath),
        input(webPath),
      ]);
      expect(declared.code, 0);
      final sources = <String>[
        for (final List<String> call in declared.calls)
          for (var i = 0; i + 1 < call.length; i++)
            if (call[i] == '--source') call[i + 1],
      ];
      expect(sources, contains('${_prefix}pkg/test/main_test.dart'));
      expect(sources, contains('package:pkg/web.dart'));
    },
  );

  for (final length in <int>[128, 16384]) {
    test('a $length byte input path round-trips through the decoder', () {
      final String path = 'p' * length;
      final Uint8List request = encodeWorkRequestForTest(
        arguments: <String>[],
        inputs: <String, Uint8List>{path: Uint8List(0)},
      );
      final List<Uint8List> inputs = decodeKernelModuleWorkRequestInputs(
        request,
      );
      expect(inputs, hasLength(1));
      expect(_pathOf(inputs.single), path);
    });
  }

  test('kernel_module_test.dart frames inputs with the varint encoder', () {
    final String source = File(Runfiles.create().rlocation(args.first))
        .readAsStringSync();
    expect(source, contains(_testName));
    expect(_framesInputsWithVarint(source), isTrue);
  });

  test(
    'the source guard rejects raw length framing and accepts delegation',
    () {
      const head = "test('$_testName', () async {\n";
      const raw =
          '$head  Uint8List encodeInput(String path) {\n'
          '    final pathBytes = utf8.encode(path);\n'
          '    return Uint8List.fromList([0x0a, pathBytes.length, ...pathBytes]);\n'
          '  }\n});\n';
      const delegated =
          '$head  Uint8List encodeInput(String p) => '
          'encodeInputForTest(p, Uint8List(0));\n});\n';
      expect(_framesInputsWithVarint(raw), isFalse);
      expect(_framesInputsWithVarint(delegated), isTrue);
      expect(_framesInputsWithVarint('// no such test'), isFalse);
    },
  );
}
