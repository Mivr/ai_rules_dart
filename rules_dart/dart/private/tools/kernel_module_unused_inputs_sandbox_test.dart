// Tests that `kernel_module.dart`'s unused-inputs list is the same whether the
// compile runs in the execroot or in a directory- or leaf-symlinked sandbox, and
// that physical `file:` source-table URIs it cannot map still veto the list.
// The compiler is a fake that writes a source-table-only `.dill`.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'dill_outline.dart' show Tag;
import 'kernel_module.dart' show ModuleCompiler, ModuleOutcome, compileModule;

/// A compiler that reports no used inputs and writes [dillBytes] to each
/// request's `--output`.
class _ReportingCompiler implements ModuleCompiler {
  new({required this.dillBytes});

  final Uint8List Function() dillBytes;

  @override
  Future<ModuleOutcome> run(List<String> args, List<Uint8List> inputs) async {
    final String? used = _flagValue(args, '--used-inputs');
    if (used != null) {
      final usedFile = File(used);
      await usedFile.parent.create(recursive: true);
      await usedFile.writeAsString('');
    }
    await File(_flagValue(args, '--output')!).writeAsBytes(dillBytes());
    return const ModuleOutcome(0, '');
  }

  @override
  Future<void> close() async {}
}

String? _flagValue(List<String> args, String flag) {
  final int index = args.indexOf(flag);
  if (index >= 0 && index + 1 < args.length) {
    return args[index + 1];
  }
  for (final arg in args) {
    if (arg.startsWith('$flag=')) {
      return arg.substring(flag.length + 1);
    }
  }
  return null;
}

/// A kernel component holding only a source table of [uris] (empty source code,
/// line starts, import URI and coverage) and the trailer index the reader needs.
Uint8List _buildDillWithUris(List<String> uris) {
  final bytes = <int>[];
  void u32(int value) =>
      bytes.addAll(<int>[for (int s = 24; s >= 0; s -= 8) (value >> s) & 0xff]);
  void str(String value) {
    final List<int> encoded = utf8.encode(value);
    final int n = encoded.length;
    bytes.addAll(n < 0x80 ? <int>[n] : <int>[0x80 | (n >> 8), n & 0xff]);
    bytes.addAll(encoded);
  }

  u32(Tag.ComponentFile);
  u32(Tag.BinaryFormatVersion);
  bytes.addAll(List<int>.filled(64, 0));
  final int sourceTable = bytes.length;
  u32(uris.length);
  for (final uri in uris) {
    str(uri);
    str('');
    bytes.add(0);
    str('');
    bytes.add(0);
  }
  final int constantTable = bytes.length;
  bytes.add(0);
  u32(sourceTable);
  u32(constantTable);
  for (var i = 0; i < 8; i++) {
    u32(constantTable);
  }
  u32(0); // libraryCount
  u32(bytes.length + 4);
  return Uint8List.fromList(bytes);
}

typedef _SandboxFixture = ({
  Directory execroot,
  Directory dirSandbox,
  Directory leafSandbox,
  File outsideFile,
  List<String> ownPhysicalUris,
});

typedef _SandboxRun = ({
  Directory cwd,
  String tag,
  List<String> dillUris,
  List<String> kmods,
  List<String> inputSources,
  bool noDrop,
});

void _writeExecFile(Directory root, String rel, String content) {
  final file = File('${root.path}/$rel');
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(content);
}

void _writeExecKoutline(Directory execroot, String name, String key) {
  final dir = 'bazel-out/k8-fastbuild/bin/$name.koutline';
  _writeExecFile(
    execroot,
    '$dir/index.json',
    jsonEncode(<String, Object>{
      'version': 1,
      'sccs': <Map<String, Object>>[
        <String, Object>{
          'dill': '$name.dill',
          'defines': <String>[key],
          'imports': <String>[],
        },
      ],
    }),
  );
  _writeExecFile(execroot, '$dir/$name.dill', '');
}

void _mirrorLeafLinks(Directory src, Directory dst, [String rel = '']) {
  for (final FileSystemEntity entity in src.listSync(followLinks: false)) {
    final String name = entity.path.replaceAll(r'\', '/').split('/').last;
    final childRel = rel.isEmpty ? name : '$rel/$name';
    if (entity is Directory) {
      Directory('${dst.path}/$childRel').createSync(recursive: true);
      _mirrorLeafLinks(entity, dst, childRel);
    } else if (entity is File) {
      final link = Link('${dst.path}/$childRel');
      link.parent.createSync(recursive: true);
      link.createSync(entity.path);
    }
  }
}

_SandboxFixture _createSandboxFixture(Directory root) {
  final String realRoot = root.resolveSymbolicLinksSync();
  final execroot = Directory('$realRoot/execroot')..createSync(recursive: true);
  final dirSandbox = Directory('$realRoot/dir_sandbox')
    ..createSync(recursive: true);
  final leafSandbox = Directory('$realRoot/leaf_sandbox')
    ..createSync(recursive: true);
  final outsideFile = File('$realRoot/outside/foreign.dart')
    ..parent.createSync(recursive: true)
    ..writeAsStringSync('class Foreign {}\n');

  _writeExecFile(execroot, 'pkg/lib/a.dart', 'class A {}\n');
  _writeExecFile(
    execroot,
    'bazel-out/k8-fastbuild/bin/pkg/lib/a.g.dart',
    '// generated\nclass AGen {}\n',
  );
  _writeExecFile(execroot, 'dep/lib/dep.dart', 'class Dep {}\n');
  _writeExecFile(execroot, 'emb/lib/e.dart', 'const int kEmb = 1;\n');
  _writeExecKoutline(execroot, 'dep', 'dep/lib/dep.dart');
  _writeExecKoutline(execroot, 'embedded', 'emb/lib/e.dart');
  _writeExecFile(
    execroot,
    'package_config.json',
    jsonEncode(<String, Object>{
      'configVersion': 2,
      'packages': <Map<String, String>>[
        for (final pkg in <String>['pkg', 'dep', 'emb'])
          <String, String>{'name': pkg, 'rootUri': pkg, 'packageUri': 'lib/'},
      ],
    }),
  );
  _writeExecFile(
    execroot,
    'libraries.json',
    jsonEncode(<String, Object>{
      'vm': <String, Object>{'libraries': <String, Object>{}},
    }),
  );

  for (final FileSystemEntity entity in execroot.listSync(followLinks: false)) {
    final String name = entity.path.replaceAll(r'\', '/').split('/').last;
    Link('${dirSandbox.path}/$name').createSync(entity.path);
  }
  _mirrorLeafLinks(execroot, leafSandbox);

  return (
    execroot: execroot,
    dirSandbox: dirSandbox,
    leafSandbox: leafSandbox,
    outsideFile: outsideFile,
    ownPhysicalUris: <String>[
      Uri.file('${execroot.path}/pkg/lib/a.dart').toString(),
      Uri.file('${execroot.path}/bazel-out/k8-fastbuild/bin/pkg/lib/a.g.dart')
          .toString(),
    ],
  );
}

/// The `compileModule` arguments of [run], writing its output at [outPrefix].
List<String> _compileArgs(
  _SandboxRun run,
  String outPrefix,
  String unusedRel,
) => <String>[
  '--source',
  'org-dartlang-root:///pkg/lib/a.dart',
  '--input-source',
  'pkg/lib/a.dart',
  '--own-source-file',
  'pkg/lib/a.dart',
  '--source',
  'org-dartlang-root:///pkg/lib/a.g.dart',
  '--input-source',
  'bazel-out/k8-fastbuild/bin/pkg/lib/a.g.dart',
  '--own-source-file',
  'bazel-out/k8-fastbuild/bin/pkg/lib/a.g.dart',
  for (final src in run.inputSources) ...<String>['--input-source', src],
  '--output',
  outPrefix,
  '--unused-inputs-list',
  unusedRel,
  '--excluded-output',
  '$outPrefix.vm_excluded.txt',
  '--packages-file',
  'package_config.json',
  '--libraries-json',
  'libraries.json',
  '--multi-root',
  '.',
  '--multi-root',
  'bazel-out/k8-fastbuild/bin',
  '--multi-root-scheme',
  'org-dartlang-root',
  '--target',
  'vm',
  if (run.noDrop) '--no-drop',
  for (final kmod in run.kmods) ...<String>['--input-kmod', kmod],
];

Future<_Outcome> _runInSandboxDir(_SandboxRun run) async {
  final compiler = _ReportingCompiler(
    dillBytes: () => _buildDillWithUris(run.dillUris),
  );
  final outPrefix = 'bazel-out/k8-fastbuild/bin/pkg/mod_${run.tag}';
  final unusedRel = '$outPrefix.unused_inputs';
  final Directory previous = Directory.current;
  Directory.current = run.cwd.path;
  try {
    final int code = await compileModule(
      _compileArgs(run, outPrefix, unusedRel),
      compiler,
      StringBuffer(),
      const <Uint8List>[],
    );
    final unusedFile = File(unusedRel);
    return (
      code: code,
      unusedLines: unusedFile.existsSync()
          ? unusedFile.readAsLinesSync()
          : null,
    );
  } finally {
    Directory.current = previous;
  }
}

typedef _Outcome = ({int code, List<String>? unusedLines});

Future<_Outcome> _runIn(
  Directory cwd,
  String tag,
  List<String> dillUris,
  List<String> kmods, {
  List<String> inputSources = const <String>[],
  bool noDrop = false,
}) => _runInSandboxDir((
  cwd: cwd,
  tag: tag,
  dillUris: dillUris,
  kmods: kmods,
  inputSources: inputSources,
  noDrop: noDrop,
));

String _fileUri(Directory dir, String rel) =>
    Uri.file('${dir.path}/$rel').toString();

const _depKmod = 'bazel-out/k8-fastbuild/bin/dep.koutline';
const _bothKmods = <String>[
  'bazel-out/k8-fastbuild/bin/embedded.koutline',
  _depKmod,
];

void _defineParityTest(Directory Function() root) {
  test('physical file: source-table URIs produce identical unused inputs in execroot and symlinked sandboxes', () async {
    final _SandboxFixture fixture = _createSandboxFixture(root());
    const kmods = <String>[_depKmod];
    final List<String> uris = fixture.ownPhysicalUris;
    final _Outcome execRun = await _runIn(
      fixture.execroot,
      'exec',
      uris,
      kmods,
    );
    final _Outcome dirRun = await _runIn(
      fixture.dirSandbox,
      'dir_sand',
      uris,
      kmods,
    );
    final _Outcome leafRun = await _runIn(
      fixture.leafSandbox,
      'leaf_sand',
      uris,
      kmods,
    );

    expect(execRun.code, 0);
    expect(dirRun.code, 0);
    expect(leafRun.code, 0);
    expect(execRun.unusedLines, kmods);
    expect(dirRun.unusedLines, execRun.unusedLines);
    expect(leafRun.unusedLines, execRun.unusedLines);
  });
}

/// Positive control in the leaf-symlinked sandbox: an embedded physical `file:`
/// URI keeps its defining `.koutline` while the untouched `.koutline` is still
/// listed. Fails on the base, and fails if the source-table evidence veto is
/// dropped.
Future<void> _expectEmbeddedKept(_SandboxFixture fixture) async {
  final _Outcome embeddedKeep = await _runIn(
    fixture.leafSandbox,
    'ctrl_keep',
    <String>[
      ...fixture.ownPhysicalUris,
      _fileUri(fixture.execroot, 'emb/lib/e.dart'),
    ],
    _bothKmods,
  );
  expect(embeddedKeep.code, 0);
  expect(embeddedKeep.unusedLines, <String>[_depKmod]);
}

/// Entry control: an unplanned dependency `file:` URI vetoes listing
/// `--input-source` dependency files (0-byte unused list, exit 0).
Future<void> _expectUnplannedEntryVeto(_SandboxFixture fixture) async {
  final _Outcome unplannedEntry = await _runIn(
    fixture.dirSandbox,
    'ctrl_entry',
    <String>[
      ...fixture.ownPhysicalUris,
      _fileUri(fixture.execroot, 'dep/lib/dep.dart'),
    ],
    const <String>[_depKmod],
    inputSources: const <String>['dep/lib/dep.dart', 'emb/lib/e.dart'],
    noDrop: true,
  );
  expect(unplannedEntry.code, 0);
  expect(unplannedEntry.unusedLines, isEmpty);
}

/// An undeclared workspace source and an outside-all-roots source both veto.
Future<void> _expectBadSourcesVeto(_SandboxFixture fixture) async {
  for (final (String tag, String badUri) in <(String, String)>[
    ('ctrl_undeclared', _fileUri(fixture.execroot, 'pkg/lib/undeclared.dart')),
    ('ctrl_outside', Uri.file(fixture.outsideFile.path).toString()),
  ]) {
    final _Outcome vetoed = await _runIn(fixture.dirSandbox, tag, <String>[
      ...fixture.ownPhysicalUris,
      badUri,
    ], _bothKmods);
    expect(vetoed.code, isNot(0), reason: tag);
    expect(vetoed.unusedLines ?? const <String>[], isEmpty, reason: tag);
  }
}

void _defineVetoTest(Directory Function() root) {
  test('undeclared and unmapped physical file: URIs still veto unused inputs under a symlinked working directory', () async {
    final _SandboxFixture fixture = _createSandboxFixture(root());
    await _expectEmbeddedKept(fixture);
    await _expectUnplannedEntryVeto(fixture);
    await _expectBadSourcesVeto(fixture);
  });
}

void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('kmod_sandbox_'));
  tearDown(() => root.deleteSync(recursive: true));

  group('unused inputs list', () {
    _defineParityTest(() => root);
    _defineVetoTest(() => root);
  });
}
