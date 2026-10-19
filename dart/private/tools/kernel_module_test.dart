// Tests the planner of `kernel_module.dart`: which sources a module compiles, which it
// excludes and why, and what each compile is given. The compiler is a recorder, so no
// `kernel_worker` runs. The planner decides before it compiles, so nothing else is
// needed.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

import 'dill_outline.dart'
    show Tag, stripDillToOutline, supportedKernelFormatVersions;
import 'kernel_link.dart'
    show KernelLinkCache, decodeKernelLinkWorkRequestInputs, linkOne;
import 'kernel_module.dart'
    show
        KernelModuleCache,
        ModuleCompiler,
        ModuleOutcome,
        compileModule,
        decodeKernelModuleWorkRequestInputs,
        decodeUriSegment,
        defaultMultiRootPrefix,
        dillSourceUris,
        ensureSummaryDigests,
        findDisallowedDirectives,
        isDisallowedDirectiveUri,
        isFileSchemeDirectiveUri,
        isWindowsDrivePath,
        kernelWorkerArgs,
        kernelWorkerUri,
        patchSnapshotSplitCommas,
        resolveDirectiveUri,
        scanAllDirectiveUris,
        scanDirectives,
        sha256Of,
        stripSourceCodeFromDill,
        vmLibraries;

const _prefix = 'org-dartlang-root:///';

late List<String> _sdkDartPaths;

/// The test's files: sources, module directories and sidecars, and the configs.
late Directory _root;

/// A compiler that records each request's arguments and succeeds.
class _Recorder implements ModuleCompiler {
  final List<List<String>> calls = [];

  @override
  Future<ModuleOutcome> run(List<String> args, List<Uint8List> inputs) async {
    calls.add(args);
    return const ModuleOutcome(0, '');
  }

  @override
  Future<void> close() async {}
}

class _ProcessModuleCompiler implements ModuleCompiler {
  _ProcessModuleCompiler(this.dartaotruntime, this.kernelWorker);

  final String dartaotruntime;
  final String kernelWorker;

  @override
  Future<ModuleOutcome> run(List<String> args, List<Uint8List> inputs) async {
    final res = await Process.run(dartaotruntime, [kernelWorker, ...args]);
    return ModuleOutcome(res.exitCode, '${res.stdout}${res.stderr}');
  }

  @override
  Future<void> close() async {}
}

/// A compiler that writes [dillBytes] to each request's `--output` and succeeds,
/// so the read-set verification has a dill to check.
class _DillWritingCompiler implements ModuleCompiler {
  _DillWritingCompiler(this.dillBytes);

  final Uint8List Function() dillBytes;
  final List<List<String>> calls = [];

  @override
  Future<ModuleOutcome> run(List<String> args, List<Uint8List> inputs) async {
    calls.add(args);
    final outIdx = args.indexOf('--output');
    await File(args[outIdx + 1]).writeAsBytes(dillBytes());
    return const ModuleOutcome(0, '');
  }

  @override
  Future<void> close() async {}
}

/// A compiler that simulates `kernel_worker --used-inputs`: it writes
/// [reported] to each request's `--used-inputs` file as `file://` URIs, like
/// the worker, writes [dillBytes] to each request's `--output` when set, and
/// answers [exitCode]. A null [reported] writes no file, so the planner's
/// passed summaries count as used.
class _ReportingCompiler implements ModuleCompiler {
  _ReportingCompiler({this.reported, this.dillBytes, this.exitCode = 0});

  final Set<String>? reported;
  final Uint8List Function()? dillBytes;
  final int exitCode;
  final List<List<String>> calls = [];

  @override
  Future<ModuleOutcome> run(List<String> args, List<Uint8List> inputs) async {
    calls.add(args);
    String? usedPath;
    for (var i = 0; i < args.length; i++) {
      if (args[i].startsWith('--used-inputs=')) {
        usedPath = args[i].substring('--used-inputs='.length);
      } else if (args[i] == '--used-inputs' && i + 1 < args.length) {
        usedPath = args[++i];
      }
    }
    if (usedPath != null && reported != null) {
      final path = usedPath.startsWith('file://')
          ? Uri.parse(usedPath).toFilePath()
          : usedPath;
      await File(path)
          .writeAsString([for (final p in reported!) 'file://$p\n'].join());
    }
    final outIdx = args.indexOf('--output');
    if (exitCode == 0 && dillBytes != null) {
      await File(args[outIdx + 1]).writeAsBytes(dillBytes!());
    }
    return ModuleOutcome(exitCode, '');
  }

  @override
  Future<void> close() async {}
}

/// A compiler whose worker predates `--used-inputs`: it fails each request
/// that passes the flag with the `package:args` unknown-option error, and
/// succeeds without it.
class _OldWorkerCompiler implements ModuleCompiler {
  final List<List<String>> calls = [];

  @override
  Future<ModuleOutcome> run(List<String> args, List<Uint8List> inputs) async {
    calls.add(args);
    if (args.any((arg) => arg.startsWith('--used-inputs'))) {
      return const ModuleOutcome(
        64,
        'Could not find an option named "used-inputs".',
      );
    }
    return const ModuleOutcome(0, '');
  }

  @override
  Future<void> close() async {}
}

/// The values that follow each `flag` in `args`, in order.
List<String> _valuesAfter(List<String> args, String flag) => [
  for (var i = 0; i + 1 < args.length; i++)
    if (args[i] == flag) args[i + 1],
];

/// A module's directory, which holds its `index.json`.
class _Scc {
  _Scc(this.dill, this.defines, this.imports);

  final String dill;
  final List<String> defines;
  final List<String> imports;
}

/// The outcome of one planned compile.
class _Result {
  _Result(this.code, this.calls, this.sidecar, this.index, [this.log = '']);

  final int code;
  final List<List<String>> calls;
  final String sidecar;
  final Map<String, dynamic> index;
  final String log;

  /// The excluded sources, by URI, with the reason each is excluded.
  Map<String, String> get excluded => {
    for (final line in const LineSplitter().convert(sidecar))
      if (line.isNotEmpty && !line.startsWith('#'))
        line.split('\t').first: line.split('\t').last,
  };

  /// The `defines` of each kernel the module wrote, in order.
  List<List<String>> get defines => [
    for (final scc in (index['sccs'] as List).cast<Map<String, dynamic>>())
      (scc['defines'] as List).cast<String>(),
  ];

  /// The `--source` URIs of each compile, in order.
  List<List<String>> get sourcesPerCall => [
    for (final call in calls) _valuesAfter(call, '--source'),
  ];
}

String _uri(String key) => '$_prefix$key';

void _write(String relative, String text) {
  final file = File('${_root.path}/$relative');
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(text);
}

/// Writes a dependency module directory with `sccs`, and returns its path.
String _module(String name, List<_Scc> sccs) {
  _write(
    '$name/index.json',
    jsonEncode({
      'version': 1,
      'sccs': [
        for (final scc in sccs)
          {'dill': scc.dill, 'defines': scc.defines, 'imports': scc.imports},
      ],
    }),
  );
  return '${_root.path}/$name';
}

/// Writes the `.vm_excluded.txt` sidecar of a module, with `excluded` as its sources.
String _sidecar(String name, Map<String, String> excluded) {
  final lines = [
    for (final entry in excluded.entries) '${_uri(entry.key)}\t${entry.value}',
  ];
  _write('$name.vm_excluded.txt', lines.map((line) => '$line\n').join());
  return '${_root.path}/$name.vm_excluded.txt';
}

/// Plans and compiles one module named `name` from `sources`, which are keys under the
/// test's root (`pkg/lib/a.dart`). Returns what it wrote and what it asked the compiler.
Future<_Result> _compile(
  String name,
  List<String> sources, {
  List<String> inputSources = const [],
  List<String> inputKmods = const [],
  List<String> closureExcluded = const [],
  bool noDrop = false,
  String? outputOutline,
  String? scheme,
  String? librariesPlatform,
  List<String> extraLibraries = const [],
  String? packagesFile,
  List<Uint8List> inputs = const [],
  ModuleCompiler? compiler,
  // When set, passes `--unused-inputs-list` with this path and returns what
  // was written there (or null when the compile wrote nothing).
  String? unusedInputsList,
}) async {
  final output = '${_root.path}/out/$name';
  final excludedPath = '$output.vm_excluded.txt';
  final prefix = scheme == null ? _prefix : '$scheme:///';
  final args = <String>[
    for (final source in sources) ...['--source', '$prefix$source'],
    for (final source in sources) ...[
      '--own-source-file',
      '${_root.path}/$source',
    ],
    for (final inputSource in inputSources) ...['--input-source', inputSource],
    '--output',
    output,
    if (unusedInputsList != null) ...['--unused-inputs-list', unusedInputsList],
    if (outputOutline != null) ...['--output-outline', outputOutline],
    '--excluded-output',
    excludedPath,
    '--packages-file',
    packagesFile ?? '${_root.path}/package_config.json',
    '--libraries-json',
    '${_root.path}/libraries.json',
    if (librariesPlatform != null) ...[
      '--libraries-platform',
      librariesPlatform,
    ],
    for (final lib in extraLibraries) ...['--extra-library', lib],
    '--multi-root',
    _root.path,
    if (scheme != null) ...['--multi-root-scheme', scheme],
    '--target',
    'vm',
    if (noDrop) '--no-drop',
    for (final dir in inputKmods) ...['--input-kmod', dir],
    for (final sidecar in closureExcluded) ...['--closure-excluded', sidecar],
  ];
  final recorder = _Recorder();
  final log = StringBuffer();
  final code = await compileModule(args, compiler ?? recorder, log, inputs);
  final written = code == 0
      ? jsonDecode(File('$output/index.json').readAsStringSync())
            as Map<String, dynamic>
      : <String, dynamic>{'sccs': <dynamic>[]};
  final calls = compiler is _DillWritingCompiler
      ? compiler.calls
      : recorder.calls;
  return _Result(
    code,
    calls,
    code == 0 ? File(excludedPath).readAsStringSync() : '',
    written,
    log.toString(),
  );
}

Uint8List _buildMinimalFieldDill({
  int formatVersion = Tag.BinaryFormatVersion,
  int languageMajor = 3,
  bool hasConstConstructor = true,
}) {
  final out = BytesBuilder();
  void u30(int v) {
    assert(v >= 0 && v < 0x80);
    out.addByte(v);
  }

  void u32(int v) {
    out.addByte((v >> 24) & 0xff);
    out.addByte((v >> 16) & 0xff);
    out.addByte((v >> 8) & 0xff);
    out.addByte(v & 0xff);
  }

  // 18-byte header + problemsAsJson (UInt30(0))
  u32(Tag.ComponentFile);
  u32(formatVersion);
  for (var i = 0; i < 10; i++) {
    out.addByte(0);
  }
  u30(0);

  final libStart = out.length;
  out.addByte(0); // flags
  u30(languageMajor); // major
  u30(0); // minor
  u30(1); // canonicalName
  u30(1); // name
  u30(0); // fileUri
  u30(0); // problemsAsJson
  u30(0); // annotations
  u30(0); // depCount
  u30(0); // expCount
  u30(0); // partCount
  u30(0); // tdCount
  u30(1); // clsCount = 1

  final clsStart = out.length;
  out.addByte(Tag.Class);
  u30(1); // canonicalName
  u30(0); // fileUri
  u30(0);
  u30(0);
  u30(0); // 3 offsets
  u30(0); // flags (not a mixin)
  u30(1); // name
  u30(0); // annotations
  u30(0); // typeParameters
  out.addByte(Tag.Nothing); // supertype
  out.addByte(Tag.Nothing); // mixedInType
  u30(0); // implementedTypes

  // 3 fields: (flags=1 final instance, val=42), (flags=5 static final, val=99), (flags=0 mutable, val=77)
  u30(3);
  for (final (flags, val) in [(1, 42), (5, 99), (0, 77)]) {
    out.addByte(Tag.Field);
    u30(1);
    u30(1);
    u30(0); // 3 canonRefs
    u30(0); // uriRef
    u30(0);
    u30(0); // 2 offsets
    u30(flags);
    u30(1); // name ("f")
    u30(0); // scopeSize
    u30(0); // annotations
    out.addByte(Tag.DynamicType);
    out.addByte(Tag.Nothing); // option variable
    out.addByte(Tag.Something); // option expression
    out.addByte(Tag.PositiveIntLiteral);
    u30(0); // fileOffset
    u30(val);
    out.addByte(Tag.Nothing); // option scope
  }
  if (hasConstConstructor) {
    u30(1); // ctorCount = 1
    out.addByte(Tag.Constructor);
    u30(1); // canonicalName
    u30(0); // fileUri
    u30(0);
    u30(0);
    u30(0); // 3 offsets
    out.addByte(1); // flags = 1 (isConst)
    u30(1); // name ("f")
    u30(0); // annotations
    out.addByte(Tag.FunctionNode);
    u30(0);
    u30(0); // 2 offsets
    out.addByte(0); // asyncMarker
    out.addByte(0); // dartAsyncMarker
    u30(0); // scopeSize
    u30(0); // typeParameters
    out.addByte(Tag.Nothing); // thisVariable
    u30(0); // totalParameterCount
    u30(0); // requiredParameterCount
    u30(0); // posCount
    u30(0); // namedCount
    out.addByte(Tag.DynamicType); // returnType
    out.addByte(Tag.Nothing); // futureValueType
    out.addByte(0); // rftTag
    out.addByte(Tag.Nothing); // body Option<Statement>
    out.addByte(Tag.Nothing); // option scope
    out.addByte(Tag.Nothing); // option captured contexts
    u30(0); // initCount
  } else {
    u30(0); // ctorCount = 0
  }
  u30(0); // pCount = 0
  final clsProcEnd = out.length;
  u32(clsProcEnd);
  u32(0); // procCount = 0
  final clsEnd = out.length;

  u30(0); // extCount
  u30(0); // extTypeCount
  u30(0); // fieldCount
  u30(2); // pCount = 2
  final procOffsets = <int>[];
  for (final (flags, val) in [(9, 88), (1, 66)]) {
    procOffsets.add(out.length);
    out.addByte(Tag.Procedure);
    u30(1); // canonicalName
    u30(0); // fileUri
    u30(0);
    u30(0);
    u30(0); // 3 offsets
    out.addByte(0); // kind
    out.addByte(0); // stubKind
    u30(flags); // flags (9 = FlagStatic | FlagConst, 1 = FlagStatic)
    u30(1); // name ("f")
    u30(0); // annotations
    u30(0); // stubTarget
    out.addByte(Tag.Nothing); // signatureType
    out.addByte(Tag.FunctionNode);
    u30(0);
    u30(0); // 2 offsets
    out.addByte(0); // asyncMarker
    out.addByte(0); // dartAsyncMarker
    u30(0); // scopeSize
    u30(0); // typeParameters
    out.addByte(Tag.Nothing); // thisVariable
    u30(0); // totalParameterCount
    u30(0); // requiredParameterCount
    u30(0); // posCount
    u30(0); // namedCount
    out.addByte(Tag.DynamicType); // returnType
    out.addByte(Tag.Nothing); // futureValueType
    out.addByte(0); // rftTag
    out.addByte(Tag.Something); // body Option<Statement>
    out.addByte(Tag.ReturnStatement);
    u30(0); // fileOffset
    out.addByte(Tag.Something); // expression
    out.addByte(Tag.PositiveIntLiteral);
    u30(0); // fileOffset
    u30(val);
    out.addByte(Tag.Nothing); // option scope
    out.addByte(Tag.Nothing); // option captured contexts
  }
  final libProcEnd = out.length;
  procOffsets.add(libProcEnd);
  final sourceRefsOffset = out.length;
  u30(0); // usedCount = 0
  u32(sourceRefsOffset);
  u32(clsStart);
  u32(clsEnd);
  u32(1); // classCount = 1
  for (final off in procOffsets) {
    u32(off);
  }
  u32(2); // procCount = 2
  final libEnd = out.length;

  // Source table
  final sourceTableOffset = libEnd;
  u32(1); // uriCount = 1
  final uriEntry0 = out.length;
  u30(0); // uriLen
  u30(0); // srcLen
  u30(0); // lineCount
  u30(0); // impLen
  u30(0); // covCount
  u32(uriEntry0);

  // Constant table
  final constantTableOffset = out.length;
  u30(0); // constCount = 0
  final constantTableIndexOffset = out.length;
  u32(0); // constCount = 0

  // Link table
  final linkTableOffset = out.length;
  u30(1); // canonCount = 1
  u30(0); // parent
  u30(1); // string index 1

  // Metadata
  final metaOffset = out.length;
  u32(0);

  // String table: ["", "f"]
  final stringTableOffset = out.length;
  u30(2);
  u30(0);
  u30(1);
  out.addByte(102); // "f"

  // Component index
  final componentIndexOffset = out.length;
  u32(sourceTableOffset);
  u32(constantTableOffset);
  u32(constantTableIndexOffset);
  u32(linkTableOffset);
  u32(metaOffset);
  u32(metaOffset);
  u32(stringTableOffset);
  u32(componentIndexOffset);
  u32(0); // mainMethodReference
  u32(libStart);
  u32(libEnd);
  u32(1); // libraryCount = 1
  u32(out.length + 4);
  return out.toBytes();
}

/// A structurally valid kernel component whose source table holds exactly [uris]
/// (with empty source code, line starts, import URIs and coverage), for
/// read-set verification tests. The bytes between the header and the source
/// table are filler: the verifier reads only the source table and the trailer
/// index.
Uint8List _buildDillWithUris(
  List<String> uris, {
  int formatVersion = Tag.BinaryFormatVersion,
}) {
  final out = BytesBuilder();
  void u30(int v) {
    if (v < 0x80) {
      out.addByte(v);
    } else if (v < 0x4000) {
      out.addByte(0x80 | (v >> 8));
      out.addByte(v & 0xff);
    } else {
      out.addByte(0xc0 | ((v >> 24) & 0x3f));
      out.addByte((v >> 16) & 0xff);
      out.addByte((v >> 8) & 0xff);
      out.addByte(v & 0xff);
    }
  }

  void u32(int v) {
    out.addByte((v >> 24) & 0xff);
    out.addByte((v >> 16) & 0xff);
    out.addByte((v >> 8) & 0xff);
    out.addByte(v & 0xff);
  }

  void str(String s) {
    final bytes = utf8.encode(s);
    u30(bytes.length);
    out.add(bytes);
  }

  u32(Tag.ComponentFile);
  u32(formatVersion);
  out.add(List.filled(64, 0));
  final sourceTableOffset = out.length;
  u32(uris.length);
  for (final uri in uris) {
    str(uri);
    str('');
    u30(0);
    str('');
    u30(0);
  }
  final constantTableOffset = out.length;
  u30(0);
  u32(sourceTableOffset);
  u32(constantTableOffset);
  for (var i = 0; i < 8; i++) {
    u32(constantTableOffset);
  }
  u32(0); // libraryCount = 0
  u32(out.length + 4);
  return out.toBytes();
}

bool _containsSubsequence(Uint8List haystack, List<int> needle) {
  for (var i = 0; i <= haystack.length - needle.length; i++) {
    var match = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        match = false;
        break;
      }
    }
    if (match) return true;
  }
  return false;
}

void main(List<String> args) {
  if (args.isNotEmpty) {
    final r = Runfiles.create();
    _sdkDartPaths = [for (final a in args) r.rlocation(a)];
  } else {
    _sdkDartPaths = [Platform.resolvedExecutable];
  }
  setUp(() {
    _root = Directory.systemTemp.createTempSync('kernel_module_test_');
    _write(
      'package_config.json',
      jsonEncode({
        'configVersion': 2,
        'packages': [
          for (final name in ['pkg', 'dep'])
            {'name': name, 'rootUri': '$_prefix$name', 'packageUri': 'lib/'},
        ],
      }),
    );
    // A VM with `async`, `core` and `io`, and no `html`.
    _write(
      'libraries.json',
      jsonEncode({
        'vm': {
          'libraries': {'async': {}, 'core': {}, 'io': {}},
        },
      }),
    );
  });

  tearDown(() => _root.deleteSync(recursive: true));

  test('a library that imports only the VM compiles every source', () async {
    _write('pkg/lib/a.dart', "import 'dart:async';\nclass A {}\n");
    _write('pkg/lib/b.dart', "import 'a.dart';\nclass B {}\n");
    final result = await _compile('m', ['pkg/lib/a.dart', 'pkg/lib/b.dart']);
    expect(result.code, 0);
    expect(result.excluded, isEmpty);
    expect(result.defines, [
      ['pkg/lib/a.dart'],
      ['pkg/lib/b.dart'],
    ]);
  });

  test(
    'a file that imports a library the VM lacks excludes its importers',
    () async {
      _write('pkg/lib/web.dart', "import 'dart:html';\nclass Web {}\n");
      _write('pkg/lib/uses_web.dart', "import 'web.dart';\n");
      _write('pkg/lib/plain.dart', "import 'dart:io';\nclass Plain {}\n");
      final result = await _compile('m', [
        'pkg/lib/web.dart',
        'pkg/lib/uses_web.dart',
        'pkg/lib/plain.dart',
      ]);
      expect(result.code, 0);
      expect(result.excluded, {
        _uri('pkg/lib/web.dart'): 'dart:html is not a VM library',
        _uri('pkg/lib/uses_web.dart'):
            'imports ${_uri('pkg/lib/web.dart')}, which is excluded',
      });
      expect(result.defines, [
        ['pkg/lib/plain.dart'],
      ]);
    },
  );

  test('a file that imports a package the module does not have is excluded', () async {
    // `absent` is in no package config, as `json_annotation` is in no closure of
    // `_advanced_sources`.
    _write('pkg/lib/needs.dart', "import 'package:absent/absent.dart';\n");
    _write('pkg/lib/fine.dart', "import 'package:pkg/other.dart';\n");
    _write('pkg/lib/other.dart', 'class Other {}\n');
    final result = await _compile('m', [
      'pkg/lib/needs.dart',
      'pkg/lib/fine.dart',
      'pkg/lib/other.dart',
    ]);
    expect(result.code, 0);
    expect(result.excluded, {
      _uri(
        'pkg/lib/needs.dart',
      ): 'package:absent/absent.dart names a package this module does not have',
    });
    expect(result.defines, [
      ['pkg/lib/other.dart'],
      ['pkg/lib/fine.dart'],
    ]);
  });

  test(
    'a library whose part is not an input is excluded with its importers',
    () async {
      // `role.dart` declares a part that exists only on the wrapping library, as in
      // json_serializable's `_advanced_sources`.
      _write('pkg/lib/role.dart', "part 'role.g.dart';\nenum Role { a }\n");
      _write('pkg/lib/user.dart', "import 'role.dart';\n");
      _write('pkg/lib/extra.dart', 'class Extra {}\n');
      final result = await _compile('m', [
        'pkg/lib/role.dart',
        'pkg/lib/user.dart',
        'pkg/lib/extra.dart',
      ]);
      expect(result.code, 0);
      expect(result.excluded, {
        _uri('pkg/lib/role.dart'):
            'its part role.g.dart is not an input of this module',
        _uri('pkg/lib/user.dart'):
            'imports ${_uri('pkg/lib/role.dart')}, which is excluded',
      });
      expect(result.defines, [
        ['pkg/lib/extra.dart'],
      ]);
    },
  );

  test(
    'a library and its part compile together when both are inputs',
    () async {
      _write('pkg/lib/role.dart', "part 'role.g.dart';\nenum Role { a }\n");
      _write('pkg/lib/role.g.dart', "part of 'role.dart';\nconst kRole = 1;\n");
      final result = await _compile('m', [
        'pkg/lib/role.dart',
        'pkg/lib/role.g.dart',
      ]);
      expect(result.code, 0);
      expect(result.excluded, isEmpty);
      expect(result.defines, [
        ['pkg/lib/role.dart', 'pkg/lib/role.g.dart'],
      ]);
    },
  );

  test('a part whose parent library is not a declared input is excluded without reading the parent from disk', () async {
    // `role.dart` exists on disk under `_root`, but is NOT passed as `--source` or
    // `--input-source`. The module must exclude `role.g.dart` and `by_name.g.dart`
    // without invoking the compiler or reading `role.dart` from disk.
    _write(
      'pkg/lib/role.dart',
      "library my.role;\npart 'role.g.dart';\npart 'by_name.g.dart';\n",
    );
    _write('pkg/lib/role.g.dart', "part of 'role.dart';\nconst kRole = 1;\n");
    _write('pkg/lib/by_name.g.dart', 'part of my.role;\nconst kByName = 2;\n');
    _write('pkg/lib/plain.dart', 'class Plain {}\n');
    final result = await _compile('m', [
      'pkg/lib/role.g.dart',
      'pkg/lib/by_name.g.dart',
      'pkg/lib/plain.dart',
    ]);
    expect(result.code, 0);
    expect(result.excluded, {
      _uri('pkg/lib/role.g.dart'):
          'its library role.dart is not an input of this module',
      _uri('pkg/lib/by_name.g.dart'):
          'its library my.role is not an input of this module',
    });
    expect(result.defines, [
      ['pkg/lib/plain.dart'],
    ]);
    expect(result.sourcesPerCall, [
      [_uri('pkg/lib/plain.dart')],
    ], reason: 'excluded parts must not be passed to the compiler');
  });

  test('a split library and part compile together when the peer is a declared inputSource', () async {
    _write(
      'pkg/lib/parent.dart',
      "library my.parent;\npart 'uri_part.dart';\npart 'named_part.dart';\nint f() => a + b;\n",
    );
    _write('pkg/lib/uri_part.dart', "part of 'parent.dart';\nconst a = 1;\n");
    _write('pkg/lib/named_part.dart', 'part of my.parent;\nconst b = 2;\n');

    // Dependent owns the parts; parent is a declared `--input-source` and listed
    // in closureExcluded from the dependency target.
    final depParent = _module('dep_parent', []);
    final sidecarParent = _sidecar('dep_parent', {
      'pkg/lib/parent.dart':
          'its part uri_part.dart is not an input of this module',
    });
    final fromParts = await _compile(
      'from_parts',
      ['pkg/lib/uri_part.dart', 'pkg/lib/named_part.dart'],
      inputSources: ['pkg/lib/parent.dart'],
      inputKmods: [depParent],
      closureExcluded: [sidecarParent],
    );
    expect(fromParts.code, 0);
    expect(fromParts.excluded, isEmpty);
    expect(fromParts.defines, [
      [
        'pkg/lib/named_part.dart',
        'pkg/lib/parent.dart',
        'pkg/lib/uri_part.dart',
      ],
    ]);

    // Reverse: dependent owns the parent; parts are declared `--input-source`s.
    final depParts = _module('dep_parts', []);
    final sidecarParts = _sidecar('dep_parts', {
      'pkg/lib/uri_part.dart':
          'its library parent.dart is not an input of this module',
      'pkg/lib/named_part.dart':
          'its library my.parent is not an input of this module',
    });
    final fromParent = await _compile(
      'from_parent',
      ['pkg/lib/parent.dart'],
      inputSources: ['pkg/lib/uri_part.dart', 'pkg/lib/named_part.dart'],
      inputKmods: [depParts],
      closureExcluded: [sidecarParts],
    );
    expect(fromParent.code, 0);
    expect(fromParent.excluded, isEmpty);
    expect(fromParent.defines, [
      [
        'pkg/lib/named_part.dart',
        'pkg/lib/parent.dart',
        'pkg/lib/uri_part.dart',
      ],
    ]);
  });

  group('directive URI resolution matches the front end', () {
    const dirs = {'pkg': 'pkg/lib', 'dep': 'dep/lib'};

    test('percent escapes decode once, in either hex case', () {
      expect(
        resolveDirectiveUri('pie%63e.dart', 'pkg/lib/a.dart', dirs),
        'pkg/lib/piece.dart',
      );
      expect(
        resolveDirectiveUri('PIE%43E.DART', 'pkg/lib/a.dart', dirs),
        'pkg/lib/PIECE.DART',
      );
      expect(
        resolveDirectiveUri('%41%42.dart', 'pkg/lib/a.dart', dirs),
        'pkg/lib/AB.dart',
      );
      expect(
        resolveDirectiveUri('%2563.dart', 'pkg/lib/a.dart', dirs),
        'pkg/lib/%63.dart',
        reason: 'decoding happens once',
      );
      expect(
        resolveDirectiveUri('lone%b.dart', 'pkg/lib/a.dart', dirs),
        'pkg/lib/lone%b.dart',
        reason: 'a lone % stays literal',
      );
      expect(
        resolveDirectiveUri('a%2.dart', 'pkg/lib/a.dart', dirs),
        'pkg/lib/a%2.dart',
        reason: 'a truncated escape stays literal',
      );
      expect(
        resolveDirectiveUri('th%C3%A9.dart', 'pkg/lib/a.dart', dirs),
        'pkg/lib/thé.dart',
      );
    });

    test('a decoded slash names no file', () {
      expect(
        resolveDirectiveUri('sub%2Fb.dart', 'pkg/lib/a.dart', dirs),
        isNull,
        reason: '%2F crashes the front end file layer',
      );
      expect(
        resolveDirectiveUri('sub%2F..%2Fb.dart', 'pkg/lib/a.dart', dirs),
        isNull,
      );
    });

    test('dot segments resolve against the package directory', () {
      expect(resolveDirectiveUri('%2E', 'pkg/lib/a.dart', dirs), 'pkg/lib');
      expect(
        resolveDirectiveUri('sub/%2E%2E', 'pkg/lib/a.dart', dirs),
        'pkg/lib',
      );
      expect(
        resolveDirectiveUri('.%2E/x.dart', 'pkg/lib/a.dart', dirs),
        'pkg/lib/x.dart',
      );
      expect(
        resolveDirectiveUri('%2e%2e/x.dart', 'pkg/lib/a.dart', dirs),
        'pkg/lib/x.dart',
      );
      expect(
        resolveDirectiveUri('./b.dart', 'pkg/lib/a.dart', dirs),
        'pkg/lib/b.dart',
      );
      expect(
        resolveDirectiveUri('a//b.dart', 'pkg/lib/a.dart', dirs),
        'pkg/lib/a/b.dart',
      );
    });

    test('relative dot-dot never leaves the package directory', () {
      expect(
        resolveDirectiveUri('../x.dart', 'pkg/lib/a.dart', dirs),
        'pkg/lib/x.dart',
      );
      expect(
        resolveDirectiveUri('sub/../../x.dart', 'pkg/lib/a.dart', dirs),
        'pkg/lib/x.dart',
      );
      expect(
        resolveDirectiveUri('../../x.dart', 'pkg/lib/sub/a.dart', dirs),
        'pkg/lib/x.dart',
      );
      expect(
        resolveDirectiveUri('../x.dart', 'main.dart', dirs),
        'x.dart',
        reason: 'unpackaged files clamp at the multi-root',
      );
      expect(resolveDirectiveUri('sub/../b.dart', 'main.dart', dirs), 'b.dart');
    });

    test('absolute paths resolve against the package directory', () {
      expect(
        resolveDirectiveUri('/sub/b.dart', 'pkg/lib/a.dart', dirs),
        'pkg/lib/sub/b.dart',
      );
      expect(
        resolveDirectiveUri('/../x.dart', 'pkg/lib/a.dart', dirs),
        'pkg/lib/x.dart',
      );
      expect(
        resolveDirectiveUri('/pkg/lib/b.dart', 'pkg/lib/sub/a.dart', dirs),
        'pkg/lib/pkg/lib/b.dart',
        reason: 'absolute paths concatenate onto the package directory',
      );
      expect(resolveDirectiveUri('/x.dart', 'main.dart', dirs), 'x.dart');
    });

    test('package URIs decode and fail when leaving the package', () {
      expect(
        resolveDirectiveUri(
          'package:pkg/sub/../x.dart',
          'pkg/lib/a.dart',
          dirs,
        ),
        'pkg/lib/x.dart',
      );
      expect(
        resolveDirectiveUri(
          'package:pkg/sub/../../x.dart',
          'pkg/lib/a.dart',
          dirs,
        ),
        isNull,
      );
      expect(
        resolveDirectiveUri(
          'package:pkg/sub%63/x.dart',
          'pkg/lib/a.dart',
          dirs,
        ),
        'pkg/lib/subc/x.dart',
      );
      expect(
        resolveDirectiveUri('package:pkg/b.dart?x=1', 'pkg/lib/a.dart', dirs),
        isNull,
      );
      expect(
        resolveDirectiveUri('package:pkg/b.dart#frag', 'pkg/lib/a.dart', dirs),
        isNull,
      );
      expect(
        resolveDirectiveUri('package:other/b.dart', 'pkg/lib/a.dart', dirs),
        isNull,
      );
      expect(
        resolveDirectiveUri('package:pkg', 'pkg/lib/a.dart', dirs),
        isNull,
      );
    });

    test('absolute multi-root URIs decode with the multi-root as floor', () {
      expect(
        resolveDirectiveUri(
          'org-dartlang-root:///pkg/lib/../x.dart',
          'pkg/lib/a.dart',
          dirs,
        ),
        'pkg/x.dart',
      );
      expect(
        resolveDirectiveUri(
          'org-dartlang-root:///../x.dart',
          'pkg/lib/a.dart',
          dirs,
        ),
        'x.dart',
      );
    });

    test('backslashes separate, everywhere', () {
      expect(
        // ignore: avoid_escaping_inner_quotes
        resolveDirectiveUri('sub\\b.dart', 'pkg/lib/a.dart', dirs),
        'pkg/lib/sub/b.dart',
      );
      expect(
        resolveDirectiveUri('package:pkg/sub\\b.dart', 'pkg/lib/a.dart', dirs),
        'pkg/lib/sub/b.dart',
      );
      expect(
        resolveDirectiveUri(
          'org-dartlang-root:///pkg/lib/sub\\b.dart',
          'pkg/lib/a.dart',
          dirs,
        ),
        'pkg/lib/sub/b.dart',
      );
      expect(
        resolveDirectiveUri('sub%5Cb.dart', 'pkg/lib/a.dart', dirs),
        'pkg/lib/sub\\b.dart',
        reason: 'a decoded backslash is a literal file character',
      );
    });

    test('queries, fragments, authorities and schemes name no file', () {
      expect(resolveDirectiveUri('b.dart?x=1', 'pkg/lib/a.dart', dirs), isNull);
      expect(
        resolveDirectiveUri('b.dart#frag', 'pkg/lib/a.dart', dirs),
        isNull,
      );
      expect(
        resolveDirectiveUri('//auth/x.dart', 'pkg/lib/a.dart', dirs),
        isNull,
      );
      expect(resolveDirectiveUri('C:/x.dart', 'pkg/lib/a.dart', dirs), isNull);
      expect(resolveDirectiveUri('C:\\x.dart', 'pkg/lib/a.dart', dirs), isNull);
      expect(
        resolveDirectiveUri('%43:/x.dart', 'pkg/lib/a.dart', dirs),
        isNull,
        reason: 'an encoded drive letter is still a scheme',
      );
      expect(
        resolveDirectiveUri('file:///C:/x.dart', 'pkg/lib/a.dart', dirs),
        isNull,
      );
      expect(resolveDirectiveUri('a:b.dart', 'pkg/lib/a.dart', dirs), isNull);
      expect(resolveDirectiveUri('dart:core', 'pkg/lib/a.dart', dirs), isNull);
      expect(resolveDirectiveUri('', 'pkg/lib/a.dart', dirs), 'pkg/lib');
      expect(resolveDirectiveUri('b.dart', 'main.dart', dirs), 'b.dart');
    });
  });

  group('dill source URIs', () {
    test('reads every source table of single and concatenated components', () {
      final one = _buildDillWithUris([
        'org-dartlang-root:///pkg/lib/a.dart',
        'org-dartlang-sdk:///sdk/lib/core/core.dart',
      ]);
      expect(dillSourceUris(one), [
        'org-dartlang-root:///pkg/lib/a.dart',
        'org-dartlang-sdk:///sdk/lib/core/core.dart',
      ]);
      final two = Uint8List.fromList([
        ..._buildDillWithUris(['a']),
        ..._buildDillWithUris(['b', 'c']),
      ]);
      expect(dillSourceUris(two), ['a', 'b', 'c']);
    });

    test('fails closed on malformed bytes', () {
      expect(dillSourceUris(Uint8List(0)), isNull);
      expect(dillSourceUris(Uint8List.fromList([1, 2, 3])), isNull);
      final good = _buildDillWithUris(['a']);
      final badMagic = Uint8List.fromList(good)..[0] = 0;
      expect(dillSourceUris(badMagic), isNull);
      // The source-table layout is stable across SDKs, so well-formed tables
      // parse at any format version (127 is Dart 3.11.0, 130 is 3.12.2):
      // gating on the version failed legitimate compiles.
      for (final version in [127, 130, Tag.BinaryFormatVersion]) {
        expect(
          dillSourceUris(_buildDillWithUris(['a'], formatVersion: version)),
          ['a'],
          reason: 'format version $version',
        );
      }
      expect(dillSourceUris(good.sublist(0, 10)), isNull, reason: 'truncated');
      // A source count the table cannot hold.
      final badCount = Uint8List.fromList(good);
      badCount[72] = 0x10;
      badCount[73] = 0x27;
      expect(dillSourceUris(badCount), isNull);
    });
  });

  test('a percent-encoded part that decodes to an undeclared shadow excludes the library', () async {
    _write(
      'pkg/lib/a.dart',
      "library a;\npart 'pie%63e.dart';\nint f() => 1;\n",
    );
    _write('pkg/lib/pie%63e.dart', 'part of a;\nint g() => 2;\n');
    _write('pkg/lib/piece.dart', 'part of a;\nint h() => 3;\n');
    final result = await _compile('m_pct_shadow', [
      'pkg/lib/a.dart',
      'pkg/lib/pie%63e.dart',
    ]);
    expect(result.code, 0);
    expect(result.excluded, {
      _uri('pkg/lib/a.dart'):
          'its part pie%63e.dart is not an input of this module',
      _uri('pkg/lib/pie%63e.dart'):
          'its library a is not an input of this module',
    });
    expect(result.calls, isEmpty, reason: 'nothing left to compile');
  });

  test(
    'a percent-encoded part that decodes to a declared file compiles',
    () async {
      _write(
        'pkg/lib/a.dart',
        "library a;\npart 'pie%63e.dart';\nint f() => g();\n",
      );
      _write('pkg/lib/piece.dart', 'part of a;\nint g() => 2;\n');
      final result = await _compile('m_pct_declared', [
        'pkg/lib/a.dart',
        'pkg/lib/piece.dart',
      ]);
      expect(result.code, 0);
      expect(result.excluded, isEmpty);
      expect(result.defines, [
        ['pkg/lib/a.dart', 'pkg/lib/piece.dart'],
      ]);
      expect(result.sourcesPerCall, [
        [_uri('pkg/lib/a.dart'), _uri('pkg/lib/piece.dart')],
      ]);
    },
  );

  test('a percent-encoded import that decodes outside the closure excludes its importer', () async {
    _write('pkg/lib/a.dart', "import 'pie%63e.dart';\nint f() => 1;\n");
    _write('pkg/lib/piece.dart', 'int s() => 2;\n');
    final result = await _compile('m_pct_import', ['pkg/lib/a.dart']);
    expect(result.code, 0);
    expect(result.excluded, {
      _uri('pkg/lib/a.dart'):
          'imports pie%63e.dart, which is not in this module closure',
    });
    expect(result.calls, isEmpty);
  });

  test(
    'a package import that escapes its package excludes its importer',
    () async {
      _write(
        'pkg/lib/a.dart',
        "import 'package:pkg/../../x.dart';\nint f() => 1;\n",
      );
      final result = await _compile('m_pkg_escape', ['pkg/lib/a.dart']);
      expect(result.code, 0);
      expect(result.excluded, {
        _uri(
          'pkg/lib/a.dart',
        ): 'package:pkg/../../x.dart names a package this module does not have',
      });
      expect(result.calls, isEmpty);
    },
  );

  test('a backslash part resolves as a separator', () async {
    _write(
      'pkg/lib/a.dart',
      // ignore: avoid_escaping_inner_quotes
      "library a;\npart 'sub\\\\b.dart';\nint f() => g();\n",
    );
    _write('pkg/lib/sub/b.dart', 'part of a;\nint g() => 2;\n');
    final result = await _compile('m_backslash', [
      'pkg/lib/a.dart',
      'pkg/lib/sub/b.dart',
    ]);
    expect(result.code, 0);
    expect(result.excluded, isEmpty);
    expect(result.defines, [
      ['pkg/lib/a.dart', 'pkg/lib/sub/b.dart'],
    ]);
  });

  test(
    'an entry that reaches a percent-decoded shadow fails without compiling it',
    () async {
      _write(
        'pkg/lib/a.dart',
        "library a;\npart 'pie%63e.dart';\nint f() => 1;\n",
      );
      _write('pkg/lib/pie%63e.dart', 'part of a;\nint g() => 2;\n');
      _write('pkg/lib/piece.dart', 'part of a;\nint h() => 3;\n');
      final entry = await _compile('entry_pct_shadow', [
        'pkg/lib/a.dart',
        'pkg/lib/pie%63e.dart',
      ], noDrop: true);
      expect(entry.code, 1);
      expect(entry.calls, isEmpty, reason: 'compiler must not run');
      expect(
        entry.log,
        contains(
          'kernel_module: cannot compile package:pkg/piece.dart '
          '(pkg/lib/piece.dart): source is not a declared input.',
        ),
      );
    },
  );

  test('an unstaged compile that reads an undeclared file is redone isolated, and refused when the restage still reads outside the declared inputs', () async {
    _write('pkg/lib/a.dart', 'class A {}\n');
    final compiler = _DillWritingCompiler(
      () => _buildDillWithUris([
        _uri('pkg/lib/a.dart'),
        _uri('pkg/lib/piece.dart'),
      ]),
    );
    final result = await _compile(
      'm_fallback',
      ['pkg/lib/a.dart'],
      // Worker inputs keep the marker-URI spellings from forcing isolated
      // staging, so the first compile runs unstaged as in a real build.
      inputs: [
        _encodeInputForTest(
          '${_root.path}/pkg/lib/a.dart',
          Uint8List.fromList([7]),
        ),
      ],
      compiler: compiler,
    );
    expect(result.calls.length, 2, reason: 'unstaged, then isolated');
    expect(_valuesAfter(result.calls[0], '--multi-root'), [
      kernelWorkerUri(_root.path),
    ]);
    final isolatedRoots = _valuesAfter(result.calls[1], '--multi-root');
    expect(isolatedRoots.length, 1);
    expect(isolatedRoots.single, contains('.isolated_root'));
    expect(result.log, contains('which is not a declared input'));
    // The restaged compile reads the same undeclared file (a `file:` URI
    // reads the host whatever the multi-root holds): the result is refused,
    // never accepted.
    expect(result.code, 1);
    expect(result.log, contains('failing the compile'));
    expect(
      Directory('${_root.path}/out/m_fallback/.isolated_root').existsSync(),
      isFalse,
      reason: 'the isolated root is cleaned up',
    );
  });

  test('an unstaged compile whose isolated restage reads only declared files is accepted', () async {
    _write('pkg/lib/a.dart', 'class A {}\n');
    var calls = 0;
    final compiler = _DillWritingCompiler(
      () => calls++ == 0
          ? _buildDillWithUris([
              _uri('pkg/lib/a.dart'),
              _uri('pkg/lib/piece.dart'),
            ])
          : _buildDillWithUris([_uri('pkg/lib/a.dart')]),
    );
    final result = await _compile(
      'm_fallback_clean',
      ['pkg/lib/a.dart'],
      inputs: [
        _encodeInputForTest(
          '${_root.path}/pkg/lib/a.dart',
          Uint8List.fromList([7]),
        ),
      ],
      compiler: compiler,
    );
    expect(result.code, 0, reason: result.log);
    expect(result.calls.length, 2, reason: 'unstaged, then isolated');
    expect(result.log, contains('which is not a declared input'));
    expect(result.log, isNot(contains('failing the compile')));
  });

  test(
    'an unstaged compile that reads only declared files runs once',
    () async {
      _write('pkg/lib/a.dart', 'class A {}\n');
      final compiler = _DillWritingCompiler(
        () => _buildDillWithUris([_uri('pkg/lib/a.dart')]),
      );
      final result = await _compile(
        'm_no_fallback',
        ['pkg/lib/a.dart'],
        inputs: [
          _encodeInputForTest(
            '${_root.path}/pkg/lib/a.dart',
            Uint8List.fromList([7]),
          ),
        ],
        compiler: compiler,
      );
      expect(result.code, 0);
      expect(result.calls.length, 1);
      expect(result.log, isNot(contains('isolated multi-root')));
    },
  );

  test('a compile that reads only declared files verifies at an older format version', () async {
    _write('pkg/lib/a.dart', 'class A {}\n');
    final compiler = _DillWritingCompiler(
      () => _buildDillWithUris([_uri('pkg/lib/a.dart')], formatVersion: 127),
    );
    final result = await _compile(
      'm_old_version',
      ['pkg/lib/a.dart'],
      inputs: [
        _encodeInputForTest(
          '${_root.path}/pkg/lib/a.dart',
          Uint8List.fromList([7]),
        ),
      ],
      compiler: compiler,
    );
    expect(result.code, 0, reason: result.log);
    expect(result.calls.length, 1, reason: 'no isolated restage');
    expect(result.log, isNot(contains('cannot read the sources')));
  });

  group('directive guard classification', () {
    test('decodeUriSegment decodes once, like the front end', () {
      expect(decodeUriSegment('pie%63e'), 'piece');
      expect(decodeUriSegment('%2563'), '%63');
      expect(defaultMultiRootPrefix, 'org-dartlang-root:///');
    });
    test('isFileSchemeDirectiveUri matches every file: spelling', () {
      for (final uri in [
        'file:///proc/self/cwd/pkg/lib/secret.dart',
        'FILE:///x.dart',
        'File:x.dart',
        'file://localhost/x.dart',
        r'file:C:\x.dart',
        'file:x.dart?y=1#z',
      ]) {
        expect(isFileSchemeDirectiveUri(uri), isTrue, reason: uri);
      }
      for (final uri in [
        'package:pkg/x.dart',
        'dart:core',
        'x.dart',
        '../x.dart',
        'notfile:x.dart',
        'org-dartlang-root:///x.dart',
        'other-scheme:///x.dart',
      ]) {
        expect(isFileSchemeDirectiveUri(uri), isFalse, reason: uri);
      }
    });

    test('isDisallowedDirectiveUri exempts only package, dart and the multi-root scheme', () {
      for (final uri in [
        'file:///x.dart',
        'FILE:x.dart',
        'other-scheme:///x.dart',
        'http://host/y.dart',
        'data:text/plain,hi',
        'C:/x.dart',
        'a:b.dart',
      ]) {
        expect(isDisallowedDirectiveUri(uri), isTrue, reason: uri);
      }
      for (final uri in [
        'package:pkg/x.dart',
        'dart:core',
        'org-dartlang-root:///x.dart',
        'x.dart',
        '../x.dart',
        '/pkg/x.dart',
      ]) {
        expect(isDisallowedDirectiveUri(uri), isFalse, reason: uri);
      }
      expect(
        isDisallowedDirectiveUri(
          'org-dartlang-app:///x.dart',
          multiRootPrefix: 'org-dartlang-app:///',
        ),
        isFalse,
      );
    });

    test('scanAllDirectiveUris collects every conditional alternative', () {
      final refs = scanAllDirectiveUris(
        "import 'a.dart' if (dart.library.html) 'file:///s.dart';\n"
        "export 'package:pkg/e.dart';\n"
        "part 'p.dart';\n",
      );
      expect(
        [for (final ref in refs) '${ref.kind} ${ref.uri}'],
        [
          'import a.dart',
          'import file:///s.dart',
          'export package:pkg/e.dart',
          'part p.dart',
        ],
      );
    });

    test('findDisallowedDirectives names the file, the directive and the URI', () {
      expect(
        findDisallowedDirectives({
          'b.dart': "import 'package:pkg/a.dart';\n",
          'a.dart': "import 'file:///secret.dart';\n",
        }),
        ["dart: a.dart import 'file:///secret.dart' is not a declared input."],
      );
    });
  });

  group('disallowed directive URIs fail the module', () {
    test('a file: import fails in every spelling', () async {
      const spellings = [
        'file:///proc/self/cwd/pkg/lib/secret.dart',
        'FILE:///proc/self/cwd/pkg/lib/secret.dart',
        'file://localhost/proc/self/cwd/pkg/lib/secret.dart',
        'file:pkg/lib/secret.dart',
        'file:///proc/self/cwd/pkg/lib/secret.dart?x=1',
        'file:///proc/self/cwd/pkg/lib/secret.dart#frag',
      ];
      for (var i = 0; i < spellings.length; i++) {
        _write('pkg/lib/f$i.dart', "import '${spellings[i]}';\nclass F$i {}\n");
      }
      final result = await _compile('m_file_uri', [
        for (var i = 0; i < spellings.length; i++) 'pkg/lib/f$i.dart',
      ]);
      expect(result.code, 1);
      for (final spelling in spellings) {
        expect(
          result.log,
          contains("import '$spelling' is not a declared input"),
          reason: spelling,
        );
      }
    });

    test(
      'a file: export, part and selected conditional alternative fail',
      () async {
        _write('pkg/lib/e.dart', "export 'file:///secret.dart';\nclass E {}\n");
        _write('pkg/lib/p.dart', "part 'file:///secret.dart';\nclass P {}\n");
        _write(
          'pkg/lib/c.dart',
          "import 'file:///secret.dart' if (dart.library.html) 'dart:async';\n"
              'class C {}\n',
        );
        _write(
          'pkg/lib/d.dart',
          "import 'dart:async' if (dart.library.io) 'file:///secret.dart';\n"
              'class D {}\n',
        );
        final result = await _compile('m_file_kinds', [
          'pkg/lib/e.dart',
          'pkg/lib/p.dart',
          'pkg/lib/c.dart',
          'pkg/lib/d.dart',
        ]);
        expect(result.code, 1);
        expect(
          result.log,
          contains("export 'file:///secret.dart' is not a declared input"),
        );
        expect(
          result.log,
          contains("part 'file:///secret.dart' is not a declared input"),
        );
        expect(
          result.log,
          contains(
            "cannot compile ${_uri('pkg/lib/c.dart')}: "
            "import 'file:///secret.dart' is not a declared input",
          ),
        );
        expect(
          result.log,
          contains(
            "cannot compile ${_uri('pkg/lib/d.dart')}: "
            "import 'file:///secret.dart' is not a declared input",
          ),
        );
      },
    );

    test(
      'an unknown-scheme import fails instead of staying excluded',
      () async {
        _write(
          'pkg/lib/a.dart',
          "import 'other-scheme:///missing.dart';\nclass A {}\n",
        );
        final result = await _compile('m_scheme', ['pkg/lib/a.dart']);
        expect(result.code, 1);
        expect(
          result.log,
          contains(
            "cannot compile ${_uri('pkg/lib/a.dart')}: "
            "import 'other-scheme:///missing.dart' is not a declared input",
          ),
        );
      },
    );

    test(
      'a file: import fails the whole-program entry instead of compiling',
      () async {
        _write(
          'pkg/lib/a.dart',
          "import 'file:///proc/self/cwd/pkg/lib/secret.dart';\n"
              'String describe() => secretValue;\n',
        );
        _write('pkg/lib/secret.dart', "const secretValue = 'x';\n");
        _write(
          'pkg/bin/main.dart',
          "import 'package:pkg/a.dart';\nvoid main() => print(describe());\n",
        );
        final result = await _compile(
          'm_file_entry',
          ['pkg/bin/main.dart'],
          inputSources: [_uri('pkg/lib/a.dart')],
          noDrop: true,
        );
        expect(result.code, 1);
        expect(
          result.log,
          contains(
            "import 'file:///proc/self/cwd/pkg/lib/secret.dart' "
            'is not a declared input',
          ),
        );
      },
    );
  });

  test('split part/part of modules produce byte-identical outputs sandboxed vs unsandboxed and rebuild when the parent edits', () async {
    final sdkDir = File(Platform.resolvedExecutable).parent.parent;
    final exeSuffix = Platform.isWindows ? '.exe' : '';
    final dartaotruntime = '${sdkDir.path}/bin/dartaotruntime$exeSuffix';
    final kernelWorker =
        '${sdkDir.path}/bin/snapshots/kernel_worker_aot.dart.snapshot';
    final platformDill = '${sdkDir.path}/lib/_internal/vm_platform_strong.dill';
    final librariesJson = '${sdkDir.path}/lib/libraries.json';

    final realCompiler = _ProcessModuleCompiler(dartaotruntime, kernelWorker);

    Future<void> runModule(
      Directory ws, {
      required String outRel,
      required String outlineRel,
      required String excludedRel,
      required List<String> sources,
      List<String> inputSources = const [],
      List<String> inputKmods = const [],
      List<String> closureExcluded = const [],
    }) async {
      final log = StringBuffer();
      final prevCwd = Directory.current;
      Directory.current = ws;
      try {
        final code = await compileModule(
          [
            for (final s in sources) ...['--source', '$_prefix$s'],
            for (final s in inputSources) ...['--input-source', s],
            '--output',
            outRel,
            '--output-outline',
            outlineRel,
            '--excluded-output',
            excludedRel,
            '--packages-file',
            'package_config.json',
            '--libraries-json',
            librariesJson,
            '--dart-sdk-summary',
            platformDill,
            '--multi-root',
            ws.path,
            '--multi-root-scheme',
            'org-dartlang-root',
            '--target',
            'vm',
            '--no-summary-only',
            '--exclude-non-sources',
            for (final k in inputKmods) ...['--input-kmod', k],
            for (final c in closureExcluded) ...['--closure-excluded', c],
          ],
          realCompiler,
          log,
          const <Uint8List>[],
        );
        expect(code, 0, reason: 'compileModule failed: $log');
      } finally {
        Directory.current = prevCwd;
      }
    }

    void writeWorkspaceConfig(Directory ws) {
      File('${ws.path}/package_config.json').writeAsStringSync(
        jsonEncode({
          'configVersion': 2,
          'packages': [
            {
              'name': 'pkg',
              'rootUri': '${_prefix}pkg',
              'packageUri': 'lib/',
              'languageVersion': '3.0',
            },
          ],
        }),
      );
    }

    const parentV1 =
        "library my.parent;\npart 'part_a.dart';\nint parentFn() => partValue + 10;\n";
    const parentV2 =
        "library my.parent;\npart 'part_a.dart';\nint parentFn() => partValue + 99;\n";
    const partSrc = "part of 'parent.dart';\nconst int partValue = 32;\n";

    // 1. Unsandboxed workspace: both parent.dart and part_a.dart exist on disk during both actions.
    final unsandboxed = Directory('${_root.path}/unsandboxed')
      ..createSync(recursive: true);
    writeWorkspaceConfig(unsandboxed);
    File('${unsandboxed.path}/pkg/lib/parent.dart')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(parentV1);
    File('${unsandboxed.path}/pkg/lib/part_a.dart').writeAsStringSync(partSrc);

    await runModule(
      unsandboxed,
      outRel: 'out/parent.kmod',
      outlineRel: 'out/parent.koutline',
      excludedRel: 'out/parent.vm_excluded.txt',
      sources: ['pkg/lib/parent.dart'],
    );
    await runModule(
      unsandboxed,
      outRel: 'out/part.kmod',
      outlineRel: 'out/part.koutline',
      excludedRel: 'out/part.vm_excluded.txt',
      sources: ['pkg/lib/part_a.dart'],
      inputSources: ['pkg/lib/parent.dart'],
      inputKmods: ['out/parent.koutline'],
      closureExcluded: ['out/parent.vm_excluded.txt'],
    );

    // 2. Sandboxed workspaces: each action only has its declared inputs materialized on disk.
    final sandboxParent = Directory('${_root.path}/sandbox_parent')
      ..createSync(recursive: true);
    writeWorkspaceConfig(sandboxParent);
    File('${sandboxParent.path}/pkg/lib/parent.dart')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(parentV1);
    await runModule(
      sandboxParent,
      outRel: 'out/parent.kmod',
      outlineRel: 'out/parent.koutline',
      excludedRel: 'out/parent.vm_excluded.txt',
      sources: ['pkg/lib/parent.dart'],
    );

    final sandboxPart = Directory('${_root.path}/sandbox_part')
      ..createSync(recursive: true);
    writeWorkspaceConfig(sandboxPart);
    File('${sandboxPart.path}/pkg/lib/part_a.dart')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(partSrc);
    File('${sandboxPart.path}/pkg/lib/parent.dart').writeAsStringSync(parentV1);
    // Copy only the declared artifacts from sandboxParent (parent.koutline and parent.vm_excluded.txt).
    Directory('${sandboxPart.path}/out/parent.koutline/sources/pkg/lib')
        .createSync(recursive: true);
    File('${sandboxParent.path}/out/parent.koutline/index.json')
        .copySync('${sandboxPart.path}/out/parent.koutline/index.json');
    File(
      '${sandboxParent.path}/out/parent.koutline/sources/pkg/lib/parent.dart',
    ).copySync(
      '${sandboxPart.path}/out/parent.koutline/sources/pkg/lib/parent.dart',
    );
    File('${sandboxParent.path}/out/parent.vm_excluded.txt')
        .copySync('${sandboxPart.path}/out/parent.vm_excluded.txt');
    await runModule(
      sandboxPart,
      outRel: 'out/part.kmod',
      outlineRel: 'out/part.koutline',
      excludedRel: 'out/part.vm_excluded.txt',
      sources: ['pkg/lib/part_a.dart'],
      inputSources: ['pkg/lib/parent.dart'],
      inputKmods: ['out/parent.koutline'],
      closureExcluded: ['out/parent.vm_excluded.txt'],
    );

    // Verify sandboxed and unsandboxed outputs are byte-identical.
    expect(
      File('${sandboxParent.path}/out/parent.kmod/index.json')
          .readAsBytesSync(),
      equals(
        File('${unsandboxed.path}/out/parent.kmod/index.json')
            .readAsBytesSync(),
      ),
    );
    expect(
      File('${sandboxParent.path}/out/parent.vm_excluded.txt')
          .readAsBytesSync(),
      equals(
        File('${unsandboxed.path}/out/parent.vm_excluded.txt')
            .readAsBytesSync(),
      ),
    );
    final partKmodV1 = File('${sandboxPart.path}/out/part.kmod/0.dill')
        .readAsBytesSync();
    expect(
      partKmodV1,
      equals(
        File('${unsandboxed.path}/out/part.kmod/0.dill').readAsBytesSync(),
      ),
      reason: 'sandboxed and unsandboxed .kmod outputs must be byte-identical',
    );
    expect(
      File('${sandboxPart.path}/out/part.koutline/0.dill').readAsBytesSync(),
      equals(
        File('${unsandboxed.path}/out/part.koutline/0.dill').readAsBytesSync(),
      ),
      reason:
          'sandboxed and unsandboxed .koutline outputs must be byte-identical',
    );

    // 3. Editing the parent library changes the rebuilt output of the part module.
    File('${sandboxPart.path}/pkg/lib/parent.dart').writeAsStringSync(parentV2);
    File('${sandboxPart.path}/out/parent.koutline/sources/pkg/lib/parent.dart')
        .writeAsStringSync(parentV2);
    await runModule(
      sandboxPart,
      outRel: 'out/part_v2.kmod',
      outlineRel: 'out/part_v2.koutline',
      excludedRel: 'out/part_v2.vm_excluded.txt',
      sources: ['pkg/lib/part_a.dart'],
      inputSources: ['pkg/lib/parent.dart'],
      inputKmods: ['out/parent.koutline'],
      closureExcluded: ['out/parent.vm_excluded.txt'],
    );
    final partKmodV2 = File('${sandboxPart.path}/out/part_v2.kmod/0.dill')
        .readAsBytesSync();
    expect(
      partKmodV2,
      isNot(equals(partKmodV1)),
      reason: 'editing the parent library must change the rebuilt output',
    );
  });

  test('a source a dependency module defines is not compiled again', () async {
    _write('pkg/lib/shared.dart', 'class Shared {}\n');
    _write('pkg/lib/top.dart', "import 'shared.dart';\n");
    final dep = _module('dep_module', [
      _Scc('0.dill', ['pkg/lib/shared.dart'], []),
    ]);
    final result = await _compile(
      'm',
      ['pkg/lib/shared.dart', 'pkg/lib/top.dart'],
      inputKmods: [dep],
    );
    expect(result.code, 0);
    expect(result.excluded, isEmpty);
    expect(result.sourcesPerCall, [
      [_uri('pkg/lib/top.dart')],
    ]);
    expect(_valuesAfter(result.calls.single, '--input-summary'), [
      kernelWorkerUri('$dep/0.dill'),
    ], reason: 'top links the kernel that defines shared');
  });

  test('a dependency excludes a file the dependent lists, so the dependent compiles its own', () async {
    _write('pkg/lib/shared.dart', 'class Shared {}\n');
    final dep = _module('dep_module', []);
    final sidecar = _sidecar('dep_module', {
      'pkg/lib/shared.dart': 'imports dart:html, which is not a VM library',
    });
    final result = await _compile(
      'm',
      ['pkg/lib/shared.dart'],
      inputKmods: [dep],
      closureExcluded: [sidecar],
    );
    expect(result.code, 0);
    expect(
      result.excluded,
      isEmpty,
      reason: 'the module compiles its own copy',
    );
    expect(result.defines, [
      ['pkg/lib/shared.dart'],
    ]);
  });

  test('a file a dependency excludes, that a dependent only imports, excludes its importer', () async {
    _write('pkg/lib/shared.dart', 'class Shared {}\n');
    _write('pkg/lib/top.dart', "import 'shared.dart';\n");
    final dep = _module('dep_module', []);
    final sidecar = _sidecar('dep_module', {
      'pkg/lib/shared.dart': 'its reason',
    });
    final result = await _compile(
      'm',
      ['pkg/lib/top.dart'],
      inputKmods: [dep],
      closureExcluded: [sidecar],
    );
    expect(result.code, 0);
    expect(result.excluded, {
      _uri('pkg/lib/top.dart'): 'imports shared.dart, which is excluded',
    });
  });

  test('an excluded file that another module of the closure defines is not excluded', () async {
    _write('pkg/lib/shared.dart', 'class Shared {}\n');
    _write('pkg/lib/top.dart', "import 'shared.dart';\n");
    final excludes = _module('excludes', []);
    final defines = _module('defines', [
      _Scc('0.dill', ['pkg/lib/shared.dart'], []),
    ]);
    final sidecar = _sidecar('excludes', {'pkg/lib/shared.dart': 'its reason'});
    final result = await _compile(
      'm',
      ['pkg/lib/top.dart'],
      inputKmods: [excludes, defines],
      closureExcluded: [sidecar],
    );
    expect(result.code, 0);
    expect(
      result.excluded,
      isEmpty,
      reason: 'the defining module supplies the file',
    );
    expect(result.defines, [
      ['pkg/lib/top.dart'],
    ]);
    expect(_valuesAfter(result.calls.single, '--input-summary'), [
      kernelWorkerUri('$defines/0.dill'),
    ]);
  });

  test('an entry compiles an excluded file from source, unless a module defines it', () async {
    _write('pkg/lib/web.dart', 'class Web {}\n');
    _write('pkg/lib/defined.dart', 'class Defined {}\n');
    _write(
      'pkg/test/main_test.dart',
      "import 'package:pkg/web.dart';\nimport 'package:pkg/defined.dart';\n",
    );
    final excludes = _module('excludes', []);
    final defines = _module('defines', [
      _Scc('0.dill', ['pkg/lib/defined.dart'], []),
    ]);
    final sidecar = _sidecar('excludes', {
      'pkg/lib/web.dart': 'dart:html is not a VM library',
      'pkg/lib/defined.dart': 'dart:html is not a VM library',
    });
    final entry = await _compile(
      'entry',
      ['pkg/test/main_test.dart'],
      inputSources: ['pkg/lib/web.dart'],
      inputKmods: [excludes, defines],
      closureExcluded: [sidecar],
      noDrop: true,
    );
    expect(entry.code, 0);
    expect(
      entry.sourcesPerCall.single,
      containsAll([_uri('pkg/test/main_test.dart'), 'package:pkg/web.dart']),
    );
    expect(
      entry.sourcesPerCall.single,
      isNot(contains('package:pkg/defined.dart')),
      reason: 'the defining module supplies it',
    );
    expect(
      _valuesAfter(entry.calls.single, '--input-summary'),
      contains(kernelWorkerUri('$defines/0.dill')),
    );
    expect(
      entry.calls.single,
      isNot(contains('--input-source')),
      reason: '--input-source is consumed by kernel_module and not forwarded',
    );
  });

  test('an entry fails clearly without reading disk when a reached excluded source is not a declared input', () async {
    // Both files exist on disk under _root, but neither is passed via --input-source.
    // If _Files.read read undeclared files from disk, scanning web.dart would also
    // discover transitive_secret.dart.
    _write(
      'pkg/lib/web.dart',
      "import 'package:pkg/transitive_secret.dart';\nclass Web {}\n",
    );
    _write('pkg/lib/transitive_secret.dart', 'class Secret {}\n');
    _write('pkg/test/main_test.dart', "import 'package:pkg/web.dart';\n");
    final excludes = _module('excludes', []);
    final sidecar = _sidecar('excludes', {
      'pkg/lib/web.dart': 'dart:html is not a VM library',
      'pkg/lib/transitive_secret.dart': 'dart:html is not a VM library',
    });
    final entry = await _compile(
      'entry_undeclared',
      ['pkg/test/main_test.dart'],
      inputKmods: [excludes],
      closureExcluded: [sidecar],
      noDrop: true,
    );
    expect(entry.code, 1);
    expect(entry.calls, isEmpty, reason: 'compiler must not run');
    expect(
      entry.log,
      contains(
        'kernel_module: cannot compile ${_uri('pkg/lib/web.dart')} '
        '(pkg/lib/web.dart): source is not a declared input.',
      ),
    );
    expect(
      entry.log,
      isNot(contains('transitive_secret.dart')),
      reason: 'undeclared file pkg/lib/web.dart must not be read from disk',
    );
  });

  group('unused inputs list', () {
    test('a library lists an unused module directory but not a used or shadowing one', () async {
      _write('pkg/lib/a.dart', 'class A {}\n');
      final unused = _module('unused', [
        _Scc('u.dill', ['dep/lib/u.dart'], []),
      ]);
      final shadow = _module('shadow', [
        _Scc('s.dill', ['pkg/lib/a.dart'], []),
      ]);
      final unusedPath = '${_root.path}/out/m.unused';
      final result = await _compile(
        'm_unused_tree',
        ['pkg/lib/a.dart'],
        inputKmods: [unused, shadow],
        unusedInputsList: unusedPath,
      );
      expect(result.code, 0, reason: result.log);
      expect(File(unusedPath).readAsLinesSync(), [unused]);
    });

    test(
      'a library never lists a module directory sharing its package',
      () async {
        _write('pkg/lib/a.dart', 'class A {}\n');
        final samePkg = _module('samepkg', [
          _Scc('o.dill', ['pkg/lib/other.dart'], []),
        ]);
        final otherPkg = _module('otherpkg', [
          _Scc('o.dill', ['dep/lib/o.dart'], []),
        ]);
        final unusedPath = '${_root.path}/out/m2.unused';
        final result = await _compile(
          'm_unused_samepkg',
          ['pkg/lib/a.dart'],
          inputKmods: [samePkg, otherPkg],
          unusedInputsList: unusedPath,
        );
        expect(result.code, 0, reason: result.log);
        expect(File(unusedPath).readAsLinesSync(), [otherPkg]);
      },
    );

    test('a library never lists a module directory staging an excluded source it reads', () async {
      _write('pkg/lib/a.dart', 'class A {}\n');
      final excluder = '${_root.path}/excluder';
      _write(
        'excluder/index.json',
        jsonEncode({
          'version': 1,
          'sccs': [
            {
              'dill': 'e.dill',
              'defines': ['dep/lib/e.dart'],
              'imports': [],
            },
          ],
          'excluded': ['dep/lib/x.dart'],
        }),
      );
      final clean = _module('clean', [
        _Scc('c.dill', ['dep/lib/c.dart'], []),
      ]);
      final sidecar = _sidecar('upstream', {
        'dep/lib/x.dart': 'dart:html is not a VM library',
      });
      final unusedPath = '${_root.path}/out/m3.unused';
      final result = await _compile(
        'm_unused_staged',
        ['pkg/lib/a.dart'],
        inputKmods: [excluder, clean],
        closureExcluded: [sidecar],
        unusedInputsList: unusedPath,
      );
      expect(result.code, 0, reason: result.log);
      expect(File(unusedPath).readAsLinesSync(), [clean]);
    });

    test('a used-inputs report marks a passed summary used', () async {
      _write('pkg/lib/a.dart', "import 'package:dep/u.dart';\nclass A {}\n");
      final used = _module('used', [
        _Scc('u.dill', ['dep/lib/u.dart'], []),
      ]);
      final clean = _module('clean', [
        _Scc('c.dill', ['dep/lib/c.dart'], []),
      ]);
      final compiler = _ReportingCompiler(reported: {'$used/u.dill'});
      final unusedPath = '${_root.path}/out/m4.unused';
      final result = await _compile(
        'm_unused_report',
        ['pkg/lib/a.dart'],
        inputKmods: [used, clean],
        compiler: compiler,
        unusedInputsList: unusedPath,
      );
      expect(result.code, 0, reason: result.log);
      expect(File(unusedPath).readAsLinesSync(), [clean]);
      expect(compiler.calls.single, contains(startsWith('--used-inputs=')));
      expect(
        Directory('${_root.path}/out/m_unused_report')
            .listSync()
            .where((entity) => entity.path.contains('.used-inputs-')),
        isEmpty,
        reason: 'the per-invocation report is deleted after it is read',
      );
    });

    test(
      'a report naming a file the action never passed lists nothing',
      () async {
        _write('pkg/lib/a.dart', "import 'package:dep/u.dart';\nclass A {}\n");
        final unused = _module('unused', [
          _Scc('u.dill', ['dep/lib/u.dart'], []),
        ]);
        final compiler = _ReportingCompiler(
          reported: {'/never/passed/foreign.dill'},
        );
        final unusedPath = '${_root.path}/out/m5.unused';
        final result = await _compile(
          'm_unused_tripwire',
          ['pkg/lib/a.dart'],
          inputKmods: [unused],
          compiler: compiler,
          unusedInputsList: unusedPath,
        );
        expect(result.code, 0, reason: result.log);
        expect(
          File(unusedPath).readAsLinesSync(),
          isEmpty,
          reason: 'a foreign report fails closed to an empty list',
        );
      },
    );

    test(
      'a worker without used-inputs support compiles on, listing from the plan',
      () async {
        _write('pkg/lib/a.dart', 'class A {}\n');
        final clean = _module('clean', [
          _Scc('c.dill', ['dep/lib/c.dart'], []),
        ]);
        final compiler = _OldWorkerCompiler();
        final unusedPath = '${_root.path}/out/m6.unused';
        final result = await _compile(
          'm_unused_oldworker',
          ['pkg/lib/a.dart'],
          inputKmods: [clean],
          compiler: compiler,
          unusedInputsList: unusedPath,
        );
        expect(result.code, 0, reason: result.log);
        expect(compiler.calls.length, 2);
        expect(compiler.calls[0], contains(startsWith('--used-inputs=')));
        expect(
          compiler.calls[1],
          isNot(contains(startsWith('--used-inputs='))),
        );
        expect(File(unusedPath).readAsLinesSync(), [clean]);
      },
    );

    test('a failed compile writes no unused-inputs file', () async {
      _write('pkg/lib/a.dart', 'class A {}\n');
      final compiler = _ReportingCompiler(exitCode: 1);
      final unusedPath = '${_root.path}/out/m7.unused';
      final result = await _compile(
        'm_unused_failure',
        ['pkg/lib/a.dart'],
        compiler: compiler,
        unusedInputsList: unusedPath,
      );
      expect(result.code, 1);
      expect(File(unusedPath).existsSync(), isFalse);
    });

    test('an entry lists dependency sources it never compiles', () async {
      _write(
        'pkg/lib/main.dart',
        "import 'package:dep/x.dart';\nvoid main() {}\n",
      );
      _write('dep/lib/x.dart', 'class X {}\n');
      _write('dep/lib/y.dart', 'class Y {}\n');
      final dep = _module('dep', [
        _Scc('x.dill', ['dep/lib/x.dart'], []),
      ]);
      final ownPath = '${_root.path}/pkg/lib/main.dart';
      final xPath = '${_root.path}/dep/lib/x.dart';
      final yPath = '${_root.path}/dep/lib/y.dart';
      final compiler = _ReportingCompiler(
        dillBytes: () => _buildDillWithUris([_uri('pkg/lib/main.dart')]),
      );
      final unusedPath = '${_root.path}/out/entry.unused';
      final entry = await _compile(
        'entry_unused_sources',
        ['pkg/lib/main.dart'],
        inputSources: [ownPath, xPath, yPath],
        inputKmods: [dep],
        noDrop: true,
        compiler: compiler,
        unusedInputsList: unusedPath,
      );
      expect(entry.code, 0, reason: entry.log);
      expect(File(unusedPath).readAsLinesSync(), [xPath, yPath]);
    });

    test('an entry lists no dependency source when its output embeds an unplanned one', () async {
      _write(
        'pkg/lib/main.dart',
        "import 'package:dep/x.dart';\nvoid main() {}\n",
      );
      _write('dep/lib/x.dart', 'class X {}\n');
      _write('dep/lib/y.dart', 'class Y {}\n');
      final dep = _module('dep', [
        _Scc('x.dill', ['dep/lib/x.dart'], []),
      ]);
      final compiler = _ReportingCompiler(
        dillBytes: () => _buildDillWithUris([
          _uri('pkg/lib/main.dart'),
          _uri('dep/lib/x.dart'),
        ]),
      );
      final unusedPath = '${_root.path}/out/entry2.unused';
      final entry = await _compile(
        'entry_unused_embedded',
        ['pkg/lib/main.dart'],
        inputSources: [
          '${_root.path}/dep/lib/x.dart',
          '${_root.path}/dep/lib/y.dart',
        ],
        inputKmods: [dep],
        noDrop: true,
        compiler: compiler,
        unusedInputsList: unusedPath,
      );
      expect(entry.code, 0, reason: entry.log);
      expect(
        File(unusedPath).readAsLinesSync(),
        isEmpty,
        reason: 'the embedded dependency source is read',
      );
    });

    test('an entry lists no dependency source after scanning declared files for a part-of name', () async {
      _write('pkg/lib/main.dart', 'part of mylib;\nclass A {}\n');
      _write('dep/lib/lib.dart', 'library mylib;\nclass L {}\n');
      _write('dep/lib/y.dart', 'class Y {}\n');
      final dep = _module('dep', [
        _Scc('lib.dill', ['dep/lib/lib.dart'], []),
      ]);
      final other = _module('other', [
        _Scc('o.dill', ['dep/lib/o.dart'], []),
      ]);
      final unusedPath = '${_root.path}/out/entry3.unused';
      final compiler = _ReportingCompiler(
        dillBytes: () => _buildDillWithUris([_uri('pkg/lib/main.dart')]),
      );
      final entry = await _compile(
        'entry_unused_lookup',
        ['pkg/lib/main.dart'],
        inputSources: ['dep/lib/lib.dart', 'dep/lib/y.dart'],
        inputKmods: [dep, other],
        noDrop: true,
        compiler: compiler,
        unusedInputsList: unusedPath,
      );
      expect(entry.code, 0, reason: entry.log);
      expect(
        File(unusedPath).readAsLinesSync(),
        [other],
        reason:
            'the name lookup scanned declared files, so no source is listed, '
            'but the untouched module directory still is',
      );
    });

    test(
      'a report in absolute URIs matches summaries passed as relative paths',
      () async {
        _write('pkg/lib/a.dart', "import 'package:dep/u.dart';\nclass A {}\n");
        final usedDir = _module('used', [
          _Scc('u.dill', ['dep/lib/u.dart'], []),
        ]);
        _module('clean', [
          _Scc('c.dill', ['dep/lib/c.dart'], []),
        ]);
        // Production passes exec-root-relative `--input-kmod` directories while
        // the worker reports absolute `file://` URIs: the same file under two
        // spellings must match, not trip the foreign-report wire.
        final previous = Directory.current;
        Directory.current = _root.path;
        try {
          final compiler = _ReportingCompiler(reported: {'$usedDir/u.dill'});
          final unusedPath = '${_root.path}/out/m8.unused';
          final result = await _compile(
            'm_unused_spellings',
            ['pkg/lib/a.dart'],
            inputKmods: ['used', 'clean'],
            compiler: compiler,
            unusedInputsList: unusedPath,
          );
          expect(result.code, 0, reason: result.log);
          expect(File(unusedPath).readAsLinesSync(), ['clean']);
        } finally {
          Directory.current = previous;
        }
      },
    );
  });

  test('WorkRequest.inputs restricts which declared sources may be read and compiled', () async {
    Uint8List encodeInput(String path) {
      final pathBytes = utf8.encode(path);
      return Uint8List.fromList([0x0a, pathBytes.length, ...pathBytes]);
    }

    _write('pkg/lib/web.dart', 'class Web {}\n');
    _write('pkg/test/main_test.dart', "import 'package:pkg/web.dart';\n");
    final excludes = _module('excludes', []);
    final sidecar = _sidecar('excludes', {
      'pkg/lib/web.dart': 'dart:html is not a VM library',
    });

    // Declared on the command line via --input-source, but absent from WorkRequest.inputs.
    final missingFromWorkerInputs = await _compile(
      'worker_missing',
      ['pkg/test/main_test.dart'],
      inputSources: ['pkg/lib/web.dart'],
      inputKmods: [excludes],
      closureExcluded: [sidecar],
      noDrop: true,
      inputs: [encodeInput('${_root.path}/pkg/test/main_test.dart')],
    );
    expect(missingFromWorkerInputs.code, 1);
    expect(missingFromWorkerInputs.calls, isEmpty);
    expect(
      missingFromWorkerInputs.log,
      contains('pkg/lib/web.dart): source is not a declared input.'),
    );

    // Present in both --input-source and WorkRequest.inputs.
    final declaredInWorkerInputs = await _compile(
      'worker_ok',
      ['pkg/test/main_test.dart'],
      inputSources: ['pkg/lib/web.dart'],
      inputKmods: [excludes],
      closureExcluded: [sidecar],
      noDrop: true,
      inputs: [
        encodeInput('${_root.path}/pkg/test/main_test.dart'),
        encodeInput('${_root.path}/pkg/lib/web.dart'),
      ],
    );
    expect(declaredInWorkerInputs.code, 0);
    expect(
      declaredInWorkerInputs.sourcesPerCall.single,
      containsAll([_uri('pkg/test/main_test.dart'), 'package:pkg/web.dart']),
    );
  });

  test('--output-outline stages excluded sources so downstream entry modules compile them hermetically', () async {
    // pkg/lib/cyclic.dart imports package:dep/b.dart, which is not in pkg_m's inputKmods
    // (as in a cross-package cycle or split package).
    _write(
      'pkg/lib/cyclic.dart',
      "import 'package:dep/b.dart';\nint a() => 1;\n",
    );
    _write('dep/lib/b.dart', 'int b() => 2;\n');
    final pkgOutline = '${_root.path}/out/pkg_m.koutline';
    final pkgRes = await _compile('pkg_m', [
      'pkg/lib/cyclic.dart',
    ], outputOutline: pkgOutline);
    expect(pkgRes.code, 0);
    expect(pkgRes.excluded, {
      _uri('pkg/lib/cyclic.dart'):
          'imports package:dep/b.dart, which is not in this module closure',
    });
    expect(
      File('$pkgOutline/sources/pkg/lib/cyclic.dart').existsSync(),
      isTrue,
    );

    final depMod = _module('dep_m', [
      _Scc('0.dill', ['dep/lib/b.dart'], []),
    ]);

    // Remove the original pkg/lib/cyclic.dart from the workspace root to prove the
    // entry module reads it from the declared pkgOutline directory instead of the source tree.
    File('${_root.path}/pkg/lib/cyclic.dart').deleteSync();
    _write('pkg/test/main_test.dart', "import 'package:pkg/cyclic.dart';\n");

    final entry = await _compile(
      'entry_from_staged',
      ['pkg/test/main_test.dart'],
      inputKmods: [pkgOutline, depMod],
      closureExcluded: ['${_root.path}/out/pkg_m.vm_excluded.txt'],
      noDrop: true,
    );
    expect(entry.code, 0, reason: entry.log);
    expect(
      entry.sourcesPerCall.single,
      containsAll([_uri('pkg/test/main_test.dart'), 'package:pkg/cyclic.dart']),
    );
    // The entry compile must see a single isolated root holding the declared
    // origins (including the staged excluded source), never the sidecar
    // directory or the workspace roots alongside it.
    expect(_valuesAfter(entry.calls.single, '--multi-root'), [
      kernelWorkerUri('${_root.path}/out/entry_from_staged/.isolated_root'),
    ]);
  });

  test(
    'the same sources give the same kernels and index in any order',
    () async {
      _write('pkg/lib/b.dart', "import 'a.dart';\n");
      _write('pkg/lib/a.dart', 'class A {}\n');
      final first = await _compile('m1', ['pkg/lib/b.dart', 'pkg/lib/a.dart']);
      final second = await _compile('m2', ['pkg/lib/a.dart', 'pkg/lib/b.dart']);
      expect(first.defines, second.defines);
      expect(first.index, second.index);
    },
  );

  test('a custom --multi-root-scheme resolves package roots, direct custom-scheme imports, parts and sidecars', () async {
    const appPrefix = 'org-dartlang-app:///';
    _write(
      'app_package_config.json',
      jsonEncode({
        'configVersion': 2,
        'packages': [
          for (final name in ['pkg', 'dep'])
            {'name': name, 'rootUri': '$appPrefix$name', 'packageUri': 'lib/'},
        ],
      }),
    );
    _write(
      'pkg/lib/a.dart',
      "import '${appPrefix}pkg/lib/b.dart';\n"
          "part '${appPrefix}pkg/lib/p.dart';\n"
          'class A {}\n',
    );
    _write(
      'pkg/lib/p.dart',
      "part of '${appPrefix}pkg/lib/a.dart';\nclass P {}\n",
    );
    _write('pkg/lib/b.dart', "import 'dart:async';\nclass B {}\n");
    _write('pkg/lib/web.dart', "import 'dart:html';\nclass Web {}\n");
    _write(
      'pkg/lib/uses_web.dart',
      "import '${appPrefix}pkg/lib/web.dart';\nclass UsesWeb {}\n",
    );
    _write(
      'pkg/lib/bad_part.dart',
      "part 'other-scheme:///missing.dart';\nclass BadPart {}\n",
    );
    final result = await _compile(
      'app_m',
      [
        'pkg/lib/a.dart',
        'pkg/lib/p.dart',
        'pkg/lib/b.dart',
        'pkg/lib/web.dart',
        'pkg/lib/uses_web.dart',
        'pkg/lib/bad_part.dart',
      ],
      scheme: 'org-dartlang-app',
      packagesFile: '${_root.path}/app_package_config.json',
    );
    expect(result.code, 0);
    expect(result.defines, [
      ['pkg/lib/b.dart'],
      ['pkg/lib/a.dart', 'pkg/lib/p.dart'],
    ]);
    expect(result.excluded, {
      '${appPrefix}pkg/lib/web.dart': 'dart:html is not a VM library',
      '${appPrefix}pkg/lib/uses_web.dart':
          'imports ${appPrefix}pkg/lib/web.dart, which is excluded',
      '${appPrefix}pkg/lib/bad_part.dart': 'its part other-scheme:///missing.dart is not an input of this module',
    });
    expect(_valuesAfter(result.calls.first, '--multi-root-scheme'), [
      'org-dartlang-app',
    ]);
  });

  test('--extra-library makes dart:ui available for imports and conditional imports', () async {
    _write('pkg/lib/widget.dart', "import 'dart:ui';\nclass W {}\n");
    _write(
      'pkg/lib/entry.dart',
      "import 'stub.dart' if (dart.library.ui) 'real.dart';\n",
    );
    _write('pkg/lib/stub.dart', "import 'dart:html';\n");
    _write('pkg/lib/real.dart', "import 'widget.dart';\n");

    // Without `--extra-library ui`, `widget.dart` is excluded and `entry.dart`
    // takes `stub.dart` (which imports `dart:html` and is also excluded).
    final withoutUi = await _compile('no_ui', [
      'pkg/lib/widget.dart',
      'pkg/lib/entry.dart',
      'pkg/lib/stub.dart',
      'pkg/lib/real.dart',
    ]);
    expect(withoutUi.code, 0);
    expect(withoutUi.defines, isEmpty);

    // With `--extra-library ui`, `widget.dart` compiles and `entry.dart`
    // resolves its conditional import to `real.dart`.
    final withUi = await _compile(
      'with_ui',
      [
        'pkg/lib/widget.dart',
        'pkg/lib/entry.dart',
        'pkg/lib/stub.dart',
        'pkg/lib/real.dart',
      ],
      extraLibraries: ['ui', 'dart:nativewrappers'],
    );
    expect(withUi.code, 0);
    expect(withUi.defines, [
      ['pkg/lib/widget.dart'],
      ['pkg/lib/real.dart'],
      ['pkg/lib/entry.dart'],
    ]);
    expect(withUi.excluded, {
      _uri('pkg/lib/stub.dart'): 'dart:html is not a VM library',
    });
    for (final call in withUi.calls) {
      expect(call, isNot(contains('--extra-library')));
    }
  });

  test(
    '--libraries-platform includes both the named platform and vm libraries',
    () async {
      _write(
        'libraries.json',
        jsonEncode({
          'vm': {
            'libraries': {'async': {}, 'core': {}, 'io': {}},
          },
          'flutter': {
            'libraries': {'ui': {}},
          },
        }),
      );
      _write(
        'pkg/lib/both.dart',
        "import 'dart:io';\nimport 'dart:ui';\nclass Both {}\n",
      );
      final result = await _compile('flutter_m', [
        'pkg/lib/both.dart',
      ], librariesPlatform: 'flutter');
      expect(result.code, 0);
      expect(result.excluded, isEmpty);
      expect(result.defines, [
        ['pkg/lib/both.dart'],
      ]);
      expect(result.calls.single, isNot(contains('--libraries-platform')));
    },
  );

  test('--output-outline creates the outline directory and writes index.json without forwarding the flag', () async {
    _write('pkg/lib/a.dart', "import 'dart:async';\nclass A {}\n");
    final outlineDir = '${_root.path}/out/m.koutline';
    final result = await _compile('m', [
      'pkg/lib/a.dart',
    ], outputOutline: outlineDir);
    expect(result.code, 0);
    expect(result.calls.single, isNot(contains('--output-outline')));
    final outlineIndex = jsonDecode(
      File('$outlineDir/index.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    expect(outlineIndex, result.index);
  });

  test('stripDillToOutline preserves final instance field initializers only when the class has a const constructor or is a mixin', () {
    final rawWithConst = _buildMinimalFieldDill(hasConstConstructor: true);
    final strippedWithConst = stripDillToOutline(rawWithConst);
    expect(
      _containsSubsequence(strippedWithConst, [
        Tag.Something,
        Tag.PositiveIntLiteral,
        0,
        42,
      ]),
      isTrue,
      reason: 'non-static final instance field initializer must be preserved when class has a const constructor',
    );
    expect(
      _containsSubsequence(strippedWithConst, [
        Tag.Something,
        Tag.PositiveIntLiteral,
        0,
        99,
      ]),
      isFalse,
      reason: 'static final field initializer should be stripped',
    );
    expect(
      _containsSubsequence(strippedWithConst, [
        Tag.Something,
        Tag.PositiveIntLiteral,
        0,
        77,
      ]),
      isFalse,
      reason: 'mutable instance field initializer should be stripped',
    );
    expect(
      _containsSubsequence(strippedWithConst, [Tag.PositiveIntLiteral, 0, 88]),
      isTrue,
      reason: 'const procedure body (e.g. extension type const constructor) must be preserved',
    );
    expect(
      _containsSubsequence(strippedWithConst, [Tag.PositiveIntLiteral, 0, 66]),
      isFalse,
      reason: 'non-const procedure body should be stripped',
    );

    final rawWithoutConst = _buildMinimalFieldDill(hasConstConstructor: false);
    final strippedWithoutConst = stripDillToOutline(rawWithoutConst);
    expect(
      _containsSubsequence(strippedWithoutConst, [
        Tag.Something,
        Tag.PositiveIntLiteral,
        0,
        42,
      ]),
      isFalse,
      reason: 'final instance field initializer must be stripped when class has no const constructor and is not a mixin',
    );
  });

  test('scanDirectives and compileModule handle shebangs and generic annotations in directive prologues', () async {
    final scanned = scanDirectives(
      "#!/usr/bin/env dart\n"
      "@Tag<int>()\n"
      "@prefix.Meta<Map<String, List<int>>>.named('x')\n"
      "library my_lib;\n"
      "@Annot<String>()\n"
      "import 'package:pkg/a.dart';\n"
      "export 'package:pkg/b.dart';\n",
      {'core', 'async'},
    );
    expect(scanned, isNotNull);
    expect(scanned!.refs.map((r) => r.uri).toList(), [
      'package:pkg/a.dart',
      'package:pkg/b.dart',
    ]);

    _write(
      'pkg/lib/shebang_web.dart',
      "#!/usr/bin/env dart\nimport 'dart:html';\nvoid main() {}\n",
    );
    _write(
      'pkg/lib/generic_annot.dart',
      "@Tag<Map<String, List<int>>>.named()\nimport 'plain.dart';\nclass G {}\n",
    );
    _write('pkg/lib/plain.dart', "class Plain {}\n");
    final result = await _compile('prologue_m', [
      'pkg/lib/shebang_web.dart',
      'pkg/lib/generic_annot.dart',
      'pkg/lib/plain.dart',
    ]);
    expect(result.code, 0);
    expect(result.excluded, {
      _uri('pkg/lib/shebang_web.dart'): 'dart:html is not a VM library',
    });
    expect(result.defines, [
      ['pkg/lib/plain.dart'],
      ['pkg/lib/generic_annot.dart'],
    ]);
  });

  test('an entry module resolves relative ../lib/ imports under the multi-root scheme and excludes own keys from index imports', () async {
    _write('dep/lib/ext.dart', 'class Ext {}\n');
    _write(
      'pkg/lib/local_helper.dart',
      "import 'package:dep/ext.dart';\nint helper() => 1;\n",
    );
    _write(
      'pkg/test/my_test.dart',
      "import '../lib/local_helper.dart';\nvoid main() { helper(); }\n",
    );
    final depMod = _module('dep_mod', [
      _Scc('0.dill', ['dep/lib/ext.dart'], []),
    ]);
    final entry = await _compile(
      'rel_entry',
      ['pkg/test/my_test.dart', 'pkg/lib/local_helper.dart'],
      inputKmods: [depMod],
      noDrop: true,
    );
    expect(entry.code, 0);
    expect(
      entry.sourcesPerCall.single,
      containsAll([
        _uri('pkg/test/my_test.dart'),
        _uri('pkg/lib/local_helper.dart'),
      ]),
      reason: 'relative ../lib/ import from test/ resolves under multi-root scheme in CFE',
    );
    final sccImports =
        ((entry.index['sccs'] as List).single
                as Map<String, dynamic>)['imports']
            as List;
    expect(
      sccImports,
      ['dep/lib/ext.dart'],
      reason: 'entry index imports must only list external module keys, not entry own sources',
    );
  });

  test('KernelLinkCache detects in-place mutations with identical size and mtime when digests are absent', () {
    final cache = KernelLinkCache();
    final modDir = Directory('${_root.path}/kmod')..createSync(recursive: true);
    final indexFile = File('${modDir.path}/index.json');
    final dillFile = File('${modDir.path}/0.dill');
    final baseKeysFile = File('${_root.path}/base.keys');
    final outFile = File('${_root.path}/linked.dill');

    final indexV1 = jsonEncode({
      'version': 1,
      'sccs': [
        {
          'dill': '0.dill',
          'defines': ['pkg/lib/a.dart'],
          'imports': <String>[],
        },
      ],
    });
    final indexV2 = jsonEncode({
      'version': 1,
      'sccs': [
        {
          'dill': '0.dill',
          'defines': ['pkg/lib/b.dart'],
          'imports': <String>[],
        },
      ],
    });
    expect(indexV1.length, indexV2.length);

    final fixedTime = DateTime.fromMillisecondsSinceEpoch(1700000000000);
    indexFile.writeAsStringSync(indexV1);
    indexFile.setLastModifiedSync(fixedTime);

    dillFile.writeAsBytesSync([1, 2, 3, 4]);
    dillFile.setLastModifiedSync(fixedTime);

    baseKeysFile.writeAsStringSync('pkg/lib/x.dart\n');
    baseKeysFile.setLastModifiedSync(fixedTime);

    final err1 = StringBuffer();
    expect(
      linkOne(
        [outFile.path, modDir.path],
        cache: cache,
        inputs: null,
        errSink: err1,
      ),
      0,
    );
    expect(outFile.readAsBytesSync(), [1, 2, 3, 4]);
    expect(cache.baseKeysOf(baseKeysFile.path, null), {'pkg/lib/x.dart'});

    // Mutate index.json, 0.dill, and base.keys in-place with identical size and mtime.
    indexFile.writeAsStringSync(indexV2);
    indexFile.setLastModifiedSync(fixedTime);
    expect(indexFile.statSync().size, indexV1.length);
    expect(indexFile.statSync().modified, fixedTime);

    dillFile.writeAsBytesSync([9, 8, 7, 6]);
    dillFile.setLastModifiedSync(fixedTime);
    expect(dillFile.statSync().size, 4);
    expect(dillFile.statSync().modified, fixedTime);

    baseKeysFile.writeAsStringSync('pkg/lib/y.dart\n');
    baseKeysFile.setLastModifiedSync(fixedTime);
    expect(baseKeysFile.statSync().modified, fixedTime);

    final err2 = StringBuffer();
    expect(
      linkOne(
        [outFile.path, modDir.path],
        cache: cache,
        inputs: const {},
        errSink: err2,
      ),
      0,
    );
    expect(
      outFile.readAsBytesSync(),
      [9, 8, 7, 6],
      reason: 'dillBytesOf must not return stale bytes on same-(size, mtime) mutation',
    );
    expect(
      cache.kernelsOf(modDir.path, const {}).single.defines,
      ['pkg/lib/b.dart'],
      reason: 'kernelsOf must not return stale index.json on same-(size, mtime) mutation',
    );
    expect(
      cache.baseKeysOf(baseKeysFile.path, const {}),
      {'pkg/lib/y.dart'},
      reason: 'baseKeysOf must not return stale keys on same-(size, mtime) mutation',
    );
  });

  test('KernelLinkCache normalizes ./ prefixes when matching WorkRequest.inputs digests', () {
    final cache = KernelLinkCache();
    final prevCwd = Directory.current;
    Directory.current = _root;
    try {
      Directory('norm_mod').createSync(recursive: true);
      final dillFile = File('norm_mod/0.dill')..writeAsBytesSync([10, 20, 30]);
      final digest1 = Uint8List.fromList([1, 1, 1, 1]);
      final digest2 = Uint8List.fromList([2, 2, 2, 2]);

      // Populate cache using './norm_mod/0.dill' while inputs key is 'norm_mod/0.dill'.
      final bytes1 = cache.dillBytesOf('./norm_mod/0.dill', {
        'norm_mod/0.dill': digest1,
      });
      expect(bytes1, [10, 20, 30]);

      // Overwrite on disk, but pass the SAME digest1 via normalized key: should hit cache.
      dillFile.writeAsBytesSync([40, 50, 60]);
      final cachedHit = cache.dillBytesOf('./norm_mod/0.dill', {
        'norm_mod/0.dill': digest1,
      });
      expect(cachedHit, [10, 20, 30]);

      // Pass a new digest2: should invalidate and read new bytes from disk.
      final updated = cache.dillBytesOf('./norm_mod/0.dill', {
        'norm_mod/0.dill': digest2,
      });
      expect(updated, [40, 50, 60]);
    } finally {
      Directory.current = prevCwd;
    }
  });

  test('stripDillToOutline preserves member bodies and field initializers for legacy-class mixins compiled by kernel_worker', () async {
    final sdkDir = File(Platform.resolvedExecutable).parent.parent;
    final exeSuffix = Platform.isWindows ? '.exe' : '';
    final dartaotruntime = '${sdkDir.path}/bin/dartaotruntime$exeSuffix';
    final kernelWorker =
        '${sdkDir.path}/bin/snapshots/kernel_worker_aot.dart.snapshot';
    final platformDill = '${sdkDir.path}/lib/_internal/vm_platform_strong.dill';
    expect(File(dartaotruntime).existsSync(), isTrue);
    expect(File(kernelWorker).existsSync(), isTrue);
    expect(File(platformDill).existsSync(), isTrue);

    _write(
      'real_packages.json',
      jsonEncode({
        'configVersion': 2,
        'packages': [
          {
            'name': 'legacy',
            'rootUri': '${_prefix}legacy',
            'packageUri': 'lib/',
            'languageVersion': '2.19',
          },
          {
            'name': 'modern',
            'rootUri': '${_prefix}modern',
            'packageUri': 'lib/',
            'languageVersion': '3.0',
          },
          {
            'name': 'app',
            'rootUri': '${_prefix}app',
            'packageUri': 'lib/',
            'languageVersion': '3.0',
          },
        ],
      }),
    );

    Future<Uint8List> compileWithKernelWorker(
      String outName,
      List<String> sources, {
      List<String> inputSummaries = const [],
    }) async {
      final outPath = '${_root.path}/$outName';
      final res = await Process.run(dartaotruntime, [
        kernelWorker,
        ...kernelWorkerArgs([
          '--target',
          'vm',
          '--dart-sdk-summary',
          platformDill,
          '--packages-file',
          '${_root.path}/real_packages.json',
          '--multi-root',
          _root.path,
          '--multi-root-scheme',
          'org-dartlang-root',
          '--no-summary-only',
          '--exclude-non-sources',
          for (final s in inputSummaries) ...['--input-summary', s],
          for (final s in sources) ...['--source', s],
          '--output',
          outPath,
        ]),
      ]);
      expect(
        res.exitCode,
        0,
        reason: 'kernel_worker failed: ${res.stdout}\n${res.stderr}',
      );
      return File(outPath).readAsBytesSync();
    }

    // 1. Pre-3.0 library with a plain `class` (no `mixin` or `mixin class` modifier).
    _write(
      'legacy/lib/legacy.dart',
      'class LegacyMixin {\n'
          "  final String tag = 'legacy-tag-v1';\n"
          '  int count = 10;\n'
          "  String get label => '\$tag:\$count';\n"
          '  set bump(int delta) {\n'
          '    count += delta;\n'
          '  }\n'
          "  String describe(String who) => 'legacy-body-v1:\$who[\$label]';\n"
          '}\n'
          'class ChainedLegacy = Object with LegacyMixin;\n',
    );
    final legacyDillV1 = await compileWithKernelWorker('legacy_v1.dill', [
      'package:legacy/legacy.dart',
    ]);

    final err1 = StringBuffer();
    final legacyOutlineV1 = stripDillToOutline(legacyDillV1, errSink: err1);
    expect(err1.toString(), isEmpty);

    // Member bodies and mutable/final field initializers must survive in the outline.
    expect(
      _containsSubsequence(legacyOutlineV1, utf8.encode('legacy-body-v1:')),
      isTrue,
      reason: 'method body of a pre-3.0 class must survive in .koutline',
    );
    expect(
      _containsSubsequence(legacyOutlineV1, utf8.encode('legacy-tag-v1')),
      isTrue,
      reason: 'field initializer of a pre-3.0 class must survive in .koutline',
    );

    // 2. Body edit in the pre-3.0 class must change the outline bytes so dependents rebuild.
    _write(
      'legacy/lib/legacy.dart',
      'class LegacyMixin {\n'
          "  final String tag = 'legacy-tag-v1';\n"
          '  int count = 25;\n'
          "  String get label => '\$tag:\$count';\n"
          '  set bump(int delta) {\n'
          '    count += delta * 2;\n'
          '  }\n'
          "  String describe(String who) => 'legacy-body-v2:\$who[\$label]';\n"
          '}\n'
          'class ChainedLegacy = Object with LegacyMixin;\n',
    );
    final legacyDillV2 = await compileWithKernelWorker('legacy_v2.dill', [
      'package:legacy/legacy.dart',
    ]);
    final legacyOutlineV2 = stripDillToOutline(legacyDillV2);
    expect(
      legacyOutlineV2,
      isNot(equals(legacyOutlineV1)),
      reason: 'editing a member body or field initializer in a pre-3.0 class must change .koutline bytes',
    );

    // 3. Modern (Dart 3.0) library: plain class bodies are stripped, mixin / mixin class bodies survive.
    _write(
      'modern/lib/modern.dart',
      'class PlainModern {\n'
          '  int m = 777;\n'
          "  String plainBody() => 'plain-modern-secret-body';\n"
          '}\n'
          'mixin ModernMixin {\n'
          "  String mixinBody() => 'modern-mixin-kept-body';\n"
          '}\n'
          'mixin class ModernMixinClass {\n'
          "  String mixinClassBody() => 'modern-mixin-class-kept-body';\n"
          '}\n',
    );
    final modernDill = await compileWithKernelWorker('modern.dill', [
      'package:modern/modern.dart',
    ]);
    final modernOutline = stripDillToOutline(modernDill);
    expect(
      _containsSubsequence(
        modernOutline,
        utf8.encode('plain-modern-secret-body'),
      ),
      isFalse,
      reason: 'plain class in a Dart 3 library is not a mixin and its body must be stripped',
    );
    expect(
      _containsSubsequence(
        modernOutline,
        utf8.encode('modern-mixin-kept-body'),
      ),
      isTrue,
      reason: 'mixin declaration body must survive in .koutline',
    );
    expect(
      _containsSubsequence(
        modernOutline,
        utf8.encode('modern-mixin-class-kept-body'),
      ),
      isTrue,
      reason: 'mixin class declaration body must survive in .koutline',
    );

    // Also verify unknown format version fallback on a real kernel_worker dill.
    final futureModernDill = Uint8List.fromList(modernDill);
    ByteData.sublistView(futureModernDill).setUint32(4, 999);
    final futureOutlineErr = StringBuffer();
    expect(
      stripDillToOutline(futureModernDill, errSink: futureOutlineErr),
      equals(futureModernDill),
    );
    expect(
      futureOutlineErr.toString(),
      contains('unsupported kernel format version 999'),
    );
    final futureSrcErr = StringBuffer();
    expect(
      stripSourceCodeFromDill(futureModernDill, errSink: futureSrcErr),
      equals(futureModernDill),
    );
    expect(
      futureSrcErr.toString(),
      contains('unsupported kernel format version 999'),
    );

    // 4. Compile a Dart 3 consumer against the stripped legacy outline and run on the VM.
    final outlinePath = '${_root.path}/legacy_v1.koutline.dill';
    File(outlinePath).writeAsBytesSync(legacyOutlineV1);
    _write(
      'app/bin/main.dart',
      "import 'package:legacy/legacy.dart';\n"
          'class Thing with LegacyMixin {}\n'
          'class SubChained extends ChainedLegacy {}\n'
          'void main() {\n'
          '  final t = Thing()..bump = 5;\n'
          "  print(t.describe('thing'));\n"
          '  final s = SubChained()..bump = 2;\n'
          "  print(s.describe('chained'));\n"
          '}\n',
    );
    final appDill = await compileWithKernelWorker(
      'app.dill',
      ['${_prefix}app/bin/main.dart'],
      inputSummaries: [outlinePath],
    );
    final legacyKmodBytes = stripSourceCodeFromDill(legacyDillV1);
    final linkedPath = '${_root.path}/app_linked.dill';
    final linkedBytes = BytesBuilder(copy: false)
      ..add(legacyKmodBytes)
      ..add(appDill);
    File(linkedPath).writeAsBytesSync(linkedBytes.takeBytes());

    final runRes = await Process.run(Platform.resolvedExecutable, [linkedPath]);
    expect(
      runRes.exitCode,
      0,
      reason: 'VM run failed: ${runRes.stdout}\n${runRes.stderr}',
    );
    expect(
      (runRes.stdout as String).replaceAll('\r\n', '\n'),
      'legacy-body-v1:thing[legacy-tag-v1:15]\n'
      'legacy-body-v1:chained[legacy-tag-v1:12]\n',
    );
  });

  test('stripDillToOutline and stripSourceCodeFromDill reject unknown format versions with a diagnostic and return unstripped bytes', () {
    expect(supportedKernelFormatVersions, {138});
    for (final badVersion in [0, 120, 137, 139, 999]) {
      final dill = _buildMinimalFieldDill(formatVersion: badVersion);
      final snapshot = Uint8List.fromList(dill);

      final outlineErr = StringBuffer();
      final outlineResult = stripDillToOutline(dill, errSink: outlineErr);
      expect(
        outlineResult,
        equals(snapshot),
        reason:
            'stripDillToOutline must return unstripped bytes for version $badVersion',
      );
      expect(
        outlineErr.toString(),
        allOf(
          contains('unsupported kernel format version $badVersion'),
          contains('falling back to unstripped dill'),
        ),
      );

      final srcErr = StringBuffer();
      final srcResult = stripSourceCodeFromDill(dill, errSink: srcErr);
      expect(
        srcResult,
        equals(snapshot),
        reason:
            'stripSourceCodeFromDill must return unstripped bytes for version $badVersion',
      );
      expect(
        srcErr.toString(),
        allOf(
          contains('unsupported kernel format version $badVersion'),
          contains('falling back to unstripped dill'),
        ),
      );
    }

    // Multi-component dill where the second component has an unknown format version:
    // stripDillToOutline must fall back to the full unstripped input bytes.
    final validPart = _buildMinimalFieldDill();
    final invalidPart = _buildMinimalFieldDill(formatVersion: 999);
    final combined = Uint8List.fromList([...validPart, ...invalidPart]);
    final combinedSnapshot = Uint8List.fromList(combined);
    final multiErr = StringBuffer();
    final multiResult = stripDillToOutline(combined, errSink: multiErr);
    expect(multiResult, equals(combinedSnapshot));
    expect(
      multiErr.toString(),
      contains('unsupported kernel format version 999'),
    );
  });

  test('compileModule preserves comma-containing defines across modular kernel_worker compiles', () async {
    final sdkDir = File(Platform.resolvedExecutable).parent.parent;
    final exeSuffix = Platform.isWindows ? '.exe' : '';
    final dartaotruntime = '${sdkDir.path}/bin/dartaotruntime$exeSuffix';
    final kernelWorker =
        '${sdkDir.path}/bin/snapshots/kernel_worker_aot.dart.snapshot';
    final platformDill = '${sdkDir.path}/lib/_internal/vm_platform_strong.dill';
    final librariesJson = '${sdkDir.path}/lib/libraries.json';

    _write(
      'pkg/lib/a.dart',
      "const libVal = String.fromEnvironment('COMMA_VAL');\n"
          "const libEq = libVal == 'a,b';\n"
          "const libSwitched = libVal == 'a,b' ? 'matched-lib' : 'missed-lib';\n",
    );
    _write(
      'pkg/bin/main.dart',
      "import 'package:pkg/a.dart';\n"
          "void main() {\n"
          "  const mainVal = String.fromEnvironment('COMMA_VAL');\n"
          "  const mainEq = mainVal == 'a,b';\n"
          "  const mainSwitched = mainVal == 'a,b' ? 'matched-main' : 'missed-main';\n"
          "  print('\$libVal|\$libEq|\$libSwitched|\$mainVal|\$mainEq|\$mainSwitched');\n"
          "}\n",
    );

    final realCompiler = _RealOneShotCompiler(dartaotruntime, kernelWorker);
    final libOut = '${_root.path}/out/lib_m.kmod';
    final libOutline = '${_root.path}/out/lib_m.koutline';
    final libExcluded = '$libOut.vm_excluded.txt';
    final libLog = StringBuffer();
    final libCode = await compileModule(
      [
        '--target',
        'vm',
        '--dart-sdk-summary',
        platformDill,
        '--packages-file',
        '${_root.path}/package_config.json',
        '--libraries-json',
        librariesJson,
        '--multi-root',
        _root.path,
        '--multi-root-scheme',
        'org-dartlang-root',
        '-DCOMMA_VAL=a,b',
        '--no-summary-only',
        '--exclude-non-sources',
        '--source',
        'package:pkg/a.dart',
        '--output',
        libOut,
        '--output-outline',
        libOutline,
        '--excluded-output',
        libExcluded,
      ],
      realCompiler,
      libLog,
      const [],
    );
    expect(libCode, 0, reason: libLog.toString());

    final entryOut = '${_root.path}/out/entry.kmod';
    final entryExcluded = '$entryOut.vm_excluded.txt';
    final entryLog = StringBuffer();
    final entryCode = await compileModule(
      [
        '--target',
        'vm',
        '--dart-sdk-summary',
        platformDill,
        '--packages-file',
        '${_root.path}/package_config.json',
        '--libraries-json',
        librariesJson,
        '--multi-root',
        _root.path,
        '--multi-root-scheme',
        'org-dartlang-root',
        '-DCOMMA_VAL=a,b',
        '--no-summary-only',
        '--exclude-non-sources',
        '--input-kmod',
        libOutline,
        '--source',
        '${_prefix}pkg/bin/main.dart',
        '--output',
        entryOut,
        '--excluded-output',
        entryExcluded,
        '--no-drop',
      ],
      realCompiler,
      entryLog,
      const [],
    );
    expect(entryCode, 0, reason: entryLog.toString());

    final linkedPath = '${_root.path}/out/linked.dill';
    final linkErr = StringBuffer();
    expect(
      linkOne(
        [linkedPath, entryOut, libOut],
        cache: KernelLinkCache(),
        inputs: null,
        errSink: linkErr,
      ),
      0,
      reason: linkErr.toString(),
    );

    final runRes = await Process.run(Platform.resolvedExecutable, [linkedPath]);
    expect(runRes.exitCode, 0, reason: '${runRes.stdout}\n${runRes.stderr}');
    expect(
      (runRes.stdout as String).trim(),
      'a,b|true|matched-lib|a,b|true|matched-main',
    );
  });

  test('whole-program and modular kernel compiles are byte-identical across clean builds and checkout paths', () async {
    final sdkDir = File(Platform.resolvedExecutable).parent.parent;
    final exeSuffix = Platform.isWindows ? '.exe' : '';
    final dartaotruntime = '${sdkDir.path}/bin/dartaotruntime$exeSuffix';
    final genKernel =
        '${sdkDir.path}/bin/snapshots/gen_kernel_aot.dart.snapshot';
    final kernelWorker =
        '${sdkDir.path}/bin/snapshots/kernel_worker_aot.dart.snapshot';
    final platformDill = '${sdkDir.path}/lib/_internal/vm_platform_strong.dill';
    final productPlatformDill =
        '${sdkDir.path}/lib/_internal/vm_platform_product.dill';
    final librariesJson = '${sdkDir.path}/lib/libraries.json';

    Future<
      ({
        Uint8List wholeDill,
        Uint8List modularDill,
        Uint8List koutline,
        String wholeOut,
        String modularOut,
      })
    >
    buildInCheckout(String relCheckout) async {
      final dir = Directory('${_root.path}/$relCheckout')
        ..createSync(recursive: true);
      void writeCheckout(String rel, String content) {
        final f = File('${dir.path}/$rel');
        f.parent.createSync(recursive: true);
        f.writeAsStringSync(content);
      }

      writeCheckout(
        'package_config.json',
        '{\n'
            '  "configVersion": 2,\n'
            '  "packages": [\n'
            '    {"name": "pkg", "rootUri": "org-dartlang-root:///pkg", "packageUri": "lib/", "languageVersion": "3.0"}\n'
            '  ]\n'
            '}\n',
      );
      writeCheckout(
        'pkg/lib/where.dart',
        "part 'gen.dart';\n"
            'const bool libProduct = bool.fromEnvironment(\'dart.vm.product\');\n'
            'String libFrame() => StackTrace.current.toString().split(\'\\n\')[0];\n'
            'String callerFrame() => StackTrace.current.toString().split(\'\\n\')[1];\n',
      );
      writeCheckout(
        'bazel-out/k8-fastbuild/bin/pkg/lib/gen.dart',
        "part of 'where.dart';\n"
            "String generatedGreeting() => 'gen:\$libProduct';\n",
      );
      writeCheckout(
        'app/lib/helper.dart',
        'String helperFrame() => StackTrace.current.toString().split(\'\\n\')[0];\n',
      );
      writeCheckout(
        'app/bin/probe.dart',
        "import 'dart:io';\n"
            "import 'package:pkg/where.dart';\n"
            "import '../lib/helper.dart';\n"
            'void main() {\n'
            "  print('product=\${const bool.fromEnvironment('dart.vm.product')}');\n"
            "  print('gen=\${generatedGreeting()}');\n"
            "  print('scriptIsDill=\${Platform.script.scheme == 'file' && Platform.script.path.endsWith('.dill')}');\n"
            "  print('caller=\${callerFrame()}');\n"
            "  print('lib=\${libFrame()}');\n"
            "  print('helper=\${helperFrame()}');\n"
            '}\n',
      );

      final wholePath =
          '${dir.path}/bazel-out/k8-fastbuild/bin/probe_whole.dill';
      File(wholePath).parent.createSync(recursive: true);
      final genRes = await Process.run(dartaotruntime, [
        genKernel,
        '--platform',
        productPlatformDill,
        '--packages',
        'package_config.json',
        '--filesystem-scheme',
        'org-dartlang-root',
        '--filesystem-root',
        '.',
        '--filesystem-root',
        'bazel-out/k8-fastbuild/bin',
        '-Ddart.vm.product=true',
        '-Ddart.vm.asan=false',
        '-Ddart.vm.msan=false',
        '-Ddart.vm.tsan=false',
        '-o',
        'bazel-out/k8-fastbuild/bin/probe_whole.dill',
        'org-dartlang-root:///app/bin/probe.dart',
      ], workingDirectory: dir.path);
      expect(
        genRes.exitCode,
        0,
        reason: 'gen_kernel failed: ${genRes.stdout}\n${genRes.stderr}',
      );

      final compiler = _CwdOneShotCompiler(
        dartaotruntime,
        kernelWorker,
        dir.path,
      );
      final libKmod = 'bazel-out/k8-fastbuild/bin/pkg.kmod';
      final libKoutline = 'bazel-out/k8-fastbuild/bin/pkg.koutline';
      final libExcluded = 'bazel-out/k8-fastbuild/bin/pkg.vm_excluded.txt';
      final libLog = StringBuffer();
      final prevCurrent = Directory.current;
      Directory.current = dir;
      try {
        final libCode = await compileModule(
          [
            '--target',
            'vm',
            '--dart-sdk-summary',
            platformDill,
            '--packages-file',
            'package_config.json',
            '--libraries-json',
            librariesJson,
            '--multi-root',
            '.',
            '--multi-root',
            'bazel-out/k8-fastbuild/bin',
            '--multi-root-scheme',
            'org-dartlang-root',
            '-Ddart.vm.product=true',
            '-Ddart.vm.asan=false',
            '-Ddart.vm.msan=false',
            '-Ddart.vm.tsan=false',
            '--no-summary-only',
            '--exclude-non-sources',
            '--source',
            'package:pkg/where.dart',
            '--source',
            'package:pkg/gen.dart',
            '--output',
            libKmod,
            '--output-outline',
            libKoutline,
            '--excluded-output',
            libExcluded,
          ],
          compiler,
          libLog,
          const [],
        );
        expect(libCode, 0, reason: libLog.toString());

        final entryKmod = 'bazel-out/k8-fastbuild/bin/entry.kmod';
        final entryExcluded =
            'bazel-out/k8-fastbuild/bin/entry.vm_excluded.txt';
        final entryLog = StringBuffer();
        final entryCode = await compileModule(
          [
            '--target',
            'vm',
            '--dart-sdk-summary',
            platformDill,
            '--packages-file',
            'package_config.json',
            '--libraries-json',
            librariesJson,
            '--multi-root',
            '.',
            '--multi-root',
            'bazel-out/k8-fastbuild/bin',
            '--multi-root-scheme',
            'org-dartlang-root',
            '-Ddart.vm.product=true',
            '-Ddart.vm.asan=false',
            '-Ddart.vm.msan=false',
            '-Ddart.vm.tsan=false',
            '--no-summary-only',
            '--exclude-non-sources',
            '--input-kmod',
            libKoutline,
            '--source',
            'org-dartlang-root:///app/bin/probe.dart',
            '--source',
            'org-dartlang-root:///app/lib/helper.dart',
            '--output',
            entryKmod,
            '--excluded-output',
            entryExcluded,
            '--no-drop',
          ],
          compiler,
          entryLog,
          const [],
        );
        expect(entryCode, 0, reason: entryLog.toString());

        final modularPath = 'bazel-out/k8-fastbuild/bin/probe_modular.dill';
        final linkErr = StringBuffer();
        expect(
          linkOne(
            [modularPath, entryKmod, libKmod],
            cache: KernelLinkCache(),
            inputs: null,
            errSink: linkErr,
          ),
          0,
          reason: linkErr.toString(),
        );
      } finally {
        Directory.current = prevCurrent;
      }

      final modularPath =
          '${dir.path}/bazel-out/k8-fastbuild/bin/probe_modular.dill';
      final wholeRun = await Process.run(Platform.resolvedExecutable, [
        wholePath,
      ]);
      expect(wholeRun.exitCode, 0, reason: '${wholeRun.stderr}');
      final modularRun = await Process.run(Platform.resolvedExecutable, [
        modularPath,
      ]);
      expect(modularRun.exitCode, 0, reason: '${modularRun.stderr}');

      return (
        wholeDill: File(wholePath).readAsBytesSync(),
        modularDill: File(modularPath).readAsBytesSync(),
        koutline: File(
          '${dir.path}/bazel-out/k8-fastbuild/bin/pkg.koutline/0.dill',
        ).readAsBytesSync(),
        wholeOut: (wholeRun.stdout as String).replaceAll('\r\n', '\n'),
        modularOut: (modularRun.stdout as String).replaceAll('\r\n', '\n'),
      );
    }

    final buildA1 = await buildInCheckout('checkout_a');
    Directory('${_root.path}/checkout_a').deleteSync(recursive: true);
    final buildA2 = await buildInCheckout('checkout_a');
    final buildB = await buildInCheckout('deep/nested/path/checkout_b');

    expect(
      buildA1.wholeDill,
      equals(buildA2.wholeDill),
      reason: 'whole-program kernel must be byte-identical across clean builds',
    );
    expect(
      buildA1.wholeDill,
      equals(buildB.wholeDill),
      reason:
          'whole-program kernel must be byte-identical across checkout paths',
    );
    expect(
      buildA1.modularDill,
      equals(buildA2.modularDill),
      reason: 'modular kernel must be byte-identical across clean builds',
    );
    expect(
      buildA1.modularDill,
      equals(buildB.modularDill),
      reason: 'modular kernel must be byte-identical across checkout paths',
    );
    expect(
      buildA1.koutline,
      equals(buildB.koutline),
      reason: '.koutline must be byte-identical across checkout paths',
    );
    expect(
      _containsSubsequence(buildA1.wholeDill, utf8.encode('checkout_a')),
      isFalse,
    );
    expect(
      _containsSubsequence(buildA1.modularDill, utf8.encode('checkout_a')),
      isFalse,
    );
    expect(
      buildA1.wholeOut,
      equals(buildA1.modularOut),
      reason: 'modular and whole-program kernels must print identical output',
    );
    expect(buildA1.wholeOut, equals(buildB.wholeOut));
    expect(buildA1.modularOut, contains('product=true\n'));
    expect(buildA1.modularOut, contains('gen=gen:true\n'));
    expect(buildA1.modularOut, contains('scriptIsDill=true\n'));
    expect(
      buildA1.modularOut,
      contains('(org-dartlang-root:///app/bin/probe.dart:'),
    );
    expect(buildA1.modularOut, contains('(package:pkg/where.dart:'));
    expect(
      buildA1.modularOut,
      contains('(org-dartlang-root:///app/lib/helper.dart:'),
    );
  });

  test('stripSourceCodeFromDill preserves 8-byte alignment of binaryOffsetForMetadataPayloads across all source size deltas', () {
    for (var srcLen = 1; srcLen <= 16; srcLen++) {
      final dill = _buildMinimalDillWithSourceAndMetadata(srcLen: srcLen);
      final stripped = stripSourceCodeFromDill(dill);
      expect(stripped.length % 8, 0, reason: 'srcLen=$srcLen');
      final bd = ByteData.sublistView(stripped);
      expect(bd.getUint32(stripped.length - 4), stripped.length);
      final libCount = bd.getUint32(stripped.length - 8);
      final idxCount = libCount + 12;
      final rawIdxStart = stripped.length - idxCount * 4;
      final offMetadataPayloads = bd.getUint32(rawIdxStart + 4 * 4);
      final offMetadataMappings = bd.getUint32(rawIdxStart + 5 * 4);
      final offStringTable = bd.getUint32(rawIdxStart + 6 * 4);
      expect(
        offMetadataPayloads % 8,
        0,
        reason:
            'binaryOffsetForMetadataPayloads ($offMetadataPayloads) must be 8-byte aligned for srcLen=$srcLen',
      );
      expect(
        Uint8List.sublistView(
          stripped,
          offMetadataPayloads,
          offMetadataMappings,
        ),
        equals([0xde, 0xad, 0xbe, 0xef, 0xca, 0xfe, 0xba, 0xbe]),
        reason: 'metadata payloads must be preserved intact for srcLen=$srcLen',
      );
      expect(
        Uint8List.sublistView(stripped, offMetadataMappings, offStringTable),
        equals([0x11, 0x22, 0x33, 0x44, 0x00, 0x00, 0x00, 0x01]),
        reason: 'metadata mappings must be preserved intact for srcLen=$srcLen',
      );
    }
  });

  test('modular outline preserves mixin stack trace offsets, UnevaluatedConstant children, and non-const final field edit cutoff across supported SDKs', () async {
    expect(_sdkDartPaths.length, greaterThanOrEqualTo(2));
    final seenSdkVersions = <String>{};
    final exeSuffix = Platform.isWindows ? '.exe' : '';

    for (final dartBin in _sdkDartPaths) {
      final sdkDir = File(dartBin).parent.parent;
      final sdkVersion = File('${sdkDir.path}/version')
          .readAsStringSync()
          .trim();
      seenSdkVersions.add(sdkVersion);
      final dartaotruntime = '${sdkDir.path}/bin/dartaotruntime$exeSuffix';
      final kernelWorker =
          '${sdkDir.path}/bin/snapshots/kernel_worker_aot.dart.snapshot';
      final platformDill =
          '${sdkDir.path}/lib/_internal/vm_platform_strong.dill';
      final librariesJson = '${sdkDir.path}/lib/libraries.json';

      _write(
        'multi_sdk_packages.json',
        jsonEncode({
          'configVersion': 2,
          'packages': [
            {
              'name': 'pkg',
              'rootUri': '${_prefix}pkg',
              'packageUri': 'lib/',
              'languageVersion': '3.0',
            },
            {
              'name': 'legacy',
              'rootUri': '${_prefix}legacy',
              'packageUri': 'lib/',
              'languageVersion': '2.19',
            },
            {
              'name': 'app',
              'rootUri': '${_prefix}app',
              'packageUri': 'lib/',
              'languageVersion': '3.0',
            },
          ],
        }),
      );

      // 1. Library with:
      //    - @Meta(String.fromEnvironment(...), [10, 20]) producing an UnevaluatedConstant
      //      whose child constants ([10, 20], 'ENV_TAG', 'def,val') only appear inside the
      //      UnevaluatedConstant expression.
      //    - NonConstBox: final instance field initializer (must be stripped from .koutline).
      //    - ConstBox: final instance field initializer with const constructor (must be kept).
      //    - ThrowingMixin: mixin method on line 24 that throws so stack trace line/column is checked.
      String libSource({required int nonConstInit, required int constInit}) =>
          'class Meta {\n'
          '  final String tag;\n'
          '  final List<int> nums;\n'
          '  const Meta(this.tag, this.nums);\n'
          '}\n'
          '\n'
          "@Meta(String.fromEnvironment('ENV_TAG', defaultValue: 'def,val'), [10, 20])\n"
          'class Annotated {\n'
          '  const Annotated();\n'
          '}\n'
          '\n'
          'class NonConstBox {\n'
          '  final int secret = $nonConstInit;\n'
          '  NonConstBox();\n'
          '}\n'
          '\n'
          'class ConstBox {\n'
          '  final int val = $constInit;\n'
          '  const ConstBox();\n'
          '}\n'
          '\n'
          'mixin ThrowingMixin {\n'
          '  int failHere(int x) {\n'
          '    if (x > 0) {\n'
          "      throw StateError('mixin-boom-\$x');\n"
          '    }\n'
          '    return x;\n'
          '  }\n'
          '}\n';

      _write('pkg/lib/a.dart', libSource(nonConstInit: 111, constInit: 222));
      _write(
        'legacy/lib/legacy_throw.dart',
        '// @dart=2.19\n'
            'class LegacyThrowingMixin {\n'
            '  int legacyFail(int y) {\n'
            '    if (y > 0) {\n'
            "      throw StateError('legacy-boom-\$y');\n"
            '    }\n'
            '    return y;\n'
            '  }\n'
            '}\n',
      );
      _write(
        'app/bin/main.dart',
        "import 'package:pkg/a.dart';\n"
            "import 'package:legacy/legacy_throw.dart';\n"
            '\n'
            'class MixedIn with ThrowingMixin, LegacyThrowingMixin {}\n'
            '\n'
            'String firstFrame(Object st, String pattern) {\n'
            '  for (final line in st.toString().split(\'\\n\')) {\n'
            '    if (line.contains(pattern)) return line.trim();\n'
            '  }\n'
            "  return 'missing';\n"
            '}\n'
            '\n'
            'void main() {\n'
            '  const box = ConstBox();\n'
            '  final nonConst = NonConstBox();\n'
            '  const envVal = String.fromEnvironment(\'ENV_TAG\', defaultValue: \'def,val\');\n'
            '  final m = MixedIn();\n'
            '  String frame1 = \'\';\n'
            '  try {\n'
            '    m.failHere(7);\n'
            '  } catch (e, st) {\n'
            "    frame1 = '\$e|' + firstFrame(st, 'failHere');\n"
            '  }\n'
            '  String frame2 = \'\';\n'
            '  try {\n'
            '    m.legacyFail(9);\n'
            '  } catch (e, st) {\n'
            "    frame2 = '\$e|' + firstFrame(st, 'legacyFail');\n"
            '  }\n'
            "  print('\${box.val}|\${nonConst.secret}|\$envVal|\$frame1|\$frame2');\n"
            '}\n',
      );

      final realCompiler = _RealOneShotCompiler(dartaotruntime, kernelWorker);

      Future<(Uint8List, Uint8List)> compilePkgModule(String tag) async {
        final kmod = '${_root.path}/out/${sdkVersion}_$tag.kmod';
        final koutline = '${_root.path}/out/${sdkVersion}_$tag.koutline';
        final log = StringBuffer();
        final code = await compileModule(
          [
            '--target',
            'vm',
            '--dart-sdk-summary',
            platformDill,
            '--packages-file=${_root.path}/multi_sdk_packages.json',
            '--libraries-json',
            librariesJson,
            '--multi-root=${_root.path}',
            '--multi-root-scheme=org-dartlang-root',
            '-DENV_TAG=custom,val',
            '--no-summary-only',
            '--exclude-non-sources',
            '--source',
            'package:pkg/a.dart',
            '--output',
            kmod,
            '--output-outline',
            koutline,
            '--excluded-output',
            '$kmod.vm_excluded.txt',
          ],
          realCompiler,
          log,
          const [],
        );
        expect(code, 0, reason: 'SDK $sdkVersion ($tag): $log');
        return (
          File('$kmod/0.dill').readAsBytesSync(),
          File('$koutline/0.dill').readAsBytesSync(),
        );
      }

      final (_, outlineV1) = await compilePkgModule('v1');

      // Editing NonConstBox.secret (111 -> 999) must NOT change .koutline bytes!
      _write('pkg/lib/a.dart', libSource(nonConstInit: 999, constInit: 222));
      final (_, outlineV2) = await compilePkgModule('v2');
      expect(
        outlineV2,
        equals(outlineV1),
        reason:
            'SDK $sdkVersion: editing final instance field initializer in class without const constructor must not change .koutline',
      );

      // Editing ConstBox.val (222 -> 333) MUST change .koutline bytes!
      _write('pkg/lib/a.dart', libSource(nonConstInit: 999, constInit: 333));
      final (_, outlineV3) = await compilePkgModule('v3');
      expect(
        outlineV3,
        isNot(equals(outlineV2)),
        reason:
            'SDK $sdkVersion: editing final instance field initializer in class with const constructor must change .koutline',
      );

      // Compile legacy module and entry module modularly, link, and compare with whole-program.
      final legacyKmod = '${_root.path}/out/${sdkVersion}_legacy.kmod';
      final legacyKoutline = '${_root.path}/out/${sdkVersion}_legacy.koutline';
      final legacyLog = StringBuffer();
      expect(
        await compileModule(
          [
            '--target',
            'vm',
            '--dart-sdk-summary',
            platformDill,
            '--packages-file=${_root.path}/multi_sdk_packages.json',
            '--libraries-json',
            librariesJson,
            '--multi-root=${_root.path}',
            '--multi-root-scheme=org-dartlang-root',
            '-DENV_TAG=custom,val',
            '--no-summary-only',
            '--exclude-non-sources',
            '--source',
            'package:legacy/legacy_throw.dart',
            '--output',
            legacyKmod,
            '--output-outline',
            legacyKoutline,
            '--excluded-output',
            '$legacyKmod.vm_excluded.txt',
          ],
          realCompiler,
          legacyLog,
          const [],
        ),
        0,
        reason: legacyLog.toString(),
      );

      final pkgKmod = '${_root.path}/out/${sdkVersion}_v3.kmod';
      final pkgKoutline = '${_root.path}/out/${sdkVersion}_v3.koutline';
      final entryKmod = '${_root.path}/out/${sdkVersion}_entry.kmod';
      final entryLog = StringBuffer();
      expect(
        await compileModule(
          [
            '--target',
            'vm',
            '--dart-sdk-summary',
            platformDill,
            '--packages-file=${_root.path}/multi_sdk_packages.json',
            '--libraries-json',
            librariesJson,
            '--multi-root=${_root.path}',
            '--multi-root-scheme=org-dartlang-root',
            '-DENV_TAG=custom,val',
            '--no-summary-only',
            '--exclude-non-sources',
            '--input-kmod',
            pkgKoutline,
            '--input-kmod',
            legacyKoutline,
            '--source',
            '${_prefix}app/bin/main.dart',
            '--output',
            entryKmod,
            '--excluded-output',
            '$entryKmod.vm_excluded.txt',
            '--no-drop',
          ],
          realCompiler,
          entryLog,
          const [],
        ),
        0,
        reason: entryLog.toString(),
      );

      final modularLinked = '${_root.path}/out/${sdkVersion}_modular.dill';
      final linkErr = StringBuffer();
      expect(
        linkOne(
          [modularLinked, entryKmod, pkgKmod, legacyKmod],
          cache: KernelLinkCache(),
          inputs: null,
          errSink: linkErr,
        ),
        0,
        reason: linkErr.toString(),
      );

      // Whole-program compile with the same SDK.
      final wholeEntryKmod = '${_root.path}/out/${sdkVersion}_whole_entry.kmod';
      final wholeEntryLog = StringBuffer();
      expect(
        await compileModule(
          [
            '--target',
            'vm',
            '--dart-sdk-summary',
            platformDill,
            '--packages-file=${_root.path}/multi_sdk_packages.json',
            '--libraries-json',
            librariesJson,
            '--multi-root=${_root.path}',
            '--multi-root-scheme=org-dartlang-root',
            '-DENV_TAG=custom,val',
            '--no-summary-only',
            '--source',
            '${_prefix}app/bin/main.dart',
            '--source',
            'package:pkg/a.dart',
            '--source',
            'package:legacy/legacy_throw.dart',
            '--output',
            wholeEntryKmod,
            '--excluded-output',
            '$wholeEntryKmod.vm_excluded.txt',
            '--no-drop',
          ],
          realCompiler,
          wholeEntryLog,
          const [],
        ),
        0,
        reason: wholeEntryLog.toString(),
      );

      final modRun = await Process.run(dartBin, [modularLinked]);
      final wholeRun = await Process.run(dartBin, [
        '$wholeEntryKmod/entry.dill',
      ]);
      expect(modRun.exitCode, 0, reason: '${modRun.stdout}\n${modRun.stderr}');
      expect(
        wholeRun.exitCode,
        0,
        reason: '${wholeRun.stdout}\n${wholeRun.stderr}',
      );
      final modOut = (modRun.stdout as String).trim();
      final wholeOut = (wholeRun.stdout as String).trim();
      expect(
        modOut,
        wholeOut,
        reason:
            'SDK $sdkVersion: modular output ($modOut) must match whole-program output ($wholeOut)',
      );
      expect(modOut, contains('333|999|custom,val|'));
      expect(modOut, contains('package:pkg/a.dart:25:7'));
      expect(modOut, contains('package:legacy/legacy_throw.dart:5:7'));
    }
    expect(seenSdkVersions, containsAll(['3.13.5', '3.13.4']));
  });

  test('KernelLinkCache enforces byte bounds across all maps, evicts globally by LRU, and unpins WorkRequest buffers', () {
    // Encode a WorkRequest protobuf payload inside a larger 64 KB buffer so
    // any sublistView slice would pin the 64 KB buffer unless copied.
    final rawReq = _encodeWorkRequestForTest(
      arguments: ['out.dill', 'mod_a'],
      inputs: {
        'mod_a/0.dill': Uint8List.fromList([1, 2, 3, 4]),
        'mod_a/index.json': Uint8List.fromList([5, 6, 7, 8]),
      },
    );
    final oversizedFrame = Uint8List(64 * 1024);
    oversizedFrame.setRange(128, 128 + rawReq.length, rawReq);
    final viewSlice = Uint8List.sublistView(
      oversizedFrame,
      128,
      128 + rawReq.length,
    );
    expect(viewSlice.buffer.lengthInBytes, 64 * 1024);

    final decodedInputs = decodeKernelLinkWorkRequestInputs(viewSlice);
    for (final digest in decodedInputs.values) {
      expect(
        digest.buffer.lengthInBytes,
        digest.lengthInBytes,
        reason:
            'decoded WorkRequest digest must not pin the 64 KB frame buffer',
      );
    }

    // Verify KernelLinkCache byte bounds and global LRU eviction across
    // _indexCache, _baseKeysCache, and _dillCache.
    final cache = KernelLinkCache(
      maxCacheBytes: 180,
      maxIndexCacheBytes: 150,
      maxBaseKeysCacheBytes: 60,
      maxSingleDillBytes: 80,
    );

    final mod1 = Directory('${_root.path}/m1')..createSync(recursive: true);
    final mod2 = Directory('${_root.path}/m2')..createSync(recursive: true);
    final indexJson = jsonEncode({
      'version': 1,
      'sccs': [
        {
          'dill': '0.dill',
          'defines': ['pkg/lib/a.dart'],
          'imports': <String>[],
        },
      ],
    });
    File('${mod1.path}/index.json').writeAsStringSync(indexJson);
    File('${mod2.path}/index.json').writeAsStringSync(indexJson);

    // Oversized dill (> maxSingleDillBytes = 80) is returned but not cached.
    final bigDill = File('${mod1.path}/big.dill')
      ..writeAsBytesSync(List<int>.filled(100, 7));
    final bigBytes = cache.dillBytesOf(bigDill.path, {
      bigDill.path: Uint8List.fromList([9, 9]),
    });
    expect(bigBytes.length, 100);
    expect(cache.dillBytes, 0);
    expect(cache.dillEntryCount, 0);

    // Oversized baseKeys (> maxBaseKeysCacheBytes = 60) is returned but not cached.
    final bigBase = File('${_root.path}/big.keys')
      ..writeAsStringSync(
        '${List<String>.filled(20, 'pkg/lib/x.dart').join('\n')}\n',
      );
    expect(bigBase.lengthSync(), greaterThan(60));
    expect(cache.baseKeysOf(bigBase.path, null), {'pkg/lib/x.dart'});
    expect(cache.baseKeysBytes, 0);
    expect(cache.baseKeysEntryCount, 0);

    // Populate dill1 (50 B), base1 (30 B), index1 (~75 B) => total ~155 B <= 180 B.
    final dill1 = File('${mod1.path}/0.dill')
      ..writeAsBytesSync(List<int>.filled(50, 1));
    final base1 = File('${_root.path}/b1.keys')
      ..writeAsStringSync('${'a' * 29}\n');
    final d1Digest = Uint8List.fromList([1]);
    final b1Digest = Uint8List.fromList([2]);
    final idx1Digest = Uint8List.fromList([3]);

    cache.dillBytesOf(dill1.path, {dill1.path: d1Digest});
    cache.baseKeysOf(base1.path, {base1.path: b1Digest});
    cache.kernelsOf(mod1.path, {'${mod1.path}/index.json': idx1Digest});
    expect(cache.dillEntryCount, 1);
    expect(cache.baseKeysEntryCount, 1);
    expect(cache.indexEntryCount, 1);
    expect(cache.totalBytes, lessThanOrEqualTo(180));

    // Touch dill1 so base1 becomes the globally oldest entry, then insert dill2 (50 B).
    // Total would be 50 + 30 + ~75 + 50 > 180, so base1 (and then index1 if needed)
    // is evicted to stay within maxCacheBytes (180).
    cache.dillBytesOf(dill1.path, {dill1.path: d1Digest});
    final dill2 = File('${mod2.path}/0.dill')
      ..writeAsBytesSync(List<int>.filled(50, 2));
    cache.dillBytesOf(dill2.path, {
      dill2.path: Uint8List.fromList([4]),
    });
    expect(cache.totalBytes, lessThanOrEqualTo(180));
    expect(
      cache.baseKeysEntryCount,
      0,
      reason: 'oldest global entry (base1) must be evicted first',
    );
    expect(
      cache.dillEntryCount,
      2,
      reason: 'recently touched dill1 and new dill2 must remain',
    );
  });

  test('KernelLinkCache uses per-file tree-artifact digests and ignores parent-directory digests', () {
    // Bazel 9.3.0 expands tree artifacts (.kmod / .koutline) in WorkRequest.inputs
    // into individual file entries (<dir>/0.dill, <dir>/index.json) and never
    // sends an Input entry for <dir>. Verify that passing a parent-directory
    // entry never causes a false cache hit when constituent files change.
    final cache = KernelLinkCache();
    final modDir = Directory('${_root.path}/tree_mod')
      ..createSync(recursive: true);
    final dillFile = File('${modDir.path}/0.dill')..writeAsBytesSync([1, 2, 3]);
    final parentDigest = Uint8List.fromList([0xaa, 0xbb, 0xcc]);
    final fileDigest1 = Uint8List.fromList([0x11, 0x22]);
    final fileDigest2 = Uint8List.fromList([0x33, 0x44]);

    // 1. With only a parent directory entry in inputs, no per-file digest exists,
    // so modifying 0.dill on disk is always observed.
    expect(cache.dillBytesOf(dillFile.path, {modDir.path: parentDigest}), [
      1,
      2,
      3,
    ]);
    dillFile.writeAsBytesSync([4, 5, 6]);
    expect(
      cache.dillBytesOf(dillFile.path, {modDir.path: parentDigest}),
      [4, 5, 6],
      reason:
          'parent directory digest must not cause a stale cache hit for 0.dill',
    );

    // 2. With a per-file entry in inputs (Bazel 9.3.0 tree-artifact expansion),
    // matching digest hits the cache without reading disk, and changing digest
    // invalidates the cache.
    expect(cache.dillBytesOf(dillFile.path, {dillFile.path: fileDigest1}), [
      4,
      5,
      6,
    ]);
    dillFile.writeAsBytesSync([7, 8, 9]);
    expect(cache.dillBytesOf(dillFile.path, {dillFile.path: fileDigest1}), [
      4,
      5,
      6,
    ], reason: 'matching per-file digest must hit cache without reading disk');
    expect(
      cache.dillBytesOf(dillFile.path, {dillFile.path: fileDigest2}),
      [7, 8, 9],
      reason:
          'changed per-file digest must invalidate cache and read new bytes',
    );
  });

  test('ensureSummaryDigests and compileModule reuse Bazel 9.3.0 per-file tree-artifact digests without re-hashing from disk and hash intra-module SCCs in memory', () async {
    // 1. Verify ensureSummaryDigests reuses existing digests (exact and normalized)
    // without touching disk, and replaces empty-digest entries when hashing fallback runs.
    final summaryFile = File('${_root.path}/dep.koutline/0.dill')
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync([10, 20, 30, 40]);
    final sentinelDigest = Uint8List.fromList(
      utf8.encode('sentinel-bazel-digest-0123456789'),
    );

    // Even if the file on disk is deleted, ensureSummaryDigests succeeds when
    // the digest is already present in inputs (under normalized path).
    final prevCwd = Directory.current;
    Directory.current = _root;
    try {
      summaryFile.deleteSync();
      final resultInputs = await ensureSummaryDigests(
        ['--input-summary', './dep.koutline/0.dill'],
        [_encodeInputForTest('dep.koutline/0.dill', sentinelDigest)],
      );
      final decoded = [
        for (final raw in resultInputs) _decodeInputForTest(raw),
      ];
      expect(
        decoded.where((e) => e.path == './dep.koutline/0.dill').single.digest,
        equals(sentinelDigest),
        reason: 'normalized path must reuse existing WorkRequest.inputs digest without reading disk',
      );

      // When an input entry has an empty digest, ensureSummaryDigests hashes from disk
      // and replaces the empty-digest entry in-place rather than leaving a duplicate.
      summaryFile.writeAsBytesSync([10, 20, 30, 40]);
      final expectedSha = sha256Of(Uint8List.fromList([10, 20, 30, 40]));
      final replacedInputs = await ensureSummaryDigests(
        ['--input-summary', 'dep.koutline/0.dill'],
        [_encodeInputForTest('dep.koutline/0.dill', Uint8List(0))],
      );
      expect(replacedInputs.length, 1);
      expect(
        _decodeInputForTest(replacedInputs.single).digest,
        equals(expectedSha),
      );
    } finally {
      Directory.current = prevCwd;
    }

    // 2. Verify compileModule reuses WorkRequest.inputs digest for staged tree-artifact
    // sources (<koutline>/sources/<key>) without re-hashing from disk, and computes
    // intra-module SCC outline digests in memory.
    _write(
      'pkg/lib/part_child.dart',
      "part of 'part_parent.dart';\nconst int y = 1;\n",
    );
    _write('pkg/lib/scc_a.dart', 'class SccA {}\n');
    _write(
      'pkg/lib/scc_b.dart',
      "import 'scc_a.dart';\nimport 'part_parent.dart';\nclass SccB extends SccA {}\n",
    );

    // Stage `part_parent.dart` ONLY in a dependency `.koutline/sources/` tree artifact.
    final depKoutline = Directory('${_root.path}/dep_parent.koutline');
    final stagedFile =
        File('${depKoutline.path}/sources/pkg/lib/part_parent.dart')
          ..parent.createSync(recursive: true)
          ..writeAsStringSync("part 'part_child.dart';\nint x() => y;\n");
    File('${depKoutline.path}/index.json').writeAsStringSync(
      jsonEncode({
        'version': 1,
        'sccs': <Object>[],
        'excluded': ['pkg/lib/part_parent.dart'],
      }),
    );

    final stagedSentinelDigest = Uint8List.fromList(
      utf8.encode('staged-tree-artifact-digest-1234'),
    );
    final inputRecorder = _InputRecordingCompiler();
    final cache = KernelModuleCache();
    final outDir = '${_root.path}/out/multi_scc.kmod';
    final outlineDir = '${_root.path}/out/multi_scc.koutline';
    final excludedPath = '$outDir.vm_excluded.txt';
    final log = StringBuffer();

    final prevCwd2 = Directory.current;
    Directory.current = _root;
    try {
      final code = await compileModule(
        [
          '--source',
          _uri('pkg/lib/part_child.dart'),
          '--source',
          _uri('pkg/lib/scc_a.dart'),
          '--source',
          _uri('pkg/lib/scc_b.dart'),
          '--input-source',
          'pkg/lib/part_parent.dart',
          '--input-kmod',
          'dep_parent.koutline',
          '--output',
          outDir,
          '--output-outline',
          outlineDir,
          '--excluded-output',
          excludedPath,
          '--packages-file',
          '${_root.path}/package_config.json',
          '--libraries-json',
          '${_root.path}/libraries.json',
          '--multi-root',
          _root.path,
          '--target',
          'vm',
        ],
        inputRecorder,
        log,
        [
          // Pass under `./`-prefixed normalized path so compileModule looks up
          // `dep_parent.koutline/sources/pkg/lib/part_parent.dart` in inputDigests.
          _encodeInputForTest(
            './dep_parent.koutline/sources/pkg/lib/part_parent.dart',
            stagedSentinelDigest,
          ),
          _encodeInputForTest(
            '${_root.path}/pkg/lib/part_child.dart',
            Uint8List.fromList([1]),
          ),
          _encodeInputForTest(
            '${_root.path}/pkg/lib/scc_a.dart',
            Uint8List.fromList([2]),
          ),
          _encodeInputForTest(
            '${_root.path}/pkg/lib/scc_b.dart',
            Uint8List.fromList([3]),
          ),
        ],
        cache: cache,
      );
      expect(code, 0, reason: log.toString());
    } finally {
      Directory.current = prevCwd2;
    }
    expect(stagedFile.existsSync(), isTrue);
    expect(inputRecorder.calls.length, 3);

    // Call 0 compiles `part_parent.dart` + `part_child.dart` (`0.dill`), Call 1 compiles `scc_a.dart` (`1.dill`),
    // Call 2 compiles `scc_b.dart` (`2.dill`) against `--input-summary` of `0.dill` and `1.dill`.
    // Every declared origin already resolves through the ordered roots (the
    // staged tree-artifact root first), so isolated staging is skipped and the
    // request passes the declared inputs through untouched.
    expect(_valuesAfter(inputRecorder.calls[0], '--multi-root'), [
      'dep_parent.koutline/sources',
      kernelWorkerUri(_root.path),
    ]);
    final call0Inputs = {
      for (final raw in inputRecorder.callInputs[0])
        _decodeInputForTest(raw).path: _decodeInputForTest(raw).digest,
    };
    expect(
      call0Inputs['./dep_parent.koutline/sources/pkg/lib/part_parent.dart'],
      equals(stagedSentinelDigest),
      reason: 'staged tree-artifact source must reuse its WorkRequest.inputs digest without re-hashing',
    );
    expect(
      call0Inputs.keys,
      isNot(contains('$outDir/.isolated_root/pkg/lib/part_parent.dart')),
      reason: 'skipped staging must not add isolated inputs',
    );

    final call2Inputs = {
      for (final raw in inputRecorder.callInputs[2])
        _decodeInputForTest(raw).path: _decodeInputForTest(raw).digest,
    };
    final expectedOutline0Sha = sha256Of(
      File('$outlineDir/0.dill').readAsBytesSync(),
    );
    final expectedOutline1Sha = sha256Of(
      File('$outlineDir/1.dill').readAsBytesSync(),
    );
    expect(
      call2Inputs['$outlineDir/0.dill'],
      equals(expectedOutline0Sha),
      reason: 'intra-module SCC 0 outline digest must be passed in memory to dependent SCC 2',
    );
    expect(
      call2Inputs['$outlineDir/1.dill'],
      equals(expectedOutline1Sha),
      reason: 'intra-module SCC 1 outline digest must be passed in memory to dependent SCC 2',
    );
  });

  test('KernelModuleCache enforces byte bounds, detects same-(size, mtime) mutations when digests are absent, and unpins WorkRequest inputs', () async {
    // Verify decodeKernelModuleWorkRequestInputs unpins slices from a larger frame buffer.
    final rawReq = _encodeWorkRequestForTest(
      arguments: ['--output', 'out'],
      inputs: {
        'dep.koutline/index.json': Uint8List.fromList([1, 2, 3, 4]),
      },
    );
    final bigBuf = Uint8List(32 * 1024)
      ..setRange(64, 64 + rawReq.length, rawReq);
    final view = Uint8List.sublistView(bigBuf, 64, 64 + rawReq.length);
    final decodedList = decodeKernelModuleWorkRequestInputs(view);
    expect(decodedList, hasLength(1));
    expect(
      decodedList.single.buffer.lengthInBytes,
      decodedList.single.lengthInBytes,
      reason: 'decodeKernelModuleWorkRequestInputs must unpin Input slices from the frame buffer',
    );

    // Verify KernelModuleCache detects in-place mutations with identical size and mtime
    // when digests are absent, and respects maxCacheBytes.
    final cache = KernelModuleCache(maxCacheBytes: 512);
    final depDir = Directory('${_root.path}/dep_cache.koutline')
      ..createSync(recursive: true);
    final indexFile = File('${depDir.path}/index.json');
    final fixedTime = DateTime.fromMillisecondsSinceEpoch(1700000000000);

    final idxV1 = jsonEncode({
      'version': 1,
      'sccs': [
        {
          'dill': '0.dill',
          'defines': ['dep/lib/one.dart'],
          'imports': <String>[],
        },
      ],
    });
    final idxV2 = jsonEncode({
      'version': 1,
      'sccs': [
        {
          'dill': '1.dill',
          'defines': ['dep/lib/one.dart'],
          'imports': <String>[],
        },
      ],
    });
    expect(idxV1.length, idxV2.length);
    indexFile.writeAsStringSync(idxV1);
    indexFile.setLastModifiedSync(fixedTime);

    _write('dep/lib/one.dart', 'class One {}\n');
    _write('pkg/lib/consumer.dart', "import 'package:dep/one.dart';\n");

    Future<List<String>> runWithCache() async {
      final rec = _Recorder();
      final log = StringBuffer();
      final code = await compileModule(
        [
          '--source',
          _uri('pkg/lib/consumer.dart'),
          '--input-kmod',
          depDir.path,
          '--output',
          '${_root.path}/out/consumer.kmod',
          '--excluded-output',
          '${_root.path}/out/consumer.vm_excluded.txt',
          '--packages-file',
          '${_root.path}/package_config.json',
          '--libraries-json',
          '${_root.path}/libraries.json',
          '--multi-root',
          _root.path,
          '--target',
          'vm',
        ],
        rec,
        log,
        const [],
        cache: cache,
      );
      expect(code, 0, reason: log.toString());
      return _valuesAfter(rec.calls.single, '--input-summary');
    }

    // When dep_cache.koutline maps `dep/lib/one.dart` to `0.dill`, `consumer.dart`
    // links against `dep_cache.koutline/0.dill`.
    expect(await runWithCache(), [kernelWorkerUri('${depDir.path}/0.dill')]);
    expect(cache.totalBytes, lessThanOrEqualTo(512));
    expect(cache.indexEntryCount, 1);

    // Mutate index.json in-place with identical size and mtime so `dep/lib/one.dart`
    // maps to `1.dill`.
    indexFile.writeAsStringSync(idxV2);
    indexFile.setLastModifiedSync(fixedTime);
    expect(indexFile.statSync().size, idxV1.length);
    expect(indexFile.statSync().modified, fixedTime);

    expect(
      await runWithCache(),
      [kernelWorkerUri('${depDir.path}/1.dill')],
      reason: 'KernelModuleCache must detect same-(size, mtime) index.json mutation when digest is absent',
    );
  });

  test('scanDirectives, vmLibraries, and compileModule handle interpolated annotations, CFE configurable import conditions, and undeclared sources identically across worker, local, and sandboxed strategies', () async {
    // 1. Unit checks for vmLibraries filtering of internal `_*` and unsupported libraries.
    final libs = vmLibraries({
      'vm': {
        'libraries': {
          'core': {'uri': 'core/core.dart'},
          'io': {'uri': 'io/io.dart'},
          '_internal': {'uri': '_internal/vm/lib/internal_patch.dart'},
          '_http': {'uri': '_http/http.dart'},
          'wasm': {'uri': 'wasm/wasm.dart', 'supported': false},
        },
        'include': [
          {'target': 'vm_common'},
        ],
      },
      'vm_common': {
        'libraries': {
          'async': {'uri': 'async/async.dart'},
          '_vm': {'uri': '_vm/vm.dart'},
        },
      },
    });
    expect(libs, equals({'core', 'io', 'async'}));

    // 2. Unit checks for scanDirectives with `${...}` string interpolations in annotations,
    // comments/raw-strings/maps inside interpolations, escapes, and CFE configurable imports.
    final complexPrologue =
        '@Deprecated("\${")"}")\n'
        '@Deprecated("\${"nested \${")"} end"}")\n'
        '@Deprecated("\${r\')\'}" "\${r"}"}")\n'
        '@Deprecated("\${/* ) " } /* inner ) */ */ \')\'}")\n'
        '@Deprecated("\${// ) " }\n\')\'}")\n'
        '@Deprecated("\${({\'k\': \')\'})[\'k\']}")\n'
        'library my.annotated.lib;\n'
        '@Deprecated("""\n\${")"}\n""")\n'
        "import 'package:pkg/a.dart';\n"
        "import 'package:pkg/default_missing_false.dart' if (dart.library.html == 'false') 'package:pkg/wrong_branch.dart';\n"
        "import 'package:pkg/default_missing_empty.dart' if (dart.library.html == '') 'package:pkg/wrong_empty.dart';\n"
        "import 'package:pkg/default_internal.dart' if (dart.library._internal) 'package:pkg/wrong_internal.dart';\n"
        "import 'package:pkg/default_io_false.dart' if (dart.library.io == 'false') 'package:pkg/wrong_io_false.dart';\n"
        "import 'package:pkg/default_io_true.dart' if (dart.library.io == 't' 'rue') 'package:pkg/io_branch.dart';\n"
        "import 'package:pkg/default_io_esc.dart' if (dart.library.io == 'tr\\x75e') 'package:pkg/io_esc_branch.dart';\n"
        "import 'package:pkg/default_io_triple.dart' if (dart.library.io == '''\ntrue''') 'package:pkg/io_triple_branch.dart';\n"
        "import 'package:pkg/default_env_empty.dart' if (CUSTOM_ENV == '') 'package:pkg/env_empty_branch.dart';\n"
        "import 'package:pkg/default_env_false.dart' if (CUSTOM_ENV == 'false') 'package:pkg/wrong_env_false.dart';\n"
        "export 'package:pkg/exp\\x2edart';\n"
        "part 'part\\u002edart';\n"
        '@deprecated\n'
        'part() => 1;\n';
    final scanned = scanDirectives(complexPrologue, libs);
    expect(scanned, isNotNull);
    expect(scanned!.libraryName, 'my.annotated.lib');
    expect(scanned.refs.map((r) => '${r.kind}:${r.uri}').toList(), [
      'import:package:pkg/a.dart',
      'import:package:pkg/default_missing_false.dart',
      'import:package:pkg/default_missing_empty.dart',
      'import:package:pkg/default_internal.dart',
      'import:package:pkg/default_io_false.dart',
      'import:package:pkg/io_branch.dart',
      'import:package:pkg/io_esc_branch.dart',
      'import:package:pkg/io_triple_branch.dart',
      'import:package:pkg/env_empty_branch.dart',
      'import:package:pkg/default_env_false.dart',
      'export:package:pkg/exp.dart',
      'part:part.dart',
    ]);

    // 3. Verify contextual keywords (`import`, `export`, `library`, `part`) as top-level
    // declaration names after annotations end the prologue cleanly without throwing.
    for (final decl in [
      '@deprecated\nimport() => 1;\n',
      '@deprecated\nexport() => 1;\n',
      '@deprecated\nlibrary() => 1;\n',
      '@deprecated\npart() => 1;\n',
    ]) {
      final res = scanDirectives("import 'a.dart';\n$decl", libs);
      expect(res, isNotNull, reason: 'failed on:\n$decl');
      expect(res!.refs.map((r) => r.uri).toList(), ['a.dart']);
    }

    // 4. End-to-end verification with real kernel_worker across worker, local, and sandboxed
    // setups when an undeclared file exists on disk in the workspace.
    final sdkDir = File(Platform.resolvedExecutable).parent.parent;
    final exeSuffix = Platform.isWindows ? '.exe' : '';
    final dartaotruntime = '${sdkDir.path}/bin/dartaotruntime$exeSuffix';
    final kernelWorker =
        '${sdkDir.path}/bin/snapshots/kernel_worker_aot.dart.snapshot';
    final platformDill = '${sdkDir.path}/lib/_internal/vm_platform_strong.dill';
    final librariesJson = '${sdkDir.path}/lib/libraries.json';

    // 4a. Library module with `@Deprecated("${")"}")` before an undeclared import or part,
    // or a configurable import whose default is undeclared and whose `== 'false'` branch
    // is declared: planner must exclude all of them without letting kernel_worker read
    // undeclared files from disk.
    _write(
      'pkg/lib/undeclared_secret.dart',
      'THIS IS NOT VALID DART AND MUST NEVER BE READ;\n',
    );
    _write(
      'pkg/lib/annot_bad.dart',
      '@Deprecated("\${")"}")\n'
          "import 'package:pkg/undeclared_secret.dart';\n"
          'int bad() => 1;\n',
    );
    _write(
      'pkg/lib/annot_bad_part.dart',
      '@Deprecated("\${")"}")\n'
          "part 'undeclared_secret.dart';\n"
          'int badPart() => 1;\n',
    );
    _write(
      'pkg/lib/cond_bad_default.dart',
      "import 'package:pkg/undeclared_secret.dart' "
          "if (dart.library.html == 'false') 'package:pkg/declared_ok.dart';\n"
          'int badCond() => 1;\n',
    );
    _write(
      'pkg/lib/declared_ok.dart',
      'const String greeting = "declared-ok";\n',
    );
    _write(
      'pkg/lib/cond_ok.dart',
      '@Deprecated("\${")"}")\n'
          "import 'package:pkg/declared_ok.dart' "
          "if (dart.library.html == 'false') 'package:pkg/undeclared_secret.dart' "
          "if (dart.library._internal) 'package:pkg/undeclared_secret.dart';\n"
          'String msg() => greeting;\n',
    );

    final libRes = await _compile('annot_lib', [
      'pkg/lib/annot_bad.dart',
      'pkg/lib/annot_bad_part.dart',
      'pkg/lib/cond_bad_default.dart',
      'pkg/lib/declared_ok.dart',
      'pkg/lib/cond_ok.dart',
    ]);
    expect(libRes.code, 0, reason: libRes.log);
    expect(libRes.excluded, {
      _uri('pkg/lib/annot_bad.dart'): 'imports package:pkg/undeclared_secret.dart, which is not in this module closure',
      _uri('pkg/lib/annot_bad_part.dart'):
          'its part undeclared_secret.dart is not an input of this module',
      _uri('pkg/lib/cond_bad_default.dart'): 'imports package:pkg/undeclared_secret.dart, which is not in this module closure',
    });
    expect(libRes.defines, [
      ['pkg/lib/declared_ok.dart'],
      ['pkg/lib/cond_ok.dart'],
    ]);

    // 4b. Entry module (`--no-drop`) that imports an undeclared file after `@Deprecated("${")"}")`:
    // must fail hermetically in worker, local, and sandboxed modes without invoking kernel_worker.
    _write(
      'pkg/bin/bad_entry.dart',
      '@Deprecated("\${")"}")\n'
          "import 'package:pkg/undeclared_secret.dart';\n"
          'void main() {}\n',
    );
    final badEntryLocal = await _compile('bad_entry_local', [
      'pkg/bin/bad_entry.dart',
    ], noDrop: true);
    expect(badEntryLocal.code, 1);
    expect(badEntryLocal.calls, isEmpty);
    expect(
      badEntryLocal.log,
      contains(
        'pkg/lib/undeclared_secret.dart): source is not a declared input.',
      ),
    );

    // 4c. Real kernel_worker compile across worker, local (with undeclared_secret.dart on disk),
    // and sandboxed (without undeclared_secret.dart on disk) strategies must produce
    // byte-identical outputs.
    Future<({Uint8List kmodDill, Uint8List koutlineDill})> buildCondStrategy(
      String mode, {
      required bool includeUndeclaredOnDisk,
      required bool useWorkerInputs,
    }) async {
      final ws = Directory('${_root.path}/strategy_$mode')
        ..createSync(recursive: true);
      void writeWs(String rel, String content) {
        File('${ws.path}/$rel')
          ..parent.createSync(recursive: true)
          ..writeAsStringSync(content);
      }

      writeWs(
        'package_config.json',
        jsonEncode({
          'configVersion': 2,
          'packages': [
            {
              'name': 'pkg',
              'rootUri': 'org-dartlang-root:///pkg',
              'packageUri': 'lib/',
              'languageVersion': '3.0',
            },
          ],
        }),
      );
      writeWs(
        'pkg/lib/declared_ok.dart',
        'const String greeting = "declared-ok";\n',
      );
      writeWs(
        'pkg/lib/cond_ok.dart',
        '@Deprecated("\${")"}")\n'
            "import 'package:pkg/declared_ok.dart' "
            "if (dart.library.html == 'false') 'package:pkg/undeclared_secret.dart' "
            "if (dart.library._internal) 'package:pkg/undeclared_secret.dart';\n"
            'String msg() => greeting;\n',
      );
      if (includeUndeclaredOnDisk) {
        writeWs(
          'pkg/lib/undeclared_secret.dart',
          'THIS IS INVALID DART AND UNDECLARED;\n',
        );
      }

      final compiler = _CwdOneShotCompiler(
        dartaotruntime,
        kernelWorker,
        ws.path,
      );
      final kmod = 'out/pkg.kmod';
      final koutline = 'out/pkg.koutline';
      final excluded = 'out/pkg.vm_excluded.txt';
      final log = StringBuffer();
      final workerInputs = useWorkerInputs
          ? [
              _encodeInputForTest(
                'pkg/lib/declared_ok.dart',
                Uint8List.fromList([1]),
              ),
              _encodeInputForTest(
                'pkg/lib/cond_ok.dart',
                Uint8List.fromList([2]),
              ),
            ]
          : const <Uint8List>[];

      final prevCwd = Directory.current;
      Directory.current = ws;
      try {
        final code = await compileModule(
          [
            '--target',
            'vm',
            '--dart-sdk-summary',
            platformDill,
            '--packages-file',
            'package_config.json',
            '--libraries-json',
            librariesJson,
            '--multi-root',
            '.',
            '--multi-root-scheme',
            'org-dartlang-root',
            '--no-summary-only',
            '--exclude-non-sources',
            '--source',
            'package:pkg/declared_ok.dart',
            '--source',
            'package:pkg/cond_ok.dart',
            '--output',
            kmod,
            '--output-outline',
            koutline,
            '--excluded-output',
            excluded,
          ],
          compiler,
          log,
          workerInputs,
        );
        expect(code, 0, reason: '$mode failed: $log');
      } finally {
        Directory.current = prevCwd;
      }
      return (
        kmodDill: File('${ws.path}/$kmod/1.dill').readAsBytesSync(),
        koutlineDill: File('${ws.path}/$koutline/1.dill').readAsBytesSync(),
      );
    }

    final workerOut = await buildCondStrategy(
      'worker',
      includeUndeclaredOnDisk: true,
      useWorkerInputs: true,
    );
    final localOut = await buildCondStrategy(
      'local',
      includeUndeclaredOnDisk: true,
      useWorkerInputs: false,
    );
    final sandboxedOut = await buildCondStrategy(
      'sandboxed',
      includeUndeclaredOnDisk: false,
      useWorkerInputs: false,
    );
    expect(workerOut.kmodDill, equals(sandboxedOut.kmodDill));
    expect(localOut.kmodDill, equals(sandboxedOut.kmodDill));
    expect(workerOut.koutlineDill, equals(sandboxedOut.koutlineDill));
    expect(localOut.koutlineDill, equals(sandboxedOut.koutlineDill));
  });

  test('multi-root resolution and _Files.read never let stale bazel-out files shadow declared source files or untracked workspace files shadow declared generated files', () async {
    final sdkDir = File(Platform.resolvedExecutable).parent.parent;
    final exeSuffix = Platform.isWindows ? '.exe' : '';
    final dartaotruntime = '${sdkDir.path}/bin/dartaotruntime$exeSuffix';
    final kernelWorker =
        '${sdkDir.path}/bin/snapshots/kernel_worker_aot.dart.snapshot';
    final genKernel =
        '${sdkDir.path}/bin/snapshots/gen_kernel_aot.dart.snapshot';
    final platformDill = '${sdkDir.path}/lib/_internal/vm_platform_strong.dill';
    final productPlatformDill =
        '${sdkDir.path}/lib/_internal/vm_platform_product.dill';
    final librariesJson = '${sdkDir.path}/lib/libraries.json';

    // Scenario 1: Declared source file in `.` (`pkg/lib/config.dart`) with a stale
    // generated output on disk at `bazel-out/k8-fastbuild/bin/pkg/lib/config.dart`.
    // The stale file in `bazel-out` imports `dart:html` and returns `"stale-gen-v1"`,
    // so if `_Files.read`, `kernel_worker`, or `gen_kernel` ever read it, the library
    // would be falsely excluded or print `"stale-gen-v1"`.
    Future<({Uint8List wholeDill, Uint8List modularDill, String output})>
    runSourceVsStaleBuild(
      String label, {
      required bool hasStaleBazelOutFile,
      required bool reverseMultiRootOrder,
      required bool passWorkerInputs,
    }) async {
      final ws = Directory('${_root.path}/stale_test_$label')
        ..createSync(recursive: true);
      void writeWs(String rel, String content) {
        File('${ws.path}/$rel')
          ..parent.createSync(recursive: true)
          ..writeAsStringSync(content);
      }

      writeWs(
        'package_config.json',
        jsonEncode({
          'configVersion': 2,
          'packages': [
            {
              'name': 'pkg',
              'rootUri': 'org-dartlang-root:///pkg',
              'packageUri': 'lib/',
              'languageVersion': '3.0',
            },
          ],
        }),
      );
      writeWs(
        'pkg/lib/config.dart',
        'String currentMode() => "declared-source-v2";\n',
      );
      writeWs(
        'app/bin/main.dart',
        "import 'package:pkg/config.dart';\n"
            'void main() {\n'
            '  print(currentMode());\n'
            '}\n',
      );
      if (hasStaleBazelOutFile) {
        writeWs(
          'bazel-out/k8-fastbuild/bin/pkg/lib/config.dart',
          "import 'dart:html';\n"
              'String currentMode() => "stale-bazel-out-v1";\n',
        );
      }

      final wholePath = '${ws.path}/bazel-out/k8-fastbuild/bin/whole.dill';
      File(wholePath).parent.createSync(recursive: true);
      final genRes = await Process.run(dartaotruntime, [
        genKernel,
        '--platform',
        productPlatformDill,
        '--packages',
        'package_config.json',
        '--filesystem-scheme',
        'org-dartlang-root',
        '--filesystem-root',
        '.',
        '--filesystem-root',
        'bazel-out/k8-fastbuild/bin',
        '-Ddart.vm.product=true',
        '-Ddart.vm.asan=false',
        '-Ddart.vm.msan=false',
        '-Ddart.vm.tsan=false',
        '-o',
        'bazel-out/k8-fastbuild/bin/whole.dill',
        'org-dartlang-root:///app/bin/main.dart',
      ], workingDirectory: ws.path);
      expect(
        genRes.exitCode,
        0,
        reason:
            'gen_kernel ($label) failed: ${genRes.stdout}\n${genRes.stderr}',
      );

      final compiler = _CwdOneShotCompiler(
        dartaotruntime,
        kernelWorker,
        ws.path,
      );
      final libKmod = 'bazel-out/k8-fastbuild/bin/pkg.kmod';
      final libKoutline = 'bazel-out/k8-fastbuild/bin/pkg.koutline';
      final libExcluded = 'bazel-out/k8-fastbuild/bin/pkg.vm_excluded.txt';
      final rootsArgs = reverseMultiRootOrder
          ? ['--multi-root', 'bazel-out/k8-fastbuild/bin', '--multi-root', '.']
          : ['--multi-root', '.', '--multi-root', 'bazel-out/k8-fastbuild/bin'];
      final libInputs = passWorkerInputs
          ? [
              _encodeInputForTest(
                'pkg/lib/config.dart',
                Uint8List.fromList([1]),
              ),
            ]
          : const <Uint8List>[];
      final entryInputs = passWorkerInputs
          ? [
              _encodeInputForTest('app/bin/main.dart', Uint8List.fromList([2])),
            ]
          : const <Uint8List>[];

      final prevCwd = Directory.current;
      Directory.current = ws;
      try {
        final libLog = StringBuffer();
        final libCode = await compileModule(
          [
            '--target',
            'vm',
            '--dart-sdk-summary',
            platformDill,
            '--packages-file',
            'package_config.json',
            '--libraries-json',
            librariesJson,
            ...rootsArgs,
            '--multi-root-scheme',
            'org-dartlang-root',
            '-Ddart.vm.product=true',
            '-Ddart.vm.asan=false',
            '-Ddart.vm.msan=false',
            '-Ddart.vm.tsan=false',
            '--no-summary-only',
            '--exclude-non-sources',
            '--source',
            'package:pkg/config.dart',
            '--output',
            libKmod,
            '--output-outline',
            libKoutline,
            '--excluded-output',
            libExcluded,
          ],
          compiler,
          libLog,
          libInputs,
        );
        expect(libCode, 0, reason: '$label lib failed: $libLog');

        final entryKmod = 'bazel-out/k8-fastbuild/bin/entry.kmod';
        final entryExcluded =
            'bazel-out/k8-fastbuild/bin/entry.vm_excluded.txt';
        final entryLog = StringBuffer();
        final entryCode = await compileModule(
          [
            '--target',
            'vm',
            '--dart-sdk-summary',
            platformDill,
            '--packages-file',
            'package_config.json',
            '--libraries-json',
            librariesJson,
            ...rootsArgs,
            '--multi-root-scheme',
            'org-dartlang-root',
            '-Ddart.vm.product=true',
            '-Ddart.vm.asan=false',
            '-Ddart.vm.msan=false',
            '-Ddart.vm.tsan=false',
            '--no-summary-only',
            '--exclude-non-sources',
            '--input-kmod',
            libKoutline,
            '--source',
            'org-dartlang-root:///app/bin/main.dart',
            '--output',
            entryKmod,
            '--excluded-output',
            entryExcluded,
            '--no-drop',
          ],
          compiler,
          entryLog,
          entryInputs,
        );
        expect(entryCode, 0, reason: '$label entry failed: $entryLog');

        final modularPath = 'bazel-out/k8-fastbuild/bin/modular.dill';
        final linkErr = StringBuffer();
        expect(
          linkOne(
            [modularPath, entryKmod, libKmod],
            cache: KernelLinkCache(),
            inputs: null,
            errSink: linkErr,
          ),
          0,
          reason: linkErr.toString(),
        );
      } finally {
        Directory.current = prevCwd;
      }

      final modularPath = '${ws.path}/bazel-out/k8-fastbuild/bin/modular.dill';
      final runRes = await Process.run(Platform.resolvedExecutable, [
        modularPath,
      ]);
      expect(runRes.exitCode, 0, reason: '${runRes.stderr}');
      return (
        wholeDill: File(wholePath).readAsBytesSync(),
        modularDill: File(modularPath).readAsBytesSync(),
        output: (runRes.stdout as String).trim(),
      );
    }

    final cleanBuild = await runSourceVsStaleBuild(
      'clean',
      hasStaleBazelOutFile: false,
      reverseMultiRootOrder: false,
      passWorkerInputs: false,
    );
    final incrementalLocal = await runSourceVsStaleBuild(
      'incremental_local',
      hasStaleBazelOutFile: true,
      reverseMultiRootOrder: false,
      passWorkerInputs: false,
    );
    final incrementalWorker = await runSourceVsStaleBuild(
      'incremental_worker',
      hasStaleBazelOutFile: true,
      reverseMultiRootOrder: false,
      passWorkerInputs: true,
    );
    final incrementalWorkerReversedRoots = await runSourceVsStaleBuild(
      'incremental_worker_reversed_roots',
      hasStaleBazelOutFile: true,
      reverseMultiRootOrder: true,
      passWorkerInputs: true,
    );

    expect(cleanBuild.output, 'declared-source-v2');
    expect(incrementalLocal.output, 'declared-source-v2');
    expect(incrementalWorker.output, 'declared-source-v2');
    expect(incrementalWorkerReversedRoots.output, 'declared-source-v2');
    expect(incrementalLocal.wholeDill, equals(cleanBuild.wholeDill));
    expect(incrementalLocal.modularDill, equals(cleanBuild.modularDill));
    expect(incrementalWorker.modularDill, equals(cleanBuild.modularDill));
    expect(
      incrementalWorkerReversedRoots.modularDill,
      equals(cleanBuild.modularDill),
    );

    // Scenario 2: Reverse case — `bazel-out/k8-fastbuild/bin/pkg/lib/gen.dart` is a
    // declared generated input in `WorkRequest.inputs` (and `--input-source`), while
    // an untracked stale file exists in the workspace at `./pkg/lib/gen.dart`
    // (importing `dart:html`). `_Files.read` and `compileModule` must skip `.` and
    // compile the declared generated file from `bazel-out/k8-fastbuild/bin`.
    // Scenario 2: Simultaneous cross-root shadowing in both worker (`WorkRequest.inputs`)
    // and local (`inputs: const []`, `--input-source` only) strategies:
    // - `bazel-out/k8-fastbuild/bin/pkg/lib/gen.dart` is declared in `bazel-out`, while
    //   an untracked valid-Dart file `./pkg/lib/gen.dart` exists in `.`.
    // - `./pkg/lib/hand.dart` is declared in `.`, while a stale generated file
    //   `bazel-out/k8-fastbuild/bin/pkg/lib/hand.dart` exists in `bazel-out`.
    // No ordering of `--multi-root .` and `--multi-root bazel-out/k8-fastbuild/bin`
    // could satisfy both at once; isolated multi-root staging must pick the exact
    // declared origin for each file.
    final genWs = Directory('${_root.path}/gen_vs_untracked')
      ..createSync(recursive: true);
    File('${genWs.path}/package_config.json').writeAsStringSync(
      jsonEncode({
        'configVersion': 2,
        'packages': [
          {
            'name': 'pkg',
            'rootUri': 'org-dartlang-root:///pkg',
            'packageUri': 'lib/',
            'languageVersion': '3.0',
          },
        ],
      }),
    );
    File('${genWs.path}/pkg/lib/gen.dart')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync("String genVal() => 'untracked-dot-shadow';\n");
    File('${genWs.path}/bazel-out/k8-fastbuild/bin/pkg/lib/gen.dart')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync("String genVal() => 'declared-generated-v2';\n");
    File('${genWs.path}/pkg/lib/hand.dart')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync("String handVal() => 'declared-hand-v2';\n");
    File('${genWs.path}/bazel-out/k8-fastbuild/bin/pkg/lib/hand.dart')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync("String handVal() => 'stale-bazel-out-shadow';\n");

    final genCompiler = _CwdOneShotCompiler(
      dartaotruntime,
      kernelWorker,
      genWs.path,
    );
    final prevCwd = Directory.current;
    Directory.current = genWs;
    try {
      for (final passInputs in [true, false]) {
        final outDir =
            'bazel-out/k8-fastbuild/bin/gen_${passInputs ? "worker" : "local"}.kmod';
        final exclOut =
            'bazel-out/k8-fastbuild/bin/gen_${passInputs ? "worker" : "local"}.vm_excluded.txt';
        final genLog = StringBuffer();
        final genCode = await compileModule(
          [
            '--target',
            'vm',
            '--dart-sdk-summary',
            platformDill,
            '--packages-file',
            'package_config.json',
            '--libraries-json',
            librariesJson,
            '--multi-root',
            '.',
            '--multi-root',
            'bazel-out/k8-fastbuild/bin',
            '--multi-root-scheme',
            'org-dartlang-root',
            '--no-summary-only',
            '--exclude-non-sources',
            '--source',
            'package:pkg/gen.dart',
            '--input-source',
            'bazel-out/k8-fastbuild/bin/pkg/lib/gen.dart',
            '--source',
            'package:pkg/hand.dart',
            '--input-source',
            'pkg/lib/hand.dart',
            '--output',
            outDir,
            '--excluded-output',
            exclOut,
          ],
          genCompiler,
          genLog,
          passInputs
              ? [
                  _encodeInputForTest(
                    'bazel-out/k8-fastbuild/bin/pkg/lib/gen.dart',
                    Uint8List.fromList([9]),
                  ),
                  _encodeInputForTest(
                    'pkg/lib/hand.dart',
                    Uint8List.fromList([10]),
                  ),
                ]
              : const [],
        );
        expect(genCode, 0, reason: genLog.toString());
        final genIdx = jsonDecode(
          File('$outDir/index.json').readAsStringSync(),
        ) as Map<String, dynamic>;
        expect((genIdx['sccs'] as List), hasLength(2));
        final dill0 = File('$outDir/0.dill').readAsBytesSync();
        final dill1 = File('$outDir/1.dill').readAsBytesSync();
        final combined = Uint8List.fromList([...dill0, ...dill1]);
        expect(
          _containsSubsequence(combined, utf8.encode('declared-generated-v2')),
          isTrue,
        );
        expect(
          _containsSubsequence(combined, utf8.encode('declared-hand-v2')),
          isTrue,
        );
        expect(
          _containsSubsequence(combined, utf8.encode('untracked-dot-shadow')),
          isFalse,
        );
        expect(
          _containsSubsequence(combined, utf8.encode('stale-bazel-out-shadow')),
          isFalse,
        );
      }
    } finally {
      Directory.current = prevCwd;
    }
  });

  test('kernelWorkerUri, kernelWorkerArgs, ensureSummaryDigests, and compileModule convert Windows drive-letter paths to file:/// URIs without breaking --output or relative paths', () async {
    expect(isWindowsDrivePath('d:/_bazel/external/vm.dill'), isTrue);
    expect(isWindowsDrivePath(r'C:\Users\runneradmin\AppData\Temp'), isTrue);
    expect(isWindowsDrivePath('C:'), isTrue);
    expect(isWindowsDrivePath('package:pkg/a.dart'), isFalse);
    expect(isWindowsDrivePath('org-dartlang-root:///pkg/lib/a.dart'), isFalse);
    expect(isWindowsDrivePath('file:///d:/_bazel/external/vm.dill'), isFalse);
    expect(isWindowsDrivePath('/tmp/ws/vm.dill'), isFalse);
    expect(isWindowsDrivePath('bazel-out/x64_windows-fastbuild/bin'), isFalse);

    const winSdkSummary =
        'd:/_bazel/external/+dart+dart_windows-x64/lib/_internal/vm_platform_strong.dill';
    const winTempRoot =
        r'C:\Users\runneradmin\AppData\Local\Temp\kernel_module_test_123';
    const winPackages =
        r'C:\Users\runneradmin\AppData\Local\Temp\kernel_module_test_123/real_packages.json';
    const winSummary =
        r'C:\Users\runneradmin\AppData\Local\Temp\kernel_module_test_123\dep.koutline/0.dill';
    const winOut = r'C:\Users\runneradmin\out\0.dill';

    expect(
      kernelWorkerUri(winSdkSummary),
      'file:///d:/_bazel/external/+dart+dart_windows-x64/lib/_internal/vm_platform_strong.dill',
    );
    expect(
      kernelWorkerUri(winTempRoot),
      'file:///C:/Users/runneradmin/AppData/Local/Temp/kernel_module_test_123',
    );
    // Idempotent when already a file:/// URI.
    expect(
      kernelWorkerUri(kernelWorkerUri(winSdkSummary)),
      kernelWorkerUri(winSdkSummary),
    );
    // Relative and POSIX paths and package:/multi-root URIs are untouched.
    expect(kernelWorkerUri('package_config.json'), 'package_config.json');
    expect(kernelWorkerUri('/tmp/ws/0.dill'), '/tmp/ws/0.dill');
    expect(kernelWorkerUri('package:pkg/a.dart'), 'package:pkg/a.dart');

    final rewritten = kernelWorkerArgs([
      '--target',
      'vm',
      '--dart-sdk-summary',
      winSdkSummary,
      '--packages-file=$winPackages',
      '--multi-root',
      winTempRoot,
      '--multi-root=.',
      '--input-summary',
      winSummary,
      '--redirect',
      '$winSummary|$winSdkSummary',
      '--source',
      'package:pkg/a.dart',
      '--output',
      winOut,
    ]);
    expect(rewritten, [
      '--target',
      'vm',
      '--dart-sdk-summary',
      'file:///d:/_bazel/external/+dart+dart_windows-x64/lib/_internal/vm_platform_strong.dill',
      '--packages-file=file:///C:/Users/runneradmin/AppData/Local/Temp/kernel_module_test_123/real_packages.json',
      '--multi-root',
      'file:///C:/Users/runneradmin/AppData/Local/Temp/kernel_module_test_123',
      '--multi-root=.',
      '--input-summary',
      'file:///C:/Users/runneradmin/AppData/Local/Temp/kernel_module_test_123/dep.koutline/0.dill',
      '--redirect',
      'file:///C:/Users/runneradmin/AppData/Local/Temp/kernel_module_test_123/dep.koutline/0.dill|file:///d:/_bazel/external/+dart+dart_windows-x64/lib/_internal/vm_platform_strong.dill',
      '--source',
      'package:pkg/a.dart',
      '--output',
      winOut,
    ]);

    // Verify ensureSummaryDigests matches a Windows drive-letter input path (with
    // backslashes or forward slashes) to a file:/// --input-summary argument without
    // touching disk, and emits the file:/// path in WorkRequest.inputs so
    // kernel_worker's `inputDigests[toUri(input.path)]` lookup succeeds.
    final winSentinel = Uint8List.fromList([0xde, 0xad, 0xbe, 0xef]);
    final winInputs = await ensureSummaryDigests(
      ['--input-summary', kernelWorkerUri(winSummary)],
      [_encodeInputForTest(winSummary, winSentinel)],
    );
    final decodedWinInputs = {
      for (final raw in winInputs)
        _decodeInputForTest(raw).path: _decodeInputForTest(raw).digest,
    };
    expect(
      decodedWinInputs['file:///C:/Users/runneradmin/AppData/Local/Temp/kernel_module_test_123/dep.koutline/0.dill'],
      equals(winSentinel),
    );

    // Verify compileModule rewrites Windows drive-letter flags passed to the
    // compiler while keeping --output as a file path.
    _write('pkg/lib/win_smoke.dart', 'int winSmoke() => 1;\n');
    final rec = _Recorder();
    final log = StringBuffer();
    final code = await compileModule(
      [
        '--target',
        'vm',
        '--dart-sdk-summary',
        winSdkSummary,
        '--packages-file',
        '${_root.path}/package_config.json',
        '--libraries-json',
        '${_root.path}/libraries.json',
        '--multi-root',
        _root.path,
        '--multi-root-scheme',
        'org-dartlang-root',
        '--source',
        _uri('pkg/lib/win_smoke.dart'),
        '--output',
        '${_root.path}/out/win_smoke.kmod',
        '--excluded-output',
        '${_root.path}/out/win_smoke.vm_excluded.txt',
      ],
      rec,
      log,
      const [],
    );
    expect(code, 0, reason: log.toString());
    expect(_valuesAfter(rec.calls.single, '--dart-sdk-summary'), [
      'file:///d:/_bazel/external/+dart+dart_windows-x64/lib/_internal/vm_platform_strong.dill',
    ]);
    expect(_valuesAfter(rec.calls.single, '--output'), [
      '${_root.path}/out/win_smoke.kmod/0.dill',
    ]);
  });

  test('isolated staging falls back to copies when symlinks are refused and still reuses digests', () async {
    // Simulates Windows without developer mode: symlink creation throws, so
    // staging must copy file contents instead, isolate just as well, and
    // still reuse WorkRequest.inputs digests without re-hashing from disk.
    // `fb_b.dart` carries an unterminated comment its directives scan cannot
    // follow, so the probe keeps isolated staging (an unscannable source may
    // import files planning never saw). It stays the dependency `fb_a`
    // imports, so its component still compiles first and every recorded call
    // runs staged.
    _write('pkg/lib/fb_a.dart', "import 'fb_b.dart';\nclass FbA {}\n");
    _write('pkg/lib/fb_b.dart', '/* unterminated prologue\nclass FbB {}\n');
    final outDir = '${_root.path}/out/fallback.kmod';
    final outlineDir = '${_root.path}/out/fallback.koutline';
    final sentinelA = Uint8List.fromList(utf8.encode('fallback-digest-a-1234'));
    final sentinelB = Uint8List.fromList(utf8.encode('fallback-digest-b-5678'));
    // While staging still exists (before compileModule cleans it up), each
    // staged file must be a real copied file (not a symlink) whose contents
    // equal the declared origin, so isolation holds without links.
    final recorder = _InputRecordingCompiler(
      onRun: (_) {
        for (final key in ['pkg/lib/fb_a.dart', 'pkg/lib/fb_b.dart']) {
          final stagedPath = '$outDir/.isolated_root/$key';
          expect(
            FileSystemEntity.typeSync(stagedPath, followLinks: false),
            FileSystemEntityType.file,
            reason: '$key must be a copied file when symlinks are refused',
          );
          expect(
            File(stagedPath).readAsStringSync(),
            File('${_root.path}/$key').readAsStringSync(),
            reason: 'copied $key must equal its declared origin',
          );
        }
      },
    );
    final log = StringBuffer();
    FileSystemException linkError() =>
        const FileSystemException('symlinks refused', 'isolated_root');
    final prevCwd = Directory.current;
    Directory.current = _root;
    try {
      final code = await compileModule(
        [
          '--source',
          _uri('pkg/lib/fb_a.dart'),
          '--source',
          _uri('pkg/lib/fb_b.dart'),
          '--output',
          outDir,
          '--output-outline',
          outlineDir,
          '--excluded-output',
          '$outDir.vm_excluded.txt',
          '--packages-file',
          '${_root.path}/package_config.json',
          '--libraries-json',
          '${_root.path}/libraries.json',
          '--multi-root',
          _root.path,
          '--target',
          'vm',
        ],
        recorder,
        log,
        [
          _encodeInputForTest('${_root.path}/pkg/lib/fb_a.dart', sentinelA),
          _encodeInputForTest('${_root.path}/pkg/lib/fb_b.dart', sentinelB),
        ],
        createLink: (_, _) => throw linkError(),
      );
      expect(code, 0, reason: log.toString());
    } finally {
      Directory.current = prevCwd;
    }
    // The front end must still see a single isolated root on every call.
    expect(recorder.calls, isNotEmpty);
    for (final call in recorder.calls) {
      expect(_valuesAfter(call, '--multi-root'), [
        kernelWorkerUri('$outDir/.isolated_root'),
      ]);
    }
    // Staged inputs must reuse the WorkRequest.inputs digests, and the origin
    // inputs must be withheld as duplicates, across every compile call.
    final callInputs = {
      for (final call in recorder.callInputs)
        for (final raw in call)
          _decodeInputForTest(raw).path: _decodeInputForTest(raw).digest,
    };
    expect(
      callInputs[kernelWorkerUri('$outDir/.isolated_root/pkg/lib/fb_a.dart')],
      equals(sentinelA),
    );
    expect(
      callInputs[kernelWorkerUri('$outDir/.isolated_root/pkg/lib/fb_b.dart')],
      equals(sentinelB),
    );
    expect(
      callInputs.keys,
      isNot(contains('${_root.path}/pkg/lib/fb_a.dart')),
      reason: 'origin inputs must be withheld once staged',
    );
    expect(
      callInputs.keys,
      isNot(contains('${_root.path}/pkg/lib/fb_b.dart')),
      reason: 'origin inputs must be withheld once staged',
    );
  });

  test('ensureSummaryDigests reuses digests across Windows path spellings without touching disk', () async {
    // Windows spells the same file with backslashes, forward slashes, or a
    // `file:///` URI; the digest must be reused in every spelling without
    // reading the file from disk (the file does not exist under these names).
    const backslash =
        r'C:\Users\runneradmin\AppData\Local\Temp\winspell\dep.koutline\0.dill';
    const forward =
        'C:/Users/runneradmin/AppData/Local/Temp/winspell/dep.koutline/0.dill';
    const uri =
        'file:///C:/Users/runneradmin/AppData/Local/Temp/winspell/dep.koutline/0.dill';
    final sentinel = Uint8List.fromList([0xaa, 0xbb, 0xcc, 0xdd]);
    for (final spelling in [backslash, forward, uri]) {
      final inputs = await ensureSummaryDigests(
        ['--input-summary', uri],
        [_encodeInputForTest(spelling, sentinel)],
      );
      final decoded = {
        for (final raw in inputs)
          _decodeInputForTest(raw).path: _decodeInputForTest(raw).digest,
      };
      expect(
        decoded[uri],
        equals(sentinel),
        reason: 'input spelled as $spelling must reuse its digest for $uri',
      );
    }
    // Drive-relative `C:foo` is not an absolute Windows path.
    expect(isWindowsDrivePath(r'C:foo'), isFalse);
    expect(isWindowsDrivePath('C:'), isTrue);
    expect(isWindowsDrivePath(r'C:\x'), isTrue);
    expect(isWindowsDrivePath('C:/x'), isTrue);
  });
}

class _InputRecordingCompiler implements ModuleCompiler {
  _InputRecordingCompiler({this.onRun});

  /// Invoked synchronously from [run], while isolated staging still exists.
  final void Function(List<String> args)? onRun;

  final List<List<String>> calls = [];
  final List<List<Uint8List>> callInputs = [];

  @override
  Future<ModuleOutcome> run(List<String> args, List<Uint8List> inputs) async {
    onRun?.call(args);
    calls.add(args);
    callInputs.add([for (final i in inputs) Uint8List.fromList(i)]);
    final outIdx = args.indexOf('--output');
    if (outIdx != -1 && outIdx + 1 < args.length) {
      final outPath = args[outIdx + 1];
      File(outPath)
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(_buildMinimalFieldDill());
    }
    return const ModuleOutcome(0, '');
  }

  @override
  Future<void> close() async {}
}

Uint8List _encodeVarintForTest(int value) {
  final out = BytesBuilder();
  var v = value;
  while (v >= 0x80) {
    out.addByte((v & 0x7f) | 0x80);
    v >>= 7;
  }
  out.addByte(v);
  return out.toBytes();
}

Uint8List _encodeInputForTest(String path, Uint8List digest) {
  final out = BytesBuilder();
  final pathBytes = utf8.encode(path);
  out.add(_encodeVarintForTest((1 << 3) | 2));
  out.add(_encodeVarintForTest(pathBytes.length));
  out.add(pathBytes);
  if (digest.isNotEmpty) {
    out.add(_encodeVarintForTest((2 << 3) | 2));
    out.add(_encodeVarintForTest(digest.length));
    out.add(digest);
  }
  return out.toBytes();
}

({String path, Uint8List digest}) _decodeInputForTest(Uint8List bytes) {
  var pos = 0;
  int readVarint() {
    var result = 0;
    var shift = 0;
    while (true) {
      final b = bytes[pos++];
      result |= (b & 0x7f) << shift;
      if ((b & 0x80) == 0) return result;
      shift += 7;
    }
  }

  var path = '';
  var digest = Uint8List(0);
  while (pos < bytes.length) {
    final tag = readVarint();
    final field = tag >> 3;
    final wire = tag & 7;
    if (wire == 2) {
      final len = readVarint();
      final slice = Uint8List.sublistView(bytes, pos, pos + len);
      pos += len;
      if (field == 1) {
        path = utf8.decode(slice);
      } else if (field == 2) {
        digest = Uint8List.fromList(slice);
      }
    } else if (wire == 0) {
      readVarint();
    }
  }
  return (path: path, digest: digest);
}

Uint8List _encodeWorkRequestForTest({
  required List<String> arguments,
  required Map<String, Uint8List> inputs,
}) {
  final out = BytesBuilder();
  for (final arg in arguments) {
    final argBytes = utf8.encode(arg);
    out.add(_encodeVarintForTest((1 << 3) | 2));
    out.add(_encodeVarintForTest(argBytes.length));
    out.add(argBytes);
  }
  for (final entry in inputs.entries) {
    final inputMsg = _encodeInputForTest(entry.key, entry.value);
    out.add(_encodeVarintForTest((2 << 3) | 2));
    out.add(_encodeVarintForTest(inputMsg.length));
    out.add(inputMsg);
  }
  return out.toBytes();
}

Uint8List _buildMinimalDillWithSourceAndMetadata({required int srcLen}) {
  final out = BytesBuilder();
  void u30(int v) {
    assert(v >= 0 && v < 0x80);
    out.addByte(v);
  }

  void u32(int v) {
    out.addByte((v >> 24) & 0xff);
    out.addByte((v >> 16) & 0xff);
    out.addByte((v >> 8) & 0xff);
    out.addByte(v & 0xff);
  }

  u32(Tag.ComponentFile);
  u32(Tag.BinaryFormatVersion);
  for (var i = 0; i < 10; i++) {
    out.addByte(0);
  }
  u30(0);

  final libStart = out.length;
  out.addByte(0); // flags
  u30(3); // major
  u30(0); // minor
  u30(1); // canonicalName
  u30(1); // name
  u30(0); // fileUri
  u30(0); // problemsAsJson
  u30(0); // annotations
  u30(0); // depCount
  u30(0); // expCount
  u30(0); // partCount
  u30(0); // tdCount
  u30(0); // clsCount
  u30(0); // extCount
  u30(0); // extTypeCount
  u30(0); // fieldCount
  u30(0); // pCount
  final sourceRefsOffset = out.length;
  u30(0); // usedCount
  u32(sourceRefsOffset);
  u32(libStart + 13); // clsOffsets[0]
  u32(0); // classCount
  u32(sourceRefsOffset); // procOffsets[0]
  u32(0); // procCount
  final libEnd = out.length;

  final sourceTableOffset = libEnd;
  u32(1); // numSources = 1
  final uriEntry0 = out.length;
  u30(5); // uriLen = 5 ("a.dart" prefix)
  out.add([97, 46, 100, 97, 114]);
  u30(srcLen);
  out.add(List<int>.filled(srcLen, 0x61));
  u30(2); // lineCount = 2
  u30(0);
  u30(1);
  u30(5); // importUri len = 5
  out.add([97, 46, 100, 97, 114]);
  u30(0); // constantCoverageConstructors
  u32(uriEntry0);

  final constantTableOffset = out.length;
  u30(0);
  final constantTableIndexOffset = out.length;
  u32(0);

  final linkTableOffset = out.length;
  u30(1); // canonCount = 1
  u30(0);
  u30(1);

  final metaPad = (8 - (out.length % 8)) % 8;
  if (metaPad > 0) out.add(Uint8List(metaPad));
  final metadataPayloadsOffset = out.length;
  out.add([0xde, 0xad, 0xbe, 0xef, 0xca, 0xfe, 0xba, 0xbe]);
  final metadataMappingsOffset = out.length;
  out.add([0x11, 0x22, 0x33, 0x44, 0x00, 0x00, 0x00, 0x01]);

  final stringTableOffset = out.length;
  u30(2);
  u30(0);
  u30(1);
  out.addByte(102); // "f"

  final componentIndexOffset = out.length;
  const idxBytes = 13 * 4;
  final pad = (8 - ((out.length + idxBytes) % 8)) % 8;
  if (pad > 0) out.add(Uint8List(pad));

  u32(sourceTableOffset);
  u32(constantTableOffset);
  u32(constantTableIndexOffset);
  u32(linkTableOffset);
  u32(metadataPayloadsOffset);
  u32(metadataMappingsOffset);
  u32(stringTableOffset);
  u32(componentIndexOffset);
  u32(0); // mainMethodReference
  u32(libStart);
  u32(libEnd);
  u32(1); // libraryCount = 1
  u32(out.length + 4);
  return out.toBytes();
}

class _RealOneShotCompiler implements ModuleCompiler {
  _RealOneShotCompiler(this._dartaotruntime, this._kernelWorker);

  final String _dartaotruntime;
  final String _kernelWorker;

  @override
  Future<ModuleOutcome> run(List<String> args, List<Uint8List> inputs) async {
    final res = await Process.run(_dartaotruntime, [
      patchSnapshotSplitCommas(_kernelWorker),
      ...args,
    ]);
    return ModuleOutcome(res.exitCode, '${res.stdout}${res.stderr}');
  }

  @override
  Future<void> close() async {}
}

class _CwdOneShotCompiler implements ModuleCompiler {
  _CwdOneShotCompiler(this._dartaotruntime, this._kernelWorker, this._cwd);

  final String _dartaotruntime;
  final String _kernelWorker;
  final String _cwd;

  @override
  Future<ModuleOutcome> run(List<String> args, List<Uint8List> inputs) async {
    final res = await Process.run(_dartaotruntime, [
      patchSnapshotSplitCommas(_kernelWorker),
      ...args,
    ], workingDirectory: _cwd);
    return ModuleOutcome(res.exitCode, '${res.stdout}${res.stderr}');
  }

  @override
  Future<void> close() async {}
}
