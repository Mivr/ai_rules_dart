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
import 'kernel_link.dart' show KernelLinkCache, linkOne;
import 'kernel_module.dart'
    show
        ModuleCompiler,
        ModuleOutcome,
        compileModule,
        scanDirectives,
        stripSourceCodeFromDill;

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
}) async {
  final output = '${_root.path}/out/$name';
  final excludedPath = '$output.vm_excluded.txt';
  final prefix = scheme == null ? _prefix : '$scheme:///';
  final args = <String>[
    for (final source in sources) ...['--source', '$prefix$source'],
    for (final inputSource in inputSources) ...['--input-source', inputSource],
    '--output',
    output,
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
  final code = await compileModule(args, recorder, log, inputs);
  final written = code == 0
      ? jsonDecode(File('$output/index.json').readAsStringSync())
            as Map<String, dynamic>
      : <String, dynamic>{'sccs': <dynamic>[]};
  return _Result(
    code,
    recorder.calls,
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
      '$dep/0.dill',
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
      '$defines/0.dill',
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
      contains('$defines/0.dill'),
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
    expect(
      _valuesAfter(entry.calls.single, '--multi-root'),
      contains('$pkgOutline/sources'),
    );
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
      "const libVal = String.fromEnvironment('COMMA_VAL');\n",
    );
    _write(
      'pkg/bin/main.dart',
      "import 'package:pkg/a.dart';\n"
          "void main() {\n"
          "  const mainVal = String.fromEnvironment('COMMA_VAL');\n"
          "  print('\$libVal|\$mainVal');\n"
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
    expect((runRes.stdout as String).trim(), 'a,b|a,b');
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
        'bazel-out/k8-fastbuild/bin',
        '--filesystem-root',
        '.',
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
            'bazel-out/k8-fastbuild/bin',
            '--multi-root',
            '.',
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
            'bazel-out/k8-fastbuild/bin',
            '--multi-root',
            '.',
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
    final res = await Process.run(_dartaotruntime, [_kernelWorker, ...args]);
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
      _kernelWorker,
      ...args,
    ], workingDirectory: _cwd);
    return ModuleOutcome(res.exitCode, '${res.stdout}${res.stderr}');
  }

  @override
  Future<void> close() async {}
}
