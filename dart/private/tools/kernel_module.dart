// Compiles one kernel module with `kernel_worker`. See `kernel_module_action` in
// `dart/private/dart_kernel.bzl`.
//
// A module compiles the sources its `dart_library` declares, except the files that
// cannot compile for the VM. Which files those are is decided before compiling,
// from the import graph, by reading each source's directives:
//
//  * A file that imports or exports a `dart:` library the VM does not have
//    (`dart:html`, `dart:js_interop`, ...) is excluded.
//  * A file that imports or exports a `package:` URI whose package is not in the
//    module's package config is excluded, since the module cannot resolve it.
//  * A file with a `part` directive whose part is not one of the module's
//    inputs, or a `part of` file whose library is not one of the module's
//    inputs, is excluded, since a library and its parts cannot compile apart.
//  * A file that imports or exports an excluded file is excluded. A `part` shares
//    its library's verdict.
//  * A conditional import takes its first `dart.library.X` alternative for a VM
//    library X, and its default URI otherwise.
//  * A directive URI resolves exactly as the front end resolves it: escapes decode
//    once (either hex case), `\` is a separator, and `..` in a relative URI never
//    leaves the importer's package directory (while a `package:` escape fails), so
//    a percent-encoded spelling that reads an undeclared file excludes its library
//    instead of compiling the shadow.
//  * The VM libraries are those of the `vm` platform in the SDK's `libraries.json`,
//    following its `include`s.
//  * A source that a dependency module already defines is not compiled again. The
//    kernels the module links against define it, and the module's dependents link
//    to that kernel.
//  * An excluded file is listed in the module's `.vm_excluded.txt` sidecar. A
//    dependent module reads the sidecars of its whole closure, so the files that
//    import an excluded file are excluded too. A dependent that lists the excluded
//    file among its own sources compiles its own copy, if it can. An excluded file
//    that some module of the closure defines is not excluded for the closure at all.
//
// The module's output is a directory. It holds one kernel per strongly connected
// component of its own sources (libraries that import each other compile together,
// and a part belongs to its library), and an `index.json` that lists them: each
// kernel's file, the keys of the libraries it defines, and the keys it imports. A
// component compiles against only the kernels it reaches, passed as `--input-summary`,
// and a kernel is written after every kernel it imports.
//
// When `--output-outline` is given, each compiled component is also stripped to a
// deterministic outline `.dill` (`stripDillToOutline`) in the `.koutline` directory
// for downstream `--input-summary` compiles, while the `.kmod` directory keeps the
// full component with embedded source text stripped (`stripSourceCodeFromDill`). Any
// class that can be used as a mixin (`mixin`, `mixin class`, and every class in a
// library whose language version is below 3.0) keeps its member bodies and field
// initializers in `.koutline`. Both strippers check the 32-bit kernel format version
// in the header (accepting version 138, Dart 3.13.x) and log a diagnostic to `stderr`
// while falling back to the unstripped `.dill` bytes on any other version.
//
// A dependent module names its dependencies' directories with `--input-kmod`. It reads
// their indexes, and each component compiles against the kernels it reaches through
// them.
//
// The remaining sources compile with `--exclude-non-sources`, so a kernel holds its
// own libraries and nothing it links against. An error from one of them is real, and
// fails the action with the compiler's output. The one exception is a safety net: an
// error that can be blamed on an own source drops that source and its importers, and
// the module compiles once more. Any other error fails at once.
//
// An unstaged compile then proves it read only declared or pinned inputs: every
// workspace file its `.dill` records must be declared, or defined by a dependency
// module of the closure, or the compile is redone with an
// isolated `--multi-root` holding symlinks to exactly the declared origins, where
// the missed read fails instead of escaping the sandbox.
//
// An executable's entry module compiles from source every file it reaches that the
// closure excludes and no module defines, so the compiler reports the genuine VM error
// exactly as a whole-program compile would. It has no safety net. Its kernel is linked,
// with the kernels it reaches, by `kernel_link`.
//
// With `--persistent_worker` this is a Bazel persistent worker. It keeps one
// `kernel_worker` child running for its requests, retries included. When the child
// cannot be trusted, the child is killed, a new one starts, and the request is sent to
// it once more. That is after the child dies, after a request runs past the timeout
// (15 minutes, or `--request-timeout-seconds=N` for a test), after bytes that are not
// the answer to the request, and after a crash, since a crashed child never answers its
// next request. A second failure fails the action, with both attempts' output. Without
// the flag it runs one compile. Either way it prints nothing on success, and on a
// failure it prints the full diagnostics.
//
// The worker protocol is spoken directly, as a length-prefixed `WorkRequest` and
// `WorkResponse`, rather than through `package:bazel_worker`. That package is a
// `dart_library`, and every `dart_library` carries this tool as an attribute, so
// depending on it would make a cycle.

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../guard/lib/directive_guard.dart';
import 'comma_patch.dart';
import 'dill_outline.dart';
// Shared through `srcs`, like the guard import above: this binary takes no
// `dart_library` dependency on purpose (see the `kernel_module` target).
import 'lib/worker_protocol.dart';

export '../../guard/lib/directive_guard.dart'
    show
        ScanRef,
        ScanResult,
        decodeUriSegment,
        defaultMultiRootPrefix,
        findDisallowedDirectives,
        isDisallowedDirectiveUri,
        isFileSchemeDirectiveUri,
        resolveDirectiveUri,
        scanAllDirectiveUris,
        scanDirectives;
export 'lib/worker_protocol.dart' show sha256Of;

const _kernelWorkerFlag = '--kernel-worker';
const _dartaotruntimeFlag = '--dartaotruntime';
const _persistentFlag = '--persistent_worker';

/// Startup flag the build passes when `--kernel-worker` names the
/// comma-patched snapshot the toolchain's declared patch action produced (see
/// `comma_patch.dart`). Without it, a request whose `-D` / `--define` values
/// contain a comma fails loudly instead of silently splitting the value.
///
/// A startup flag, not a params-file flag: the worker key covers the startup
/// arguments, so comma compiles (which name the patched snapshot) get their
/// own worker process and never share one running the pristine snapshot. It
/// never reaches a request's arguments, so `kernel_worker` never sees it.
const _commaPatchedFlag = '--comma-patched-snapshot';

// Flags this tool consumes. `kernel_worker` never sees them.
const _excludedOutputFlag = '--excluded-output';
const _closureExcludedFlag = '--closure-excluded';
const _librariesJsonFlag = '--libraries-json';
const _librariesPlatformFlag = '--libraries-platform';
const _extraLibraryFlag = '--extra-library';
const _inputKmodFlag = '--input-kmod';
const _inputSourceFlag = '--input-source';
const _outputOutlineFlag = '--output-outline';
const _ownSourceFileFlag = '--own-source-file';
const _unusedInputsListFlag = '--unused-inputs-list';

/// The file in each module directory that lists its kernels.
const _indexName = 'index.json';
const _noDropFlag = '--no-drop';
const _packagesFlag = '--packages-file';
const _multiRootFlag = '--multi-root';
const _multiRootSchemeFlag = '--multi-root-scheme';

const _defaultMultiRootPrefix = 'org-dartlang-root:///';

/// `<path>:<line>:<col>: Error: <message>`, one per located diagnostic.
final _errorLine = RegExp(r'^(.+?):(\d+):(\d+): Error: (.*)$', multiLine: true);

/// The `bazel-out/<config>/bin/` prefix a diagnostic may give a generated file.
final _bazelOutPrefix = RegExp(r'^(?:\./)?bazel-out/[^/]+/bin/');

const _kernelWorkerUriFlags = <String>{
  '--dart-sdk-summary',
  '--packages-file',
  '--libraries-file',
  '--multi-root',
  '--input-summary',
  '--input-linked',
  '--source',
  '--native-assets',
};

bool _isAsciiAlpha(int c) =>
    (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a);

/// True when [s] starts with a Windows drive letter (`C:/...`, `d:\...`, `C:`).
bool isWindowsDrivePath(String s) =>
    s.length >= 2 &&
    _isAsciiAlpha(s.codeUnitAt(0)) &&
    s.codeUnitAt(1) == 0x3a &&
    (s.length == 2 || s.codeUnitAt(2) == 0x2f || s.codeUnitAt(2) == 0x5c);

/// Converts a Windows drive-letter or UNC file path to a `file://` URI string
/// for `kernel_worker` (`package:frontend_server/compute_kernel.dart`).
///
/// `kernel_worker` resolves URI-bearing flags via
/// `Uri.base.resolve(s.replaceAll(r'\', '/'))`. For an absolute Windows path
/// such as `d:/_bazel/...` or `C:\Users\...`, `Uri.base.resolve` treats the
/// drive letter as a URI scheme (`scheme: 'd'`), which `StandardFileSystem`
/// rejects (`StandardFileSystem only supports file:* and data:* URIs`).
String kernelWorkerUri(String pathOrUri) {
  if (isWindowsDrivePath(pathOrUri) || pathOrUri.startsWith(r'\\')) {
    return Uri.file(pathOrUri, windows: true).toString();
  }
  return pathOrUri;
}

String _filePathOf(String pathOrUri) {
  if (pathOrUri.startsWith('file:///')) {
    final rest = pathOrUri.substring('file:///'.length);
    if (isWindowsDrivePath(rest)) return rest;
  }
  if (pathOrUri.startsWith('file://')) {
    return Uri.parse(pathOrUri).toFilePath(windows: true);
  }
  return pathOrUri;
}

String _rewriteRedirectUri(String value) {
  final sep = value.indexOf('|');
  if (sep < 0) return kernelWorkerUri(value);
  return '${kernelWorkerUri(value.substring(0, sep))}|'
      '${kernelWorkerUri(value.substring(sep + 1))}';
}

/// Rewrites Windows drive-letter and UNC paths in `kernel_worker` URI-bearing
/// flags to `file:///` URIs while leaving `--output` and other file-system
/// path flags unchanged.
List<String> kernelWorkerArgs(List<String> args) {
  final out = <String>[];
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (_kernelWorkerUriFlags.contains(arg) && i + 1 < args.length) {
      out
        ..add(arg)
        ..add(kernelWorkerUri(args[++i]));
      continue;
    }
    if (arg == '--redirect' && i + 1 < args.length) {
      out
        ..add(arg)
        ..add(_rewriteRedirectUri(args[++i]));
      continue;
    }
    if (arg.startsWith('--redirect=')) {
      final raw = arg.substring('--redirect='.length);
      out.add('--redirect=${_rewriteRedirectUri(raw)}');
      continue;
    }
    var matchedEq = false;
    for (final flag in _kernelWorkerUriFlags) {
      final prefix = '$flag=';
      if (arg.startsWith(prefix)) {
        out.add('$flag=${kernelWorkerUri(arg.substring(prefix.length))}');
        matchedEq = true;
        break;
      }
    }
    if (!matchedEq) {
      out.add(arg);
    }
  }
  return out;
}

Future<void> main(List<String> argv) async {
  var persistent = false;
  var snapshotPatched = false;
  String? kernelWorker;
  String? dartaotruntime;
  Duration? requestTimeout;
  final rest = <String>[];
  for (var i = 0; i < argv.length; i++) {
    final arg = argv[i];
    if (arg == _persistentFlag) {
      persistent = true;
    } else if (arg == _commaPatchedFlag) {
      snapshotPatched = true;
    } else if (arg.startsWith(_requestTimeoutFlag)) {
      final seconds = int.tryParse(arg.substring(_requestTimeoutFlag.length));
      if (seconds == null || seconds <= 0) {
        stderr.writeln(
          'kernel_module: $arg is not a positive number of seconds.',
        );
        exitCode = 64;
        return;
      }
      requestTimeout = Duration(seconds: seconds);
    } else if (arg == _kernelWorkerFlag) {
      kernelWorker = argv[++i];
    } else if (arg == _dartaotruntimeFlag) {
      dartaotruntime = argv[++i];
    } else {
      rest.add(arg);
    }
  }
  if (kernelWorker == null || dartaotruntime == null) {
    stderr.writeln(
      'kernel_module: $_kernelWorkerFlag and $_dartaotruntimeFlag are required.',
    );
    exitCode = 64;
    return;
  }
  if (persistent) {
    await _serve(dartaotruntime, kernelWorker, requestTimeout, snapshotPatched);
    // Exit explicitly. Streams of the `kernel_worker` child stay subscribed after
    // it is killed, and would otherwise keep this process alive past its work.
    await stdout.flush();
    exit(0);
  }
  final args = await _expandParamFiles(rest);
  final log = StringBuffer();
  final code = await compileModule(
    args,
    _OneShot(dartaotruntime, kernelWorker, snapshotPatched: snapshotPatched),
    log,
    const [],
  );
  if (code != 0) {
    stderr.write(log);
  }
  await stderr.flush();
  exit(code);
}

/// Serves Bazel `WorkRequest`s until stdin closes.
Future<void> _serve(
  String dartaotruntime,
  String kernelWorker,
  Duration? requestTimeout,
  bool snapshotPatched,
) async {
  final requests = _Frames(stdin);
  final cache = KernelModuleCache();
  final compiler = _Persistent(
    dartaotruntime,
    kernelWorker,
    snapshotPatched: snapshotPatched,
    requestTimeout: requestTimeout,
  );
  try {
    while (true) {
      final frame = await requests.next();
      if (frame == null) break;
      // Every request is answered, even one that fails to decode or compile:
      // a worker that closes stdout without a `WorkResponse` fails the action
      // with no diagnostics at all.
      final log = StringBuffer();
      var code = 1;
      var requestId = 0;
      try {
        final request = _WorkRequest.decode(frame);
        requestId = request.requestId;
        code = await compileModule(
          request.arguments,
          compiler,
          log,
          request.inputs,
          cache: cache,
        );
      } catch (error, stack) {
        log.writeln('kernel_module: $error\n$stack');
      }
      stdout.add(_frame(_encodeResponse(code, log.toString(), requestId)));
      await stdout.flush();
    }
  } finally {
    await compiler.close();
  }
}

/// Compiles one module, or the entry module when `--no-drop` is set.
///
/// The module's directory receives one kernel per strongly connected component of its
/// own sources, and an `index.json` that lists them. Returns 0 on success. Returns 1
/// when a compile fails, with the compiler's output in `log`. Returns 64 when an
/// argument is missing.
///
/// Public so that a test can drive the planner with a [ModuleCompiler] that records its
/// arguments, without a `kernel_worker`.
Future<int> compileModule(
  List<String> rawArgs,
  ModuleCompiler compiler,
  StringBuffer log,
  List<Uint8List> inputs, {
  KernelModuleCache? cache,
  // Injects symlink creation for isolated-root staging. Tests pass a throwing
  // function to exercise the copy fallback that Windows without developer
  // mode takes. Production callers leave it null to create real symlinks.
  void Function(String linkPath, String target)? createLink,
}) async {
  final options = _ModuleOptions();
  final usage = _parseModuleArgs(rawArgs, options, log);
  if (usage != null) return usage;
  final decoded = _decodeWorkerInputs(inputs);
  final build = await _ModuleBuild.load(
    options,
    compiler,
    log,
    inputs,
    decoded.workerInputPaths,
    decoded.inputDigests,
    cache: cache,
    createLink: createLink,
  );
  if (build == null) return 1;
  if (options.noDrop) return build.runEntry();
  return build.runLibrary();
}

/// The command-line options of one `compileModule` run.
class _ModuleOptions {
  final base = <String>[];
  final sources = <String>[];
  final inputSources = <String>[];
  final ownSourceFiles = <String>[];
  final multiRoots = <String>[];
  final closureExcluded = <String>[];
  final inputKmods = <String>[];
  final extraLibraries = <String>[];
  String? excludedPath;
  String? unusedInputsPath;
  String? output;
  String? outputOutline;
  String? packagesFile;
  String? librariesJson;
  var librariesPlatform = 'vm';
  var multiRootPrefix = _defaultMultiRootPrefix;
  var noDrop = false;
}

/// Parses [rawArgs] into [options], returning the exit code on fatal usage
/// errors, or null to continue.
int? _parseModuleArgs(
  List<String> rawArgs,
  _ModuleOptions options,
  StringBuffer log,
) {
  var i = 0;
  while (i < rawArgs.length) {
    i = _parseModuleArg(rawArgs, i, options, log);
    if (i < 0) return 64;
  }
  if (options.excludedPath == null ||
      options.output == null ||
      options.packagesFile == null ||
      options.librariesJson == null) {
    log.writeln(
      'kernel_module: $_excludedOutputFlag, $_librariesJsonFlag, --output and '
      '$_packagesFlag are required.',
    );
    return 64;
  }
  return null;
}

/// Parses the argument at [i], returning the next index, or -1 when
/// `--input-linked` was passed.
int _parseModuleArg(
  List<String> rawArgs,
  int i,
  _ModuleOptions options,
  StringBuffer log,
) {
  final arg = rawArgs[i];
  if (arg == '--source') {
    options.sources.add(rawArgs[++i]);
  } else if (arg == _inputSourceFlag) {
    options.inputSources.add(rawArgs[++i]);
  } else if (arg == _ownSourceFileFlag && i + 1 < rawArgs.length) {
    options.ownSourceFiles.add(rawArgs[++i]);
  } else if (arg.startsWith('$_ownSourceFileFlag=')) {
    options.ownSourceFiles.add(arg.substring(_ownSourceFileFlag.length + 1));
  } else if (arg == _unusedInputsListFlag && i + 1 < rawArgs.length) {
    options.unusedInputsPath = rawArgs[++i];
  } else if (arg.startsWith('$_unusedInputsListFlag=')) {
    options.unusedInputsPath = arg.substring(_unusedInputsListFlag.length + 1);
  } else if (arg == '--output') {
    options.output = rawArgs[++i];
  } else if (arg == _outputOutlineFlag) {
    options.outputOutline = rawArgs[++i];
  } else if (arg == _excludedOutputFlag) {
    options.excludedPath = rawArgs[++i];
  } else if (arg == _closureExcludedFlag) {
    options.closureExcluded.add(rawArgs[++i]);
  } else if (arg == _inputKmodFlag) {
    options.inputKmods.add(rawArgs[++i]);
  } else if (arg == _librariesJsonFlag) {
    options.librariesJson = rawArgs[++i];
  } else if (arg == _librariesPlatformFlag) {
    options.librariesPlatform = rawArgs[++i];
  } else if (arg == _extraLibraryFlag) {
    options.extraLibraries.add(rawArgs[++i]);
  } else if (arg == _noDropFlag) {
    options.noDrop = true;
  } else if (arg == '--input-linked') {
    log.writeln(
      'kernel_module: --input-linked is not accepted; pass $_inputKmodFlag.',
    );
    return -1;
  } else if ((arg == '-D' || arg == '--define') && i + 1 < rawArgs.length) {
    options.base
      ..add(arg)
      ..add(rawArgs[++i]);
  } else {
    _parseBaseArg(rawArgs, i, options);
  }
  return i + 1;
}

/// Parses a compiler pass-through argument at [i] into [options].
void _parseBaseArg(List<String> rawArgs, int i, _ModuleOptions options) {
  final arg = rawArgs[i];
  if (arg == _packagesFlag) {
    options.packagesFile = rawArgs[i + 1];
  } else if (arg.startsWith('$_packagesFlag=')) {
    options.packagesFile = arg.substring(_packagesFlag.length + 1);
  } else if (arg == _multiRootFlag) {
    options.multiRoots.add(rawArgs[i + 1]);
  } else if (arg.startsWith('$_multiRootFlag=')) {
    options.multiRoots.add(arg.substring(_multiRootFlag.length + 1));
  } else if (arg == _multiRootSchemeFlag) {
    options.multiRootPrefix = '${rawArgs[i + 1]}:///';
  } else if (arg.startsWith('$_multiRootSchemeFlag=')) {
    options.multiRootPrefix =
        '${arg.substring(_multiRootSchemeFlag.length + 1)}:///';
  }
  options.base.add(arg);
}

/// The worker input paths and their digests, or nulls when [inputs] is empty.
({Set<String>? workerInputPaths, Map<String, Uint8List>? inputDigests})
_decodeWorkerInputs(List<Uint8List> inputs) {
  if (inputs.isEmpty) {
    return (workerInputPaths: null, inputDigests: null);
  }
  final paths = <String>{};
  final digests = <String, Uint8List>{};
  for (final raw in inputs) {
    final decoded = _decodeInputView(raw);
    final rawPath = decoded.path;
    if (rawPath.isEmpty) continue;
    if (_isNormalizedRelative(rawPath)) {
      paths.add(rawPath);
      if (decoded.digest.isNotEmpty) {
        digests[rawPath] = decoded.digest;
      }
    } else {
      paths.add(rawPath);
      final norm = _normalize(rawPath);
      if (norm.isNotEmpty) paths.add(norm);
      if (decoded.digest.isNotEmpty) {
        digests[rawPath] = decoded.digest;
        final normFile = normalizePath(rawPath);
        digests.putIfAbsent(normFile, () => decoded.digest);
        if (norm.isNotEmpty) {
          digests.putIfAbsent(norm, () => decoded.digest);
          digests.putIfAbsent('./$norm', () => decoded.digest);
        }
      }
    }
  }
  return (workerInputPaths: paths, inputDigests: digests);
}

/// A staged isolated `--multi-root` and the inputs it covers.
typedef _IsolatedRoot = ({
  String rootDir,
  List<Uint8List> inputs,
  Map<String, Uint8List> covered,
});

/// The entry kernel's file name within the module's directory.
const _entryDillName = 'entry.dill';

/// The inputs a post-compile read-set verification consults: the kernel it
/// checks, the declared file view, the closure graph, the multi-root layout,
/// the log, the entry's own URIs and the package roots. One object travels
/// from the compile through the unstaged check to the isolated verdict.
final class _VerifyReads {
  const _VerifyReads({
    required this.dillPath,
    required this.files,
    required this.graph,
    required this.multiRoots,
    required this.multiRootPrefix,
    required this.log,
    required this.ownUris,
    required this.roots,
  });

  final String dillPath;
  final _Files files;
  final Map<String, _Node> graph;
  final List<String> multiRoots;
  final String multiRootPrefix;
  final StringBuffer log;
  final Set<String> ownUris;
  final Map<String, _PackageRoot> roots;
}

/// Compiles with [runCompile] and verifies the read set of [verify.dillPath].
/// An unverified unstaged success is redone after [stage] isolates the
/// compile. Returns the outcome and the (possibly newly staged) isolated
/// root; [refused] reports an isolated result that still read outside the
/// declared inputs — a `file:` URI reads the host whatever the multi-root
/// holds — whose result is refused, never accepted.
Future<({ModuleOutcome outcome, _IsolatedRoot? isolated, bool refused})>
_compileAndVerify(
  Future<ModuleOutcome> Function(_IsolatedRoot? isolated) runCompile,
  Future<_IsolatedRoot> Function() stage,
  _IsolatedRoot? isolated,
  _VerifyReads verify,
) async {
  var current = isolated;
  var outcome = await runCompile(current);
  var verified = false;
  if (outcome.exitCode == 0 && current == null) {
    if (await _unstagedReadsAreDeclared(verify)) {
      verified = true;
    } else {
      // The plan missed a file the front end read (a directive spelling the
      // planner resolves differently): redo the compile where only declared
      // inputs exist, so the read fails instead of escaping the sandbox.
      current = await stage();
      outcome = await runCompile(current);
    }
  }
  if (outcome.exitCode == 0 &&
      !verified &&
      !await _unstagedReadsAreDeclared(
        verify,
        consequence: 'failing the compile',
      )) {
    return (outcome: outcome, isolated: current, refused: true);
  }
  return (outcome: outcome, isolated: current, refused: false);
}

/// Deletes the isolated staging directory, if any.
Future<void> _cleanIsolated(_IsolatedRoot? isolated) async {
  if (isolated == null) return;
  final dir = Directory(_filePathOf(isolated.rootDir));
  if (await dir.exists()) {
    await dir.delete(recursive: true);
  }
}

/// The VM libraries for the module's platform and extra libraries.
Future<Set<String>> _loadVmLibraries(
  _ModuleOptions options,
  KernelModuleCache? cache,
  Map<String, Uint8List>? inputDigests,
) async {
  if (cache != null && options.extraLibraries.isEmpty) {
    return cache.vmLibrariesOf(
      options.librariesJson!,
      inputDigests,
      platform: options.librariesPlatform,
    );
  }
  final librariesMap = cache != null
      ? await cache.librariesJsonOf(options.librariesJson!, inputDigests)
      : jsonDecode(await File(options.librariesJson!).readAsString())
            as Map<String, dynamic>;
  return vmLibraries(
    librariesMap,
    platform: options.librariesPlatform,
    extraLibraries: options.extraLibraries,
  );
}

/// The declared keys and root paths of the entry and input sources.
({Set<String> keys, Set<String> rootPaths}) _declareInputs(
  List<String> raws,
  Map<String, _PackageRoot> roots,
  List<String> multiRoots,
  String multiRootPrefix,
) {
  final declaredKeys = <String>{};
  final declaredRootPaths = <String>{};
  for (final raw in raws) {
    final key = _keyOfUri(raw, roots, multiRootPrefix);
    if (key != null) declaredKeys.add(key);
    for (final spelling in _inputSpellings(raw, multiRoots)) {
      declaredKeys.add(spelling);
    }
    if (!raw.contains(':') || isWindowsDrivePath(raw)) {
      declaredRootPaths.add(raw);
      final norm = _normalize(raw);
      if (norm.isNotEmpty) declaredRootPaths.add(norm);
      final normFile = normalizePath(raw);
      if (normFile.isNotEmpty) declaredRootPaths.add(normFile);
    }
  }
  return (keys: declaredKeys, rootPaths: declaredRootPaths);
}

/// The parsed options and loaded inputs of one `compileModule` run.
class _ModuleBuild {
  _ModuleBuild({
    required this.options,
    required this.compiler,
    required this.log,
    required this.inputs,
    required this.workerInputPaths,
    required this.inputDigests,
    required this.roots,
    required this.closure,
    required this.vm,
    required this.graph,
    required this.stagedSources,
    required this.own,
    required this.inherited,
    required this.files,
    required this.reporter,
    required this.cache,
    required this.createLink,
  });

  final _ModuleOptions options;
  final ModuleCompiler compiler;
  final StringBuffer log;
  final List<Uint8List> inputs;
  final Set<String>? workerInputPaths;
  final Map<String, Uint8List>? inputDigests;
  final Map<String, _PackageRoot> roots;
  final Map<String, String> closure;
  final Set<String> vm;
  final Map<String, _Node> graph;
  final Map<String, String> stagedSources;

  /// The own sources this module compiles: `--source` URIs no closure module
  /// defines.
  final List<String> own;

  /// The closure's excluded sources no closure module defines: this module
  /// neither compiles nor excludes them.
  final Map<String, String> inherited;
  final _Files files;
  final _UsedInputsReporter reporter;
  final KernelModuleCache? cache;
  final void Function(String linkPath, String target)? createLink;

  /// Loads the packages, closure, VM libraries, indexes and file view,
  /// returning null when a module index cannot be read.
  static Future<_ModuleBuild?> load(
    _ModuleOptions options,
    ModuleCompiler compiler,
    StringBuffer log,
    List<Uint8List> inputs,
    Set<String>? workerInputPaths,
    Map<String, Uint8List>? inputDigests, {
    KernelModuleCache? cache,
    void Function(String linkPath, String target)? createLink,
  }) async {
    final roots = await _packageRoots(
      options.packagesFile!,
      options.multiRootPrefix,
    );
    final closure = await _readExcluded(
      options.closureExcluded,
      roots,
      options.multiRootPrefix,
      cache: cache,
      inputDigests: inputDigests,
    );
    final vm = await _loadVmLibraries(options, cache, inputDigests);
    // Every kernel the closure indexes, by the key of each library it defines.
    final graph = <String, _Node>{};
    final stagedSources = <String, String>{};
    for (final dir in options.inputKmods) {
      if (!await _readIndex(
        dir,
        graph,
        log,
        stagedSources: stagedSources,
        cache: cache,
        inputDigests: inputDigests,
      )) {
        return null;
      }
    }
    final declared = _declareInputs(
      [...options.sources, ...options.inputSources],
      roots,
      options.multiRoots,
      options.multiRootPrefix,
    );
    return _assemble(
      options,
      compiler,
      log,
      inputs,
      workerInputPaths,
      inputDigests,
      roots,
      closure,
      vm,
      graph,
      stagedSources,
      declared,
      cache: cache,
      createLink: createLink,
    );
  }

  /// Assembles the file view, outputs and plan inputs from the loaded parts.
  static Future<_ModuleBuild> _assemble(
    _ModuleOptions options,
    ModuleCompiler compiler,
    StringBuffer log,
    List<Uint8List> inputs,
    Set<String>? workerInputPaths,
    Map<String, Uint8List>? inputDigests,
    Map<String, _PackageRoot> roots,
    Map<String, String> closure,
    Set<String> vm,
    Map<String, _Node> graph,
    Map<String, String> stagedSources,
    ({Set<String> keys, Set<String> rootPaths}) declared, {
    KernelModuleCache? cache,
    void Function(String linkPath, String target)? createLink,
  }) async {
    final files = _Files(
      options.multiRoots.isEmpty ? const ['.'] : options.multiRoots,
      declaredKeys: declared.keys,
      declaredRootPaths: declared.rootPaths,
      stagedRoots: stagedSources,
      workerInputPaths: workerInputPaths,
    );
    await Directory(options.output!).create(recursive: true);
    if (options.outputOutline != null) {
      await Directory(options.outputOutline!).create(recursive: true);
    }
    // An excluded file in the closure counts only while no module of the
    // closure defines it: then the module that defines it is the copy the
    // executable links.
    final inherited = <String, String>{
      for (final entry in closure.entries)
        if (!graph.containsKey(entry.key)) entry.key: entry.value,
    };
    final own = <String>[
      for (final uri in options.sources)
        if (!_definedBy(uri, graph, roots, options.multiRootPrefix)) uri,
    ];
    // Records each invocation's `--used-inputs` report for the unused-inputs
    // list. `compiler` itself still answers the `_Persistent` checks below.
    final reporter = _UsedInputsReporter(compiler, options.output!);
    return _ModuleBuild(
      options: options,
      compiler: compiler,
      log: log,
      inputs: inputs,
      workerInputPaths: workerInputPaths,
      inputDigests: inputDigests,
      roots: roots,
      closure: closure,
      vm: vm,
      graph: graph,
      stagedSources: stagedSources,
      own: own,
      inherited: inherited,
      files: files,
      reporter: reporter,
      cache: cache,
      createLink: createLink,
    );
  }

  /// Stages the isolated `--multi-root` holding exactly the declared origins.
  Future<_IsolatedRoot> _stageIsolated() => _stageIsolatedMultiRoot(
    options.output!,
    files,
    inputDigests,
    includeInputDigests: inputs.isNotEmpty || compiler is _Persistent,
    createLink: createLink,
  );

  /// Staged-source roots for every declared key the base roots do not hold, in
  /// first-seen order: the front end resolves those keys through the pinned
  /// dependency copies, ahead of any workspace shadow.
  List<String> _extraStagedRoots() {
    final extraMultiRoots = <String>[];
    final seenStagedRoots = <String>{};
    for (final key in files.declaredKeys) {
      if (!files.isDeclaredInRoots(key)) {
        final stagedRoot = stagedSources[key];
        if (stagedRoot != null && seenStagedRoots.add(stagedRoot)) {
          extraMultiRoots.add(stagedRoot);
        }
      }
    }
    return extraMultiRoots;
  }

  /// Digests for staged keys the worker inputs do not already digest.
  Future<List<Uint8List>> _stagedInputsFor(Iterable<String> keys) async {
    final stagedInputs = <Uint8List>[];
    for (final key in keys) {
      if (!files.isDeclaredInRoots(key)) {
        final stagedRoot = stagedSources[key];
        if (stagedRoot != null && inputs.isNotEmpty) {
          final stagedPath = '$stagedRoot/$key';
          if (_lookupDigest(stagedPath, inputDigests) == null) {
            stagedInputs.add(
              _encodeInput(
                stagedPath,
                sha256Of(await File(stagedPath).readAsBytes()),
              ),
            );
          }
        }
      }
    }
    return stagedInputs;
  }

  /// Compiles the entry module from source, verifying and staging as needed.
  Future<int> runEntry() async {
    final entry = await _entrySources(
      options.sources,
      inherited,
      graph,
      roots,
      files,
      vm,
      options.multiRootPrefix,
    );
    final blocked = _checkEntry(entry);
    if (blocked != null) return blocked;
    final extraMultiRoots = _extraStagedRoots();
    final stagedInputs = await _stagedInputsFor(entry.keys);
    _IsolatedRoot? isolated;
    try {
      if (await _needsIsolatedMultiRoot(
        options.multiRoots,
        extraMultiRoots,
        entry.keys,
        files,
        vm,
      )) {
        isolated = await _stageIsolated();
      }
      final result = await _compileAndVerify(
        (current) =>
            _compileEntry(current, extraMultiRoots, entry, stagedInputs),
        _stageIsolated,
        isolated,
        _VerifyReads(
          dillPath: '${options.output!}/$_entryDillName',
          files: files,
          graph: graph,
          multiRoots: options.multiRoots,
          multiRootPrefix: options.multiRootPrefix,
          log: log,
          ownUris: entry.uris.toSet(),
          roots: roots,
        ),
      );
      isolated = result.isolated;
      if (result.refused) {
        log.write(result.outcome.output);
        return 1;
      }
      if (result.outcome.exitCode != 0) {
        log.write(result.outcome.output);
        return 1;
      }
      await _finishEntry(entry);
    } finally {
      await _cleanIsolated(isolated);
    }
    return 0;
  }

  /// Reports the entry walk's failures, returning the exit code, or null.
  int? _checkEntry(_EntrySources entry) {
    if (entry.disallowed.isNotEmpty) {
      for (final error in entry.disallowed) {
        log.writeln(error);
      }
      return 1;
    }
    if (entry.undeclared.isNotEmpty) {
      for (final missing in entry.undeclared) {
        log.writeln(
          'kernel_module: cannot compile $missing: '
          'source is not a declared input.',
        );
      }
      return 1;
    }
    return null;
  }

  /// Compiles the entry sources once, through the isolated root when staged.
  Future<ModuleOutcome> _compileEntry(
    _IsolatedRoot? isolated,
    List<String> extraMultiRoots,
    _EntrySources entry,
    List<Uint8List> stagedInputs,
  ) async {
    final staged = isolated;
    final entryBase = staged != null
        ? _baseWithSingleMultiRoot(options.base, staged.rootDir)
        : _baseWithOrderedMultiRoots(
            options.base,
            options.multiRoots,
            entry.keys,
            files,
          );
    // The compiler reads each declared file through the isolated root, so
    // its origin inputs are withheld as duplicates.
    final callInputs = staged != null
        ? (staged.inputs.isEmpty
              ? inputs
              : [...staged.inputs, ..._uncoveredInputs(inputs, staged.covered)])
        : (stagedInputs.isEmpty ? inputs : [...inputs, ...stagedInputs]);
    return reporter.run(
      kernelWorkerArgs([
        // Staged-source roots come first so the pinned dependency copies
        // win over any workspace shadow, exactly as the probe validates.
        if (staged == null)
          for (final root in extraMultiRoots) ...[_multiRootFlag, root],
        ...entryBase,
        for (final d in neededDills(entry.imports, graph)) ...[
          '--input-summary',
          d,
        ],
        for (final source in entry.uris) ...['--source', source],
        '--output',
        '${options.output!}/$_entryDillName',
      ]),
      callInputs,
    );
  }

  /// Writes the entry index, outline, sidecar and unused-inputs list.
  Future<void> _finishEntry(_EntrySources entry) async {
    final output = options.output!;
    final entrySccs = [
      _Scc(
        dill: _entryDillName,
        keys: const [],
        uris: const [],
        imports: entry.imports,
      ),
    ];
    await _writeIndex(output, entrySccs);
    if (options.outputOutline != null) {
      final fullFile = File('$output/$_entryDillName');
      if (await fullFile.exists()) {
        final rawBytes = await fullFile.readAsBytes();
        final outlineBytes = stripDillToOutline(rawBytes);
        await File('${options.outputOutline}/$_entryDillName')
            .writeAsBytes(outlineBytes);
      }
      await _writeIndex(options.outputOutline!, entrySccs);
    }
    await File(options.excludedPath!).writeAsString('');
    if (options.unusedInputsPath != null) {
      await _writeUnusedInputsList(
        unusedInputsPath: options.unusedInputsPath!,
        reports: reporter.records,
        inputKmods: options.inputKmods,
        graph: graph,
        inherited: inherited,
        stagedSources: stagedSources,
        ownKeys: {
          for (final uri in options.sources)
            ?_keyOfUri(uri, roots, options.multiRootPrefix),
        },
        // The entry walk has no removal decisions about dependency files: a
        // source it compiled is visited, and looking up a `part of` name
        // lists nothing at all.
        consultedTargets: const {},
        output: output,
        outputOutline: options.outputOutline,
        entryKeys: entry.keys.toSet(),
        lookedUpLibraryNames: entry.lookedUpLibraryNames,
        inputSources: options.inputSources,
        ownSourceFiles: options.ownSourceFiles.toSet(),
        multiRoots: options.multiRoots,
        entryDill: '$output/$_entryDillName',
        outputDills: const [],
        declaredKeys: files.declaredKeys,
        multiRootPrefix: options.multiRootPrefix,
      );
    }
  }

  /// Plans, compiles and links the module's own sources component by component.
  Future<int> runLibrary() async {
    final planned = await _planLibrary();
    final plannedExit = planned.exit;
    if (plannedExit != null) return plannedExit;
    final keys = planned.keys;
    final plan = planned.plan;
    var remaining = [
      for (final uri in own)
        if (!plan.isExcluded(keys[uri])) uri,
    ];
    final extraMultiRoots = _extraStagedRoots();
    var retried = false;
    _IsolatedRoot? isolated;
    var sccs = <_Scc>[];
    try {
      while (true) {
        sccs = _componentsOf(remaining, keys, plan);
        // The kernels this attempt has written, by key. A later component
        // links to them.
        final local = Map<String, _Node>.of(graph);
        ModuleOutcome? failure;
        var failedUris = const <String>[];
        for (final scc in sccs) {
          final step = await _compileScc(scc, local, extraMultiRoots, isolated);
          isolated = step.isolated;
          if (step.stop) return 1;
          if (step.failure != null) {
            failure = step.failure;
            failedUris = scc.uris;
            break;
          }
        }
        if (failure == null) break;
        // The one retry: drop the own sources that failed, and their
        // importers. The components are then formed again from what remains.
        final verdict = _attribute(
          failure.output,
          failedUris,
          roots,
          options.multiRootPrefix,
        );
        if (retried ||
            verdict.unattributed ||
            verdict.outside ||
            verdict.failing.isEmpty) {
          log.write(failure.output);
          return 1;
        }
        retried = true;
        plan.exclude({
          for (final entry in verdict.failing.entries)
            entry.key: 'compile error: ${entry.value}',
        });
        remaining = [
          for (final uri in remaining)
            if (!plan.isExcluded(keys[uri])) uri,
        ];
      }
    } finally {
      await _cleanIsolated(isolated);
    }
    await _finishLibrary(sccs, keys, plan, remaining);
    return 0;
  }

  /// Plans the own sources' imports, adopting part peers. Returns the exit
  /// code when an own source is undeclared or a directive is disallowed.
  Future<({Map<String, String> keys, _Plan plan, int? exit})>
  _planLibrary() async {
    final keys = <String, String>{};
    final plan = _Plan();
    for (final uri in own) {
      final key = _keyOfUri(uri, roots, options.multiRootPrefix);
      if (key == null) continue;
      if (!files.isDeclared(key)) {
        log.writeln(
          'kernel_module: cannot compile $uri ($key): '
          'source is not a declared input.',
        );
        return (keys: keys, plan: plan, exit: 1);
      }
      keys[uri] = key;
      plan.addOwn(key, uri);
    }
    await _adoptDeclaredPartPeers(
      own,
      keys,
      plan,
      inherited,
      graph,
      roots,
      files,
      vm,
      options.multiRootPrefix,
    );
    final disallowed = await _planImports(
      plan,
      keys,
      inherited,
      graph,
      roots,
      files,
      vm,
      log,
      options.multiRootPrefix,
    );
    if (disallowed.isNotEmpty) {
      for (final error in disallowed) {
        log.writeln(error);
      }
      return (keys: keys, plan: plan, exit: 1);
    }
    return (keys: keys, plan: plan, exit: null);
  }

  /// Compiles one component and records its kernel node. Returns whether the
  /// build must stop, the outcome to attribute when the compile failed, and
  /// the isolated root (staged when an unstaged success proved unverified).
  Future<({bool stop, ModuleOutcome? failure, _IsolatedRoot? isolated})>
  _compileScc(
    _Scc scc,
    Map<String, _Node> local,
    List<String> extraMultiRoots,
    _IsolatedRoot? isolated,
  ) async {
    final stagedInputs = await _stagedInputsFor(scc.keys);
    var current = isolated;
    if (current == null &&
        await _needsIsolatedMultiRoot(
          options.multiRoots,
          extraMultiRoots,
          scc.keys,
          files,
          vm,
        )) {
      // The front end sees a single `--multi-root` holding symlinks to
      // exactly the declared origins, so untracked workspace files and
      // stale generated outputs can never shadow a declared source, and
      // references to undeclared files fail instead of reading the
      // workspace.
      current = await _stageIsolated();
    }
    final dillPath = '${options.output!}/${scc.dill}';
    final result = await _compileAndVerify(
      (staged) => _compileSccOnce(
        scc,
        local,
        staged,
        extraMultiRoots,
        stagedInputs,
        dillPath,
      ),
      _stageIsolated,
      current,
      _VerifyReads(
        dillPath: dillPath,
        files: files,
        graph: local,
        multiRoots: options.multiRoots,
        multiRootPrefix: options.multiRootPrefix,
        log: log,
        ownUris: scc.uris.toSet(),
        roots: roots,
      ),
    );
    if (result.refused) {
      // The isolated restage still read outside the declared inputs: its
      // result is refused, never accepted.
      log.write(result.outcome.output);
      return (stop: true, failure: null, isolated: result.isolated);
    }
    final outcome = result.outcome;
    if (outcome.exitCode != 0) {
      return (stop: false, failure: outcome, isolated: result.isolated);
    }
    await _recordSccNode(scc, local, dillPath);
    return (stop: false, failure: null, isolated: result.isolated);
  }

  /// Compiles one component once, through the isolated root when staged.
  Future<ModuleOutcome> _compileSccOnce(
    _Scc scc,
    Map<String, _Node> local,
    _IsolatedRoot? isolated,
    List<String> extraMultiRoots,
    List<Uint8List> stagedInputs,
    String dillPath,
  ) async {
    final staged = isolated;
    final summaryNodes = _neededNodes(scc.imports, local);
    final summaryInputs = <Uint8List>[];
    if (inputs.isNotEmpty || compiler is _Persistent) {
      for (final node in summaryNodes) {
        final encoded = node.encodedInput;
        if (encoded != null) {
          summaryInputs.add(encoded);
        }
      }
    }
    final sccBase = staged != null
        ? _baseWithSingleMultiRoot(options.base, staged.rootDir)
        : _baseWithOrderedMultiRoots(
            options.base,
            options.multiRoots,
            scc.keys,
            files,
          );
    final extraInputs = [
      if (staged != null) ...staged.inputs else ...stagedInputs,
      ...summaryInputs,
      if (staged != null) ..._uncoveredInputs(inputs, staged.covered),
    ];
    return reporter.run(
      kernelWorkerArgs([
        // Staged-source roots come first so the pinned dependency copies
        // win over any workspace shadow, exactly as the probe validates.
        if (staged == null)
          for (final root in extraMultiRoots) ...[_multiRootFlag, root],
        ...sccBase,
        for (final node in summaryNodes) ...['--input-summary', node.dill],
        for (final uri in scc.uris) ...['--source', uri],
        '--output',
        dillPath,
      ]),
      staged != null
          ? (extraInputs.isEmpty ? inputs : extraInputs)
          : (extraInputs.isEmpty ? inputs : [...inputs, ...extraInputs]),
    );
  }

  /// Strips a written component and records its kernel node for linking.
  Future<void> _recordSccNode(
    _Scc scc,
    Map<String, _Node> local,
    String dillPath,
  ) async {
    var nodeDill = dillPath;
    Uint8List? nodeDillBytes;
    final dillFile = File(dillPath);
    if (await dillFile.exists()) {
      final rawBytes = await dillFile.readAsBytes();
      if (options.outputOutline != null) {
        final outlineBytes = stripDillToOutline(rawBytes);
        nodeDill = '${options.outputOutline}/${scc.dill}';
        await File(nodeDill).writeAsBytes(outlineBytes);
        nodeDillBytes = outlineBytes;
        await dillFile.writeAsBytes(_stripSourceCodeFromDill(rawBytes));
      } else {
        final strippedBytes = _stripSourceCodeFromDill(rawBytes);
        await dillFile.writeAsBytes(strippedBytes);
        nodeDillBytes = strippedBytes;
      }
    }
    final node = _Node(nodeDill, scc.imports, dillBytes: nodeDillBytes);
    for (final key in scc.keys) {
      local[key] = node;
    }
  }

  /// Writes the indexes, the excluded sidecar and the unused-inputs list.
  Future<void> _finishLibrary(
    List<_Scc> sccs,
    Map<String, String> keys,
    _Plan plan,
    List<String> remaining,
  ) async {
    await _writeLibraryIndexes(sccs, own, keys, plan);
    await _writeExcludedSidecar(keys, plan, remaining);
    if (options.unusedInputsPath != null) {
      // A library lists only the module directories no invocation used and
      // whose files no plan decision consulted. Every own source counts as
      // referencing, including one a shadowing dependency dropped from the
      // compile: the module links that dependency's kernel for it. Every
      // dependency key a removal decision read counts too: an exclusion
      // target, an adopted part peer, a missing closure key. The evidence veto
      // reads what the written kernels embedded, so an adopted part peer keeps
      // the module that staged it even when no kernel was written.
      await _writeUnusedInputsList(
        unusedInputsPath: options.unusedInputsPath!,
        reports: reporter.records,
        inputKmods: options.inputKmods,
        graph: graph,
        inherited: inherited,
        stagedSources: stagedSources,
        ownKeys: {
          for (final uri in options.sources)
            ?_keyOfUri(uri, roots, options.multiRootPrefix),
        },
        consultedTargets: plan.consultedTargets,
        output: options.output!,
        outputOutline: options.outputOutline,
        entryKeys: null,
        lookedUpLibraryNames: false,
        inputSources: const [],
        ownSourceFiles: const {},
        multiRoots: options.multiRoots,
        entryDill: null,
        outputDills: [for (final scc in sccs) '${options.output!}/${scc.dill}'],
        declaredKeys: files.declaredKeys,
        multiRootPrefix: options.multiRootPrefix,
      );
    }
  }

  /// Writes the component index, staging excluded sources beside outlines.
  Future<void> _writeLibraryIndexes(
    List<_Scc> sccs,
    List<String> own,
    Map<String, String> keys,
    _Plan plan,
  ) async {
    final output = options.output!;
    final outputOutline = options.outputOutline;
    await _writeIndex(output, sccs);
    if (outputOutline == null) return;
    final excludedKeys = <String>[];
    for (final uri in own) {
      final key = keys[uri];
      if (key == null || !plan.isExcluded(key)) continue;
      final text = await files.read(key);
      if (text == null) continue;
      final staged = File('$outputOutline/sources/$key');
      await staged.parent.create(recursive: true);
      await staged.writeAsString(text);
      excludedKeys.add(key);
    }
    excludedKeys.sort();
    await _writeIndex(outputOutline, sccs, excluded: excludedKeys);
  }

  /// Writes the excluded-sources sidecar: a declared output even when nothing
  /// is excluded. Its `#` line is a count for the build log, and each excluded
  /// source is listed under its `package:` URI and its multi-root URI, with
  /// the reason.
  Future<void> _writeExcludedSidecar(
    Map<String, String> keys,
    _Plan plan,
    List<String> remaining,
  ) async {
    final lines = StringBuffer()
      ..writeln(
        '# ${remaining.length} of ${own.length} sources compile; the others '
        'are excluded for the VM.',
      );
    for (final uri in own) {
      final key = keys[uri];
      final reason = plan.reasonOf(key);
      if (key == null || reason == null) continue;
      lines.writeln('$uri\t$reason');
      if (!uri.startsWith(options.multiRootPrefix)) {
        lines.writeln('${options.multiRootPrefix}$key\t$reason');
      }
    }
    await File(options.excludedPath!).writeAsString(lines.toString());
  }
}

/// One kernel a module writes: the sources it compiles, and the keys it imports.
class _Scc {
  _Scc({
    required this.dill,
    required this.keys,
    required this.uris,
    required this.imports,
  });

  /// The file name within the module's directory.
  final String dill;

  /// The keys of the libraries (and parts) this kernel defines, sorted.
  final List<String> keys;

  /// The URIs the kernel compiles each of `keys` under.
  final List<String> uris;

  /// The keys this kernel imports or exports from outside itself, sorted.
  final List<String> imports;
}

/// A kernel an index names: its file, and the keys it imports.
class _Node {
  _Node(this.dill, this.imports, {Uint8List? dillBytes})
    : _dillBytes = dillBytes;

  final String dill;
  final List<String> imports;
  Uint8List? _dillBytes;
  Uint8List? _encodedInput;

  /// Encoded protobuf `Input` message for an intra-module SCC kernel written
  /// during this compile, computed lazily in memory without re-reading disk.
  Uint8List? get encodedInput {
    final cached = _encodedInput;
    if (cached != null) return cached;
    final bytes = _dillBytes;
    if (bytes == null) return null;
    _dillBytes = null;
    return _encodedInput = _encodeInput(dill, sha256Of(bytes));
  }
}

class _IndexedScc {
  const _IndexedScc({
    required this.dill,
    required this.defines,
    required this.imports,
  });

  final String dill;
  final List<String> defines;
  final List<String> imports;
}

class _ParsedIndex {
  const _ParsedIndex({required this.sccs, required this.excluded});

  final List<_IndexedScc> sccs;
  final List<String> excluded;
}

class _ModuleCacheEntry<T> {
  _ModuleCacheEntry({
    required this.value,
    required this.inputDigest,
    required this.contentSha256,
    required this.byteSize,
    required this.tick,
  });

  final T value;
  final Uint8List? inputDigest;
  final Uint8List? contentSha256;
  final int byteSize;
  int tick;
  Map<String, Set<String>>? vmByPlatform;
}

bool _isNormalizedRelative(String path) {
  final len = path.length;
  if (len == 0) return false;
  if (isWindowsDrivePath(path)) return false;
  if (path.codeUnitAt(0) == 0x2f ||
      path.codeUnitAt(0) == 0x5c ||
      path.codeUnitAt(len - 1) == 0x2f ||
      path.codeUnitAt(len - 1) == 0x5c) {
    return false;
  }
  var segStart = 0;
  for (var i = 0; i <= len; i++) {
    if (i < len && path.codeUnitAt(i) == 0x5c) return false;
    if (i == len || path.codeUnitAt(i) == 0x2f) {
      final segLen = i - segStart;
      if (segLen == 0) return false;
      if (segLen == 1 && path.codeUnitAt(segStart) == 0x2e) return false;
      if (segLen == 2 &&
          path.codeUnitAt(segStart) == 0x2e &&
          path.codeUnitAt(segStart + 1) == 0x2e) {
        return false;
      }
      segStart = i + 1;
    }
  }
  return true;
}

Uint8List? _lookupDigest(String path, Map<String, Uint8List>? inputDigests) {
  if (inputDigests == null) return null;
  final direct = _nonEmptyDigest(inputDigests[path]);
  if (direct != null) return direct;
  final alternate = _lookupAlternateSpelling(path, inputDigests);
  if (alternate != null) return alternate;
  if (_isNormalizedRelative(path)) {
    return _nonEmptyDigest(inputDigests['./$path']);
  }
  final normFile = normalizePath(path);
  if (normFile != path) {
    final hit = _nonEmptyDigest(inputDigests[normFile]);
    if (hit != null) return hit;
  }
  return _lookupNormalizedRelative(path, inputDigests);
}

/// [digest] when it names file bytes, else null.
Uint8List? _nonEmptyDigest(Uint8List? digest) =>
    digest != null && digest.isNotEmpty ? digest : null;

// Requests and staged keys may spell the same file as a `file:///` URI or
// as a filesystem path (Windows drive-letter paths become `file:///` URIs
// for `kernel_worker`). Try the alternate spelling before normalization so
// a cache keyed on one spelling still hits for the other.
Uint8List? _lookupAlternateSpelling(
  String path,
  Map<String, Uint8List> inputDigests,
) {
  if (path.startsWith('file://')) {
    final filePath = _filePathOf(path);
    if (filePath != path) return _lookupDigest(filePath, inputDigests);
    return null;
  }
  final uri = kernelWorkerUri(path);
  if (uri != path) return _nonEmptyDigest(inputDigests[uri]);
  return null;
}

/// The digest stored under the `./`-less or `./`-prefixed relative
/// normalization of [path], or null.
Uint8List? _lookupNormalizedRelative(
  String path,
  Map<String, Uint8List> inputDigests,
) {
  final relNorm = _normalize(path);
  if (relNorm.isEmpty) return null;
  final relHit = _nonEmptyDigest(inputDigests[relNorm]);
  if (relHit != null) return relHit;
  if (relNorm.startsWith('/')) return null;
  return _nonEmptyDigest(inputDigests['./$relNorm']);
}

/// Byte-bounded cache of parsed `index.json` manifests, `.vm_excluded.txt`
/// sidecars, and SDK `libraries.json` across persistent-worker requests.
///
/// Validates entries against the file's digest in `WorkRequest.inputs` (which
/// Bazel 9.3.0 populates for all constituent files of `.kmod` / `.koutline`
/// tree artifacts), falling back to reading from disk and checking `sha256Of`
/// when no digest is present in `WorkRequest.inputs`.
class KernelModuleCache {
  KernelModuleCache({this.maxCacheBytes = defaultMaxCacheBytes});

  static const int defaultMaxCacheBytes = 32 * 1024 * 1024;

  final int maxCacheBytes;
  final _indexCache = <String, _ModuleCacheEntry<_ParsedIndex>>{};
  final _librariesCache = <String, _ModuleCacheEntry<Map<String, dynamic>>>{};
  final _excludedCache = <String, _ModuleCacheEntry<List<String>>>{};
  int _indexBytesTotal = 0;
  int _librariesBytesTotal = 0;
  int _excludedBytesTotal = 0;
  int _clock = 0;

  int get indexBytes => _indexBytesTotal;
  int get librariesBytes => _librariesBytesTotal;
  int get excludedBytes => _excludedBytesTotal;
  int get totalBytes =>
      _indexBytesTotal + _librariesBytesTotal + _excludedBytesTotal;
  int get indexEntryCount => _indexCache.length;
  int get librariesEntryCount => _librariesCache.length;
  int get excludedEntryCount => _excludedCache.length;

  static Uint8List _unpin(Uint8List bytes) =>
      bytes.buffer.lengthInBytes == bytes.lengthInBytes
      ? bytes
      : Uint8List.fromList(bytes);

  static bool _sameBytes(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  void _evictForBudget(int incomingBytes) {
    while (totalBytes + incomingBytes > maxCacheBytes) {
      String? oldestIndexKey;
      int? oldestIndexTick;
      if (_indexCache.isNotEmpty) {
        final first = _indexCache.entries.first;
        oldestIndexKey = first.key;
        oldestIndexTick = first.value.tick;
      }

      String? oldestLibKey;
      int? oldestLibTick;
      if (_librariesCache.isNotEmpty) {
        final first = _librariesCache.entries.first;
        oldestLibKey = first.key;
        oldestLibTick = first.value.tick;
      }

      String? oldestExclKey;
      int? oldestExclTick;
      if (_excludedCache.isNotEmpty) {
        final first = _excludedCache.entries.first;
        oldestExclKey = first.key;
        oldestExclTick = first.value.tick;
      }

      if (oldestIndexTick == null &&
          oldestLibTick == null &&
          oldestExclTick == null) {
        break;
      }

      var minTick = oldestIndexTick ?? oldestLibTick ?? oldestExclTick!;
      if (oldestLibTick != null && oldestLibTick < minTick) {
        minTick = oldestLibTick;
      }
      if (oldestExclTick != null && oldestExclTick < minTick) {
        minTick = oldestExclTick;
      }

      if (oldestIndexTick != null && oldestIndexTick == minTick) {
        final removed = _indexCache.remove(oldestIndexKey!)!;
        _indexBytesTotal -= removed.byteSize;
      } else if (oldestExclTick != null && oldestExclTick == minTick) {
        final removed = _excludedCache.remove(oldestExclKey!)!;
        _excludedBytesTotal -= removed.byteSize;
      } else if (oldestLibTick != null) {
        final removed = _librariesCache.remove(oldestLibKey!)!;
        _librariesBytesTotal -= removed.byteSize;
      }
    }
  }

  Future<_ModuleCacheEntry<Map<String, dynamic>>> _librariesEntryOf(
    String path,
    Map<String, Uint8List>? inputDigests,
  ) async {
    final key = normalizePath(path);
    final digest = _lookupDigest(path, inputDigests);
    final hasDigest = digest != null && digest.isNotEmpty;
    final cached = _librariesCache.remove(key);
    if (cached != null) {
      if (hasDigest &&
          cached.inputDigest != null &&
          _sameBytes(digest, cached.inputDigest!)) {
        cached.tick = ++_clock;
        _librariesCache[key] = cached;
        return cached;
      }
      _librariesBytesTotal -= cached.byteSize;
    }

    final bytes = await File(path).readAsBytes();
    final entryBytes = bytes.length;
    final contentSha256 = hasDigest ? null : sha256Of(bytes);
    if (!hasDigest &&
        cached != null &&
        cached.byteSize == entryBytes &&
        cached.contentSha256 != null &&
        _sameBytes(contentSha256!, cached.contentSha256!)) {
      if (entryBytes <= maxCacheBytes) {
        _evictForBudget(entryBytes);
        cached.tick = ++_clock;
        _librariesCache[key] = cached;
        _librariesBytesTotal += entryBytes;
      }
      return cached;
    }

    final parsed = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    final entry = _ModuleCacheEntry(
      value: parsed,
      inputDigest: hasDigest ? _unpin(digest) : null,
      contentSha256: contentSha256,
      byteSize: entryBytes,
      tick: ++_clock,
    );
    if (entryBytes <= maxCacheBytes) {
      _evictForBudget(entryBytes);
      _librariesCache[key] = entry;
      _librariesBytesTotal += entryBytes;
    }
    return entry;
  }

  Future<Map<String, dynamic>> librariesJsonOf(
    String path,
    Map<String, Uint8List>? inputDigests,
  ) async => (await _librariesEntryOf(path, inputDigests)).value;

  Future<Set<String>> vmLibrariesOf(
    String path,
    Map<String, Uint8List>? inputDigests, {
    required String platform,
  }) async {
    final entry = await _librariesEntryOf(path, inputDigests);
    final map = entry.vmByPlatform ??= <String, Set<String>>{};
    return map[platform] ??= vmLibraries(entry.value, platform: platform);
  }

  Future<List<String>> excludedLinesOf(
    String path,
    Map<String, Uint8List>? inputDigests,
  ) async {
    final key = normalizePath(path);
    final digest = _lookupDigest(path, inputDigests);
    final hasDigest = digest != null && digest.isNotEmpty;
    final cached = _excludedCache.remove(key);
    if (cached != null) {
      if (hasDigest &&
          cached.inputDigest != null &&
          _sameBytes(digest, cached.inputDigest!)) {
        cached.tick = ++_clock;
        _excludedCache[key] = cached;
        return cached.value;
      }
      _excludedBytesTotal -= cached.byteSize;
    }

    final bytes = await File(path).readAsBytes();
    final entryBytes = bytes.length;
    final contentSha256 = hasDigest ? null : sha256Of(bytes);
    if (!hasDigest &&
        cached != null &&
        cached.byteSize == entryBytes &&
        cached.contentSha256 != null &&
        _sameBytes(contentSha256!, cached.contentSha256!)) {
      if (entryBytes <= maxCacheBytes) {
        _evictForBudget(entryBytes);
        cached.tick = ++_clock;
        _excludedCache[key] = cached;
        _excludedBytesTotal += entryBytes;
      }
      return cached.value;
    }

    final text = utf8.decode(bytes);
    final uris = <String>[];
    for (final line in const LineSplitter().convert(text)) {
      if (line.isEmpty || line.codeUnitAt(0) == 0x23) continue;
      final tab = line.indexOf('\t');
      uris.add(tab < 0 ? line : line.substring(0, tab));
    }
    final stored = uris.isEmpty ? const <String>[] : uris;
    if (entryBytes <= maxCacheBytes) {
      _evictForBudget(entryBytes);
      _excludedCache[key] = _ModuleCacheEntry(
        value: stored,
        inputDigest: hasDigest ? _unpin(digest) : null,
        contentSha256: contentSha256,
        byteSize: entryBytes,
        tick: ++_clock,
      );
      _excludedBytesTotal += entryBytes;
    }
    return stored;
  }

  Future<_ParsedIndex?> _indexOf(
    String dir,
    Map<String, Uint8List>? inputDigests,
  ) async {
    final indexPath = '$dir/$_indexName';
    final key = normalizePath(indexPath);
    final digest = _lookupDigest(indexPath, inputDigests);
    final hasDigest = digest != null && digest.isNotEmpty;
    final cached = _indexCache.remove(key);
    if (cached != null) {
      if (hasDigest &&
          cached.inputDigest != null &&
          _sameBytes(digest, cached.inputDigest!)) {
        cached.tick = ++_clock;
        _indexCache[key] = cached;
        return cached.value;
      }
      _indexBytesTotal -= cached.byteSize;
    }

    final file = File(indexPath);
    if (!await file.exists()) return null;
    final bytes = await file.readAsBytes();
    final entryBytes = bytes.length;
    final contentSha256 = hasDigest ? null : sha256Of(bytes);
    if (!hasDigest &&
        cached != null &&
        cached.byteSize == entryBytes &&
        cached.contentSha256 != null &&
        _sameBytes(contentSha256!, cached.contentSha256!)) {
      if (entryBytes <= maxCacheBytes) {
        _evictForBudget(entryBytes);
        cached.tick = ++_clock;
        _indexCache[key] = cached;
        _indexBytesTotal += entryBytes;
      }
      return cached.value;
    }

    final json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    final sccs = [
      for (final scc in (json['sccs'] as List).cast<Map<String, dynamic>>())
        _IndexedScc(
          dill: scc['dill'] as String,
          defines: (scc['defines'] as List).cast<String>(),
          imports: (scc['imports'] as List).cast<String>(),
        ),
    ];
    final excluded = json['excluded'] is List
        ? (json['excluded'] as List).cast<String>()
        : const <String>[];
    final parsed = _ParsedIndex(sccs: sccs, excluded: excluded);
    if (entryBytes <= maxCacheBytes) {
      _evictForBudget(entryBytes);
      _indexCache[key] = _ModuleCacheEntry(
        value: parsed,
        inputDigest: hasDigest ? _unpin(digest) : null,
        contentSha256: contentSha256,
        byteSize: entryBytes,
        tick: ++_clock,
      );
      _indexBytesTotal += entryBytes;
    }
    return parsed;
  }
}

/// The components of the remaining own sources, dependencies first. Each is one
/// kernel, named by its position: `<n>.dill`. Libraries that import each other, and
/// the parts of a library, form one component.
List<_Scc> _componentsOf(
  List<String> remaining,
  Map<String, String> keys,
  _Plan plan,
) {
  final uriOf = <String, String>{};
  for (final uri in remaining) {
    uriOf.putIfAbsent(keys[uri] ?? 'uri:$uri', () => uri);
  }
  final nodes = uriOf.keys.toList()..sort();
  final members = uriOf.keys.toSet();
  Iterable<String> successors(String key) => plan
      .importsOf(key)
      .where((target) => target != key && members.contains(target));
  final components = stronglyConnected(nodes, successors);
  return [
    for (var i = 0; i < components.length; i++)
      _sccOf('$i.dill', components[i], uriOf, plan),
  ];
}

_Scc _sccOf(
  String dill,
  List<String> keys,
  Map<String, String> uriOf,
  _Plan plan,
) {
  final own = keys.toSet();
  final imports = <String>{
    for (final key in keys) ...plan.importsOf(key),
  }.where((target) => !own.contains(target)).toList()..sort();
  return _Scc(
    dill: dill,
    keys: keys,
    uris: [for (final key in keys) uriOf[key]!],
    imports: imports,
  );
}

/// The strongly connected components of a graph, each sorted, in an order where every
/// component follows the components it reaches. Tarjan's algorithm emits a component
/// once everything it reaches is emitted, which gives that order directly. Nodes and
/// successors are visited in sorted order, so the same graph always gives the same
/// components in the same order.
List<List<String>> stronglyConnected(
  List<String> nodes,
  Iterable<String> Function(String) successors,
) {
  final index = <String, int>{};
  final low = <String, int>{};
  final onStack = <String>{};
  final stack = <String>[];
  final out = <List<String>>[];
  void visit(String v) {
    index[v] = low[v] = index.length;
    stack.add(v);
    onStack.add(v);
    for (final w in successors(v)) {
      if (!index.containsKey(w)) {
        visit(w);
        final lowW = low[w]!;
        if (lowW < low[v]!) low[v] = lowW;
      } else if (onStack.contains(w)) {
        final indexW = index[w]!;
        if (indexW < low[v]!) low[v] = indexW;
      }
    }
    if (low[v] == index[v]) {
      final component = <String>[];
      String w;
      do {
        w = stack.removeLast();
        onStack.remove(w);
        component.add(w);
      } while (w != v);
      out.add(component..sort());
    }
  }

  for (final node in nodes) {
    if (!index.containsKey(node)) visit(node);
  }
  return out;
}

/// The kernels a dependency module needs to compile against: every kernel reached from
/// `roots` through the imports of the kernels they name. Sorted, so the arguments of
/// a compile do not change from one build to the next.
List<String> neededDills(Iterable<String> roots, Map<String, _Node> graph) => [
  for (final node in _neededNodes(roots, graph)) node.dill,
];

List<_Node> _neededNodes(Iterable<String> roots, Map<String, _Node> graph) {
  final byDill = <String, _Node>{};
  final visited = <String>{};
  final queue = Queue<String>.of(roots);
  while (queue.isNotEmpty) {
    final key = queue.removeFirst();
    if (!visited.add(key)) continue;
    final node = graph[key];
    if (node == null) continue;
    if (!byDill.containsKey(node.dill)) {
      byDill[node.dill] = node;
      queue.addAll(node.imports);
    }
  }
  final sortedDills = byDill.keys.toList()..sort();
  return [for (final dill in sortedDills) byDill[dill]!];
}

/// Adds the kernels that the module directory `dir` indexes to `graph`, by each key
/// they define. Returns false, after saying why, when the index is missing.
Future<bool> _readIndex(
  String dir,
  Map<String, _Node> graph,
  StringBuffer log, {
  Map<String, String>? stagedSources,
  KernelModuleCache? cache,
  Map<String, Uint8List>? inputDigests,
}) async {
  if (cache != null) {
    final parsed = await cache._indexOf(dir, inputDigests);
    if (parsed == null) {
      log.writeln('kernel_module: $dir has no $_indexName.');
      return false;
    }
    for (final scc in parsed.sccs) {
      final node = _Node('$dir/${scc.dill}', scc.imports);
      for (final key in scc.defines) {
        graph.putIfAbsent(key, () => node);
      }
    }
    if (stagedSources != null && parsed.excluded.isNotEmpty) {
      for (final key in parsed.excluded) {
        stagedSources.putIfAbsent(key, () => '$dir/sources');
      }
    }
    return true;
  }
  final file = File('$dir/$_indexName');
  if (!await file.exists()) {
    log.writeln('kernel_module: $dir has no $_indexName.');
    return false;
  }
  final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
  for (final scc in (json['sccs'] as List).cast<Map<String, dynamic>>()) {
    final node = _Node(
      '$dir/${scc['dill']}',
      (scc['imports'] as List).cast<String>(),
    );
    for (final key in (scc['defines'] as List).cast<String>()) {
      graph.putIfAbsent(key, () => node);
    }
  }
  if (stagedSources != null && json['excluded'] is List) {
    for (final key in (json['excluded'] as List).cast<String>()) {
      stagedSources.putIfAbsent(key, () => '$dir/sources');
    }
  }
  return true;
}

Future<void> _writeIndex(
  String dir,
  List<_Scc> sccs, {
  List<String> excluded = const [],
}) async {
  final json = const JsonEncoder.withIndent('  ').convert({
    'version': 1,
    'sccs': [
      for (final scc in sccs)
        {'dill': scc.dill, 'defines': scc.keys, 'imports': scc.imports},
    ],
    if (excluded.isNotEmpty) 'excluded': excluded,
  });
  await File('$dir/$_indexName').writeAsString('$json\n');
}

/// The import graph of a module's own sources, and which of them are excluded.
class _Plan {
  /// The URI each own source was given, by key.
  final Map<String, String> _uriOf = {};

  /// The own sources that import each own source, by key, in the order found.
  final Map<String, List<String>> _importers = {};

  /// The excluded own sources, by key, with the reason. In the order excluded.
  final Map<String, String> _excluded = {};

  /// What each source imports or exports, by key: own sources and dependencies alike.
  final Map<String, Set<String>> _imports = {};

  /// The dependency keys a plan decision consulted while removing a source
  /// from the compile: an exclusion's target (an inherited-excluded source, a
  /// non-own part or parent library, a missing closure key), or an adopted
  /// part peer. A module that stages or defines a key of one of these keys'
  /// packages is never listed as unused: renaming a file into such a name
  /// recompiles the dependency but would skip this module, keeping the stale
  /// decision.
  final Set<String> consultedTargets = {};

  /// Records that a removal decision consulted `target`.
  void addConsulted(String target) {
    consultedTargets.add(target);
  }

  void addOwn(String key, String uri) => _uriOf.putIfAbsent(key, () => uri);

  bool isOwn(String key) => _uriOf.containsKey(key);

  /// Records that `importer` imports or exports `imported`, an own source.
  void addImporter({required String imported, required String importer}) {
    final list = _importers[imported] ??= [];
    if (!list.contains(importer)) list.add(importer);
  }

  /// Records that `importer` imports or exports `target`, whether or not it is own.
  void addImport({required String importer, required String target}) {
    (_imports[importer] ??= {}).add(target);
  }

  /// The keys `key` imports or exports, sorted.
  List<String> importsOf(String key) =>
      (_imports[key] ?? const <String>{}).toList()..sort();

  bool isExcluded(String? key) => key != null && _excluded.containsKey(key);

  String? reasonOf(String? key) => key == null ? null : _excluded[key];

  /// Excludes each seed, then every own source that imports an excluded one.
  void exclude(Map<String, String> seeds) {
    final queue = Queue<String>();
    seeds.forEach((key, reason) {
      if (isOwn(key) && !_excluded.containsKey(key)) {
        _excluded[key] = reason;
        queue.add(key);
      }
    });
    while (queue.isNotEmpty) {
      final key = queue.removeFirst();
      for (final importer in _importers[key] ?? const <String>[]) {
        if (_excluded.containsKey(importer)) continue;
        _excluded[importer] = 'imports ${_uriOf[key]}, which is excluded';
        queue.add(importer);
      }
    }
  }
}

/// Adopts declared non-graph peer files (`--input-source` or staged `.koutline`
/// sources) that complete a `part` / `part of` library unit with this module's
/// own or inherited excluded sources.
Future<void> _adoptDeclaredPartPeers(
  List<String> own,
  Map<String, String> keys,
  _Plan plan,
  Map<String, String> inherited,
  Map<String, _Node> graph,
  Map<String, _PackageRoot> roots,
  _Files files,
  Set<String> vm,
  String multiRootPrefix,
) async {
  if (!await _usesPartDirectives(
    {...keys.values, ...inherited.keys},
    files,
    vm,
  )) {
    return;
  }

  final candidates = <String>{
    ...keys.values,
    for (final key in files.declaredKeys)
      if (!graph.containsKey(key)) key,
  };
  final peers = await _scanPeerCandidates(candidates, files, vm);
  final links = _linkPartDirectives(
    peers.scans,
    peers.libraryByName,
    roots,
    multiRootPrefix,
  );

  final resolvedPartsOf = <String, Set<String>>{
    for (final entry in links.partsOf.entries)
      entry.key: {for (final target in entry.value) ?target},
  };
  final sortedRoots = peers.scans.keys.toList()..sort();
  for (final root in sortedRoots) {
    if (links.hasPartOf.contains(root)) continue;
    final unit = _completeUnit(root, links, peers.scans, resolvedPartsOf);
    if (unit == null ||
        !unit.any((m) => plan.isOwn(m) || inherited.containsKey(m))) {
      continue;
    }
    _adoptUnit(unit, plan, inherited, own, keys, roots, multiRootPrefix);
  }
}

/// Whether any scanned source uses a `part` or `part of` directive.
Future<bool> _usesPartDirectives(
  Set<String> keys,
  _Files files,
  Set<String> vm,
) async {
  for (final key in keys) {
    final scan = await files.scan(key, vm);
    if (scan == null) continue;
    if (scan.partOfLibrary != null ||
        scan.refs.any((r) => r.isPart || r.isPartOf)) {
      return true;
    }
  }
  return false;
}

/// Scans the candidate peers, indexing libraries by their declared name.
Future<({Map<String, ScanResult> scans, Map<String, String> libraryByName})>
_scanPeerCandidates(
  Set<String> candidates,
  _Files files,
  Set<String> vm,
) async {
  final scans = <String, ScanResult>{};
  final libraryByName = <String, String>{};
  for (final key in candidates) {
    final scan = await files.scan(key, vm);
    if (scan == null) continue;
    scans[key] = scan;
    if (scan.libraryName != null) {
      libraryByName.putIfAbsent(scan.libraryName!, () => key);
    }
  }
  return (scans: scans, libraryByName: libraryByName);
}

/// The `part` targets, `part of` members, and member parents of scanned peers.
typedef _PartLinks = ({
  Map<String, List<String?>> partsOf,
  Set<String> hasPartOf,
  Map<String, String?> parentOf,
});

/// Resolves each peer's `part` and `part of` directives to graph keys.
_PartLinks _linkPartDirectives(
  Map<String, ScanResult> scans,
  Map<String, String> libraryByName,
  Map<String, _PackageRoot> roots,
  String multiRootPrefix,
) {
  final partsOf = <String, List<String?>>{};
  final hasPartOf = <String>{};
  final parentOf = <String, String?>{};
  scans.forEach((key, scan) {
    if (scan.partOfLibrary != null) {
      hasPartOf.add(key);
      parentOf[key] = libraryByName[scan.partOfLibrary!];
    }
    for (final ref in scan.refs) {
      if (ref.uri.startsWith('dart:')) continue;
      final target = _resolveUri(ref.uri, key, roots, multiRootPrefix);
      if (ref.isPart) {
        (partsOf[key] ??= []).add(target);
      } else if (ref.isPartOf) {
        hasPartOf.add(key);
        parentOf[key] = target;
      }
    }
  });
  return (partsOf: partsOf, hasPartOf: hasPartOf, parentOf: parentOf);
}

/// The complete `part` unit rooted at `root`, or null when a part is missing,
/// unscanned, or parented outside the unit.
List<String>? _completeUnit(
  String root,
  _PartLinks links,
  Map<String, ScanResult> scans,
  Map<String, Set<String>> resolvedPartsOf,
) {
  final directParts = links.partsOf[root];
  if (directParts == null || directParts.isEmpty) return null;
  final unit = <String>[root];
  final seen = <String>{root};
  final queue = Queue<String>()..add(root);
  while (queue.isNotEmpty) {
    final current = queue.removeFirst();
    for (final partKey in links.partsOf[current] ?? const <String?>[]) {
      if (partKey == null ||
          !scans.containsKey(partKey) ||
          !links.hasPartOf.contains(partKey)) {
        return null;
      }
      final parent = links.parentOf[partKey];
      if (parent == null ||
          !seen.contains(parent) ||
          !_reachesViaPart(parent, partKey, resolvedPartsOf)) {
        return null;
      }
      if (seen.add(partKey)) {
        unit.add(partKey);
        queue.add(partKey);
      }
    }
  }
  return unit;
}

/// Moves a complete unit's non-own members into this module's own sources.
void _adoptUnit(
  List<String> unit,
  _Plan plan,
  Map<String, String> inherited,
  List<String> own,
  Map<String, String> keys,
  Map<String, _PackageRoot> roots,
  String multiRootPrefix,
) {
  for (final member in unit) {
    if (plan.isOwn(member)) continue;
    // The adoption decision read this peer: renaming a file into its name
    // recompiles the dependency, so its provider is never listed as unused.
    plan.addConsulted(member);
    final uri = _packageUriOf(
      member,
      inherited[member] ?? '$multiRootPrefix$member',
      roots,
    );
    own.add(uri);
    keys[uri] = member;
    plan.addOwn(member, uri);
    inherited.remove(member);
  }
}

/// Whether `parent` reaches `partKey` through one or more `part` directives in
/// `declaredPartsOf`.
bool _reachesViaPart(
  String parent,
  String partKey,
  Map<String, Set<String>> declaredPartsOf,
) {
  final visited = <String>{parent};
  final queue = Queue<String>()..add(parent);
  while (queue.isNotEmpty) {
    final current = queue.removeFirst();
    final parts = declaredPartsOf[current];
    if (parts == null) continue;
    if (parts.contains(partKey)) return true;
    for (final next in parts) {
      if (visited.add(next)) queue.add(next);
    }
  }
  return false;
}

/// Records each own source's imports in `plan`, and excludes the sources a VM
/// cannot compile: those that import a `dart:` library the VM lacks, a `package:` that
/// the module's config does not name, a part or parent library that is not an own
/// source, or a file that `inherited` lists as excluded.
///
/// Returns a diagnostic for every directive URI that names no file the action
/// can read through its declared inputs: a `file:` URI in any spelling, any
/// other scheme but `dart:` and `package:`, or any URI with an empty path
/// segment (which the front end resolves differently than skipping it would).
/// The front end reads such a URI off the host, outside every multi-root, so
/// the module fails instead of compiling it. (A `part` or `part of` keeps its
/// old rule unless it is a `file:` URI or has an empty segment: excluding the
/// library already keeps an unknown-scheme part out of the compile, while a
/// `file:` part would still read the host.) Each diagnostic names the file,
/// the directive and the URI.
Future<List<String>> _planImports(
  _Plan plan,
  Map<String, String> keys,
  Map<String, String> inherited,
  Map<String, _Node> graph,
  Map<String, _PackageRoot> roots,
  _Files files,
  Set<String> vm,
  StringBuffer log,
  String multiRootPrefix,
) async {
  final disallowed = <String>[];
  final uriOfKey = <String, String>{
    for (final entry in keys.entries) entry.value: entry.key,
  };
  final scanned = await _scanImportDirectives(
    keys,
    files,
    vm,
    roots,
    multiRootPrefix,
    log,
  );
  final direct = <String, String>{};
  for (final entry in scanned.scans.entries) {
    final key = entry.key;
    final scan = entry.value;
    if (scan.partOfLibrary != null) {
      _planPartOfLibrary(
        key,
        scan,
        scanned.libraryKeyByName,
        scanned.declaredPartsOf,
        plan,
        direct,
      );
    }
    for (final ref in scan.refs) {
      if (_rejectMalformedRef(ref, key, uriOfKey, disallowed)) continue;
      if (_planSdkRef(ref, key, vm, direct)) continue;
      final target = _resolveUri(ref.uri, key, roots, multiRootPrefix);
      if (target == null) {
        _planUnresolvedRef(
          ref,
          key,
          uriOfKey,
          multiRootPrefix,
          plan,
          direct,
          disallowed,
        );
        continue;
      }
      if (ref.isPartOf) {
        _planPartOfRef(ref, key, target, scanned.declaredPartsOf, plan, direct);
        continue;
      }
      _planResolvedImport(ref, key, target, inherited, graph, plan, direct);
    }
  }
  plan.exclude(direct);
  return disallowed;
}

/// The scanned directives of a module's own sources.
typedef _ScannedImports = ({
  Map<String, ScanResult> scans,
  Map<String, String> libraryKeyByName,
  Map<String, Set<String>> declaredPartsOf,
});

/// Scans each own source's directives, indexing libraries by declared name and
/// recording each library's declared parts.
Future<_ScannedImports> _scanImportDirectives(
  Map<String, String> keys,
  _Files files,
  Set<String> vm,
  Map<String, _PackageRoot> roots,
  String multiRootPrefix,
  StringBuffer log,
) async {
  final scans = <String, ScanResult>{};
  final libraryKeyByName = <String, String>{};
  final declaredPartsOf = <String, Set<String>>{};
  for (final key in keys.values) {
    final scan = await files.scan(key, vm);
    if (scan == null) {
      // Not readable here, or not a directive prologue the scanner can follow. The
      // compiler decides, and a failure in it is attributed or fails the action.
      log.writeln('kernel_module: could not read the directives of $key.');
      continue;
    }
    scans[key] = scan;
    if (scan.libraryName != null) {
      libraryKeyByName.putIfAbsent(scan.libraryName!, () => key);
    }
    for (final ref in scan.refs) {
      if (!ref.isPart || ref.uri.startsWith('dart:')) continue;
      final target = _resolveUri(ref.uri, key, roots, multiRootPrefix);
      if (target != null) {
        (declaredPartsOf[key] ??= {}).add(target);
      }
    }
  }
  return (
    scans: scans,
    libraryKeyByName: libraryKeyByName,
    declaredPartsOf: declaredPartsOf,
  );
}

/// Plans a `part of <name>` directive: links a part to its own parent library,
/// or excludes a part whose library is not an input of this module.
void _planPartOfLibrary(
  String key,
  ScanResult scan,
  Map<String, String> libraryKeyByName,
  Map<String, Set<String>> declaredPartsOf,
  _Plan plan,
  Map<String, String> direct,
) {
  final libName = scan.partOfLibrary!;
  final parent = libraryKeyByName[libName];
  if (parent == null ||
      !plan.isOwn(parent) ||
      !_reachesViaPart(parent, key, declaredPartsOf)) {
    // The exclusion decision consulted the named parent (when it names a
    // file), so its provider is never listed as unused.
    if (parent != null) plan.addConsulted(parent);
    direct.putIfAbsent(
      key,
      () => 'its library $libName is not an input of this module',
    );
  } else {
    plan.addImport(importer: key, target: parent);
    plan.addImporter(imported: parent, importer: key);
    plan.addImporter(imported: key, importer: parent);
    plan.addImport(importer: parent, target: key);
  }
}

/// Refuses a URI spanning lines or with an empty path segment, however it
/// spells its target: the front end's multi-line first-line rule reads a
/// different file than [_resolveUri] names, and an empty segment resolves
/// differently in the front end than by skipping it (a `package:` doubled
/// slash resolves absolutely). Reports whether the directive was refused.
bool _rejectMalformedRef(
  ScanRef ref,
  String key,
  Map<String, String> uriOfKey,
  List<String> disallowed,
) {
  if (!hasLineBreak(ref.uri) && !hasEmptyPathSegment(ref.uri)) return false;
  disallowed.add(
    'kernel_module: cannot compile ${uriOfKey[key] ?? key}: '
    "${ref.kind} '${ref.uri}' is not a declared input.",
  );
  return true;
}

/// Plans a `dart:` import: allowed for VM libraries, excluding otherwise.
/// Reports whether the directive was a `dart:` import.
bool _planSdkRef(
  ScanRef ref,
  String key,
  Set<String> vm,
  Map<String, String> direct,
) {
  if (!ref.uri.startsWith('dart:')) return false;
  if (!vm.contains(ref.uri.substring('dart:'.length))) {
    direct.putIfAbsent(key, () => '${ref.uri} is not a VM library');
  }
  return true;
}

/// Plans a directive URI the resolver cannot name: slash-authority and
/// host-reading URIs fail the build, while unknown-scheme names exclude the
/// importer with the reason the compiler would lack.
void _planUnresolvedRef(
  ScanRef ref,
  String key,
  Map<String, String> uriOfKey,
  String multiRootPrefix,
  _Plan plan,
  Map<String, String> direct,
  List<String> disallowed,
) {
  // A schemeless `//` authority (`\` separates like the front end, so a
  // leading `\\` counts too) reads above every root, outside the declared
  // inputs: it fails however the directive names it, parts included.
  if (_isSlashAuthorityUri(ref.uri)) {
    disallowed.add(
      'kernel_module: cannot compile ${uriOfKey[key] ?? key}: '
      "${ref.kind} '${ref.uri}' is not a declared input.",
    );
    return;
  }
  // A directive URI outside the declared inputs fails the build (see the
  // doc comment): it would read the host, outside every multi-root.
  final outsideInputs = ref.isPart || ref.isPartOf
      ? isFileSchemeDirectiveUri(ref.uri)
      : isDisallowedDirectiveUri(ref.uri, multiRootPrefix: multiRootPrefix);
  if (outsideInputs) {
    disallowed.add(
      'kernel_module: cannot compile ${uriOfKey[key] ?? key}: '
      "${ref.kind} '${ref.uri}' is not a declared input.",
    );
    return;
  }
  // A `package:` the module's config does not name. Other schemes are not Dart
  // sources this module can read, and resolve to null without a rule of their own.
  if (ref.isPartOf) {
    direct.putIfAbsent(
      key,
      () => 'its library ${ref.uri} is not an input of this module',
    );
  } else if (ref.isPart) {
    direct.putIfAbsent(
      key,
      () => 'its part ${ref.uri} is not an input of this module',
    );
  } else if (ref.uri.startsWith('package:')) {
    direct.putIfAbsent(
      key,
      () => '${ref.uri} names a package this module does not have',
    );
  } else {
    // A schemeless URI the resolver cannot name (a fragment, a decoded
    // `/`): the front end reads no declared file through it, so the
    // directive fails instead of compiling without it.
    disallowed.add(
      'kernel_module: cannot compile ${uriOfKey[key] ?? key}: '
      "${ref.kind} '${ref.uri}' is not a declared input.",
    );
  }
}

/// Plans a resolved `part of` URI: links the part both ways to an own parent
/// it reaches through `part` directives, or excludes it.
void _planPartOfRef(
  ScanRef ref,
  String key,
  String target,
  Map<String, Set<String>> declaredPartsOf,
  _Plan plan,
  Map<String, String> direct,
) {
  if (!plan.isOwn(target) || !_reachesViaPart(target, key, declaredPartsOf)) {
    // The exclusion decision consulted the parent library, so its
    // provider is never listed as unused.
    plan.addConsulted(target);
    direct.putIfAbsent(
      key,
      () => 'its library ${ref.uri} is not an input of this module',
    );
    return;
  }
  plan.addImport(importer: key, target: target);
  plan.addImporter(imported: target, importer: key);
  plan.addImporter(imported: key, importer: target);
  plan.addImport(importer: target, target: key);
}

/// Plans a resolved import, export or `part` URI: records the edge, and
/// excludes the importer when the target is outside this module's closure.
void _planResolvedImport(
  ScanRef ref,
  String key,
  String target,
  Map<String, String> inherited,
  Map<String, _Node> graph,
  _Plan plan,
  Map<String, String> direct,
) {
  plan.addImport(importer: key, target: target);
  if (ref.isPart && !plan.isOwn(target)) {
    // The exclusion decision consulted the non-own part, so its provider
    // is never listed as unused.
    plan.addConsulted(target);
    direct.putIfAbsent(
      key,
      () => 'its part ${ref.uri} is not an input of this module',
    );
    return;
  }
  if (plan.isOwn(target)) {
    plan.addImporter(imported: target, importer: key);
    // A part follows its library both ways.
    if (ref.isPart) {
      plan.addImporter(imported: key, importer: target);
      plan.addImport(importer: target, target: key);
    }
  } else if (inherited.containsKey(target)) {
    // The exclusion decision consulted the closure-excluded source, so
    // its provider is never listed as unused.
    plan.addConsulted(target);
    direct.putIfAbsent(key, () => 'imports ${ref.uri}, which is excluded');
  } else if (!graph.containsKey(target)) {
    // The missing-key exclusion consulted the absent closure key, so its
    // package's providers are never listed as unused.
    plan.addConsulted(target);
    direct.putIfAbsent(
      key,
      () => 'imports ${ref.uri}, which is not in this module closure',
    );
  }
}

/// Whether the source at `uri` is one a module of the closure defines, so that this
/// module need not compile it. `graph` holds the keys the closure's modules define.
bool _definedBy(
  String uri,
  Map<String, _Node> graph,
  Map<String, _PackageRoot> roots,
  String multiRootPrefix,
) {
  final key = _keyOfUri(uri, roots, multiRootPrefix);
  return key != null && graph.containsKey(key);
}

/// What the entry module compiles, and what it imports.
class _EntrySources {
  _EntrySources(
    this.uris,
    this.imports,
    this.keys,
    this.undeclared,
    this.disallowed,
    this.lookedUpLibraryNames,
  );

  /// The URIs the entry compiles: its own sources, and each excluded file it reaches.
  final List<String> uris;

  /// The keys of every library the entry's sources import, sorted. The entry links
  /// against the kernels these reach.
  final List<String> imports;

  /// The keys of all sources in [uris].
  final List<String> keys;

  /// Any source reached by the entry module that is not a declared input.
  final List<String> undeclared;

  /// A diagnostic for every directive URI the walk reached that names no file
  /// the action can read through its declared inputs (see [_planImports]).
  final List<String> disallowed;

  /// Whether the walk scanned declared files for a `part of` library name.
  /// Those wrapper reads are invisible to the unused-inputs report, so no
  /// dependency source is listed when this is set.
  final bool lookedUpLibraryNames;
}

/// The sources the entry module compiles: its own, and each excluded file it reaches.
/// An excluded file is compiled from source here, so the compiler reports its genuine
/// VM error. Every other file it reaches is in a module.
class _EntryEdge {
  _EntryEdge(this.from, this.uri, this.target);

  final String from;
  final String uri;
  final String target;
}

Future<_EntrySources> _entrySources(
  List<String> sources,
  Map<String, String> closure,
  Map<String, _Node> graph,
  Map<String, _PackageRoot> roots,
  _Files files,
  Set<String> vm,
  String multiRootPrefix,
) async {
  final walk = _EntryWalk(closure, graph, roots, files, vm, multiRootPrefix);
  walk.seed(sources);
  await walk.run();
  return walk.result();
}

/// Lazily indexes declared sources by their `library <name>`.
class _LibraryNameIndex {
  _LibraryNameIndex(this._closure, this._files, this._vm);

  final Map<String, String> _closure;
  final _Files _files;
  final Set<String> _vm;

  Map<String, String>? _map;

  /// Whether the index was built: the walk scanned declared files for a
  /// `part of` library name. Those wrapper reads are invisible to the
  /// unused-inputs report, so no dependency source is listed when set.
  bool get wasBuilt => _map != null;

  Future<String?> find(String name) async {
    var map = _map;
    if (map == null) {
      map = <String, String>{};
      for (final candidate in <String>{
        ..._closure.keys,
        ..._files.declaredKeys,
      }) {
        final scan = await _files.scan(candidate, _vm);
        if (scan?.libraryName != null) {
          map.putIfAbsent(scan!.libraryName!, () => candidate);
        }
      }
      _map = map;
    }
    return map[name];
  }
}

/// The breadth-first walk from the entry's sources through their directives.
class _EntryWalk {
  _EntryWalk(
    Map<String, String> closure,
    Map<String, _Node> graph,
    Map<String, _PackageRoot> roots,
    _Files files,
    Set<String> vm,
    String multiRootPrefix,
  ) : _closure = closure,
      _graph = graph,
      _roots = roots,
      _files = files,
      _vm = vm,
      _multiRootPrefix = multiRootPrefix,
      _names = _LibraryNameIndex(closure, files, vm);

  final Map<String, String> _closure;
  final Map<String, _Node> _graph;
  final Map<String, _PackageRoot> _roots;
  final _Files _files;
  final Set<String> _vm;
  final String _multiRootPrefix;

  final _out = <String>[];
  final _ownUris = <String, String>{};
  final _imports = <String>{};
  final _seen = <String>{};
  final _queue = Queue<String>();
  final _edges = <_EntryEdge>[];
  final _undeclared = <String>[];
  final _disallowed = <String>[];
  final _LibraryNameIndex _names;

  void seed(List<String> sources) {
    for (final uri in sources) {
      final key = _keyOfUri(uri, _roots, _multiRootPrefix);
      if (key == null) {
        _out.add(uri);
      } else {
        _ownUris.putIfAbsent(key, () => uri);
        if (_seen.add(key)) _queue.add(key);
      }
    }
  }

  Future<void> run() async {
    while (_queue.isNotEmpty) {
      await _visitKey(_queue.removeFirst());
    }
    _imports.removeAll(_ownUris.keys);
  }

  _EntrySources result() {
    final shapes = _entryUriShapes(_ownUris, _edges, _roots, _multiRootPrefix);
    _emitEntryUris(
      _out,
      _ownUris,
      _roots,
      _multiRootPrefix,
      shapes.usedAsRaw,
      shapes.usedAsPackage,
    );
    return _EntrySources(
      _out,
      _imports.toList()..sort(),
      _ownUris.keys.toList(),
      _undeclared,
      _disallowed,
      _names.wasBuilt,
    );
  }

  Future<void> _visitKey(String key) async {
    if (!_files.isDeclared(key)) {
      _undeclared.add('${_ownUris[key] ?? key} ($key)');
      return;
    }
    final text = await _files.read(key);
    if (text == null) {
      _undeclared.add('${_ownUris[key] ?? key} ($key)');
      return;
    }
    final scan = await _files.scan(key, _vm);
    if (scan == null) return;
    if (scan.partOfLibrary != null) {
      await _followPartOfName(key, scan.partOfLibrary!);
    }
    for (final ref in scan.refs) {
      if (ref.uri.startsWith('dart:')) continue;
      await _followRef(key, ref);
    }
  }

  Future<void> _followPartOfName(String key, String library) async {
    final target = await _names.find(library);
    if (target == null) {
      _undeclared.add('${_ownUris[key] ?? key} (part of $library)');
      return;
    }
    final uri =
        _closure[target] ??
        _packageUriOf(target, '$_multiRootPrefix$target', _roots);
    _edges.add(_EntryEdge(key, uri, target));
    _imports.add(target);
    if (_seen.add(target)) {
      _ownUris.putIfAbsent(target, () => uri);
      _queue.add(target);
    }
  }

  Future<void> _followRef(String key, ScanRef ref) async {
    if (_rejectMalformedRef(ref, key, _ownUris, _disallowed)) return;
    final target = _resolveUri(ref.uri, key, _roots, _multiRootPrefix);
    if (target == null) {
      _followUnresolvedRef(key, ref);
      return;
    }
    _edges.add(_EntryEdge(key, ref.uri, target));
    _imports.add(target);
    if (!_seen.add(target)) return;
    final uri =
        _closure[target] ??
        ((!_graph.containsKey(target) || ref.isPart || ref.isPartOf)
            ? _packageUriOf(target, '$_multiRootPrefix$target', _roots)
            : null);
    if (uri == null) return;
    _ownUris.putIfAbsent(target, () => uri);
    _queue.add(target);
  }

  void _followUnresolvedRef(String key, ScanRef ref) {
    // A schemeless `//` authority reads above every root, outside the
    // declared inputs: it fails however the directive names it.
    if (_isSlashAuthorityUri(ref.uri)) {
      _disallowed.add(
        'kernel_module: cannot compile ${_ownUris[key] ?? key}: '
        "${ref.kind} '${ref.uri}' is not a declared input.",
      );
      return;
    }
    // A directive URI outside the declared inputs fails the build (see
    // [_planImports]): it would read the host, outside every multi-root.
    final outsideInputs = ref.isPart || ref.isPartOf
        ? isFileSchemeDirectiveUri(ref.uri)
        : isDisallowedDirectiveUri(ref.uri, multiRootPrefix: _multiRootPrefix);
    if (outsideInputs) {
      _disallowed.add(
        'kernel_module: cannot compile ${_ownUris[key] ?? key}: '
        "${ref.kind} '${ref.uri}' is not a declared input.",
      );
      return;
    }
    // A schemeless `import` or `export` URI the resolver cannot name (a
    // fragment, a decoded `/`) reads no declared file: it fails instead of
    // compiling without it. Other nulls (parts, unknown packages) stay on
    // their exclusion paths, where the compiler reports them.
    if (!ref.isPart && !ref.isPartOf && !ref.uri.startsWith('package:')) {
      _disallowed.add(
        'kernel_module: cannot compile ${_ownUris[key] ?? key}: '
        "${ref.kind} '${ref.uri}' is not a declared input.",
      );
    }
  }
}

/// How each walked source is named on the compile command line.
typedef _EntryUriShapes = ({Set<String> usedAsRaw, Set<String> usedAsPackage});

/// Computes which walked sources are named by raw or `package:` URI.
_EntryUriShapes _entryUriShapes(
  Map<String, String> ownUris,
  List<_EntryEdge> edges,
  Map<String, _PackageRoot> roots,
  String multiRootPrefix,
) {
  final usedAsRaw = <String>{};
  final usedAsPackage = <String>{};
  ownUris.forEach((key, uri) {
    final pkgUri = _packageUriOf(key, uri, roots);
    if (pkgUri == uri) {
      usedAsRaw.add(key);
    } else if (uri.startsWith('package:')) {
      usedAsPackage.add(key);
    }
  });
  for (final edge in edges) {
    if (!ownUris.containsKey(edge.target)) continue;
    if (edge.uri.startsWith('package:')) {
      usedAsPackage.add(edge.target);
    } else if (edge.uri.startsWith(multiRootPrefix)) {
      usedAsRaw.add(edge.target);
    }
  }
  _propagateRawUse(edges, ownUris, usedAsRaw);
  ownUris.forEach((key, uri) {
    if (_packageUriOf(key, uri, roots) != uri && !usedAsRaw.contains(key)) {
      usedAsPackage.add(key);
    }
  });
  _propagatePackageUse(edges, ownUris, roots, usedAsPackage);
  return (usedAsRaw: usedAsRaw, usedAsPackage: usedAsPackage);
}

/// Spreads raw naming along relative edges from raw-named sources.
void _propagateRawUse(
  List<_EntryEdge> edges,
  Map<String, String> ownUris,
  Set<String> usedAsRaw,
) {
  var changed = true;
  while (changed) {
    changed = false;
    for (final edge in edges) {
      if (!ownUris.containsKey(edge.target) || edge.uri.contains(':')) {
        continue;
      }
      if (usedAsRaw.contains(edge.from) && usedAsRaw.add(edge.target)) {
        changed = true;
      }
    }
  }
}

/// Spreads `package:` naming along relative edges from `package:` sources.
void _propagatePackageUse(
  List<_EntryEdge> edges,
  Map<String, String> ownUris,
  Map<String, _PackageRoot> roots,
  Set<String> usedAsPackage,
) {
  var changed = true;
  while (changed) {
    changed = false;
    for (final edge in edges) {
      if (!ownUris.containsKey(edge.target) || edge.uri.contains(':')) {
        continue;
      }
      final targetUri = ownUris[edge.target]!;
      if (usedAsPackage.contains(edge.from) &&
          _packageUriOf(edge.target, targetUri, roots) != targetUri &&
          usedAsPackage.add(edge.target)) {
        changed = true;
      }
    }
  }
}

/// Emits each walked source under the URIs the compile must name it by.
void _emitEntryUris(
  List<String> out,
  Map<String, String> ownUris,
  Map<String, _PackageRoot> roots,
  String multiRootPrefix,
  Set<String> usedAsRaw,
  Set<String> usedAsPackage,
) {
  ownUris.forEach((key, uri) {
    final pkgUri = _packageUriOf(key, uri, roots);
    if (pkgUri == uri) {
      out.add(uri);
      return;
    }
    if (usedAsPackage.contains(key) || !usedAsRaw.contains(key)) {
      out.add(pkgUri);
    }
    if (usedAsRaw.contains(key)) {
      final rawUri = uri.startsWith(multiRootPrefix)
          ? uri
          : '$multiRootPrefix$key';
      if (rawUri != pkgUri) out.add(rawUri);
    }
  });
}

/// The `package:` URI of the file with `key`, when a package names it under its
/// `lib/`, and otherwise `uri`. An importer names such a library by its `package:`
/// URI, and `--exclude-non-sources` emits a library only under the URI it was given,
/// so an entry compiles its own `lib/` files under that URI too.
String _packageUriOf(String key, String uri, Map<String, _PackageRoot> roots) {
  String? best;
  var bestLength = -1;
  roots.forEach((name, root) {
    final prefix = '${root.path}${root.packageUri}';
    if (key.startsWith(prefix) && prefix.length > bestLength) {
      best = 'package:$name/${key.substring(prefix.length)}';
      bestLength = prefix.length;
    }
  });
  return best ?? uri;
}

/// The result of attributing a failing compile's diagnostics to own sources.
class _Verdict {
  const _Verdict({
    this.failing = const {},
    this.outside = false,
    this.unattributed = false,
  });

  /// Each own source with an error, by key, mapped to its first error message.
  final Map<String, String> failing;

  /// True when an error is located in a file that is not one of the own sources.
  final bool outside;

  /// True when a diagnostic names no location the tool can read.
  final bool unattributed;
}

_Verdict _attribute(
  String output,
  List<String> uris,
  Map<String, _PackageRoot> roots,
  String multiRootPrefix,
) {
  final keyOfSpelling = <String, String>{};
  for (final uri in uris) {
    final key = _keyOfUri(uri, roots, multiRootPrefix);
    if (key == null) continue;
    for (final spelling in _spellings(uri, key)) {
      keyOfSpelling.putIfAbsent(spelling, () => key);
    }
  }
  final failing = <String, String>{};
  var outside = false;
  var located = 0;
  for (final match in _errorLine.allMatches(output)) {
    located++;
    final key = _lookup(keyOfSpelling, match.group(1)!, multiRootPrefix);
    if (key == null) {
      outside = true;
      continue;
    }
    failing.putIfAbsent(key, () => match.group(4)!);
  }
  final errorLines = output
      .split('\n')
      .where((line) => line.startsWith('Error: ') || line.contains(': Error: '))
      .length;
  return _Verdict(
    failing: failing,
    outside: outside,
    unattributed: located == 0 || errorLines != located,
  );
}

final _isolatedRootPrefix = RegExp(r'^(?:.*/)?\.isolated_root/');

/// The key of the first spelling of `path` that `spellings` knows.
String? _lookup(
  Map<String, String> spellings,
  String path,
  String multiRootPrefix,
) {
  final slashPath = path.contains(r'\') ? path.replaceAll(r'\', '/') : path;
  for (final spelling in [
    path,
    slashPath,
    _stripPrefix(path, multiRootPrefix),
    _stripPrefix(slashPath, multiRootPrefix),
    slashPath.replaceFirst(_bazelOutPrefix, ''),
    slashPath.replaceFirst(_isolatedRootPrefix, ''),
  ]) {
    if (spelling == null) continue;
    final key = spellings[spelling];
    if (key != null) return key;
  }
  return null;
}

/// Every name a diagnostic might use for a source: its key, and its URI.
Iterable<String> _spellings(String uri, String key) sync* {
  yield key;
  yield uri;
}

/// Normalized path spellings for an input path or `--input-source` flag value.
Iterable<String> _inputSpellings(
  String? raw, [
  List<String> multiRoots = const [],
]) sync* {
  if (raw == null || raw.isEmpty) return;
  final norm = _normalize(raw);
  if (norm.isNotEmpty) yield norm;
  if (raw.startsWith('bazel-out/') || raw.startsWith('./bazel-out/')) {
    final stripped = _normalize(raw.replaceFirst(_bazelOutPrefix, ''));
    if (stripped.isNotEmpty && stripped != norm) yield stripped;
  }
  final rawSlash = _filePathOf(raw).replaceAll(r'\', '/');
  for (final r in multiRoots) {
    final rootFile = _filePathOf(r)
        .replaceAll(r'\', '/')
        .replaceFirst(RegExp(r'/+$'), '');
    if (rootFile.isEmpty || rootFile == '.') continue;
    if (rawSlash.startsWith('$rootFile/')) {
      final stripped = _normalize(rawSlash.substring(rootFile.length + 1));
      if (stripped.isNotEmpty && stripped != norm) yield stripped;
    }
    final normRoot = _normalize(rootFile);
    if (normRoot.isNotEmpty &&
        normRoot != '.' &&
        norm.startsWith('$normRoot/')) {
      final stripped = _normalize(norm.substring(normRoot.length + 1));
      if (stripped.isNotEmpty && stripped != norm) yield stripped;
    }
  }
}

/// The path after `multiRootPrefix`, or null for any other URI.
String? _stripPrefix(String uri, String multiRootPrefix) {
  if (uri.startsWith(multiRootPrefix)) {
    return uri.substring(multiRootPrefix.length);
  }
  return null;
}

/// The key of a source or a library: the path it has under the multi-root
/// directories, without the scheme. Null for a URI this module cannot name, such as
/// a `dart:` library or a `package:` whose package it does not list.
///
/// The key is the literal spelling: `--source` URIs name action inputs, and the
/// spelling the rule passes is the input's path. (The front end percent-decodes
/// flag URIs when it reads them, so a `--source` URI with an escape reads the
/// decoded file; the read-set verification in [_unstagedReadsAreDeclared]
/// catches that divergence and recompiles isolated, where the read fails
/// instead of reaching an undeclared file.)
String? _keyOfUri(
  String uri,
  Map<String, _PackageRoot> roots,
  String multiRootPrefix,
) {
  final stripped = _stripPrefix(uri, multiRootPrefix);
  if (stripped != null) return _normalize(stripped);
  if (!uri.startsWith('package:')) return null;
  final rest = uri.substring('package:'.length);
  final slash = rest.indexOf('/');
  if (slash <= 0) return null;
  final root = roots[rest.substring(0, slash)];
  if (root == null) return null;
  return _normalize(
    '${root.path}${root.packageUri}${rest.substring(slash + 1)}',
  );
}

/// Whether [uri] is a schemeless `//`-authority reference: after `\` becomes
/// `/` (it separates like the front end), it starts with `//`. The front end
/// resolves such a reference above every multi-root, so it reads the host
/// whatever the roots hold, and every resolver nulls it.
bool _isSlashAuthorityUri(String uri) {
  final text = uri.contains(r'\') ? uri.replaceAll(r'\', '/') : uri;
  return text.startsWith('//');
}

/// The key a URI in a file named `fromKey` refers to, or null when the URI is not
/// one this module can name.
String? _resolveUri(
  String uri,
  String fromKey,
  Map<String, _PackageRoot> roots,
  String multiRootPrefix,
) {
  final packageDirs = <String, String>{
    for (final entry in roots.entries)
      entry.key: (entry.value.path + entry.value.packageUri).replaceFirst(
        RegExp(r'/+$'),
        '',
      ),
  };
  return resolveDirectiveUri(
    uri,
    fromKey,
    packageDirs,
    multiRootPrefix: multiRootPrefix,
  );
}

/// `path` without empty and `.` segments, with each `..` applied.
String _normalize(String path) {
  if (_isNormalizedRelative(path)) return path;
  final slashPath = path.contains(r'\') ? path.replaceAll(r'\', '/') : path;
  final parts = <String>[];
  for (final part in slashPath.split('/')) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..') {
      if (parts.isNotEmpty) parts.removeLast();
    } else {
      parts.add(part);
    }
  }
  return parts.join('/');
}

/// Reads the files of a module's sources from the multi-root directories.
///
/// Only files declared via `--source`, `--input-source`, or a dependency
/// `.koutline`'s staged excluded sources (and present in `WorkRequest.inputs`
/// when running as a persistent worker) may be read.
class _Files {
  _Files(
    this._roots, {
    required Set<String> declaredKeys,
    Set<String> declaredRootPaths = const {},
    Map<String, String> stagedRoots = const {},
    Set<String>? workerInputPaths,
  }) : _declaredKeys = declaredKeys,
       _declaredRootPaths = declaredRootPaths,
       _stagedRoots = stagedRoots,
       _workerInputPaths = workerInputPaths;

  final List<String> _roots;
  final Set<String> _declaredKeys;
  final Set<String> _declaredRootPaths;
  final Map<String, String> _stagedRoots;
  final Set<String>? _workerInputPaths;
  final String _cwd = Directory.current.path.replaceAll(r'\', '/');
  final Map<String, String?> _cache = {};
  final Map<String, ScanResult?> _scanCache = {};

  bool _matchesPathSet(Set<String> pathSet, String root, String key) {
    final rootFile = _filePathOf(root);
    final normRoot = rootFile.contains(r'\')
        ? rootFile.replaceAll(r'\', '/')
        : rootFile;
    final raw = normRoot == '.' ? key : '$normRoot/$key';
    if (pathSet.contains(raw)) return true;
    final norm = _normalize(raw);
    if (pathSet.contains(norm)) return true;
    if (raw.startsWith('/') || isWindowsDrivePath(raw)) {
      if (raw.startsWith('$_cwd/')) {
        final rel = _normalize(raw.substring(_cwd.length + 1));
        if (pathSet.contains(rel)) return true;
      }
      final normFile = normalizePath(raw);
      if (pathSet.contains(normFile)) return true;
      if (normFile.startsWith('$_cwd/')) {
        final rel = _normalize(normFile.substring(_cwd.length + 1));
        if (pathSet.contains(rel)) return true;
      }
    } else {
      final abs = '$_cwd/$norm';
      if (pathSet.contains(abs) ||
          pathSet.contains(_normalize(abs)) ||
          pathSet.contains(normalizePath(abs))) {
        return true;
      }
    }
    return false;
  }

  /// Whether `(root, key)` was explicitly named in `WorkRequest.inputs` or
  /// `--input-source`.
  bool isExplicitlyDeclaredInRoot(String root, String key) {
    final workerPaths = _workerInputPaths;
    if (workerPaths != null) {
      return _matchesPathSet(workerPaths, root, key);
    }
    if (_declaredRootPaths.isNotEmpty) {
      return _matchesPathSet(_declaredRootPaths, root, key);
    }
    return false;
  }

  /// Whether `key` may be read from `root`.
  bool isDeclaredInRoot(String root, String key) {
    if (!_declaredKeys.contains(key)) return false;
    final workerPaths = _workerInputPaths;
    if (workerPaths != null) {
      return _matchesPathSet(workerPaths, root, key);
    }
    if (_declaredRootPaths.isNotEmpty) {
      var anyRootDeclared = false;
      for (final candidateRoot in _roots) {
        if (_matchesPathSet(_declaredRootPaths, candidateRoot, key)) {
          anyRootDeclared = true;
          break;
        }
      }
      if (anyRootDeclared) {
        return _matchesPathSet(_declaredRootPaths, root, key);
      }
    }
    return true;
  }

  /// Whether `key` is declared via `--source` or `--input-source` (and present
  /// in `WorkRequest.inputs` when active).
  bool isDeclaredInRoots(String key) {
    if (!_declaredKeys.contains(key)) return false;
    for (final root in _roots) {
      if (isDeclaredInRoot(root, key)) return true;
    }
    return false;
  }

  /// Whether `key` is a declared input of this action.
  bool isDeclared(String key) =>
      isDeclaredInRoots(key) || _stagedRoots.containsKey(key);

  /// All keys declared as inputs of this action.
  Set<String> get declaredKeys => {
    for (final key in _declaredKeys)
      if (isDeclaredInRoots(key)) key,
    ..._stagedRoots.keys,
  };

  /// The single root from which [key] is declared to be read, or `null` when
  /// [key] is not a declared input of this action.
  ///
  /// When [key] is declared in [_roots], only [_roots] are considered (never
  /// [_stagedRoots]); otherwise [_stagedRoots] is used.
  String? declaredRootOf(String key) {
    if (isDeclaredInRoots(key)) {
      String? firstDeclared;
      for (final root in _roots) {
        if (!isDeclaredInRoot(root, key)) continue;
        firstDeclared ??= root;
        final path = _filePathOf(root == '.' ? key : '$root/$key');
        if (File(path).existsSync()) {
          return root;
        }
      }
      return firstDeclared;
    }
    return _stagedRoots[key];
  }

  /// The file-system path of the single declared origin for [key], or `null`
  /// when [key] is not a declared input.
  String? declaredOriginOf(String key) {
    final root = declaredRootOf(key);
    if (root == null) return null;
    return _filePathOf(root == '.' ? key : '$root/$key');
  }

  /// The text of the file with `key` from its single declared origin, or null
  /// when it is not a declared input or its declared origin does not exist.
  Future<String?> read(String key) async {
    if (!isDeclared(key)) return null;
    if (_cache.containsKey(key)) return _cache[key];
    String? text;
    final origin = declaredOriginOf(key);
    if (origin != null) {
      final file = File(origin);
      if (await file.exists()) {
        text = utf8.decode(await file.readAsBytes(), allowMalformed: true);
      }
    }
    return _cache[key] = text;
  }

  /// Cached directive scan of `key`.
  Future<ScanResult?> scan(String key, Set<String> vm) async {
    if (_scanCache.containsKey(key)) return _scanCache[key];
    final text = await read(key);
    final result = text == null ? null : scanDirectives(text, vm);
    return _scanCache[key] = result;
  }
}

/// Replaces all `--multi-root` flags in [base] with a single `--multi-root`
/// pointing at [singleRoot].
List<String> _baseWithSingleMultiRoot(List<String> base, String singleRoot) {
  final out = <String>[];
  var inserted = false;
  for (var i = 0; i < base.length; i++) {
    final arg = base[i];
    if (arg == _multiRootFlag && i + 1 < base.length) {
      i++;
      if (!inserted) {
        inserted = true;
        out
          ..add(_multiRootFlag)
          ..add(singleRoot);
      }
    } else if (arg.startsWith('$_multiRootFlag=')) {
      if (!inserted) {
        inserted = true;
        out.add('$_multiRootFlag=$singleRoot');
      }
    } else {
      out.add(arg);
    }
  }
  if (!inserted) {
    out
      ..add(_multiRootFlag)
      ..add(singleRoot);
  }
  return out;
}

/// Orders [multiRoots] so the front end resolves each of [keys] to its declared
/// input: roots holding an explicitly declared spelling come first, then
/// roots without conflicts, then roots where an undeclared file shadows a
/// declared key. Within one build the order is stable, so a warm compiler
/// reuses its cached files across requests; a shadowing root never wins over
/// the declared copy, so untracked and stale files stay invisible without
/// staging anything.
List<String> _orderedMultiRoots(
  List<String> multiRoots,
  Iterable<String> keys,
  _Files files,
) {
  if (multiRoots.length <= 1) return multiRoots;
  final useKeys = _orderedCheckKeys(keys, files);
  if (useKeys.isEmpty) return multiRoots;
  final kinds = _classifyMultiRoots(multiRoots, useKeys, files);
  final orderedRoots = _conflictLastOrder(multiRoots, kinds);
  if (_sameRootOrder(multiRoots, orderedRoots)) return multiRoots;
  return orderedRoots;
}

/// The keys whose resolution decides the root order: [keys], or every declared
/// key when the compile names none.
List<String> _orderedCheckKeys(Iterable<String> keys, _Files files) {
  final checkKeys = keys.toList();
  if (checkKeys.isNotEmpty) return checkKeys;
  return files.declaredKeys.toList();
}

/// Whether each root holds an explicitly declared spelling, and whether an
/// undeclared file shadows a checked key under it.
Map<String, ({bool explicit, bool conflict})> _classifyMultiRoots(
  List<String> multiRoots,
  List<String> useKeys,
  _Files files,
) {
  final kinds = <String, ({bool explicit, bool conflict})>{};
  for (final root in multiRoots) {
    kinds[root] = _classifyMultiRoot(root, useKeys, files);
  }
  return kinds;
}

/// Whether [root] holds an explicitly declared spelling of a checked key, and
/// whether an undeclared file shadows one under it.
({bool explicit, bool conflict}) _classifyMultiRoot(
  String root,
  List<String> useKeys,
  _Files files,
) {
  var conflict = false;
  var explicit = false;
  for (final key in useKeys) {
    if (files.isExplicitlyDeclaredInRoot(root, key)) {
      explicit = true;
    } else if (!files.isDeclaredInRoot(root, key)) {
      final f = File(root == '.' ? key : '$root/$key');
      if (f.existsSync()) {
        conflict = true;
      }
    }
  }
  return (explicit: explicit, conflict: conflict);
}

/// [multiRoots] with shadowing roots last: roots holding an explicitly declared
/// spelling come first, then roots without conflicts.
List<String> _conflictLastOrder(
  List<String> multiRoots,
  Map<String, ({bool explicit, bool conflict})> kinds,
) => [
  for (final root in multiRoots)
    if (!kinds[root]!.conflict && kinds[root]!.explicit) root,
  for (final root in multiRoots)
    if (!kinds[root]!.conflict && !kinds[root]!.explicit) root,
  for (final root in multiRoots)
    if (kinds[root]!.conflict) root,
];

/// Whether [orderedRoots] names the same roots in the same order.
bool _sameRootOrder(List<String> multiRoots, List<String> orderedRoots) {
  for (var i = 0; i < multiRoots.length; i++) {
    if (orderedRoots[i] != multiRoots[i]) return false;
  }
  return true;
}

/// Rewrites the `--multi-root` flags in [base] to the order
/// [_orderedMultiRoots] computes.
List<String> _baseWithOrderedMultiRoots(
  List<String> base,
  List<String> multiRoots,
  Iterable<String> keys,
  _Files files,
) {
  final orderedRoots = _orderedMultiRoots(multiRoots, keys, files);
  if (identical(orderedRoots, multiRoots)) return base;
  final out = <String>[];
  var rootIdx = 0;
  for (var i = 0; i < base.length; i++) {
    final arg = base[i];
    if (arg == _multiRootFlag && i + 1 < base.length) {
      out
        ..add(_multiRootFlag)
        ..add(orderedRoots[rootIdx++]);
      i++;
    } else if (arg.startsWith('$_multiRootFlag=')) {
      out.add('$_multiRootFlag=${orderedRoots[rootIdx++]}');
    } else {
      out.add(arg);
    }
  }
  return out;
}

/// Whether `compileModule` should stage an isolated `--multi-root` directory
/// containing only declared inputs at their single declared origins.
///
/// Staging is skipped when the front end already resolves every key it may
/// read to exactly its declared origin through the staged-source roots in
/// [extraMultiRoots] (first) and the ordered base [multiRoots]: the first
/// root holding the key is its [files.declaredOriginOf], so an unstaged
/// compile reads byte-for-byte the same files staging would link, and the
/// request keeps the stable roots a warm compiler caches across requests.
/// Staging stays for layouts where a shadow would win (stale generated
/// outputs, untracked files over declared keys), for origins outside every
/// root, and for keys whose directives do not scan.
Future<bool> _needsIsolatedMultiRoot(
  List<String> multiRoots,
  List<String> extraMultiRoots,
  Iterable<String> keys,
  _Files files,
  Set<String> vm,
) async {
  final orderedBase = _orderedMultiRoots(multiRoots, keys, files);
  final finalOrder = <String>[...extraMultiRoots, ...orderedBase];
  // Staging can be skipped only when every declared input already lives under
  // one of the candidate roots (so the front end can resolve it without a
  // staged copy).
  if (_hasOriginOutsideRoots(files, finalOrder.toSet())) return true;
  // ... and the first root holding each key the front end may read is exactly
  // its declared origin (so no shadow or stale copy wins over it).
  if (_hasShadowedKey(keys, files, finalOrder)) return true;
  // ... and every compiled key's directives scan (so planning sees every
  // import the front end will follow).
  return _hasUnscannableKey(keys, files, vm);
}

/// Whether a declared input's origin lives outside every candidate root.
bool _hasOriginOutsideRoots(_Files files, Set<String> candidateRoots) {
  for (final key in files.declaredKeys) {
    final origin = files.declaredOriginOf(key);
    if (origin == null || !_originIsUnderRoots(origin, candidateRoots)) {
      return true;
    }
  }
  return false;
}

/// Whether [origin] lives under one of [candidateRoots].
bool _originIsUnderRoots(String origin, Set<String> candidateRoots) {
  final originNorm = origin.replaceAll(r'\', '/');
  for (final root in candidateRoots) {
    final slashRoot = root
        .replaceAll(r'\', '/')
        .replaceFirst(RegExp(r'/+$'), '');
    final prefix = slashRoot == '.' ? '' : '$slashRoot/';
    if (slashRoot == '.' && !originNorm.startsWith('/')) {
      // relative origin under cwd root
      return true;
    }
    if (prefix.isNotEmpty && originNorm.startsWith(prefix)) return true;
  }
  return false;
}

/// Whether the first root holding a key the front end may read is not exactly
/// its declared origin.
bool _hasShadowedKey(
  Iterable<String> keys,
  _Files files,
  List<String> finalOrder,
) {
  final checkKeys = <String>{...keys, ...files.declaredKeys};
  for (final key in checkKeys) {
    final origin = files.declaredOriginOf(key);
    if (origin == null ||
        _firstRootHolding(key, finalOrder) != _filePathOf(origin)) {
      return true;
    }
  }
  return false;
}

/// The first root's path holding [key], or null when no root holds it.
String? _firstRootHolding(String key, List<String> finalOrder) {
  for (final root in finalOrder) {
    final path = _filePathOf(root == '.' ? key : '$root/$key');
    if (File(path).existsSync()) return path;
  }
  return null;
}

/// Whether a compiled key's directives do not scan.
Future<bool> _hasUnscannableKey(
  Iterable<String> keys,
  _Files files,
  Set<String> vm,
) async {
  for (final key in keys) {
    if (await files.scan(key, vm) == null) return true;
  }
  return false;
}

/// Stages `$output/.isolated_root` holding one symlink per declared input in
/// [files], each pointing at its single [files.declaredOriginOf].
///
/// The front end runs with a single `--multi-root` pointing here, so it
/// resolves exactly the declared inputs: untracked workspace files and stale
/// generated outputs can never shadow a declared source, and references to
/// undeclared files fail instead of reading them from the workspace.
/// Symlinks keep staging to metadata operations; no file contents are read or
/// copied. When the platform refuses symlinks, files are copied instead.
/// The returned `covered` maps every staged origin (under each of its path
/// spellings) to the digest passed for it, so callers can withhold the
/// now-duplicate origin inputs from the compiler: it reads each declared
/// file once, through the isolated root.
///
/// [createLink] injects symlink creation (tests pass a throwing function to
/// exercise the copy fallback that Windows without developer mode takes).
Future<
  ({String rootDir, List<Uint8List> inputs, Map<String, Uint8List> covered})
>
_stageIsolatedMultiRoot(
  String output,
  _Files files,
  Map<String, Uint8List>? inputDigests, {
  required bool includeInputDigests,
  void Function(String linkPath, String target)? createLink,
}) async {
  final rootDir = '$output/.isolated_root';
  final dir = Directory(_filePathOf(rootDir));
  if (await dir.exists()) {
    await dir.delete(recursive: true);
  }
  await dir.create(recursive: true);
  final stagedInputs = <Uint8List>[];
  final covered = <String, Uint8List>{};
  final createdParents = <String>{};
  final sortedKeys = files.declaredKeys.toList()..sort();
  final cwd = Directory.current.path.replaceAll(r'\', '/');
  for (final key in sortedKeys) {
    final origin = files.declaredOriginOf(key);
    if (origin == null) continue;
    // A `File` view of a directory never exists, so directories are skipped
    // exactly as with the previous copying stage.
    if (!File(origin).existsSync()) continue;
    final dstPath = _filePathOf('$rootDir/$key');
    final dstParent = File(dstPath).parent;
    if (createdParents.add(dstParent.path)) {
      await dstParent.create(recursive: true);
    }
    if (!_linkOrCopy(origin, dstPath, cwd, createLink: createLink)) continue;
    if (includeInputDigests) {
      final digest =
          _lookupDigest(origin, inputDigests) ??
          sha256Of(await File(origin).readAsBytes());
      _addCovered(covered, origin, digest);
      stagedInputs.add(_encodeInput(kernelWorkerUri(dstPath), digest));
    }
  }
  return (rootDir: rootDir, inputs: stagedInputs, covered: covered);
}

/// Records [origin] in [covered] under each of its path spellings, mirroring
/// how request input digests are indexed, so [_uncoveredInputs] recognizes
/// the origin however the worker request spells it (relative, `./`-prefixed,
/// backslash-separated, drive-letter, or `file:///` URI).
void _addCovered(
  Map<String, Uint8List> covered,
  String origin,
  Uint8List digest,
) {
  covered[origin] = digest;
  final norm = _normalize(origin);
  if (norm.isNotEmpty) {
    covered.putIfAbsent(norm, () => digest);
    if (!norm.startsWith('/')) {
      covered.putIfAbsent('./$norm', () => digest);
    }
  }
  final normFile = normalizePath(origin);
  if (normFile != origin) {
    covered.putIfAbsent(normFile, () => digest);
  }
  // Staged inputs are encoded as `file:///` URIs on Windows, while worker
  // requests may spell the same origin as a filesystem path (or vice versa).
  final uri = kernelWorkerUri(origin);
  if (uri != origin) {
    covered.putIfAbsent(uri, () => digest);
  }
  final uriNorm = kernelWorkerUri(normFile);
  if (uriNorm != normFile) {
    covered.putIfAbsent(uriNorm, () => digest);
  }
}

/// The entries of [inputs] whose paths are not staged isolated origins in
/// [covered]. The compiler resolves every declared file through the isolated
/// root, so passing its origin inputs as well only repeats work.
List<Uint8List> _uncoveredInputs(
  List<Uint8List> inputs,
  Map<String, Uint8List> covered,
) {
  if (covered.isEmpty) return inputs;
  final out = <Uint8List>[];
  for (final raw in inputs) {
    final path = _decodeInputView(raw).path;
    if (path.isEmpty || _lookupDigest(path, covered) == null) {
      out.add(raw);
    }
  }
  return out;
}

/// Creates [dstPath] as a symlink to [origin], falling back to a copy when
/// the platform refuses symlinks. Returns whether [dstPath] was created.
///
/// [createLink] injects symlink creation (tests pass a throwing function to
/// exercise the copy fallback that Windows without developer mode takes).
bool _linkOrCopy(
  String origin,
  String dstPath,
  String cwd, {
  void Function(String linkPath, String target)? createLink,
}) {
  final slashOrigin = origin.replaceAll(r'\', '/');
  final target = slashOrigin.startsWith('/') || isWindowsDrivePath(slashOrigin)
      ? slashOrigin
      : '$cwd/$slashOrigin';
  try {
    if (createLink != null) {
      createLink(dstPath, target);
    } else {
      Link(dstPath).createSync(target);
    }
    return true;
  } on FileSystemException {
    // Symlinks need privileges on some platforms (Windows without developer
    // mode); fall back to a copy, which isolates just as well.
  }
  try {
    File(dstPath).writeAsBytesSync(File(origin).readAsBytesSync());
    return true;
  } on FileSystemException {
    return false;
  }
}

/// The excluded files the sidecars list, by key. Each maps to its `package:` URI
/// when a sidecar gives one, and otherwise to its multi-root URI.
Future<Map<String, String>> _readExcluded(
  List<String> paths,
  Map<String, _PackageRoot> roots,
  String multiRootPrefix, {
  KernelModuleCache? cache,
  Map<String, Uint8List>? inputDigests,
}) async {
  final out = <String, String>{};
  for (final path in paths) {
    final Iterable<String> uris;
    if (cache != null) {
      uris = await cache.excludedLinesOf(path, inputDigests);
    } else {
      final list = <String>[];
      for (final line in await File(path).readAsLines()) {
        if (line.isEmpty || line.startsWith('#')) continue;
        list.add(line.split('\t').first);
      }
      uris = list;
    }
    for (final uri in uris) {
      final key = _keyOfUri(uri, roots, multiRootPrefix);
      if (key == null) continue;
      final known = out[key];
      if (known == null ||
          (uri.startsWith('package:') && !known.startsWith('package:'))) {
        out[key] = uri;
      }
    }
  }
  return out;
}

/// The libraries of `platform` in a `libraries.json`, plus `extraLibraries`, by bare
/// name. The platform's `include`s count too (`vm` inherits `vm_common`), and a
/// platform other than `vm` also inherits `vm` when `libraries.json` defines it.
Set<String> vmLibraries(
  Map<String, dynamic> json, {
  String platform = 'vm',
  Iterable<String> extraLibraries = const [],
}) {
  final names = <String>{};
  final seen = <String>{};
  if (json.containsKey(platform)) {
    _collectVmPlatform(json, platform, seen, names);
  }
  if (platform != 'vm' && json.containsKey('vm')) {
    _collectVmPlatform(json, 'vm', seen, names);
  }
  for (final extra in extraLibraries) {
    names.add(_bareDartLibraryName(extra));
  }
  return names;
}

/// The `dart:`-less name of a `libraries.json` library or `--extra-library`.
String _bareDartLibraryName(String text) =>
    text.startsWith('dart:') ? text.substring('dart:'.length) : text;

/// Adds the libraries of `target` in [json] to [names], following its `include`s.
void _collectVmPlatform(
  Map<String, dynamic> json,
  String target,
  Set<String> seen,
  Set<String> names,
) {
  if (!seen.add(target)) return;
  final entry = json[target];
  if (entry is! Map) return;
  _addVmPlatformLibraries(entry['libraries'], names);
  final includes = entry['include'];
  if (includes is List) {
    for (final include in includes) {
      if (include is Map && include['target'] is String) {
        _collectVmPlatform(json, include['target'] as String, seen, names);
      }
    }
  }
}

/// Adds every supported, non-private library of one platform entry to [names].
void _addVmPlatformLibraries(Object? libraries, Set<String> names) {
  if (libraries is! Map) return;
  for (final entry in libraries.entries) {
    final spec = entry.value;
    if (spec is Map && spec['supported'] == false) continue;
    final bare = _bareDartLibraryName(entry.key.toString());
    if (bare.startsWith('_')) continue;
    names.add(bare);
  }
}

/// Each package's root, read from the `package_config.json` the module compiles
/// against, so a `package:` source can be matched to the path a diagnostic names.
Future<Map<String, _PackageRoot>> _packageRoots(
  String packagesFile,
  String multiRootPrefix,
) async {
  final config =
      jsonDecode(await File(_filePathOf(packagesFile)).readAsString()) as Map;
  final roots = <String, _PackageRoot>{};
  for (final entry in (config['packages'] as List).cast<Map>()) {
    var root = entry['rootUri'] as String;
    if (root.startsWith(multiRootPrefix)) {
      root = root.substring(multiRootPrefix.length);
    }
    if (root.isNotEmpty && !root.endsWith('/')) root = '$root/';
    final packageUri = (entry['packageUri'] as String?) ?? 'lib/';
    roots[entry['name'] as String] = _PackageRoot(root, packageUri);
  }
  return roots;
}

class _PackageRoot {
  const _PackageRoot(this.path, this.packageUri);

  /// The `rootUri` with its scheme removed, ending in `/` unless empty.
  final String path;

  /// The `packageUri`, ending in `/`.
  final String packageUri;
}

/// Expands `@params` arguments in one-shot mode, one argument per line.
Future<List<String>> _expandParamFiles(List<String> args) async {
  final out = <String>[];
  for (final arg in args) {
    if (arg.startsWith('@') && File(arg.substring(1)).existsSync()) {
      final lines = await File(arg.substring(1)).readAsLines();
      out.addAll(lines);
    } else {
      out.add(arg);
    }
  }
  return out;
}

/// The result of one `kernel_worker` run.
class ModuleOutcome {
  const ModuleOutcome(this.exitCode, this.output);

  final int exitCode;
  final String output;
}

/// Runs `kernel_worker` with a full argument list. `inputs` are the Bazel
/// `WorkRequest.inputs` of the request. They are passed on unchanged, so the child
/// receives the request Bazel would have sent it.
abstract class ModuleCompiler {
  Future<ModuleOutcome> run(List<String> args, List<Uint8List> inputs);

  Future<void> close();
}

/// One `kernel_worker` invocation's `--input-summary` files, and the subset the
/// worker reports it used, or null when no report exists.
class _UsedReport {
  _UsedReport(this.passed, this.reported);

  /// Every `--input-summary` the invocation passed, canonicalized.
  final Set<String> passed;

  /// The canonicalized `--used-inputs` report, or null when the worker wrote
  /// none (an older `kernel_worker`, or a fake compiler in tests). Then every
  /// passed summary counts as used.
  final Set<String>? reported;
}

/// Records per-invocation `--used-inputs` reports for the unused-inputs list.
///
/// Wraps the real [ModuleCompiler]: each invocation gets its own
/// `--used-inputs` file under the module's output directory, read back and
/// deleted right after the invocation, so the output tree holds it only
/// transiently. A worker that rejects `--used-inputs` as an unknown option is
/// an older SDK: the invocation is retried without the flag, later invocations
/// skip it, and every passed summary counts as used.
class _UsedInputsReporter implements ModuleCompiler {
  _UsedInputsReporter(this._inner, this._outputDir);

  final ModuleCompiler _inner;
  final String _outputDir;
  final records = <_UsedReport>[];
  var _invocations = 0;

  /// False once a worker rejects `--used-inputs`, so later invocations of this
  /// action skip it. An older SDK pays one rejected invocation per action.
  var _supportsUsedInputs = true;

  /// `package:args` rejecting an unknown option.
  static final _unknownOption = RegExp('Could not find an option');

  @override
  Future<ModuleOutcome> run(List<String> args, List<Uint8List> inputs) async {
    final passed = <String>{};
    for (var i = 0; i + 1 < args.length; i++) {
      if (args[i] == '--input-summary') {
        passed.add(_canonicalActionPath(args[i + 1]));
      }
    }
    if (!_supportsUsedInputs) {
      records.add(_UsedReport(passed, null));
      return _inner.run(args, inputs);
    }
    final tmp = _canonicalActionPath(
      '$_outputDir/.used-inputs-${_invocations++}.tmp',
    );
    ModuleOutcome outcome;
    Set<String>? reported;
    try {
      outcome = await _inner.run([
        ...args,
        // A native path on every OS: the worker opens this with `File()`
        // (frontend_server's compute_kernel.dart), which rejects `file://`
        // URIs (on Windows: errno 123). Only URI-bearing flags the worker
        // resolves with `Uri.base.resolve` go through [kernelWorkerUri].
        '--used-inputs=$tmp',
      ], inputs);
      if (outcome.exitCode != 0 &&
          outcome.output.contains('used-inputs') &&
          _unknownOption.hasMatch(outcome.output)) {
        // An older `kernel_worker`: retry without the flag, and stop asking.
        _supportsUsedInputs = false;
        outcome = await _inner.run(args, inputs);
      } else {
        reported = _readUsedInputs(tmp);
      }
    } finally {
      try {
        File(tmp).deleteSync();
      } on FileSystemException {
        // The compile owns its outputs; a stale report only costs precision.
      }
    }
    records.add(_UsedReport(passed, reported));
    return outcome;
  }

  @override
  Future<void> close() => _inner.close();
}

/// The canonical absolute form of an action path or `file://` URI: `file://`
/// URIs become paths, relative paths resolve against the execution root (this
/// process runs with it as its working directory), `.`/`..` segments are
/// applied, and symlinks resolve to one physical spelling. That last step is
/// what lets a relative path and an absolute URI name the same file: `getcwd`
/// spells the working directory physically (`/private/var/...` on macOS, where
/// `/var` is a symlink), while the worker reports the caller's logical spelling
/// (`/var/...`). Without it the same file has two spellings and the
/// foreign-report tripwire fires on every precise report. The same holds on
/// Windows, where the working directory may sit behind a symlink or junction:
/// drive-letter paths resolve to one physical spelling too, with separators
/// and drive-letter case normalized. Compares `--used-inputs` report lines
/// with the paths this action passed to `kernel_worker`.
String _canonicalActionPath(String pathOrUri) {
  final slash = _filePathOf(pathOrUri).replaceAll(r'\', '/');
  if (isWindowsDrivePath(slash)) {
    return _resolveActionPathSymlinks(_normalizeDrivePath(_normalize(slash)));
  }
  // `_normalize` drops empty segments, including the leading one: restore the
  // root, so an absolute path stays absolute. A relative tmp or report path
  // would otherwise resolve against whatever directory the caller runs in
  // instead of the execution root.
  if (slash.startsWith('/'))
    return _resolveActionPathSymlinks('/${_normalize(slash)}');
  final cwd = Directory.current.path.replaceAll(r'\', '/');
  final joined = _normalize('$cwd/$slash');
  // `_normalize` drops the leading segment too: a posix absolute working
  // directory must stay absolute (a Windows drive letter survives as a segment,
  // so only posix needs the root restored). Without this, a relative action
  // path canonicalizes differently from the absolute `file://` URI the worker
  // reports for the same file, and the foreign-report tripwire fires on every
  // precise report.
  // A UNC working directory keeps its double-slash root, so an absolute
  // report spelling still matches a relative action path through it.
  if (cwd.startsWith('//')) return _resolveActionPathSymlinks('//${joined}');
  if (cwd.startsWith('/')) return _resolveActionPathSymlinks('/$joined');
  if (isWindowsDrivePath(cwd)) {
    return _resolveActionPathSymlinks(_normalizeDrivePath(joined));
  }
  return joined;
}

/// [path] with an upper-case Windows drive letter (`c:/...` becomes `C:/...`),
/// so drive-letter spellings compare equal whatever case named them.
String _normalizeDrivePath(String path) {
  if (isWindowsDrivePath(path)) {
    final drive = path.codeUnitAt(0);
    if (drive >= 0x61 && drive <= 0x7a) {
      return '${String.fromCharCode(drive - 0x20)}${path.substring(1)}';
    }
  }
  return path;
}

/// A path `File.resolveSymbolicLinksSync` returned, in slash spelling: native
/// separators become `/`, and a verbatim `\\?\` prefix (an extended-length
/// `\\?\C:\...` path or a `\\?\UNC\...` device path) is removed, so a verbatim
/// spelling compares equal with the plain one it names.
String _normalizeResolvedPath(String resolved) {
  var slash = resolved.contains(r'\')
      ? resolved.replaceAll(r'\', '/')
      : resolved;
  if (slash.startsWith('//?/')) {
    slash = slash.substring(4);
    if (slash.startsWith('UNC/')) {
      // A `\\?\UNC\server\share` device path names the `\\server\share` UNC
      // root: keep the double slash so it matches the plain UNC spelling.
      slash = '/${slash.substring(3)}';
    }
  }
  return slash;
}

/// [normalized] (an absolute path with `.`/`..` applied, posix or Windows
/// drive-letter) with every symlink resolved, so two spellings of one file
/// compare equal. The file itself may not exist (a summary that was never
/// written, a report file not yet created), so the longest existing prefix
/// resolves and the rest is re-appended. Anything unresolvable keeps its
/// normalized spelling: still consistent for identical inputs, just not
/// symlink-proof.
String _resolveActionPathSymlinks(String normalized) {
  final isDrive = isWindowsDrivePath(normalized);
  if (!isDrive && !normalized.startsWith('/')) return normalized;
  final parts = normalized.split('/');
  // A bare drive root (`C:`) names the drive's working directory, which
  // resolves elsewhere: only resolve prefixes below the root.
  final floor = isDrive ? 2 : 1;
  for (var end = parts.length; end > floor; end--) {
    final prefix = parts.sublist(0, end).join('/');
    String resolved;
    try {
      resolved = File(prefix.isEmpty ? '/' : prefix).resolveSymbolicLinksSync();
    } on FileSystemException {
      continue;
    }
    resolved = _normalizeDrivePath(_normalizeResolvedPath(resolved));
    final rest = parts.sublist(end).join('/');
    final combined = rest.isEmpty ? resolved : '$resolved/$rest';
    if (isWindowsDrivePath(combined)) {
      return _normalizeDrivePath(_normalize(combined));
    }
    // A UNC spelling keeps its double-slash root through normalization.
    if (combined.startsWith('//')) return '//${_normalize(combined)}';
    return combined.startsWith('/') ? '/${_normalize(combined)}' : combined;
  }
  return normalized;
}

/// The canonicalized lines of the `--used-inputs` file the worker wrote, or
/// null when it wrote none.
Set<String>? _readUsedInputs(String path) {
  final file = File(path);
  if (!file.existsSync()) return null;
  try {
    final used = <String>{};
    for (final line in file.readAsLinesSync()) {
      final trimmed = line.trim();
      if (trimmed.isNotEmpty) used.add(_canonicalActionPath(trimmed));
    }
    return used;
  } on FileSystemException {
    // An unreadable report (file reads surface malformed UTF-8 as a
    // file-system error too) proves nothing: fall back to the plan.
    return null;
  } on FormatException {
    // A report line naming no URI the planner understands (such as a
    // malformed `file://` URI) proves nothing either: same fallback.
    return null;
  }
}

/// The package (or bare first segment) of a module key.
String _packageOfKey(String key) {
  final slash = key.indexOf('/');
  return slash < 0 ? key : key.substring(0, slash);
}

/// Whether the entry's output embeds only the sources it planned to compile.
///
/// The front end embeds a dependency source it was never passed to compile
/// (a mixin a compiled library applies, say), and the planner resolves some
/// directive spellings differently than the front end does. Either case reads
/// a declared dependency source outside [planned]; then no dependency source
/// is listed as unused. Unmappable URIs (`dart:`, the SDK) are never listed
/// anyway. A missing or unreadable output proves nothing, and lists nothing.
Future<bool> _entryReadsArePlanned(
  String entryDill,
  Set<String> planned,
  List<String> multiRoots,
  String multiRootPrefix,
) async {
  final dillFile = File(entryDill);
  if (!await dillFile.exists()) return false;
  final uris = dillSourceUris(await dillFile.readAsBytes());
  if (uris == null) return false;
  for (final uri in uris) {
    final key = _keyOfDillSourceUri(uri, multiRoots, multiRootPrefix);
    if (key != null && !planned.contains(key)) return false;
  }
  return true;
}

/// Writes the Bazel `unused_inputs_list` file at [unusedInputsPath]: the
/// execution-root-relative paths of the declared inputs no compile of this
/// action read. Writes an empty file when everything was read.
///
/// A dependency module directory is listed only when no invocation used a
/// summary it holds (reported, or every passed one when no report exists),
/// none of its keys is referenced (by a used summary, by an own source, which
/// a shadowing dependency would drop from the compile, or by an entry key,
/// which an adopted part peer embeds), none shares an own source's package,
/// none shares the package of a dependency key a plan decision consulted
/// while removing a source from the compile (an exclusion target, an adopted
/// part peer, a missing closure key: renaming a file into such a name
/// recompiles the dependency but must recompile this module too), no kernel
/// this action wrote embeds a source it staged or defined ([outputDills],
/// plus [entryDill]), and it stages no excluded source this action reads or
/// scans. A dependency source of an entry module is listed only when the entry
/// neither compiled it nor scanned it for a `part of` library name, and its
/// output embeds nothing unplanned.
/// Anything else (own sources, configs, sidecars, the toolchain) is never
/// listed. A report naming a file the action never passed fails closed to an
/// empty list, as does a written kernel whose source table names a file no
/// known input maps to, or names no table at all.
Future<void> _writeUnusedInputsList({
  required String unusedInputsPath,
  required List<_UsedReport> reports,
  required List<String> inputKmods,
  required Map<String, _Node> graph,
  required Map<String, String> inherited,
  required Map<String, String> stagedSources,
  required Set<String> ownKeys,
  required Set<String> consultedTargets,
  required String output,
  required String? outputOutline,
  required Set<String>? entryKeys,
  required bool lookedUpLibraryNames,
  required List<String> inputSources,
  required Set<String> ownSourceFiles,
  required List<String> multiRoots,
  required String? entryDill,
  required List<String> outputDills,
  required Set<String> declaredKeys,
  required String multiRootPrefix,
}) async {
  final lines =
      await _unusedInputsLines(
        reports: reports,
        inputKmods: inputKmods,
        graph: graph,
        inherited: inherited,
        stagedSources: stagedSources,
        ownKeys: ownKeys,
        consultedTargets: consultedTargets,
        output: output,
        outputOutline: outputOutline,
        entryKeys: entryKeys,
        lookedUpLibraryNames: lookedUpLibraryNames,
        inputSources: inputSources,
        ownSourceFiles: ownSourceFiles,
        multiRoots: multiRoots,
        entryDill: entryDill,
        outputDills: outputDills,
        declaredKeys: declaredKeys,
        multiRootPrefix: multiRootPrefix,
      ) ??
      const <String>[];
  final file = File(unusedInputsPath);
  await file.parent.create(recursive: true);
  await file.writeAsString(lines.isEmpty ? '' : '${lines.join('\n')}\n');
}

/// The unused input lines [_writeUnusedInputsList] writes, or null when a
/// report names a file the action never passed, or when a kernel this action
/// wrote embeds a source no known input maps to (or no readable source table).
Future<List<String>?> _unusedInputsLines({
  required List<_UsedReport> reports,
  required List<String> inputKmods,
  required Map<String, _Node> graph,
  required Map<String, String> inherited,
  required Map<String, String> stagedSources,
  required Set<String> ownKeys,
  required Set<String> consultedTargets,
  required String output,
  required String? outputOutline,
  required Set<String>? entryKeys,
  required bool lookedUpLibraryNames,
  required List<String> inputSources,
  required Set<String> ownSourceFiles,
  required List<String> multiRoots,
  required String? entryDill,
  required List<String> outputDills,
  required Set<String> declaredKeys,
  required String multiRootPrefix,
}) => _UnusedInputs(
  reports: reports,
  inputKmods: inputKmods,
  graph: graph,
  inherited: inherited,
  stagedSources: stagedSources,
  ownKeys: ownKeys,
  consultedTargets: consultedTargets,
  output: output,
  outputOutline: outputOutline,
  entryKeys: entryKeys,
  lookedUpLibraryNames: lookedUpLibraryNames,
  inputSources: inputSources,
  ownSourceFiles: ownSourceFiles,
  multiRoots: multiRoots,
  entryDill: entryDill,
  outputDills: outputDills,
  declaredKeys: declaredKeys,
  multiRootPrefix: multiRootPrefix,
).compute();

/// Computes the unused input lines [_writeUnusedInputsList] writes.
class _UnusedInputs {
  _UnusedInputs({
    required this.reports,
    required this.inputKmods,
    required this.graph,
    required this.inherited,
    required this.stagedSources,
    required this.ownKeys,
    required this.consultedTargets,
    required this.output,
    required this.outputOutline,
    required this.entryKeys,
    required this.lookedUpLibraryNames,
    required this.inputSources,
    required this.ownSourceFiles,
    required this.multiRoots,
    required this.entryDill,
    required this.outputDills,
    required this.declaredKeys,
    required this.multiRootPrefix,
  });

  final List<_UsedReport> reports;
  final List<String> inputKmods;
  final Map<String, _Node> graph;
  final Map<String, String> inherited;
  final Map<String, String> stagedSources;
  final Set<String> ownKeys;
  final Set<String> consultedTargets;
  final String output;
  final String? outputOutline;
  final Set<String>? entryKeys;
  final bool lookedUpLibraryNames;
  final List<String> inputSources;
  final Set<String> ownSourceFiles;
  final List<String> multiRoots;
  final String? entryDill;
  final List<String> outputDills;
  final Set<String> declaredKeys;
  final String multiRootPrefix;

  /// Every summary an invocation used.
  final _used = <String>{};

  // A module that defines a key this action compiles is linked for it (a
  // shadowing dependency) or embeds it (an entry's adopted part peer), so its
  // keys count as referenced alongside the own ones.
  late final _referenced = <String>{...ownKeys, ...?entryKeys};
  final _usedTrees = <String>{};
  final _keepTrees = <String>{};

  late final _outputRoots = <String>{
    _canonicalActionPath(output),
    if (outputOutline != null) _canonicalActionPath(outputOutline!),
  };
  late final _keysOfDill = _indexKeysOfDill(graph);
  late final _canonicalKmods = <String, String>{
    for (final dir in inputKmods) dir: _canonicalActionPath(dir),
  };
  late final _ownPackages = {for (final key in ownKeys) _packageOfKey(key)};

  // A plan decision that removes a source from the compile still read the
  // dependency key it decided about. Renaming a file into such a name
  // recompiles the dependency but must recompile this module too, so a
  // module sharing one of those keys' packages is never listed as unused.
  late final _consultedPackages = {
    for (final key in consultedTargets) _packageOfKey(key),
  };

  /// The lines, or null when a report names a file the action never passed,
  /// or when a written kernel embeds an unmapped source (or no readable
  /// source table).
  Future<List<String>?> compute() async {
    if (!_collectUsedReports()) return null;
    _markUsedTrees();
    if (!await _collectEvidenceVeto()) return null;
    final lines = _listUnusedModules();
    await _listUnusedEntrySources(lines);
    return lines;
  }

  bool _isOwnOutput(String path) =>
      _outputRoots.any((root) => path == root || path.startsWith('$root/'));

  /// Folds every used report into [_used], failing closed when a reported
  /// file is neither a passed summary nor the action's own output.
  bool _collectUsedReports() {
    for (final report in reports) {
      final reported = report.reported;
      if (reported == null) {
        _used.addAll(report.passed);
        continue;
      }
      for (final path in reported) {
        if (!report.passed.contains(path) && !_isOwnOutput(path)) {
          return false;
        }
      }
      _used.addAll(reported);
    }
    return true;
  }

  /// Marks the summaries the invocations used as referenced, with their trees.
  void _markUsedTrees() {
    for (final path in _used) {
      final keys = _keysOfDill[path];
      if (keys == null) continue;
      _referenced.addAll(keys);
      for (final entry in _canonicalKmods.entries) {
        if (path == entry.value || path.startsWith('${entry.value}/')) {
          _usedTrees.add(entry.value);
        }
      }
    }
  }

  /// Keeps the module directory that staged or defined every source a kernel
  /// this action wrote embedded. The dill's source table cannot drift from
  /// what the compile read — an adopted part peer, a folded constant, a
  /// re-export, a mixin, an augmentation — so a dependency whose bytes the
  /// output holds is never listed, however the plan classified the file. A
  /// source no known input maps to, or a table that cannot be read, fails
  /// closed to no list. A missing output (a recording test compiler, which
  /// writes none) proves nothing, and the report and plan checks still apply.
  Future<bool> _collectEvidenceVeto() async {
    final entry = entryDill;
    for (final dillPath in [...outputDills, if (entry != null) entry]) {
      final dillFile = File(dillPath);
      if (!await dillFile.exists()) continue;
      final uris = dillSourceUris(await dillFile.readAsBytes());
      if (uris == null) return false;
      for (final uri in uris) {
        if (!_vetoEvidenceOwner(uri)) return false;
      }
    }
    return true;
  }

  /// Keeps the owner of one embedded source. Reports whether it has one.
  bool _vetoEvidenceOwner(String uri) {
    final key = _keyOfDillSourceUri(uri, multiRoots, multiRootPrefix);
    if (key == null) return true;
    if (ownKeys.contains(key) || (entryKeys?.contains(key) ?? false)) {
      return true;
    }
    final stagedRoot = stagedSources[key];
    if (stagedRoot != null) {
      final owner = _ownerStaging(stagedRoot);
      if (owner == null) return false;
      _keepTrees.add(owner);
      return true;
    }
    if (graph.containsKey(key)) {
      final owner = _ownerDefining(key);
      if (owner == null) return false;
      _keepTrees.add(owner);
      return true;
    }
    if (declaredKeys.contains(key)) return true;
    return false;
  }

  /// The module directory whose staged sources hold [stagedRoot], if any.
  String? _ownerStaging(String stagedRoot) {
    for (final dir in inputKmods) {
      if ('$dir/sources' == stagedRoot) return dir;
    }
    return null;
  }

  /// The module directory whose summary defines [key], if any.
  String? _ownerDefining(String key) {
    final dill = _canonicalActionPath(graph[key]!.dill);
    for (final entry in _canonicalKmods.entries) {
      if (dill == entry.value || dill.startsWith('${entry.value}/')) {
        return entry.key;
      }
    }
    return null;
  }

  /// The input module directories no check keeps.
  List<String> _listUnusedModules() {
    final lines = <String>[];
    for (final dir in inputKmods) {
      if (_isModuleUsed(dir)) continue;
      lines.add(dir);
    }
    return lines;
  }

  /// Whether [dir] is used, referenced, package-shared, or stages inheritance.
  bool _isModuleUsed(String dir) {
    final canonical = _canonicalKmods[dir]!;
    if (_usedTrees.contains(canonical)) return true;
    if (_keepTrees.contains(dir)) return true;
    var defines = false;
    var definesReferenced = false;
    var sharesOwnPackage = false;
    var sharesConsultedPackage = false;
    for (final entry in _keysOfDill.entries) {
      final dill = entry.key;
      if (dill != canonical && !dill.startsWith('$canonical/')) continue;
      for (final key in entry.value) {
        defines = true;
        if (_referenced.contains(key)) definesReferenced = true;
        if (_ownPackages.contains(_packageOfKey(key))) {
          sharesOwnPackage = true;
        }
        if (_consultedPackages.contains(_packageOfKey(key))) {
          sharesConsultedPackage = true;
        }
      }
    }
    // A module directory that defines nothing has no summary to use, but its
    // index still feeds the plan, so only a directory that defines an
    // unreferenced library outside the own and consulted packages is listed.
    if (!defines ||
        definesReferenced ||
        sharesOwnPackage ||
        sharesConsultedPackage) {
      return true;
    }
    final stagedPrefix = '$dir/sources';
    for (final staged in stagedSources.entries) {
      if (staged.value == stagedPrefix && inherited.containsKey(staged.key)) {
        return true;
      }
    }
    return false;
  }

  /// Lists the dependency sources of an entry module the entry neither
  /// compiled nor scanned for a `part of` library name, when its output
  /// embeds nothing unplanned.
  Future<void> _listUnusedEntrySources(List<String> lines) async {
    if (entryKeys == null ||
        lookedUpLibraryNames ||
        entryDill == null ||
        !await _entryReadsArePlanned(
          entryDill!,
          entryKeys!,
          multiRoots,
          multiRootPrefix,
        )) {
      return;
    }
    final seen = <String>{};
    for (final path in inputSources) {
      if (!seen.add(path) || ownSourceFiles.contains(path)) continue;
      if (!_isEntryVisited(path)) lines.add(path);
    }
  }

  /// Whether the entry's keys visit [path] under any of its spellings.
  bool _isEntryVisited(String path) {
    for (final spelling in _inputSpellings(path, multiRoots)) {
      if (entryKeys!.contains(spelling)) return true;
    }
    return false;
  }
}

/// Indexes closure keys by the canonical path of the summary defining them.
Map<String, Set<String>> _indexKeysOfDill(Map<String, _Node> graph) {
  final keysOfDill = <String, Set<String>>{};
  for (final entry in graph.entries) {
    keysOfDill
        .putIfAbsent(_canonicalActionPath(entry.value.dill), () => <String>{})
        .add(entry.key);
  }
  return keysOfDill;
}

/// One `kernel_worker` process per compile.
class _OneShot implements ModuleCompiler {
  _OneShot(
    this._dartaotruntime,
    this._kernelWorker, {
    bool snapshotPatched = false,
  }) : _snapshotPatched = snapshotPatched;

  final String _dartaotruntime;
  final String _kernelWorker;

  /// Whether [_kernelWorker] is the comma-patched snapshot the toolchain's
  /// declared patch action produced, rather than the SDK's pristine one.
  final bool _snapshotPatched;

  @override
  Future<ModuleOutcome> run(List<String> args, List<Uint8List> inputs) async {
    final workerArgs = kernelWorkerArgs(args);
    final error = unpatchedCommaDefinesError(
      workerArgs,
      snapshotPatched: _snapshotPatched,
      snapshotKind: 'kernel_worker',
      toolName: 'kernel_module',
    );
    if (error != null) return ModuleOutcome(1, '$error\n');
    final result = await Process.run(_dartaotruntime, [
      _kernelWorker,
      ...workerArgs,
    ]);
    return ModuleOutcome(result.exitCode, '${result.stdout}${result.stderr}');
  }

  @override
  Future<void> close() async {}
}

/// One `kernel_worker` child, kept running across requests.
///
/// A child that cannot be trusted is killed and replaced, and its request is sent
/// once more to the new child. That is after the child dies; after a request that runs
/// past the timeout, which a wedged child does; after bytes that are not the
/// `WorkResponse` to the request; and after a crash, since the child then never answers
/// its next request. A compile writes only its own outputs, so repeating it is safe.
/// A request that fails again on the new child fails the action with both reasons.
class _Persistent implements ModuleCompiler {
  _Persistent(
    this._dartaotruntime,
    this._kernelWorker, {
    bool snapshotPatched = false,
    Duration? requestTimeout,
  }) : _snapshotPatched = snapshotPatched,
       _requestTimeout = requestTimeout ?? _defaultRequestTimeout;

  /// Far above the compile of one library. A request that takes longer is wedged.
  /// `--request-timeout-seconds` replaces it, so a test can exercise a wedged child
  /// without waiting this long.
  static const _defaultRequestTimeout = Duration(minutes: 15);

  /// What the compiler prints for a crash.
  static const _crashMarker = 'Crash when compiling';

  final String _dartaotruntime;
  final String _kernelWorker;

  /// Whether [_kernelWorker] is the comma-patched snapshot the toolchain's
  /// declared patch action produced, rather than the SDK's pristine one.
  final bool _snapshotPatched;

  final Duration _requestTimeout;
  Process? _child;
  _Frames? _responses;

  /// The `request_id` of every request. Bazel sends a worker that is not multiplexed
  /// request 0, and `kernel_worker` answers with the id it was sent.
  static const _requestId = 0;

  /// The child's stderr, kept for the failure message of a child that dies.
  final _stderr = StringBuffer();

  @override
  Future<ModuleOutcome> run(List<String> args, List<Uint8List> inputs) async {
    // Digested before the child is written to, so a file that cannot be read fails the
    // request with its reason, not as a child that died.
    final workerArgs = kernelWorkerArgs(args);
    final error = unpatchedCommaDefinesError(
      workerArgs,
      snapshotPatched: _snapshotPatched,
      snapshotKind: 'kernel_worker',
      toolName: 'kernel_module',
    );
    if (error != null) return ModuleOutcome(1, '$error\n');
    final withDigests = await _withDigests(workerArgs, inputs);
    final first = await _attempt(workerArgs, withDigests);
    if (!first.lost) return first.outcome;
    final second = await _attempt(workerArgs, withDigests);
    if (second.lost) {
      return ModuleOutcome(
        second.outcome.exitCode,
        'Failed twice, on a fresh kernel_worker each time.\n'
        'First attempt: ${first.outcome.output}\nSecond attempt: '
        '${second.outcome.output}',
      );
    }
    return second.outcome;
  }

  /// Sends one request to the running child, or to a new one, and reads its answer.
  Future<_Attempt> _attempt(List<String> args, List<Uint8List> inputs) async {
    final child = await _start();
    try {
      child.stdin.add(_frame(_encodeRequest(args, inputs, _requestId)));
      await child.stdin.flush();
    } on StateError {
      // A child that died before reading the request: the read below reports it.
    } on FileSystemException {
      // A broken pipe to a dead child: the read below reports it too.
    }
    try {
      final frame = await _responses!.next().timeout(_requestTimeout);
      if (frame == null) {
        await _reap();
        return _Attempt(
          ModuleOutcome(1, 'kernel_worker exited before responding.\n$_stderr'),
          lost: true,
        );
      }
      final response = _WorkResponse.decode(frame);
      if (response.requestId != _requestId) {
        throw FormatException(
          'it answered request ${response.requestId}, not request $_requestId',
        );
      }
      final outcome = ModuleOutcome(response.exitCode, response.output);
      final crashed =
          outcome.exitCode != 0 && outcome.output.contains(_crashMarker);
      if (crashed) await _reap();
      return _Attempt(outcome, lost: crashed);
    } on TimeoutException {
      await _reap();
      return _Attempt(
        ModuleOutcome(
          1,
          'kernel_worker did not answer within $_requestTimeout, so it was '
          'killed.\n$_stderr',
        ),
        lost: true,
      );
    } on FormatException catch (error) {
      // Undecodable bytes (bad UTF-8, an unknown wire type, or an answer to
      // another request): the child cannot be trusted, so it is reaped and
      // the request is repeated on a fresh child.
      return _lostChildResponse(error);
    } on RangeError catch (error) {
      // A frame truncated mid-field reads past its bytes: same lost child.
      return _lostChildResponse(error);
    }
  }

  /// Reaps a child that answered with bytes that are not a `WorkResponse` and
  /// reports the request as lost, so it runs again on a fresh child. Only
  /// decoding failures reach here: a write to a dead child is swallowed above
  /// (the read then reports it), an ended stdout reads as null, and a late
  /// answer is a `TimeoutException`. Anything else escapes to the worker
  /// loop, which logs it and fails the request.
  Future<_Attempt> _lostChildResponse(Object error) async {
    await _reap();
    return _Attempt(
      ModuleOutcome(
        1,
        'kernel_worker sent bytes that are not a WorkResponse ($error), so it was '
        'killed.\n$_stderr',
      ),
      lost: true,
    );
  }

  Future<Process> _start() async {
    final running = _child;
    if (running != null) return running;
    final child = await Process.start(_dartaotruntime, [
      _kernelWorker,
      _persistentFlag,
    ]);
    _stderr.clear();
    child.stderr.transform(utf8.decoder).listen(_stderr.write);
    _child = child;
    _responses = _Frames(child.stdout);
    return child;
  }

  /// Kills the child and waits for it to exit. The kill is SIGKILL: a stopped child
  /// does not act on SIGTERM until it is continued, so waiting after SIGTERM could wait
  /// forever.
  Future<void> _reap() async {
    final child = _child;
    _child = null;
    if (child == null) return;
    child.kill(ProcessSignal.sigkill);
    unawaited(child.stdin.close().catchError((Object _) {}));
    await child.exitCode;
  }

  @override
  Future<void> close() => _reap();
}

/// One attempt at a request. `lost` is set when the child died, wedged, or answered
/// with bytes that are not the answer, or crashed, so the request is repeated.
class _Attempt {
  _Attempt(this.outcome, {required this.lost});

  final ModuleOutcome outcome;
  final bool lost;
}

/// The startup flag that sets the request timeout, in seconds. A test passes it with
/// `--worker_extra_flag=DartKernel=--request-timeout-seconds=N`.
const _requestTimeoutFlag = '--request-timeout-seconds=';

// ---------------------------------------------------------------------------
// Digests. Bazel 9.3.0 expands tree artifacts (`declare_directory`, such as
// `.kmod` and `.koutline` directories) in `WorkRequest.inputs` into individual
// `Input` entries with SHA-256 digests for every constituent file (`<dir>/0.dill`,
// `<dir>/index.json`, `<dir>/sources/<key>`). Those digests are forwarded
// directly to `kernel_worker` without re-hashing from disk.
//
// Only files that lack a non-empty digest in `WorkRequest.inputs` — such as
// intra-module SCC kernels produced earlier in the same `compileModule` run
// (which are hashed once in memory when needed) or files in synthetic test
// requests that omit `WorkRequest.inputs` digests — are hashed with `sha256Of`.

/// The SHA-256 digest of the file at `path`.
Future<Uint8List> _digestOf(String path) async =>
    sha256Of(await File(_filePathOf(path)).readAsBytes());

/// The `Input` message for a file: its `path` and `digest`.
Uint8List _encodeInput(String path, Uint8List digest) {
  final writer = _Writer()
    ..stringField(1, path)
    ..messageField(2, digest);
  return writer.toBytes();
}

/// Decodes the `path` (field 1) and `digest` (field 2) of a protobuf `Input`
/// message, copying `digest` out of `bytes` so the message buffer is not pinned.
({String path, Uint8List digest}) _decodeInput(Uint8List bytes) {
  final reader = _Reader(bytes);
  var path = '';
  var digest = Uint8List(0);
  while (!reader.done) {
    final key = reader.varint();
    final field = key >> 3;
    final wire = key & 7;
    if (field == 1 && wire == 2) {
      path = utf8.decode(reader.bytes(), allowMalformed: true);
    } else if (field == 2 && wire == 2) {
      digest = Uint8List.fromList(reader.bytes());
    } else {
      reader.skip(wire);
    }
  }
  return (path: path, digest: digest);
}

/// Decodes `path` and a view of `digest` from a single `Input` message without
/// allocating a new `Uint8List` copy for the digest.
({String path, Uint8List digest}) _decodeInputView(Uint8List bytes) {
  final reader = _Reader(bytes);
  var path = '';
  var digest = _emptyBytes;
  while (!reader.done) {
    final key = reader.varint();
    final field = key >> 3;
    final wire = key & 7;
    if (field == 1 && wire == 2) {
      path = utf8.decode(reader.bytes(), allowMalformed: true);
    } else if (field == 2 && wire == 2) {
      digest = reader.bytes();
    } else {
      reader.skip(wire);
    }
  }
  return (path: path, digest: digest);
}

final Uint8List _emptyBytes = Uint8List(0);

/// Public wrapper around [_withDigests] for unit tests.
Future<List<Uint8List>> ensureSummaryDigests(
  List<String> args,
  List<Uint8List> inputs,
) => _withDigests(args, inputs);

/// The request's `inputs`, with a digest added for each `--input-summary` or
/// `--input-linked` file that does not already carry a non-empty digest in
/// `inputs`. If `inputs` already has a non-empty digest under a normalized
/// spelling of the path (such as `./<path>` vs `<path>`), that digest is reused
/// without reading or hashing the file from disk.
Future<List<Uint8List>> _withDigests(
  List<String> args,
  List<Uint8List> inputs,
) async {
  if (!_takesSummaryInputs(args)) return inputs;

  final exactWithDigest = _exactDigestedPaths(inputs);
  if (_summaryDigestsComplete(args, exactWithDigest)) return inputs;

  final emptyDigestIndices = <String, List<int>>{};
  final byPath = <String, Uint8List>{};
  for (var idx = 0; idx < inputs.length; idx++) {
    _indexInputDigest(byPath, emptyDigestIndices, inputs[idx], idx);
  }
  List<Uint8List>? out;
  for (var i = 0; i + 1 < args.length; i++) {
    if (args[i] != '--input-summary' && args[i] != '--input-linked') continue;
    final rawPath = args[i + 1];
    final targetPath = kernelWorkerUri(rawPath);
    final filePath = _filePathOf(rawPath);
    if (!exactWithDigest.add(targetPath)) continue;
    final digest = await _resolveTargetDigest(targetPath, filePath, byPath);
    out ??= [...inputs];
    _placeDigest(out, targetPath, digest, filePath, emptyDigestIndices);
  }
  return out ?? inputs;
}

/// Whether any `--input-summary` or `--input-linked` file is requested.
bool _takesSummaryInputs(List<String> args) {
  for (var i = 0; i + 1 < args.length; i++) {
    final arg = args[i];
    if (arg == '--input-summary' || arg == '--input-linked') return true;
  }
  return false;
}

/// The exact input paths that already carry a non-empty digest.
Set<String> _exactDigestedPaths(List<Uint8List> inputs) {
  final exactWithDigest = <String>{};
  for (var idx = 0; idx < inputs.length; idx++) {
    final decoded = _decodeInputView(inputs[idx]);
    if (decoded.path.isNotEmpty && decoded.digest.isNotEmpty) {
      exactWithDigest.add(decoded.path);
    }
  }
  return exactWithDigest;
}

/// Whether every requested summary or linked file is already digested.
bool _summaryDigestsComplete(List<String> args, Set<String> exactWithDigest) {
  for (var i = 0; i + 1 < args.length; i++) {
    final arg = args[i];
    if (arg != '--input-summary' && arg != '--input-linked') continue;
    if (!exactWithDigest.contains(kernelWorkerUri(args[i + 1]))) return false;
  }
  return true;
}

/// Indexes one input's digest under its path spellings, or records the indices
/// whose digest still needs filling in.
void _indexInputDigest(
  Map<String, Uint8List> byPath,
  Map<String, List<int>> emptyDigestIndices,
  Uint8List input,
  int idx,
) {
  final decoded = _decodeInput(input);
  if (decoded.path.isEmpty) return;
  if (decoded.digest.isNotEmpty) {
    byPath[decoded.path] = decoded.digest;
    _indexDigestSpellings(byPath, decoded.path, decoded.digest);
  } else {
    (emptyDigestIndices[decoded.path] ??= <int>[]).add(idx);
    final uriSpelling = kernelWorkerUri(decoded.path);
    if (uriSpelling != decoded.path) {
      (emptyDigestIndices[uriSpelling] ??= <int>[]).add(idx);
    }
  }
}

/// Indexes a digest under every spelling of its path the worker may use.
void _indexDigestSpellings(
  Map<String, Uint8List> byPath,
  String path,
  Uint8List digest,
) {
  final fileSpelling = _filePathOf(path);
  byPath.putIfAbsent(fileSpelling, () => digest);
  byPath.putIfAbsent(kernelWorkerUri(fileSpelling), () => digest);
  final norm = normalizePath(fileSpelling);
  byPath.putIfAbsent(norm, () => digest);
  byPath.putIfAbsent(kernelWorkerUri(norm), () => digest);
  final relNorm = _normalize(fileSpelling);
  if (relNorm.isNotEmpty &&
      !isWindowsDrivePath(fileSpelling) &&
      !fileSpelling.startsWith('/')) {
    byPath.putIfAbsent(relNorm, () => digest);
    byPath.putIfAbsent('./$relNorm', () => digest);
  }
}

/// The digest for a requested file: reused from the index, else hashed from
/// disk, then memoized under both spellings for later requests.
Future<Uint8List> _resolveTargetDigest(
  String targetPath,
  String filePath,
  Map<String, Uint8List> byPath,
) async {
  final digest =
      _lookupDigest(targetPath, byPath) ??
      _lookupDigest(filePath, byPath) ??
      await _digestOf(filePath);
  byPath[targetPath] = digest;
  byPath[filePath] = digest;
  return digest;
}

/// Replaces the inputs still missing a digest, or appends a new digested input.
void _placeDigest(
  List<Uint8List> out,
  String targetPath,
  Uint8List digest,
  String filePath,
  Map<String, List<int>> emptyDigestIndices,
) {
  final replaceIndices =
      emptyDigestIndices.remove(targetPath) ??
      emptyDigestIndices.remove(filePath);
  if (replaceIndices != null && replaceIndices.isNotEmpty) {
    final encoded = _encodeInput(targetPath, digest);
    for (final idx in replaceIndices) {
      out[idx] = encoded;
    }
  } else {
    out.add(_encodeInput(targetPath, digest));
  }
}

// ---------------------------------------------------------------------------
// The Bazel worker protocol: varint-length-prefixed protobuf messages. Only the
// fields this tool reads or writes are handled, and the rest are skipped.

/// Reads varint-length-prefixed frames from a byte stream.
class _Frames {
  _Frames(Stream<List<int>> source) : _iterator = StreamIterator(source);

  final StreamIterator<List<int>> _iterator;
  Uint8List _chunk = _emptyBytes;
  int _offset = 0;

  Future<bool> _fill() async {
    while (true) {
      if (!await _iterator.moveNext()) return false;
      final current = _iterator.current;
      if (current.isEmpty) continue;
      _chunk = current is Uint8List ? current : Uint8List.fromList(current);
      _offset = 0;
      return true;
    }
  }

  Future<int?> _varint() async {
    var result = 0;
    var shift = 0;
    while (true) {
      if (_offset >= _chunk.length && !await _fill()) return null;
      final byte = _chunk[_offset++];
      result |= (byte & 0x7f) << shift;
      if (byte < 0x80) return result;
      shift += 7;
    }
  }

  /// The next frame's bytes, or null at end of stream.
  Future<Uint8List?> next() async {
    final length = await _varint();
    if (length == null) return null;
    final out = Uint8List(length);
    var written = 0;
    while (written < length) {
      if (_offset >= _chunk.length && !await _fill()) return null;
      final available = _chunk.length - _offset;
      final need = length - written;
      final count = available < need ? available : need;
      out.setRange(written, written + count, _chunk, _offset);
      _offset += count;
      written += count;
    }
    if (_offset >= _chunk.length) {
      _chunk = _emptyBytes;
      _offset = 0;
    }
    return out;
  }
}

/// Reads one protobuf message.
class _Reader {
  _Reader(this._bytes);

  final Uint8List _bytes;
  int _pos = 0;

  bool get done => _pos >= _bytes.length;

  int varint() {
    var result = 0;
    var shift = 0;
    while (true) {
      final byte = _bytes[_pos++];
      result |= (byte & 0x7f) << shift;
      if (byte < 0x80) return result;
      shift += 7;
    }
  }

  Uint8List bytes() {
    final length = varint();
    final out = Uint8List.sublistView(_bytes, _pos, _pos + length);
    _pos += length;
    return out;
  }

  void skip(int wireType) {
    switch (wireType) {
      case 0:
        varint();
      case 1:
        _pos += 8;
      case 2:
        bytes();
      case 5:
        _pos += 4;
      default:
        throw FormatException('Unsupported protobuf wire type $wireType.');
    }
  }
}

/// Writes one protobuf message. Zero values are omitted, as proto3 does.
class _Writer {
  final _out = BytesBuilder();

  void varintField(int field, int value) {
    if (value == 0) return;
    _addVarint(_out, field << 3);
    _addVarint(_out, value);
  }

  void stringField(int field, String value) {
    if (value.isEmpty) return;
    messageField(field, utf8.encode(value));
  }

  /// A length-delimited field: a string, or an embedded message.
  void messageField(int field, List<int> bytes) {
    _addVarint(_out, (field << 3) | 2);
    _addVarint(_out, bytes.length);
    _out.add(bytes);
  }

  Uint8List toBytes() => _out.toBytes();
}

void _addVarint(BytesBuilder out, int value) {
  var rest = value;
  while (rest >= 0x80) {
    out.addByte((rest & 0x7f) | 0x80);
    rest >>= 7;
  }
  out.addByte(rest);
}

Uint8List _frame(Uint8List message) {
  final out = BytesBuilder();
  _addVarint(out, message.length);
  out.add(message);
  return out.toBytes();
}

/// Decodes the `inputs` list from a raw `WorkRequest` protobuf payload,
/// copying each `Input` entry out of [bytes] so the request buffer is not pinned.
List<Uint8List> decodeKernelModuleWorkRequestInputs(Uint8List bytes) =>
    _WorkRequest.decode(bytes).inputs;

/// `WorkRequest`: `arguments` = 1, `inputs` = 2 (each an `Input` message, kept as
/// an unpinned copy of its bytes so it is forwarded unchanged without pinning
/// the request buffer), `request_id` = 3.
class _WorkRequest {
  _WorkRequest(this.arguments, this.inputs, this.requestId);

  factory _WorkRequest.decode(Uint8List bytes) {
    final reader = _Reader(bytes);
    final arguments = <String>[];
    final inputs = <Uint8List>[];
    var requestId = 0;
    while (!reader.done) {
      final key = reader.varint();
      final field = key >> 3;
      final wire = key & 7;
      if (field == 1 && wire == 2) {
        arguments.add(utf8.decode(reader.bytes()));
      } else if (field == 2 && wire == 2) {
        inputs.add(Uint8List.fromList(reader.bytes()));
      } else if (field == 3 && wire == 0) {
        requestId = reader.varint();
      } else {
        reader.skip(wire);
      }
    }
    return _WorkRequest(arguments, inputs, requestId);
  }

  final List<String> arguments;
  final List<Uint8List> inputs;
  final int requestId;
}

/// The `WorkRequest` for one compile. The child answers with the same `request_id`.
Uint8List _encodeRequest(
  List<String> arguments,
  List<Uint8List> inputs,
  int requestId,
) {
  final writer = _Writer();
  for (final argument in arguments) {
    writer.stringField(1, argument);
  }
  for (final input in inputs) {
    writer.messageField(2, input);
  }
  writer.varintField(3, requestId);
  return writer.toBytes();
}

/// `WorkResponse`: `exit_code` = 1, `output` = 2, `request_id` = 3.
class _WorkResponse {
  _WorkResponse(this.exitCode, this.output, this.requestId);

  factory _WorkResponse.decode(Uint8List bytes) {
    final reader = _Reader(bytes);
    var exitCode = 0;
    var output = '';
    var requestId = 0;
    while (!reader.done) {
      final key = reader.varint();
      final field = key >> 3;
      final wire = key & 7;
      if (field == 1 && wire == 0) {
        exitCode = reader.varint();
      } else if (field == 2 && wire == 2) {
        output = utf8.decode(reader.bytes());
      } else if (field == 3 && wire == 0) {
        requestId = reader.varint();
      } else {
        reader.skip(wire);
      }
    }
    return _WorkResponse(exitCode, output, requestId);
  }

  final int exitCode;
  final String output;
  final int requestId;
}

Uint8List _encodeResponse(int exitCode, String output, int requestId) {
  final writer = _Writer()
    ..varintField(1, exitCode)
    ..stringField(2, output)
    ..varintField(3, requestId);
  return writer.toBytes();
}

/// Strips `Source.sourceCode` UTF-8 bytes from a compiled Kernel `.dill` while
/// preserving `uri`, `lineStarts`, `importUri`, and `constantCoverageConstructors`.
///
/// `kernel_worker` has no `--no-embed-sources` flag, so it embeds the full source
/// text of every `.dart` file in each module `.dill`'s `SourceTable` (~55% of all
/// `.dill` bytes). The VM uses `lineStarts` (not `sourceCode`) for stack traces and
/// `SourceReport` coverage, and downstream `--input-linked` compiles read only
/// library outlines.
///
/// Format guard: reads the 32-bit kernel format version at byte offset 4 of the
/// header and accepts only [supportedKernelFormatVersions] (version 138, Dart
/// 3.13.x). On any other format version, writes a diagnostic to [errSink]
/// (defaulting to [stderr]) and falls back to returning [data] unstripped,
/// never emitting a malformed `.dill`.
Uint8List stripSourceCodeFromDill(Uint8List data, {StringSink? errSink}) =>
    _stripSourceCodeFromDill(data, errSink: errSink);

Uint8List _stripSourceCodeFromDill(Uint8List data, {StringSink? errSink}) {
  final sink = errSink ?? stderr;
  if (data.length < 8) return data;
  final bd = ByteData.sublistView(data);
  if (bd.getUint32(0) != Tag.ComponentFile) return data;
  final version = bd.getUint32(4);
  if (!supportedKernelFormatVersions.contains(version)) {
    sink.writeln(
      'kernel_module: unsupported kernel format version $version '
      '(supported: $supportedKernelFormatVersions); '
      'falling back to unstripped dill.',
    );
    return data;
  }
  if (data.length < 48) return data;
  final lastSize = bd.getUint32(data.length - 4);
  if (lastSize == data.length) {
    return _stripSingleComponentSourceCode(data, sink);
  }
  final ranges = <(int, int)>[];
  var end = data.length;
  while (end >= 48) {
    final compSize = bd.getUint32(end - 4);
    if (compSize < 48 || compSize > end) return data;
    final start = end - compSize;
    if (bd.getUint32(start) != Tag.ComponentFile) return data;
    final compVersion = bd.getUint32(start + 4);
    if (!supportedKernelFormatVersions.contains(compVersion)) {
      sink.writeln(
        'kernel_module: unsupported kernel format version $compVersion '
        '(supported: $supportedKernelFormatVersions); '
        'falling back to unstripped dill.',
      );
      return data;
    }
    ranges.add((start, end));
    end = start;
  }
  if (end != 0 || ranges.isEmpty) return data;
  final out = BytesBuilder(copy: false);
  for (var i = ranges.length - 1; i >= 0; i--) {
    final (s, e) = ranges[i];
    out.add(
      _stripSingleComponentSourceCode(Uint8List.sublistView(data, s, e), sink),
    );
  }
  return out.takeBytes();
}

Uint8List _stripSingleComponentSourceCode(Uint8List data, StringSink sink) {
  final index = _parseStripIndex(data);
  if (index == null) return data;
  final numSources = ByteData.sublistView(data).getUint32(index.offSourceTable);
  if (numSources == 0) return data;
  final rebuilt = _rebuildSourceTable(
    data,
    index.offSourceTable,
    index.offConstantTable,
    numSources,
  );
  final delta = rebuilt.bytes.length - rebuilt.replacedLength;
  if (delta == 0) return data;
  final linkTableEnd = _linkTableEnd(
    data,
    index.offLinkTable,
    index.offMetadataPayloads,
  );
  return _reassembleStripped(data, index, rebuilt.bytes, delta, linkTableEnd);
}

/// A single component's table layout for source stripping.
typedef _StripIndex = ({
  List<int> fields,
  int idxCount,
  int idxBytes,
  int offSourceTable,
  int offConstantTable,
  int offLinkTable,
  int offMetadataPayloads,
  int offComponentIndex,
});

/// Reads and validates the component index, or null when it is inconsistent.
_StripIndex? _parseStripIndex(Uint8List data) {
  final bd = ByteData.sublistView(data);
  final libCount = bd.getUint32(data.length - 8);
  final idxCount = libCount + 12;
  final idxBytes = idxCount * 4;
  if (idxBytes > data.length) return null;
  final rawIdxStart = data.length - idxBytes;

  final fields = List<int>.generate(
    idxCount,
    (i) => bd.getUint32(rawIdxStart + i * 4),
  );
  final offSourceTable = fields[0];
  final offConstantTable = fields[1];
  final offLinkTable = fields[3];
  final offMetadataPayloads = fields[4];
  final offMetadataMappings = fields[5];
  final offStringTable = fields[6];
  final offComponentIndex = fields[7];
  if (offSourceTable + 4 > offConstantTable ||
      offConstantTable > offLinkTable ||
      offLinkTable > offMetadataPayloads ||
      offMetadataPayloads > offMetadataMappings ||
      offMetadataMappings > offStringTable ||
      offStringTable > offComponentIndex ||
      offComponentIndex > rawIdxStart) {
    return null;
  }
  return (
    fields: fields,
    idxCount: idxCount,
    idxBytes: idxBytes,
    offSourceTable: offSourceTable,
    offConstantTable: offConstantTable,
    offLinkTable: offLinkTable,
    offMetadataPayloads: offMetadataPayloads,
    offComponentIndex: offComponentIndex,
  );
}

/// Reads kernel UInt30 values from a component's bytes, tracking the offset.
/// The source-table rewriter and the link-table scanner read the same
/// encoding over trusted offsets (both fail closed before reading), so one
/// cursor serves both.
final class _U30Reader {
  _U30Reader(this._data, int position) : _pos = position;

  final Uint8List _data;
  int _pos;

  /// The current offset in [_data].
  int get position => _pos;

  /// Advances past [count] bytes.
  void skip(int count) {
    _pos += count;
  }

  /// The next UInt30 value.
  int read() {
    final b0 = _data[_pos++];
    if ((b0 & 0x80) == 0) return b0;
    if ((b0 & 0x40) == 0) {
      return ((b0 & 0x3f) << 8) | _data[_pos++];
    }
    final b1 = _data[_pos++];
    final b2 = _data[_pos++];
    final b3 = _data[_pos++];
    return ((b0 & 0x3f) << 24) | (b1 << 16) | (b2 << 8) | b3;
  }
}

/// Rewrites the source table with every source body emptied, returning the new
/// table and the length of the table it replaces.
({Uint8List bytes, int replacedLength}) _rebuildSourceTable(
  Uint8List data,
  int offSourceTable,
  int offConstantTable,
  int numSources,
) {
  final u30 = _U30Reader(data, offSourceTable + 4);

  final newSt = BytesBuilder(copy: false);
  final header4 = ByteData(4)..setUint32(0, numSources);
  newSt.add(header4.buffer.asUint8List());
  final newSourceOffsets = List<int>.filled(numSources, 0);

  for (var i = 0; i < numSources; i++) {
    newSourceOffsets[i] = offSourceTable + newSt.length;

    // 1. uri: UInt30 byteLength + UTF-8 bytes
    final uStart = u30.position;
    final uLen = u30.read();
    u30.skip(uLen);
    newSt.add(Uint8List.sublistView(data, uStart, u30.position));

    // 2. sourceCode: UInt30 byteLength + UTF-8 bytes -> replace with empty (0x00)
    final sLen = u30.read();
    u30.skip(sLen);
    newSt.addByte(0);

    // 3. lineStarts: UInt30 count + count * UInt30 delta
    final lsStart = u30.position;
    final lineCount = u30.read();
    for (var j = 0; j < lineCount; j++) {
      u30.read();
    }
    // 4. importUri: UInt30 byteLength + UTF-8 bytes
    final iuLen = u30.read();
    u30.skip(iuLen);
    // 5. constantCoverageConstructors: UInt30 count + count * UInt30
    final ccCount = u30.read();
    for (var j = 0; j < ccCount; j++) {
      u30.read();
    }
    newSt.add(Uint8List.sublistView(data, lsStart, u30.position));
  }

  final offsetsBuf = ByteData(numSources * 4);
  for (var i = 0; i < numSources; i++) {
    offsetsBuf.setUint32(i * 4, newSourceOffsets[i]);
  }
  newSt.add(offsetsBuf.buffer.asUint8List());

  return (
    bytes: newSt.takeBytes(),
    replacedLength: offConstantTable - offSourceTable,
  );
}

/// The end of the link table's canonical entries, clamped to the metadata.
int _linkTableEnd(Uint8List data, int offLinkTable, int offMetadataPayloads) {
  final u30 = _U30Reader(data, offLinkTable);

  final canonCount = u30.read();
  for (var i = 0; i < canonCount; i++) {
    u30.read();
    u30.read();
  }
  return u30.position <= offMetadataPayloads
      ? u30.position
      : offMetadataPayloads;
}

/// Splices the rewritten source table back into the component, realigning the
/// metadata payloads and rewriting the component index.
Uint8List _reassembleStripped(
  Uint8List data,
  _StripIndex index,
  Uint8List newStBytes,
  int delta,
  int linkTableEnd,
) {
  final fields = index.fields;
  final out = BytesBuilder(copy: false);
  out.add(Uint8List.sublistView(data, 0, index.offSourceTable));
  out.add(newStBytes);
  out.add(Uint8List.sublistView(data, index.offConstantTable, linkTableEnd));

  // Kernel requires binaryOffsetForMetadataPayloads (fields[4]) to be 8-byte
  // aligned (ComponentFile.metadataPayloadsAlignment = 8).
  final metaPad = (8 - (out.length % 8)) % 8;
  if (metaPad > 0) {
    out.add(Uint8List(metaPad));
  }
  final newOffMetadataPayloads = out.length;
  final metaDelta = newOffMetadataPayloads - index.offMetadataPayloads;

  out.add(
    Uint8List.sublistView(
      data,
      index.offMetadataPayloads,
      index.offComponentIndex,
    ),
  );

  final newOffComponentIndex = out.length;
  final totalUnpadded = out.length + index.idxBytes;
  final pad = (8 - (totalUnpadded % 8)) % 8;
  if (pad > 0) {
    out.add(Uint8List(pad));
  }

  for (var i = 1; i <= 3; i++) {
    fields[i] += delta;
  }
  for (var i = 4; i <= 6; i++) {
    fields[i] += metaDelta;
  }
  fields[7] = newOffComponentIndex;
  fields[index.idxCount - 1] = out.length + index.idxBytes;

  final idxBuf = ByteData(index.idxBytes);
  for (var i = 0; i < index.idxCount; i++) {
    idxBuf.setUint32(i * 4, fields[i]);
  }
  out.add(idxBuf.buffer.asUint8List());
  return out.takeBytes();
}

/// The byte ranges of the kernel components in [data] (a single component, or
/// concatenated ones), or null when [data] is structurally not a kernel file.
/// Mirrors the splitting in [_stripSourceCodeFromDill].
List<(int, int)>? _componentRanges(Uint8List data) {
  if (data.length < 48) return null;
  final bd = ByteData.sublistView(data);
  if (bd.getUint32(0) != Tag.ComponentFile) return null;
  final lastSize = bd.getUint32(data.length - 4);
  if (lastSize == data.length) return [(0, data.length)];
  final ranges = <(int, int)>[];
  var end = data.length;
  while (end >= 48) {
    final compSize = bd.getUint32(end - 4);
    if (compSize < 48 || compSize > end) return null;
    final start = end - compSize;
    if (bd.getUint32(start) != Tag.ComponentFile) return null;
    ranges.add((start, end));
    end = start;
  }
  if (end != 0 || ranges.isEmpty) return null;
  return ranges.reversed.toList();
}

/// A bounds-checked cursor over one kernel component's table bytes. Reads stop
/// at [limit], so malformed bytes fail instead of misreading.
class _TableCursor {
  _TableCursor(this._part, this._limit, int pos) : _pos = pos;

  final Uint8List _part;
  final int _limit;
  int _pos;

  /// The cursor's offset in [_part].
  int get position => _pos;

  /// The next UInt30, or null at the limit.
  int? readU30() {
    if (_pos >= _limit) return null;
    final b0 = _part[_pos++];
    if ((b0 & 0x80) == 0) return b0;
    if ((b0 & 0x40) == 0) {
      if (_pos >= _limit) return null;
      return ((b0 & 0x3f) << 8) | _part[_pos++];
    }
    if (_pos + 3 > _limit) return null;
    final value =
        ((b0 & 0x3f) << 24) |
        (_part[_pos] << 16) |
        (_part[_pos + 1] << 8) |
        _part[_pos + 2];
    _pos += 3;
    return value;
  }

  /// Whether [n] bytes from here stay within the limit.
  bool hasBytes(int n) => n >= 0 && _pos + n <= _limit;

  /// Advances past [n] bytes, or false when they leave the limit.
  bool skipBytes(int n) {
    if (!hasBytes(n)) return false;
    _pos += n;
    return true;
  }

  /// Advances past [n] bytes without checking; call only after [hasBytes].
  void advance(int n) {
    _pos += n;
  }

  /// The next [n] bytes decoded as UTF-8, or null when they are malformed.
  String? readUtf8(int n) {
    final start = _pos;
    _pos += n;
    // Callers bounds-check with `hasBytes` first, so the slice is in range
    // and only malformed UTF-8 fails.
    try {
      return utf8.decode(_part.sublist(start, start + n));
    } on FormatException {
      return null;
    }
  }
}

/// The bounds of one kernel component's source table: the constant-table
/// limit, the first entry's offset, and the entry count. Null when the header
/// does not parse; every offset is bounds-checked.
({int limit, int pos, int numSources})? _sourceTableHeader(Uint8List part) {
  if (part.length < 12) return null;
  final bd = ByteData.sublistView(part);
  if (bd.getUint32(0) != Tag.ComponentFile) return null;
  final libCount = bd.getUint32(part.length - 8);
  final idxBytes = (libCount + 12) * 4;
  if (idxBytes > part.length) return null;
  final rawIdxStart = part.length - idxBytes;
  final offSourceTable = bd.getUint32(rawIdxStart);
  final offConstantTable = bd.getUint32(rawIdxStart + 4);
  if (offSourceTable + 4 > offConstantTable || offConstantTable > rawIdxStart) {
    return null;
  }
  return (
    limit: offConstantTable,
    pos: offSourceTable + 4,
    numSources: bd.getUint32(offSourceTable),
  );
}

/// Skips one UInt30 count and the values it counts. False at the limit.
bool _skipU30Run(_TableCursor cursor) {
  final count = cursor.readU30();
  if (count == null) return false;
  for (var j = 0; j < count; j++) {
    if (cursor.readU30() == null) return false;
  }
  return true;
}

/// Reads one source-table entry into [uris] (and [importUris], when given).
/// False, leaving them short, when the entry does not parse.
bool _readSourceEntry(
  _TableCursor cursor,
  List<String> uris,
  List<String>? importUris,
) {
  // 1. uri: UInt30 byteLength + UTF-8 bytes.
  final uriLen = cursor.readU30();
  if (uriLen == null || uriLen < 0 || !cursor.hasBytes(uriLen)) {
    return false;
  }
  final uri = cursor.readUtf8(uriLen);
  if (uri == null) return false;
  uris.add(uri);
  // 2. sourceCode: UInt30 byteLength + UTF-8 bytes.
  final srcLen = cursor.readU30();
  if (srcLen == null || !cursor.skipBytes(srcLen)) return false;
  // 3. lineStarts: UInt30 count + count * UInt30 delta.
  if (!_skipU30Run(cursor)) return false;
  // 4. importUri: UInt30 byteLength + UTF-8 bytes.
  final impLen = cursor.readU30();
  if (impLen == null || impLen < 0 || !cursor.hasBytes(impLen)) {
    return false;
  }
  if (importUris != null) {
    final importUri = cursor.readUtf8(impLen);
    if (importUri == null) return false;
    importUris.add(importUri);
  } else {
    cursor.advance(impLen);
  }
  // 5. constantCoverageConstructors: UInt30 count + count * UInt30.
  return _skipU30Run(cursor);
}

/// Adds the `fileUri` of every source in the one kernel component [part] to
/// [uris]. Returns false (leaving [uris] short) when [part] is not a
/// well-formed component: every offset and length is bounds-checked against
/// its source table, so malformed bytes fail instead of misreading.
///
/// The source-table entry layout (`uri`, `sourceCode`, `lineStarts`,
/// `importUri`, `constantCoverageConstructors`) is stable across every Dart
/// SDK this rule set supports, while the 32-bit kernel format version in the
/// header moves with the SDK (127 under 3.11.0, 130 under 3.12.2, 138 under
/// 3.13.5), so the table is parsed structurally with no version gate: gating
/// here failed every read-set verification on older SDKs, failing legitimate
/// compiles. Byte-rewriting stays version-gated in the strippers below.
/// Adds the `fileUri` of every source in the one kernel component [part] to
/// [uris] — and, when [importUris] is given, the `importUri` recorded
/// alongside it (the spelling the importer named the library by, which the
/// library-reference check below verifies independently of the file read).
bool _collectComponentSourceUris(
  Uint8List part,
  List<String> uris, [
  List<String>? importUris,
]) {
  final header = _sourceTableHeader(part);
  if (header == null) return false;
  final cursor = _TableCursor(part, header.limit, header.pos);
  for (var i = 0; i < header.numSources; i++) {
    if (!_readSourceEntry(cursor, uris, importUris)) return false;
  }
  return true;
}

/// The `fileUri` of every source recorded in the kernel component(s) in [data]
/// — the files the compile actually read — or null when [data] is not a
/// well-formed kernel file. Any format version parses: the source-table layout
/// is stable across SDKs, and every offset is bounds-checked.
List<String>? dillSourceUris(Uint8List data) {
  final ranges = _componentRanges(data);
  if (ranges == null) return null;
  final uris = <String>[];
  for (final (start, end) in ranges) {
    if (!_collectComponentSourceUris(
      Uint8List.sublistView(data, start, end),
      uris,
    )) {
      return null;
    }
  }
  return uris;
}

/// One library node of a kernel component: the source-table entry it was read
/// from, and the names it is linked under. A `null` [fileUri] or [importUri]
/// means the node's source index names no table entry (a corrupt or
/// truncated component, which carries no reference to check); an empty
/// [canonicalName] means the node has no canonical-name reference.
typedef DillLibraryReference = ({
  int fileUriIndex,
  String? fileUri,
  String? importUri,
  String canonicalName,
});

/// The library references of the kernel component(s) in [data] — one record
/// per library node, holding its source-table index with that entry's
/// `fileUri`/`importUri` spellings, and its canonical name's root string
/// (libraries link under their import URI, so the root names the library the
/// same way the source table's `importUri` does).
///
/// Null when [data] is not a well-formed kernel file, or when its
/// string, link, or library tables do not parse: the caller then keeps the
/// source-table verdict, which never depends on these tables. Per-library
/// reference failures (a dangling source index, an unresolvable canonical
/// name) degrade to a missing reference in that record, never to a refusal:
/// only a present reference the inputs do not define fails the check, so a
/// future SDK that reshapes an unread table cannot fail a legitimate compile
/// here — the source table still verifies every file read.
///
/// The node header prefix (`flags`, version, canonical-name, name, file-URI
/// references) is position-stable across SDKs; only that prefix is read, so
/// appended fields never disturb the parse. Every offset and length is
/// bounds-checked against its table.
List<DillLibraryReference>? dillLibraryReferences(Uint8List data) {
  final ranges = _componentRanges(data);
  if (ranges == null) return null;
  final refs = <DillLibraryReference>[];
  for (final (start, end) in ranges) {
    if (!_collectComponentLibraries(
      Uint8List.sublistView(data, start, end),
      refs,
    )) {
      return null;
    }
  }
  return refs;
}

/// The name tables of one kernel component: its source-table URIs plus the
/// string table and canonical-name table its library references link through.
/// Null when the component's tables do not parse; every offset and length is
/// bounds-checked.
typedef _NameTables = ({
  List<String> fileUris,
  List<String> importUris,
  String? Function(int) stringAt,
  List<int> canonParents,
  List<int> canonStrings,
});

_NameTables? _componentNameTables(Uint8List part) {
  if (part.length < 12) return null;
  final bd = ByteData.sublistView(part);
  if (bd.getUint32(0) != Tag.ComponentFile) return null;
  final libCount = bd.getUint32(part.length - 8);
  // No library nodes means no library references: the source-table verdict
  // stands alone, and the remaining tables (whose offsets test fixtures may
  // leave unset) are never touched.
  if (libCount == 0) {
    return (
      fileUris: <String>[],
      importUris: <String>[],
      stringAt: (int index) => null,
      canonParents: <int>[],
      canonStrings: <int>[],
    );
  }
  final idxBytes = (libCount + 12) * 4;
  if (idxBytes > part.length) return null;
  final rawIdxStart = part.length - idxBytes;
  final offSourceTable = bd.getUint32(rawIdxStart);
  final offLinkTable = bd.getUint32(rawIdxStart + 12);
  final offStringTable = bd.getUint32(rawIdxStart + 24);
  if (offSourceTable + 4 > part.length ||
      offLinkTable > rawIdxStart ||
      offStringTable > rawIdxStart ||
      offLinkTable > offStringTable) {
    return null;
  }
  final fileUris = <String>[];
  final importUris = <String>[];
  if (!_collectComponentSourceUris(part, fileUris, importUris)) return null;

  final stringAt = _readComponentStrings(part, offStringTable, rawIdxStart);
  if (stringAt == null) return null;
  // The canonical-name table: a count of (parent, name-string) pairs, with
  // the parent biased by one (zero names the nameless root).
  final canon = _readCanonTable(part, offLinkTable, offStringTable);
  if (canon == null) return null;
  final (canonParents, canonStrings) = canon;
  return (
    fileUris: fileUris,
    importUris: importUris,
    stringAt: stringAt,
    canonParents: canonParents,
    canonStrings: canonStrings,
  );
}

/// The string-table reader of one kernel component: resolves a string index,
/// or null when the table does not parse. Every offset is bounds-checked.
String? Function(int)? _readComponentStrings(
  Uint8List part,
  int offStringTable,
  int rawIdxStart,
) {
  // The string table: a count, cumulative end offsets, then the bytes.
  final cursor = _TableCursor(part, rawIdxStart, offStringTable);
  final strCount = cursor.readU30();
  if (strCount == null || strCount < 0) return null;
  final strEnds = <int>[];
  var prevEnd = 0;
  for (var i = 0; i < strCount; i++) {
    final end = cursor.readU30();
    if (end == null || end < prevEnd) return null;
    strEnds.add(end);
    prevEnd = end;
  }
  final strBase = cursor.position;
  if (strEnds.isNotEmpty && strBase + strEnds.last > rawIdxStart) return null;
  String? stringAt(int index) {
    if (index < 0 || index >= strEnds.length) return null;
    final start = index == 0 ? 0 : strEnds[index - 1];
    // The header enforces monotonic ends within the part, so the slice is in
    // range and only malformed UTF-8 fails.
    try {
      return utf8.decode(
        part.sublist(strBase + start, strBase + strEnds[index]),
      );
    } on FormatException {
      return null;
    }
  }

  return stringAt;
}

/// The canonical-name table of one component as (parents, name strings), or
/// null when it does not parse.
(List<int>, List<int>)? _readCanonTable(
  Uint8List part,
  int offLinkTable,
  int offStringTable,
) {
  final cursor = _TableCursor(part, offStringTable, offLinkTable);
  final canonCount = cursor.readU30();
  if (canonCount == null || canonCount < 0) return null;
  final canonParents = <int>[];
  final canonStrings = <int>[];
  for (var i = 0; i < canonCount; i++) {
    final parent = cursor.readU30();
    final name = cursor.readU30();
    if (parent == null || name == null) return null;
    canonParents.add(parent);
    canonStrings.add(name);
  }
  return (canonParents, canonStrings);
}

/// Adds one [DillLibraryReference] per library node of the one kernel
/// component [part] to [refs]. Returns false (leaving [refs] short) when the
/// component's tables do not parse; every offset and length is bounds-checked.
bool _collectComponentLibraries(
  Uint8List part,
  List<DillLibraryReference> refs,
) {
  final tables = _componentNameTables(part);
  if (tables == null) return false;
  final nodeCount = _libraryNodeCount(part);
  if (nodeCount == null) return false;
  // No library nodes means no library references: the source-table verdict
  // stands alone, and the remaining tables are never touched.
  for (var i = 0; i < nodeCount; i++) {
    final ref = _readLibraryNode(part, nodeCount, i, tables);
    if (ref == null) return false;
    refs.add(ref);
  }
  return true;
}

/// The library-node count of one kernel component, or null when its index
/// does not parse.
int? _libraryNodeCount(Uint8List part) {
  if (part.length < 12) return null;
  final bd = ByteData.sublistView(part);
  final libCount = bd.getUint32(part.length - 8);
  if (libCount == 0) return 0;
  final idxBytes = (libCount + 12) * 4;
  if (idxBytes > part.length) return null;
  return libCount;
}

/// The canonical-name root of one biased reference: the topmost ancestor's
/// string, or empty when the chain dangles. Only a present root the inputs do
/// not define fails the check, so an unresolvable one degrades to empty.
String _canonicalRoot(int biased, _NameTables tables) {
  final canonParents = tables.canonParents;
  final canonCount = canonParents.length;
  var index = biased - 1;
  if (biased <= 0 || index >= canonCount) return '';
  var guard = canonCount + 1;
  while (canonParents[index] != 0) {
    if (guard-- <= 0) return '';
    index = canonParents[index] - 1;
    if (index < 0 || index >= canonCount) return '';
  }
  return tables.stringAt(tables.canonStrings[index]) ?? '';
}

/// One library node's reference: its source-table index with that entry's
/// `fileUri`/`importUri` spellings, and its canonical name's root string.
/// Null when the node header does not parse.
///
/// The node header prefix (`flags`, version, canonical-name, name, file-URI
/// references) is position-stable across SDKs; only that prefix is read, so
/// appended fields never disturb the parse. Every offset is bounds-checked.
DillLibraryReference? _readLibraryNode(
  Uint8List part,
  int libCount,
  int i,
  _NameTables tables,
) {
  final bd = ByteData.sublistView(part);
  final rawIdxStart = part.length - (libCount + 12) * 4;
  final libStart = bd.getUint32(rawIdxStart + 36 + i * 4);
  final libEnd = bd.getUint32(rawIdxStart + 36 + (i + 1) * 4);
  if (libEnd < libStart || libStart > part.length || libEnd > part.length) {
    return null;
  }
  // Each node header opens with a flags byte, the version, and three
  // references — canonical name (biased), name string, source-table file URI
  // — after which only that prefix has been consumed.
  final cursor = _TableCursor(part, libEnd, libStart);
  if (!cursor.skipBytes(1)) return null; // Flags.
  if (cursor.readU30() == null) return null; // Major version.
  if (cursor.readU30() == null) return null; // Minor version.
  final canon = cursor.readU30();
  if (canon == null) return null;
  if (cursor.readU30() == null) return null; // Name string reference.
  final fileUriIndex = cursor.readU30();
  if (fileUriIndex == null) return null;
  final fileUris = tables.fileUris;
  final importUris = tables.importUris;
  final importUri = fileUriIndex >= 0 && fileUriIndex < importUris.length
      ? importUris[fileUriIndex]
      : null;
  return (
    fileUriIndex: fileUriIndex,
    fileUri: fileUriIndex >= 0 && fileUriIndex < fileUris.length
        ? fileUris[fileUriIndex]
        : null,
    importUri: importUri == null || importUri.isEmpty ? null : importUri,
    canonicalName: _canonicalRoot(canon, tables),
  );
}

/// Every top-level canonical-name string (parent index zero) recorded in the
/// `.dill` [bytes] across all components, or `null` when the tables do not
/// parse. A held component can smuggle a root the library nodes never mention —
/// a `file:` canonical root with no corresponding library node, for example —
/// so the backstop below checks these roots too, not just the library nodes.
/// Returns an empty list (never `null`) for a component file with no
/// libraries, mirroring [dillLibraryReferences].
List<String>? dillCanonicalRoots(Uint8List bytes) {
  final ranges = _componentRanges(bytes);
  if (ranges == null) return null;
  final roots = <String>[];
  for (final (start, end) in ranges) {
    final tables = _componentNameTables(
      Uint8List.sublistView(bytes, start, end),
    );
    if (tables == null) return null;
    for (var i = 0; i < tables.canonParents.length; i++) {
      // An unresolvable root string degrades to empty (accepted, like the
      // per-library walk's `canonicalRoot`): only a present root the inputs do
      // not define fails the check.
      if (tables.canonParents[i] == 0) {
        roots.add(tables.stringAt(tables.canonStrings[i]) ?? '');
      }
    }
  }
  return roots;
}

/// The declared-input key the `.dill` source-table URI [uri] names, or null when
/// it names no workspace file (`dart:`, `data:`, the SDK, an untranslatable
/// URI, or the empty entry, which names no file at all). The empty string
/// marks a file no root names — outside every root, or an unknown scheme —
/// which is never a declared input, so such reads fail closed.
///
/// Recorded multi-root URIs decode once, undoing the encoding the recording
/// adds: a literal `%` in a file name round-trips through `%25`. Recorded
/// `file:` URIs are already file paths and decode no further.
String? _keyOfDillSourceUri(
  String uri,
  List<String> multiRoots,
  String multiRootPrefix,
) {
  // An empty source-table entry names no file, so there is no read to verify.
  if (uri.isEmpty) return null;
  final stripped = _stripPrefix(uri, multiRootPrefix);
  if (stripped != null) {
    return stripped.contains('%')
        ? stripped.split('/').map(decodeUriSegment).join('/')
        : stripped;
  }
  if (uri.startsWith('dart:') ||
      uri.startsWith('data:') ||
      uri.startsWith('org-dartlang-sdk:') ||
      uri.startsWith('org-dartlang-untranslatable-uri:')) {
    return null;
  }
  if (uri.startsWith('file:')) {
    return _keyOfDillFileUri(uri, multiRoots);
  }
  return '';
}

/// The declared-input key of the recorded `file:` URI [uri], or null when it
/// names no workspace file. The empty string marks a file no root names —
/// outside every root, or an unknown scheme — which is never a declared
/// input, so such reads fail closed.
String _keyOfDillFileUri(String uri, List<String> multiRoots) {
  String path;
  try {
    path = Uri.parse(uri).toFilePath();
  } on FormatException {
    // Not a URI at all: no workspace file.
    return '';
  } on UnsupportedError {
    // A `file:` URI with an authority or query converts to no local path:
    // no workspace file.
    return '';
  }
  final normPath = path.contains(r'\') ? path.replaceAll(r'\', '/') : path;
  final cwd = Directory.current.path.replaceAll(r'\', '/');
  for (final root in multiRoots) {
    final key = _keyUnderRoot(normPath, root, cwd);
    if (key != null) return key;
  }
  return '';
}

/// The key of [normPath] under [root], or null when it lives elsewhere.
String? _keyUnderRoot(String normPath, String root, String cwd) {
  var rootFile = root.contains(r'\') ? root.replaceAll(r'\', '/') : root;
  rootFile = rootFile.replaceFirst(RegExp(r'/+$'), '');
  final candidates = rootFile.isEmpty || rootFile == '.'
      ? [cwd]
      : rootFile.startsWith('/') || isWindowsDrivePath(rootFile)
      ? [rootFile]
      : ['$cwd/$rootFile', rootFile];
  for (final base in candidates) {
    if (normPath == base || normPath.startsWith('$base/')) {
      return normPath == base ? '' : normPath.substring(base.length + 1);
    }
  }
  return null;
}

/// Whether the `.dill` a compile wrote read only declared or pinned
/// inputs: every workspace file its source table names is either one of
/// [files]' declared inputs, or defined by a dependency module of the closure
/// ([graph] holds the keys every module of the closure defines). Dependency
/// sources are pinned inputs the front end links against — it embeds one when,
/// for example, a compiled library applies its mixin — so they cannot smuggle
/// an undeclared workspace file in. A missing output (a recording test
/// compiler, which writes none) passes; an unreadable table fails closed.
///
/// A dirty read set never passes: [consequence] says what happens next, either
/// `recompiling with an isolated multi-root` (the unstaged compile is redone
/// where only declared inputs exist) or `failing the compile` (the isolated
/// restage still read outside the declared inputs, so its result is refused).
/// Whether the `.dill` a compile wrote read only declared or pinned
/// inputs: every workspace file its source table names is either one of
/// [files]' declared inputs, or defined by a dependency module of the closure
/// ([graph] holds the keys every module of the closure defines). Dependency
/// sources are pinned inputs the front end links against — it embeds one when,
/// for example, a compiled library applies its mixin — so they cannot smuggle
/// an undeclared workspace file in. A missing output (a recording test
/// compiler, which writes none) passes; an unreadable table fails closed.
///
/// The source table is spelling-dependent: it records the file the front end
/// read, but a library node also records the `importUri` spelling the
/// importer named it by and the canonical name it links under, and either can
/// name a file the recorded `fileUri` spelling does not. So every library
/// reference is checked too, spelling-independently — its `importUri` and
/// canonical-name root — and every top-level canonical name is checked as
/// well, since a held component can smuggle a root no library node mentions.
/// Each must be one of [ownUris] (the URIs this compile was
/// given as `--source`), a `dart:` library, or an import URI an input module
/// defines — the `package:` and multi-root spellings of [graph]'s keys under
/// [roots], computed without touching the filesystem — or else name a
/// declared or graph-contained file when resolved like a recorded source URI
/// (a `file:` spelling of one, say). Any other present reference fails
/// closed, except a bare identifier with neither URI nor path shape, which
/// names no file (only synthetic kernels record those as canonical roots). References no input can define never occur legitimately: the
/// front end records the URI it was given for own sources, the import URI
/// for linked ones, and `dart:` URIs for the SDK.
///
/// A library or canonical-root table that does not parse counts as unverified
/// on the unstaged path, so the isolated recompile runs: without the tables
/// there is no reference to check, and passing would accept a read set the
/// check never saw. On the isolated path the source-table verdict stands,
/// since isolation already confines reads to declared inputs. A node whose
/// source index dangles keeps the source-table verdict on either path: it
/// carries no reference to check, so refusing on it would fail legitimate
/// compiles over a tool limitation, while the source table still verifies
/// every file actually read.
///
/// A dirty read set never passes: [consequence] says what happens next, either
/// `recompiling with an isolated multi-root` (the unstaged compile is redone
/// where only declared inputs exist) or `failing the compile` (the isolated
/// restage still read outside the declared inputs, so its result is refused).
Future<bool> _unstagedReadsAreDeclared(
  _VerifyReads verify, {
  String consequence = 'recompiling with an isolated multi-root',
}) async {
  final dillFile = File(verify.dillPath);
  if (!await dillFile.exists()) return true;
  final bytes = await dillFile.readAsBytes();
  if (!_dillSourcesAreDeclared(bytes, verify, consequence)) {
    return false;
  }
  final checker = _ReferenceChecker(
    verify.dillPath,
    verify.files,
    verify.graph,
    verify.multiRoots,
    verify.multiRootPrefix,
    verify.roots,
    verify.ownUris,
    _depImportUris(verify.graph, verify.roots, verify.multiRootPrefix),
    consequence,
  );
  final libraries = dillLibraryReferences(bytes);
  // Whether this check guards the unstaged compile (whose consequence is an
  // isolated recompile) rather than the isolated restage (whose consequence
  // is refusing the result).
  final unstaged = consequence == 'recompiling with an isolated multi-root';
  if (libraries == null) {
    // An unparsable library table carries no reference to check. On the
    // unstaged path that counts as unverified, so the isolated recompile
    // runs; on the isolated path the source-table verdict stands, since
    // isolation already confines reads to declared inputs.
    if (unstaged) {
      verify.log.writeln(
        'kernel_module: cannot read the libraries of ${verify.dillPath}; '
        '$consequence.',
      );
      return false;
    }
  } else {
    if (!checker.allDeclared([
      for (final library in libraries) ...[
        library.importUri,
        library.canonicalName,
      ],
    ], verify.log)) {
      return false;
    }
    // A held component can smuggle a root the library nodes never mention, so
    // every top-level canonical name is checked with the same predicate. An
    // unparsable table counts as unverified on the unstaged path, so the
    // isolated recompile runs; on the isolated path the source-table verdict
    // stands, since isolation already confines reads to declared inputs.
    final canonicalRoots = dillCanonicalRoots(bytes);
    if (canonicalRoots == null) {
      if (unstaged) {
        verify.log.writeln(
          'kernel_module: cannot read the canonical names of ${verify.dillPath}; '
          '$consequence.',
        );
        return false;
      }
    } else if (!checker.allDeclared(canonicalRoots, verify.log)) {
      return false;
    }
  }
  return true;
}

/// Whether the dill's source table names only declared inputs.
bool _dillSourcesAreDeclared(
  Uint8List bytes,
  _VerifyReads verify,
  String consequence,
) {
  final uris = dillSourceUris(bytes);
  if (uris == null) {
    verify.log.writeln(
      'kernel_module: cannot read the sources of ${verify.dillPath}; $consequence.',
    );
    return false;
  }
  for (final uri in uris) {
    final key = _keyOfDillSourceUri(
      uri,
      verify.multiRoots,
      verify.multiRootPrefix,
    );
    if (key == null) continue;
    if (!verify.files.isDeclared(key) && !verify.graph.containsKey(key)) {
      verify.log.writeln(
        'kernel_module: ${verify.dillPath} reads $uri, which is not a declared input; '
        '$consequence.',
      );
      return false;
    }
  }
  return true;
}

/// The import URIs input modules define: every graph key under its
/// multi-root spelling and its `package:` spellings (one per package whose
/// directory holds the key, as [_packageUriOf] builds them).
Set<String> _depImportUris(
  Map<String, _Node> graph,
  Map<String, _PackageRoot> roots,
  String multiRootPrefix,
) {
  final packagePrefixes = <String, String>{
    for (final entry in roots.entries)
      entry.key: '${entry.value.path}${entry.value.packageUri}',
  };
  return <String>{
    for (final key in graph.keys) ...[
      '$multiRootPrefix$key',
      for (final entry in packagePrefixes.entries)
        if (key.startsWith(entry.value))
          'package:${entry.key}/${key.substring(entry.value.length)}',
    ],
  };
}

/// Checks dill library references against the declared inputs.
class _ReferenceChecker {
  _ReferenceChecker(
    this._dillPath,
    this._files,
    this._graph,
    this._multiRoots,
    this._multiRootPrefix,
    this._roots,
    this._ownUris,
    this._depImportUris,
    this._consequence,
  );

  final String _dillPath;
  final _Files _files;
  final Map<String, _Node> _graph;
  final List<String> _multiRoots;
  final String _multiRootPrefix;
  final Map<String, _PackageRoot> _roots;
  final Set<String> _ownUris;
  final Set<String> _depImportUris;
  final String _consequence;

  /// Whether every reference is declared, logging the first that is not.
  bool allDeclared(Iterable<String?> references, StringBuffer log) {
    for (final reference in references) {
      if (!isDeclared(reference)) {
        log.writeln(
          'kernel_module: $_dillPath references $reference, which no '
          'compiled source, `dart:` library, or input module defines; '
          '$_consequence.',
        );
        return false;
      }
    }
    return true;
  }

  /// Whether one library reference names a declared input or dependency.
  bool isDeclared(String? reference) {
    if (reference == null || reference.isEmpty) return true;
    // A bare identifier names no file: only a URI- or path-shaped reference
    // can name one. Real front ends record URIs here; anything else is a
    // linking name from a synthetic kernel, with no file identity to verify
    // (the file read is verified separately through the source table).
    if (!reference.contains(':') && !reference.contains('/')) return true;
    if (_ownUris.contains(reference) || _depImportUris.contains(reference)) {
      return true;
    }
    if (reference.startsWith('dart:') ||
        reference.startsWith('data:') ||
        reference.startsWith('org-dartlang-sdk:') ||
        reference.startsWith('org-dartlang-untranslatable-uri:')) {
      return true;
    }
    // A resolvable spelling of a verified file passes: the source table
    // already verified the file read, and this spelling names it. The
    // recorded-URI mapping comes first so multi-root and `file:` spellings
    // resolve exactly as the source-table check resolves them; the
    // package-URI mapping covers `package:` spellings, which the recorded
    // mapping leaves untranslated.
    var key = _keyOfDillSourceUri(reference, _multiRoots, _multiRootPrefix);
    if (key == null || key.isEmpty) {
      key = _keyOfUri(reference, _roots, _multiRootPrefix);
    }
    return key != null &&
        key.isNotEmpty &&
        (_files.isDeclared(key) || _graph.containsKey(key));
  }
}
