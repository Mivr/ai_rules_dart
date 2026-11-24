// Compiles one kernel module on the Dart SDK's own front end. See
// `kernel_module_action` in `dart/private/dart_kernel.bzl`.
//
// This program is built from `pkg/front_end`, `pkg/kernel` and `pkg/vm` at the
// tag of the SDK that runs it (see `dart/private/module_compiler_repo.bzl`), so
// nothing here knows the kernel binary format: reading and writing is
// `package:kernel`'s own `BinaryBuilder` and `BinaryPrinter`.
//
// One request compiles the sources of one `dart_library` (or of one
// executable's entry) against the platform and the outline of each dependency
// module, with one call of the front end's modular entry point, and writes:
//
//  * the module (`--output`, a directory): one kernel per strongly connected
//    component of the module's libraries, with offsets and line starts and
//    without the source text, and an `index.json` that lists each kernel, the
//    keys of the libraries it defines and the keys it imports. `kernel_link`
//    links the kernels an executable reaches. An entry's module is one kernel,
//    `entry.dill`, which keeps its source text.
//  * the outline (`--output-outline`, a directory): `outline.dill`, the same
//    libraries without executable code (see `module_outline.dart`), which is
//    what a dependant compiles against; the sources this module left out,
//    under `sources/`; and an `index.json` naming both.
//  * the sidecar (`--excluded-output`): each source the module left out, and
//    why.
//  * the unused-inputs list (`--unused-inputs-list`): each dependency module
//    whose outline the front end did not need, and each extra source it did
//    not read. Bazel does not rerun the action when only those change.
//
// Which libraries a module leaves out is decided on the front end's result,
// not by scanning directives. A library module leaves out a library of its own
// that does not compile (it imports a `dart:` library the target lacks, say),
// one that imports a library no dependency module defines, and every library
// that imports one of those; it then compiles once more with exactly the
// libraries it keeps, so the result never depends on the first attempt. An
// executable's entry (`--no-drop`) leaves nothing out: it compiles from source
// whatever it reaches that no module defines, so the genuine error is
// reported, and any error fails the action.
//
// The front end reads through a file system that serves only the files the
// request declares, so a compile cannot read a file Bazel does not track.
//
// With `--persistent_worker` this is a Bazel persistent worker. It keeps the
// front end's state between requests: the platform, and each dependency
// outline by the digest Bazel sent. The front end compiles one module at a
// time, so the worker is not multiplexed. The state of the last two targets
// and environments stays loaded. `--max-rss-mb=N` drops all of it when the
// process holds more than N megabytes after a request.
//
// A request whose compile throws (an internal error of the front end, not a
// diagnostic) is compiled once more from a fresh state, so a build never
// fails on a state the worker kept; a retry that succeeds is reported on
// stderr, the worker's log, with the requests that state served before.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:_fe_analyzer_shared/src/messages/diagnostic_message.dart'
    show getMessageUri;
import 'package:_fe_analyzer_shared/src/parser/experimental_features.dart'
    show DefaultExperimentalFeatures;
import 'package:_fe_analyzer_shared/src/parser/listener.dart' show Listener;
import 'package:_fe_analyzer_shared/src/parser/quote.dart' show unescapeString;
import 'package:_fe_analyzer_shared/src/parser/top_level_parser.dart'
    show TopLevelParser;
import 'package:_fe_analyzer_shared/src/scanner/scanner.dart' show scan;
import 'package:_fe_analyzer_shared/src/scanner/token.dart' show Token;
import 'package:build_integration/file_system/multi_root.dart';
import 'package:front_end/src/api_prototype/file_system.dart';
import 'package:front_end/src/api_prototype/incremental_kernel_generator.dart'
    show IncrementalCompilerResult;
import 'package:front_end/src/api_unstable/bazel_worker.dart' as fe;
import 'package:kernel/ast.dart';
import 'package:kernel/binary/ast_to_binary.dart';
import 'package:kernel/target/targets.dart';
import 'package:vm/modular/target/flutter.dart';
import 'package:vm/modular/target/vm.dart';
import 'package:vm/native_assets/json_to_kernel_constant.dart';
import 'package:yaml/yaml.dart' show loadYaml;

import 'lib/layering_message.dart';
import 'lib/worker_protocol.dart';
import 'lib/worker_serve.dart';
import 'module_outline.dart';
import 'package_config.dart' show materializePackageConfig;

const _tool = 'module_compiler';
const _entryDill = 'entry.dill';
const _outlineDill = 'outline.dill';

/// One compile, as `kernel_module_action` states it.
/// A library whose import, export or part names a file that is not an input
/// of the compile: why, and that file's key.
typedef _Undeclared = ({String reason, String file});

class Request {
  Request(List<String> args) {
    String value(int i) => i < args.length
        ? args[i]
        : throw FormatException('${args[i - 1]} needs a value.');
    for (var i = 0; i < args.length; i++) {
      final String arg = args[i];
      switch (arg) {
        case '--target':
          target = value(++i);
        case '--dart-sdk-summary':
          platform = value(++i);
        case '--packages-file':
          packages = value(++i);
        case '--multi-root':
          roots.add(Uri.base.resolveUri(Uri.directory(value(++i))));
        case '--multi-root-scheme':
          scheme = value(++i);
        case '--define-file':
          defineFiles.add(value(++i));
        case '--input-kmod':
          inputModules.add(value(++i));
        case '--source':
          sources.add(Uri.parse(value(++i)));
        case '--input-source':
          inputSources.add(value(++i));
        case '--source-dir':
          sourceDirs.add((uri: value(++i), dir: value(++i)));
        case '--own-source-file':
          ownSourceFiles.add(value(++i));
        case '--output':
          output = value(++i);
        case '--output-outline':
          outline = value(++i);
        case '--excluded-output':
          excluded = value(++i);
        case '--unused-inputs-list':
          unusedInputs = value(++i);
        case '--no-drop':
          entry = true;
        case '--native-assets':
          nativeAssets = value(++i);
        case '--track-widget-creation':
          trackWidgetCreation = true;
        case '--check-imports':
          checkImports = true;
        case '--target-label':
          label = value(++i);
        case '--own-package' || '--direct-package':
          allowedPackages.add(value(++i));
        case '--refused-library':
          refusedLibraries.add(value(++i));
        case '--enable-experiment':
          experiments.add(value(++i));
        case '--poison-state-for-test':
          poisonStateForTest = true;
        default:
          final int eq = arg.indexOf('=');
          if (arg.startsWith('-D') && eq > 2) {
            defines[arg.substring(2, eq)] = arg.substring(eq + 1);
          } else if (arg.startsWith('--enable-experiment=')) {
            experiments.add(arg.substring(eq + 1));
          } else {
            throw FormatException('unknown argument: $arg');
          }
      }
    }
    if (platform == null || packages == null || output == null) {
      throw const FormatException(
        '--dart-sdk-summary, --packages-file and --output are required.',
      );
    }
    if (roots.isEmpty) roots.add(Uri.base);
    // A source directory (a `dart_library`'s `srcs_dir`) is one input whose
    // files the analysis phase cannot name: each `.dart` file under it is a
    // source of this module, under the URI prefix plus its relative path.
    for (final (:String uri, :String dir) in sourceDirs) {
      if (!uri.endsWith('/')) {
        throw FormatException('--source-dir $uri: the URI prefix ends in /.');
      }
      final root = Directory(dir);
      // A package with no `lib/` has no library to compile.
      if (!root.existsSync()) continue;
      final files = [
        for (final e in root.listSync(recursive: true))
          if (e is File && e.path.endsWith('.dart')) e.path,
      ]..sort();
      for (final String path in files) {
        final String rel = path
            .substring(root.path.length + 1)
            .replaceAll(Platform.pathSeparator, '/');
        sources.add(Uri.parse('$uri${Uri(path: rel)}'));
        inputSources.add(path);
        ownSourceFiles.add(path);
      }
    }
    if (nativeAssets != null && !entry) {
      throw const FormatException(
        '--native-assets is an entry option: it needs --no-drop.',
      );
    }
    // A defines file states `-DKEY=VALUE` lines that come before every `-D`
    // of the request, so a `-D` of the same key wins. A value is everything
    // after the first `=`, commas included.
    final fromFiles = <String, String>{};
    for (final String path in defineFiles) {
      for (final String line in File(path).readAsLinesSync()) {
        final int eq = line.indexOf('=');
        if (line.isEmpty) continue;
        if (!line.startsWith('-D') || eq < 3) {
          throw FormatException(
            "$path: expected a '-DKEY=VALUE' line, got '$line'.",
          );
        }
        fromFiles[line.substring(2, eq)] = line.substring(eq + 1);
      }
    }
    defines = {...fromFiles, ...defines};
  }

  String target = 'vm';
  String? platform;
  String? packages;
  String scheme = 'org-dartlang-root';
  final List<Uri> roots = [];
  final List<String> defineFiles = [];
  Map<String, String> defines = {};
  final List<String> experiments = [];
  bool trackWidgetCreation = false;

  /// The outline directory of each dependency module.
  final List<String> inputModules = [];

  /// The URI each source compiles under. An entry's entry point comes first.
  final List<Uri> sources = [];

  /// Source directories: a URI prefix and the directory its files sit in.
  final List<({String uri, String dir})> sourceDirs = [];

  /// Every source file the compile may read, and those that are its own.
  final List<String> inputSources = [];
  final Set<String> ownSourceFiles = {};
  String? output;
  String? outline;
  String? excluded;
  String? unusedInputs;

  /// The native-assets mapping an entry embeds, as `frontend_server
  /// --native-assets` embeds it in a whole program.
  String? nativeAssets;

  /// An executable's entry module: nothing is left out, any error fails.
  bool entry = false;
  bool checkImports = false;
  String label = '';
  final Set<String> allowedPackages = {};

  /// The `dart:` libraries `//dart:refused_dart_libraries` refuses.
  final Set<String> refusedLibraries = {};

  /// Tests only: the front-end state this request leaves behind throws on
  /// its next use, as a state that went wrong would.
  bool poisonStateForTest = false;

  /// What the front end's state is kept by: it starts over when the target
  /// or the environment changes.
  String get stateKey => [
    target,
    trackWidgetCreation,
    experiments,
    for (final String name in defines.keys.toList()..sort())
      '$name=${defines[name]}',
  ].join('\n');
}

Uri _fileUri(String path) => Uri.base.resolveUri(Uri.file(path));

/// Serves only the files a request declares, and records which it read.
class _DeclaredFileSystem implements FileSystem {
  _DeclaredFileSystem(this.declared);

  final Set<Uri> declared;
  final Set<Uri> read = {};

  @override
  FileSystemEntity entityForUri(Uri uri) {
    if (!declared.contains(uri)) return MissingFileSystemEntity(uri);
    read.add(uri);
    return fe.StandardFileSystem.instance.entityForUri(uri);
  }
}

/// A library the module leaves out, with every source file it is made of.
typedef _LeftOut = ({String reason, List<Uri> files, List<Uri> sources});

class Compiler {
  Compiler({this.persistent = false, this.maxRssMb});

  /// Whether requests come from Bazel with a digest for each input.
  final bool persistent;
  final int? maxRssMb;

  /// The front end's state, by target and environment, least recently used
  /// first. The front end starts over when either changes, and a build
  /// alternates between a few (a test's modules and a binary's, an app's
  /// flavors), so the last two stay loaded.
  final Map<String, fe.InitializedCompilerState> _states = {};
  static const _maxStates = 2;

  /// The `--output` of each request a kept state served, oldest first, so a
  /// retry can say what the state had compiled before it went wrong.
  final Map<String, List<String>> _served = {};
  static const _maxServed = 200;

  /// The keys of the states a test poisoned (`--poison-state-for-test`).
  final Set<String> _poisoned = {};

  void _drop(String key) {
    _states.remove(key);
    _served.remove(key);
    _poisoned.remove(key);
  }

  /// The file a `package:` URI names under the request's package config. A
  /// `part` directive may spell its file that way.
  Uri Function(Uri) _fileOf = (Uri uri) => uri;

  /// Compiles the module [rawArgs] describe. Returns the exit code, with the
  /// diagnostics in [log] when it is not 0.
  ///
  /// A compile that throws anything but a [FormatException] (a request the
  /// tool refuses) is an internal error, not a diagnostic of the program: the
  /// state it used is dropped and the request is compiled once more from a
  /// fresh state. Only when that throws too does the request fail, with both
  /// traces.
  Future<int> compile(
    List<String> rawArgs,
    Map<String, Uint8List> digests,
    StringBuffer log,
  ) async {
    try {
      final List<String>? args = materializePackageConfig(rawArgs, log);
      if (args == null) return 64;
      final request = Request(args);
      final String key = request.stateKey;
      final List<String> served = [...?_served[key]];
      final first = StringBuffer();
      final Object error;
      final StackTrace stack;
      try {
        final int code = await _attempt(request, digests, first);
        log.write(first);
        if (request.poisonStateForTest) _poisoned.add(key);
        return code;
      } on FormatException {
        rethrow;
      } catch (e, s) {
        (error, stack) = (e, s);
      }
      _drop(key);
      final second = StringBuffer();
      try {
        final watch = Stopwatch()..start();
        final int code = await _attempt(request, digests, second);
        log.write(second);
        stderr.writeln(
          '$_tool: an internal error of the front end; the same request '
          'compiled from a fresh state in ${watch.elapsedMilliseconds} ms '
          '(exit $code). To reproduce it, replay in one worker the requests '
          'that state served, oldest first, then this one.\n'
          '  request: ${request.output}\n'
          '${[for (final String output in served) '  served before: $output\n'].join()}'
          '  error: $error\n$stack',
        );
        return code;
      } on FormatException {
        rethrow;
      } catch (e, s) {
        _drop(key);
        log.writeln(
          '$_tool: $error\n$stack\n'
          '$_tool: the same request from a fresh state failed too: $e\n$s',
        );
        return 1;
      }
    } on FormatException catch (e) {
      log.writeln('$_tool: ${e.message}');
      return 64;
    } finally {
      final int? budget = maxRssMb;
      if (budget != null && ProcessInfo.currentRss > budget << 20) {
        _states.keys.toList().forEach(_drop);
      }
    }
  }

  /// One compile of [request], its diagnostics and the front end's prints in
  /// [log].
  Future<int> _attempt(
    Request request,
    Map<String, Uint8List> digests,
    StringBuffer log,
  ) =>
      // The front end prints when it resets its state. In a worker, stdout
      // is the protocol's channel, so a print goes to the log instead.
      runZoned(
        () => _compile(request, digests, log),
        zoneSpecification: ZoneSpecification(
          print: (_, _, _, String line) => log.writeln(line),
        ),
      );

  List<int> _digest(String path, Map<String, Uint8List> digests) =>
      digests[path] ??
      (persistent ? sha256Of(File(path).readAsBytesSync()) : const [0]);

  Future<int> _compile(
    Request r,
    Map<String, Uint8List> digests,
    StringBuffer log,
  ) async {
    final Uri platform = _fileUri(r.platform!);
    final declared = <Uri>{
      platform,
      _fileUri(r.packages!),
      for (final String path in r.inputSources) _fileUri(path),
    };
    final inputDigests = <Uri, List<int>>{
      platform: _digest(r.platform!, digests),
    };
    // Each dependency module: its outline, and the sources it left out, which
    // an entry compiles from source when it reaches them.
    final outlineOf = <String, Uri>{};
    final stagedOf = <String, List<Uri>>{};
    final stagedRoots = <Uri>[];
    // Each source a dependency module left out, by its key: the module's
    // directory and the reason it gave.
    final depLeftOut = <String, ({String dir, String reason})>{};
    for (final String dir in r.inputModules) {
      final index = jsonDecode(
        File('$dir/index.json').readAsStringSync(),
      ) as Map<String, dynamic>;
      if (index['outline'] case final String name) {
        final Uri uri = outlineOf[dir] = _fileUri('$dir/$name');
        declared.add(uri);
        inputDigests[uri] = _digest('$dir/$name', digests);
      }
      final List<String> staged = (index['excluded'] as List).cast<String>();
      final reasons = (index['reasons'] as Map<String, dynamic>?) ?? const {};
      for (final String key in staged) {
        depLeftOut[key] = (
          dir: dir,
          reason: reasons[key] as String? ?? 'left out for the target',
        );
      }
      if (r.entry && staged.isNotEmpty) {
        stagedRoots.add(Uri.base.resolveUri(Uri.directory('$dir/sources')));
        stagedOf[dir] = [
          for (final String key in staged) _fileUri('$dir/sources/$key'),
        ];
        declared.addAll(stagedOf[dir]!);
      }
    }
    // The output must not depend on the order the build names the inputs in.
    final List<Uri> outlines = outlineOf.values.toList()
      ..sort((a, b) => '$a'.compareTo('$b'));
    final files = _DeclaredFileSystem(declared);
    // A staged source comes first, as the copy its own module compiled from.
    final fileSystem = MultiRootFileSystem(r.scheme, [
      ...stagedRoots,
      ...r.roots,
    ], files);
    final flags = TargetFlags(trackCreationLocations: r.trackWidgetCreation);
    final String stateKey = r.stateKey;
    if (_states.containsKey(stateKey)) {
      if (_poisoned.contains(stateKey)) {
        throw StateError('the front-end state was poisoned by a test');
      }
    } else {
      _served.remove(stateKey);
      _poisoned.remove(stateKey);
    }
    (_served[stateKey] ??= []).add(r.output!);
    if (_served[stateKey]!.length > _maxServed) _served[stateKey]!.removeAt(0);
    final sourceSet = r.sources.toSet();
    final leftOut = <Uri, _LeftOut>{};
    var entryPoints = r.entry
        ? r.sources
        : (r.sources.toList()..sort((a, b) => '$a'.compareTo('$b')));

    while (true) {
      final out = StringBuffer();
      final errors = <fe.CfeDiagnosticMessage>[];
      final state = await fe.initializeIncrementalCompiler(
        _states.remove(stateKey),
        {'target=${r.target}', 'track=${r.trackWidgetCreation}'},
        platform,
        _fileUri(r.packages!),
        null,
        outlines,
        inputDigests,
        switch (r.target) {
          'vm' => VmTarget(flags),
          'flutter' => FlutterTarget(flags),
          _ => throw FormatException('unknown target: ${r.target}'),
        },
        fileSystem,
        r.experiments,
        false,
        r.defines,
        trackNeededDillLibraries: true,
      );
      _states[stateKey] = state;
      while (_states.length > _maxStates) {
        _drop(_states.keys.first);
      }
      _keepOneOutlinePerLibrary(state, [platform, ...outlines]);
      state.options.onDiagnostic = (fe.CfeDiagnosticMessage message) {
        fe.printDiagnosticMessage(message, out.writeln);
        if (message.severity == fe.CfeSeverity.error) errors.add(message);
      };
      final compiler = state.incrementalCompiler!;
      final IncrementalCompilerResult result;
      try {
        result = await compiler.computeDelta(
          entryPoints: entryPoints,
          fullComponent: true,
          trackNeededDillLibraries: true,
        );
      } finally {
        state.options.onDiagnostic = null;
      }
      final Component component = result.component;
      final Map<Uri, Uri> fromDill = state.libraryToInputDill!;
      final translator = await state.processedOpts.getUriTranslator();
      _fileOf = (Uri uri) => uri.isScheme('package')
          ? translator.translate(uri, false) ?? uri
          : uri;

      // The libraries this compile built from source, and which are the
      // module's own: its declared sources that no dependency defines.
      final List<Library> compiled = [
        for (final Library library in component.libraries)
          if (!library.importUri.isScheme('dart') &&
              !fromDill.containsKey(library.importUri))
            library,
      ];
      bool isOwn(Library library) =>
          r.entry || sourceSet.contains(library.importUri);
      final List<Library> own = compiled.where(isOwn).toList();
      final ownSet = own.toSet();

      final List<String> misspelled = await _misspelled(
        [
          for (final Uri dill in outlines)
            state.workerInputCache![dill]!.component,
        ],
        compiled,
        fromDill,
        fileSystem,
      );
      if (misspelled.isNotEmpty) {
        misspelled.forEach(log.writeln);
        return 1;
      }
      final Map<Library, _Undeclared> undeclared = await _undeclared(
        r,
        own,
        fromDill,
        fileSystem,
        (Uri uri) => translator.translate(uri, false),
        depLeftOut,
      );
      // An entry may not leave anything out: an undeclared file fails it. A
      // library module leaves the library out, naming the import (another
      // target of a package split across targets may declare the file).
      if (r.entry && undeclared.isNotEmpty) {
        _reportUndeclared(r, undeclared, depLeftOut).forEach(log.writeln);
        return 1;
      }
      if (r.checkImports && leftOut.isEmpty) {
        final List<String> violations = await _layering(r, own, fileSystem);
        if (violations.isNotEmpty) {
          violations.forEach(log.writeln);
          return 1;
        }
      }
      if (r.entry) {
        if (errors.isNotEmpty) {
          log.write(out);
          _explainLeftOut(r, errors, depLeftOut).forEach(log.writeln);
          return 1;
        }
      } else {
        final Map<Library, String>? bad = _unfit(
          r,
          compiled,
          ownSet,
          errors,
          depLeftOut,
          {for (final e in undeclared.entries) e.key: e.value.reason},
        );
        if (bad == null) {
          log.write(out);
          return 1;
        }
        if (bad.isNotEmpty) {
          for (final MapEntry<Library, String> entry in bad.entries) {
            final Library library = entry.key;
            leftOut[library.importUri] = (
              reason: entry.value,
              files: _filesOf(library),
              sources: [
                library.importUri,
                for (final LibraryPart part in library.parts)
                  library.importUri.resolve(part.partUri),
              ],
            );
          }
          // Once more with exactly the libraries that are kept.
          entryPoints = [
            for (final Library library in own)
              if (!bad.containsKey(library)) library.importUri,
          ]..sort((a, b) => '$a'.compareTo('$b'));
          if (entryPoints.isNotEmpty) continue;
          // Nothing is kept: the module is empty.
          await _write(r, component, [], leftOut, fileSystem);
          _writeUnused(r, const []);
          return 0;
        }
      }

      // An entry point a dependency module defines (an app's `lib/main.dart`
      // that its library lists) is not compiled again: the program's `main`
      // is that library's, under the library's own URI, and the link reaches
      // its module through the entry's imports.
      Library? linkedMain;
      Procedure? linkedMainProcedure;
      if (r.entry &&
          r.sources.isNotEmpty &&
          !own.any((l) => l.importUri == r.sources.first)) {
        linkedMain = _dependencyLibrary(r.sources.first, component, [
          for (final Uri dill in outlines)
            state.workerInputCache![dill]!.component,
        ]);
        if (linkedMain == null) {
          log.writeln(
            '$_tool: the entry point ${r.sources.first} is neither a source '
            'of this compile nor a library of a dependency module.',
          );
          return 1;
        }
        linkedMainProcedure = _mainOf(linkedMain);
        if (linkedMainProcedure == null) {
          log.writeln(
            '$_tool: the entry point ${linkedMain.importUri} declares no '
            'top-level `main`.',
          );
          return 1;
        }
      }

      await compiler.context.runInContext((_) async {
        _makeStable(component);
        if (!r.entry) component.setMainMethodAndMode(null, true);
        if (linkedMainProcedure != null) {
          component.setMainMethodAndMode(linkedMainProcedure.reference, true);
        }
        await _write(
          r,
          component,
          own,
          leftOut,
          fileSystem,
          linkedImports: [if (linkedMain != null) _key(linkedMain.fileUri, r)],
        );
      });
      // What was left out was decided on everything the first attempt read,
      // which the kept compile no longer shows: every input then counts as
      // used.
      if (leftOut.isNotEmpty) {
        _writeUnused(r, const []);
        return 0;
      }
      final needed = <Uri?>{
        for (final Library library in result.neededDillLibraries!)
          fromDill[library.importUri],
        // The module that defines the entry point is needed whatever the
        // front end read of it: the program's `main` is there.
        if (linkedMain != null) fromDill[linkedMain.importUri],
      };
      _writeUnused(r, [
        for (final String dir in r.inputModules)
          if (!needed.contains(outlineOf[dir]) &&
              !(stagedOf[dir] ?? const []).any(files.read.contains))
            dir,
        if (r.entry)
          for (final String path in r.inputSources.toSet())
            if (!r.ownSourceFiles.contains(path) &&
                !files.read.contains(_fileUri(path)))
              path,
      ]);
      return 0;
    }
  }

  /// The imports that reach a dependency's source by another URI than the
  /// one its module defines it under: the front end would compile a second
  /// copy of the library from source, where every other consumer links the
  /// module's. Each is refused, naming the importer, the URI as written and
  /// the URI to use.
  Future<List<String>> _misspelled(
    List<Component> dependencies,
    List<Library> compiled,
    Map<Uri, Uri> fromDill,
    FileSystem fileSystem,
  ) async {
    // Only an import of a library compiled from source can be one.
    final fromSource = compiled.toSet();
    if (!compiled.any(
      (l) => l.dependencies.any((d) => fromSource.contains(d.targetLibrary)),
    )) {
      return const [];
    }
    final defined = <Uri, Uri>{
      for (final Component dependency in dependencies)
        for (final Library library in dependency.libraries)
          library.fileUri: library.importUri,
    };
    final lines = <String>[];
    for (final Library library in compiled) {
      for (final LibraryDependency dependency in library.dependencies) {
        final Library target = dependency.targetLibrary;
        final Uri? name = defined[target.fileUri];
        if (name == null || fromDill.containsKey(target.importUri)) continue;
        final String written =
            await _written(fileSystem, library, dependency) ??
            '${target.importUri}';
        lines.add(
          "$_tool: cannot compile ${library.importUri}: import '$written' "
          "reaches a source its dependencies define under '$name'; import "
          'that instead.',
        );
      }
    }
    return lines;
  }

  /// The URI of [dependency] as [library]'s source spells it, or null when
  /// the source does not show it at the directive's offset.
  Future<String?> _written(
    FileSystem fileSystem,
    Library library,
    LibraryDependency dependency,
  ) async {
    final FileSystemEntity entity = fileSystem.entityForUri(library.fileUri);
    if (dependency.fileOffset < 0 || !await entity.exists()) return null;
    final String text = await entity.readAsString();
    if (dependency.fileOffset >= text.length) return null;
    return RegExp(r"""(?:import|export)\s+r?(['"])(.*?)\1""")
        .matchAsPrefix(text, dependency.fileOffset)
        ?.group(2);
  }

  /// Writes the unused-inputs list: Bazel does not rerun the action when
  /// only files it names change.
  void _writeUnused(Request r, List<String> lines) {
    if (r.unusedInputs case final String path) {
      File(path).writeAsStringSync(lines.map((l) => '$l\n').join());
    }
  }

  /// The libraries of a library module that cannot stay, each with the
  /// reason, or null when an error belongs to none of them.
  Map<Library, String>? _unfit(
    Request r,
    List<Library> compiled,
    Set<Library> own,
    List<fe.CfeDiagnosticMessage> errors,
    Map<String, ({String dir, String reason})> depLeftOut,
    Map<Library, String> undeclared,
  ) {
    final owner = <Uri, Library>{
      for (final Library library in compiled)
        for (final Uri file in _filesOf(library)) file: library,
    };
    final fromSource = compiled.toSet();
    final bad = <Library, String>{...undeclared};
    for (final Library library in own) {
      for (final LibraryDependency dependency in library.dependencies) {
        final Library target = dependency.targetLibrary;
        if (fromSource.contains(target) && !own.contains(target)) {
          final ({String dir, String reason})? upstream =
              depLeftOut[_key(target.fileUri, r)];
          bad[library] ??= upstream != null
              ? 'imports ${target.importUri}, which its module left out '
                    '(${upstream.reason})'
              : 'imports ${target.importUri}, which no dependency module '
                    'defines';
        }
      }
    }
    for (final fe.CfeDiagnosticMessage error in errors) {
      final Library? library = owner[getMessageUri(error)];
      if (library == null && undeclared.isNotEmpty) continue;
      if (library == null) return null;
      // An error in a library that is not this module's is left to the
      // rule above: whatever imports that library is left out.
      if (own.contains(library)) {
        bad[library] ??=
            'compile error: ${error.plainTextFormatted.first.split('\n').first}';
      }
    }
    for (var grew = true; grew;) {
      grew = false;
      for (final Library library in own) {
        if (bad.containsKey(library)) continue;
        for (final LibraryDependency dependency in library.dependencies) {
          if (bad.containsKey(dependency.targetLibrary)) {
            bad[library] =
                'imports ${dependency.targetLibrary.importUri}, which is left out';
            grew = true;
            break;
          }
        }
      }
    }
    return bad;
  }

  /// The strict-layering violations of [own]: a `package:` import whose
  /// package is neither the target's own nor a direct dependency's, and an
  /// import or export of a refused `dart:` library.
  ///
  /// The front end resolves a conditional import to the one URI the target
  /// takes, so the others are read from the directives of the module's own
  /// sources: a branch the target does not take may not name an undeclared
  /// package either.
  Future<List<String>> _layering(
    Request r,
    List<Library> own,
    FileSystem fileSystem,
  ) async {
    final lines = <String>{};
    final List<Library> sorted = own.toList()
      ..sort((a, b) => '${a.fileUri}'.compareTo('${b.fileUri}'));
    void check(Library library, String uri, {String kind = 'import'}) {
      if (r.refusedLibraries.contains(uri)) {
        lines.add(refusedLine(r.label, _key(library.fileUri, r), kind, uri));
        return;
      }
      final String? name = packageOfUri(uri);
      if (name == null || r.allowedPackages.contains(name)) return;
      lines.add(violationLine(r.label, _key(library.fileUri, r), uri, name));
    }

    for (final Library library in sorted) {
      for (final LibraryDependency dependency in library.dependencies) {
        check(
          library,
          '${dependency.targetLibrary.importUri}',
          kind: dependency.isExport ? 'export' : 'import',
        );
      }
      final FileSystemEntity entity = fileSystem.entityForUri(library.fileUri);
      if (!await entity.exists()) continue;
      for (final String uri in _conditionalUris(await entity.readAsBytes())) {
        check(library, '${library.importUri.resolve(uri)}');
      }
    }
    return lines.toList();
  }

  /// The imports and exports of [library] (and of its parts) that name a
  /// file the request does not declare, each refused with the URI as written.
  /// A library may still be left out for importing a `dart:` library the
  /// target lacks, for an error of its own, or for importing a library its
  /// dependency module left out; a file that is simply not an input is a
  /// mistake in the build, and leaving the library out would hide it until
  /// something reaches it. An import of a package the package config does not
  /// name is left to the layering check.
  Future<Map<Library, _Undeclared>> _undeclared(
    Request r,
    List<Library> own,
    Map<Uri, Uri> fromDill,
    FileSystem fileSystem,
    Uri? Function(Uri) translate,
    Map<String, ({String dir, String reason})> depLeftOut,
  ) async {
    final exists = <Uri, bool>{};
    Future<bool> present(Uri file) async =>
        exists[file] ??= await fileSystem.entityForUri(file).exists();
    final found = <Library, _Undeclared>{};
    final List<Library> sorted = own.toList()
      ..sort((a, b) => '${a.fileUri}'.compareTo('${b.fileUri}'));
    for (final Library library in sorted) {
      if (!r.entry && !await present(library.fileUri)) {
        final String file = _key(library.fileUri, r);
        found[library] = (
          reason: 'its file $file is not an input of this compile.',
          file: file,
        );
        continue;
      }
      for (final LibraryDependency dependency in library.dependencies) {
        final Library target = dependency.targetLibrary;
        final Uri uri = target.importUri;
        if (uri.isScheme('dart') || fromDill.containsKey(uri)) continue;
        if (uri.isScheme('package') && translate(uri) == null) continue;
        if (depLeftOut.containsKey(_key(target.fileUri, r))) continue;
        if (await present(target.fileUri)) continue;
        if (found.containsKey(library)) continue;
        final String written =
            await _written(fileSystem, library, dependency) ?? '$uri';
        final String file = _key(target.fileUri, r);
        found[library] = (
          reason:
              "${dependency.isExport ? 'export' : 'import'} "
              "'$written' names $file, which is not an input of this "
              'compile. Add it to the srcs of the target that owns it, and '
              'that target to deps.',
          file: file,
        );
      }
      for (final LibraryPart part in library.parts) {
        final Uri file = _fileOf(library.fileUri.resolve(part.partUri));
        if (await present(file) || found.containsKey(library)) continue;
        final String key = _key(file, r);
        found[library] = (
          reason:
              "part '${part.partUri}' names $key, which is not an input of "
              'this compile. Add it to the srcs of the target that owns the '
              'library.',
          file: key,
        );
      }
    }
    return found;
  }

  /// The lines an entry fails with when its program reaches a file that is
  /// not an input: one per missing file, naming the first library (by URI)
  /// that reaches it and how, and how many others do. Every library that
  /// imports a missing file is unfit, so one line per library would repeat
  /// one cause many times over.
  List<String> _reportUndeclared(
    Request r,
    Map<Library, _Undeclared> undeclared,
    Map<String, ({String dir, String reason})> depLeftOut,
  ) {
    final byFile = <String, List<Library>>{};
    for (final MapEntry<Library, _Undeclared> e in undeclared.entries) {
      (byFile[e.value.file] ??= []).add(e.key);
    }
    final lines = <String>[];
    for (final String file in byFile.keys.toList()..sort()) {
      final List<Library> libraries = byFile[file]!
        ..sort((a, b) => '${a.importUri}'.compareTo('${b.importUri}'));
      final Library first = libraries.first;
      final ({String dir, String reason})? upstream =
          depLeftOut[_key(first.fileUri, r)];
      final int others = libraries.length - 1;
      lines.add(
        '$_tool: cannot compile ${first.importUri}: '
        '${undeclared[first]!.reason}'
        '${upstream == null ? '' : ' The module of ${upstream.dir} left it '
                  'out; this program reaches it.'}'
        '${others == 0 ? '' : ' $others more '
                  '${others == 1 ? 'library reaches' : 'libraries reach'} '
                  '$file the same way.'}',
      );
    }
    lines.add(
      '$_tool: a directory with a BUILD file of its own is a package of its '
      'own: a glob in a BUILD file above it does not list its files.',
    );
    return lines;
  }

  /// Why an entry that failed reached a source a dependency module left out:
  /// the entry compiled it from source, and its error is the front end's own,
  /// so each line names the module and the reason it gave.
  List<String> _explainLeftOut(
    Request r,
    List<fe.CfeDiagnosticMessage> errors,
    Map<String, ({String dir, String reason})> depLeftOut,
  ) {
    final lines = <String>{};
    for (final fe.CfeDiagnosticMessage error in errors) {
      final Uri? uri = getMessageUri(error);
      if (uri == null) continue;
      final String key = _key(uri, r);
      final ({String dir, String reason})? upstream = depLeftOut[key];
      if (upstream == null) continue;
      lines.add(
        '$_tool: $key is not in the module of ${upstream.dir}, which left it '
        'out: ${upstream.reason}. This program reaches it, so it compiled it '
        'from source.',
      );
    }
    return lines.toList()..sort();
  }

  /// The file of [library] and of each of its parts.
  List<Uri> _filesOf(Library library) => [
    library.fileUri,
    for (final LibraryPart part in library.parts)
      _fileOf(library.fileUri.resolve(part.partUri)),
  ];

  /// The library [uri] names in the compile's result or in a dependency
  /// outline, or null.
  Library? _dependencyLibrary(
    Uri uri,
    Component component,
    List<Component> dependencies,
  ) {
    for (final Component c in [component, ...dependencies]) {
      for (final Library library in c.libraries) {
        if (library.importUri == uri) return library;
      }
    }
    return null;
  }

  /// The top-level `main` of [library], as the front end finds it for an
  /// entry point it compiles: declared there, or exported by it.
  Procedure? _mainOf(Library library) {
    for (final Procedure procedure in library.procedures) {
      if (procedure.name.text == 'main' && procedure.isStatic) {
        return procedure;
      }
    }
    for (final Reference reference in library.additionalExports) {
      final TreeNode? node = reference.node;
      if (node is Procedure && node.name.text == 'main') return node;
    }
    return null;
  }

  Future<void> _write(
    Request r,
    Component component,
    List<Library> own,
    Map<Uri, _LeftOut> leftOut,
    FileSystem fileSystem, {
    List<String> linkedImports = const [],
  }) async {
    own.sort((a, b) => '${a.fileUri}'.compareTo('${b.fileUri}'));
    final List<Uri> ownFiles = own.expand(_filesOf).toList();
    final String output = r.output!;
    Directory(output).createSync(recursive: true);
    List<String> importsOf(Set<Library> group) => {
      for (final Library library in group)
        for (final LibraryDependency dependency in library.dependencies)
          if (!dependency.targetLibrary.importUri.isScheme('dart') &&
              !group.contains(dependency.targetLibrary))
            _key(dependency.targetLibrary.fileUri, r),
    }.toList()..sort();
    final List<Map<String, Object>> kernels;
    if (r.entry) {
      // The entry keeps its source text. A native-assets mapping follows it
      // as a component of its own, as `frontend_server` writes it for a JIT
      // program: the VM loads the concatenation as one program.
      final bytes = BytesBuilder(copy: false)
        ..add(_serialize(component, own.toSet().contains));
      if (r.nativeAssets case final String path) {
        bytes.add(_nativeAssetsKernel(path));
      }
      File('$output/$_entryDill').writeAsBytesSync(bytes.takeBytes());
      kernels = [
        {
          'dill': _entryDill,
          'defines': const <String>[],
          'imports': {...importsOf(own.toSet()), ...linkedImports}.toList()
            ..sort(),
        },
      ];
    } else {
      final List<List<Library>> groups = _stronglyConnected(own);
      kernels = [
        for (final (int i, List<Library> group) in groups.indexed)
          {
            'dill': '$i.dill',
            'defines': [
              for (final Library library in group)
                for (final Uri file in _filesOf(library)) _key(file, r),
            ]..sort(),
            'imports': importsOf(group.toSet()),
          },
      ];
      for (final (int i, List<Library> group) in groups.indexed) {
        File('$output/$i.dill').writeAsBytesSync(
          _serialize(component, group.toSet().contains, textless: ownFiles),
        );
      }
    }
    const json = JsonEncoder.withIndent('  ');
    File(
      '$output/index.json',
    ).writeAsStringSync('${json.convert({'version': 1, 'sccs': kernels})}\n');

    // The sidecar: a count for the build log, then each source left out.
    if (r.excluded != null) {
      final lines = StringBuffer();
      if (!r.entry) {
        final int listed = own.length + leftOut.length;
        lines.writeln(
          '# ${own.length} of $listed libraries compile; the others are left '
          'out for the target.',
        );
        final prefix = '${r.scheme}:///';
        for (final _LeftOut library in leftOut.values) {
          for (final (int i, Uri source) in library.sources.indexed) {
            lines.writeln('$source\t${library.reason}');
            if (!'$source'.startsWith(prefix)) {
              lines.writeln(
                '$prefix${_key(library.files[i], r)}\t${library.reason}',
              );
            }
          }
        }
      }
      File(r.excluded!).writeAsStringSync('$lines');
    }

    final String? outline = r.outline;
    if (outline == null) return;
    Directory(outline).createSync(recursive: true);
    final staged = <String>[];
    final reasons = <String, String>{};
    for (final _LeftOut library in leftOut.values) {
      for (final Uri file in library.files) {
        final FileSystemEntity entity = fileSystem.entityForUri(file);
        if (!await entity.exists()) continue;
        final String key = _key(file, r);
        File('$outline/sources/$key')
          ..parent.createSync(recursive: true)
          ..writeAsBytesSync(await entity.readAsBytes());
        staged.add(key);
        reasons[key] = library.reason;
      }
    }
    // From here the libraries are stripped in place; the next request
    // discards them anyway. A library that declares a class that can be
    // mixed in keeps its offsets and line starts, so a copy of the mixin's
    // members reports the right positions; the others carry neither, so an
    // edit that only moves code leaves them byte-identical.
    own.forEach(stripToOutline);
    final Set<Library> whole = {
      for (final Library library in own)
        if (library.classes.any(canBeMixedIn)) library,
    };
    final Set<Library> plain = own.toSet().difference(whole);
    final bytes = BytesBuilder(copy: false);
    if (plain.isNotEmpty) {
      bytes.add(_serialize(component, plain.contains, sources: false));
    }
    if (whole.isNotEmpty) {
      bytes.add(_serialize(component, whole.contains, textless: ownFiles));
    }
    if (own.isNotEmpty) {
      File('$outline/$_outlineDill').writeAsBytesSync(bytes.takeBytes());
    }
    File('$outline/index.json').writeAsStringSync(
      '${json.convert({
        'version': 2,
        'outline': own.isEmpty ? null : _outlineDill,
        'excluded': staged..sort(),
        'reasons': {for (final String key in staged) key: reasons[key]},
      })}\n',
    );
  }
}

/// Keeps the front end's cache of loaded outlines at one outline per library.
///
/// Every outline the front end loads binds the shared references of its
/// libraries (one per class, member and library, by canonical name) to its
/// own nodes. An older outline of the same library that stays cached then has
/// nodes its own references no longer reach: a later request that reuses it
/// builds its dependency's classes from those nodes, while every reference,
/// such as a dependant's `extends`, reaches the newer outline's. That request
/// sees two copies of one class, and the front end fails on it (a
/// `super(...)` whose constructor belongs to neither copy's hierarchy: "Null
/// check operator used on a null value" in `visitInternalSuperInitializer`;
/// "No class info for ..." in the class hierarchy).
///
/// The front end means to evict the older outline when it loads one that
/// defines the same library, by the owner it records for each library
/// (`InitializedCompilerState.workerInputCacheLibs`). But when it evicts one,
/// it records no owner for the library it loaded
/// (`initializeIncrementalCompiler` in the SDK's
/// `pkg/front_end/lib/src/api_unstable/modular_incremental_compilation.dart`,
/// the same at 3.13.5 and on `main` in November 2026), so the next outline of
/// that library, loaded from a third URI, evicts nothing. A worker sees one
/// library under several URIs whenever a build has one module in two
/// configurations with the same target and environment (`bazel-out/k8-dbg`
/// and `bazel-out/k8-dbg-ST-<hash>`; a tool's module and the target's), and
/// Bazel hands such requests to one worker in any order.
///
/// So after every initialization: each cached outline that is not an input
/// of this request and defines a library an input defines is dropped (the
/// inputs own the references now), and the owner of every cached library is
/// recorded again from what stays.
void _keepOneOutlinePerLibrary(
  fe.InitializedCompilerState state,
  List<Uri> inputs,
) {
  final cache = state.workerInputCache!;
  final Set<Uri> current = inputs.toSet();
  final defined = <Uri>{
    for (final Uri uri in current)
      if (cache[uri] case final input?)
        for (final Library library in input.component.libraries)
          library.importUri,
  };
  cache.removeWhere(
    (Uri uri, input) =>
        !current.contains(uri) &&
        input.component.libraries.any(
          (Library library) => defined.contains(library.importUri),
        ),
  );
  state.workerInputCacheLibs!
    ..clear()
    ..addAll({
      for (final MapEntry(key: Uri uri, value: input) in cache.entries)
        for (final Library library in input.component.libraries)
          library.importUri: uri,
    });
}

/// The path of a multi-root [file] below its root: the key a module index
/// names a library by.
String _key(Uri file, Request r) =>
    file.isScheme(r.scheme) ? file.path.substring(1) : '$file';

/// The strongly connected components of [own]'s import graph, each sorted,
/// every component after the components it reaches (Tarjan's algorithm).
/// [own] is sorted, and so are the successors, so the same libraries always
/// give the same components in the same order.
List<List<Library>> _stronglyConnected(List<Library> own) {
  final members = own.toSet();
  final index = <Library, int>{};
  final low = <Library, int>{};
  final stack = <Library>[];
  final onStack = <Library>{};
  final out = <List<Library>>[];
  int byFile(Library a, Library b) => '${a.fileUri}'.compareTo('${b.fileUri}');
  void visit(Library v) {
    index[v] = low[v] = index.length;
    stack.add(v);
    onStack.add(v);
    final List<Library> successors = {
      for (final LibraryDependency dependency in v.dependencies)
        if (members.contains(dependency.targetLibrary))
          dependency.targetLibrary,
    }.toList()..sort(byFile);
    for (final Library w in successors) {
      if (!index.containsKey(w)) {
        visit(w);
        if (low[w]! < low[v]!) low[v] = low[w]!;
      } else if (onStack.contains(w) && index[w]! < low[v]!) {
        low[v] = index[w]!;
      }
    }
    if (low[v] == index[v]) {
      final component = <Library>[];
      Library w;
      do {
        w = stack.removeLast();
        onStack.remove(w);
        component.add(w);
      } while (w != v);
      out.add(component..sort(byFile));
    }
  }

  for (final Library library in own) {
    if (!index.containsKey(library)) visit(library);
  }
  return out;
}

/// The URIs of the conditional imports and exports in [source]: the default
/// and each configuration's, as written. Parsed by the SDK's own parser,
/// which skips every declaration body.
List<String> _conditionalUris(Uint8List source) {
  final listener = _ConditionalUris();
  try {
    TopLevelParser(
      listener,
      experimentalFeatures: const DefaultExperimentalFeatures(),
    ).parseUnit(scan(source).tokens);
  } catch (_) {
    // A source the parser cannot read fails its compile on its own.
    return const [];
  }
  return listener.uris;
}

class _ConditionalUris extends Listener {
  final List<String> uris = [];
  bool _inDirective = false;
  bool _inCondition = false;
  final List<String> _strings = [];
  final List<String> _conditional = [];

  @override
  void beginImport(Token importKeyword) => _begin();

  @override
  void beginExport(Token token) => _begin();

  void _begin() {
    _inDirective = true;
    _default = null;
    _strings.clear();
    _conditional.clear();
  }

  @override
  void beginConditionalUri(Token ifKeyword) {
    _inCondition = true;
    _strings.clear();
  }

  @override
  void endConditionalUri(Token ifKeyword, Token leftParen, Token? equalSign) {
    // The last string of a configuration is its URI; one before it is the
    // value the condition compares with.
    if (_strings.isNotEmpty) _conditional.add(_strings.last);
    _inCondition = false;
    _strings.clear();
  }

  /// The directive's first string: its default URI.
  String? _default;

  @override
  void beginLiteralString(Token token) {
    if (!_inDirective) return;
    final String value = unescapeString(token.lexeme, token, this);
    if (_inCondition) {
      _strings.add(value);
    } else {
      _default ??= value;
    }
  }

  @override
  void endImport(Token importKeyword, Token? semicolon) => _end();

  @override
  void endExport(Token exportKeyword, Token semicolon) => _end();

  void _end() {
    if (_conditional.isNotEmpty) {
      uris.addAll([?_default, ..._conditional]);
    }
    _inDirective = false;
    _default = null;
    _strings.clear();
    _conditional.clear();
  }
}

/// The kernel `frontend_server --native-assets` appends to a JIT program for
/// the mapping in [path]: one library, `vm:ffi:native-assets`, whose pragma
/// carries the mapping the VM resolves `@Native` assets with. As the SDK's
/// `NativeAssetsSynthesizer` writes it, against a stand-in `pragma` class: the
/// reference is symbolic, so the kernel binds it to `dart:core`'s.
Uint8List _nativeAssetsKernel(String path) {
  final Object? yaml = loadYaml(File(path).readAsStringSync());
  final Object? version = yaml is Map ? yaml['format-version'] : null;
  final Object? assets = yaml is Map ? yaml['native-assets'] : null;
  if (version is! List || version.isEmpty || version.first != 1) {
    throw FormatException("$path: expected 'format-version: [1, ...]'.");
  }
  if (assets is! Map) {
    throw FormatException("$path: expected a 'native-assets' map.");
  }
  final dummy = Uri.parse('dummy');
  final dartCore = Uri.parse('dart:core');
  final pragma = Class(
    name: 'pragma',
    fileUri: dartCore,
    fields: [
      Field.immutable(Name('name'), fileUri: dummy),
      Field.immutable(Name('options'), fileUri: dummy),
    ],
  );
  Component(
    libraries: [
      Library(dartCore, fileUri: dummy, classes: [pragma]),
    ],
  );
  Expression annotation(String name, Constant options) => ConstantExpression(
    InstanceConstant(pragma.reference, [], {
      pragma.fields[0].fieldReference: StringConstant(name),
      pragma.fields[1].fieldReference: options,
    }),
  );
  final library = Library(
    Uri.parse('vm:ffi:native-assets'),
    name: 'vm:ffi:native-assets',
    fileUri: dummy,
    annotations: [
      annotation('vm:entry-point', NullConstant()),
      annotation('vm:ffi:native-assets', jsonToKernelConstant(assets)),
    ],
  );
  final sink = _Bytes();
  BinaryPrinter(sink).writeComponentFile(Component(libraries: [library]));
  return sink.builder.takeBytes();
}

/// As `makeStable` in the SDK's `compute_kernel.dart`.
void _makeStable(Component component) {
  component.libraries.sort((a, b) => '${a.fileUri}'.compareTo('${b.fileUri}'));
  component.problemsAsJson?.sort();
  component.computeCanonicalNames();
  for (final Library library in component.libraries) {
    library.additionalExports.sort();
    library.problemsAsJson?.sort();
  }
}

/// Serializes the libraries [filter] keeps. With [sources] the kernel
/// carries offsets and the source table; the text of the files in [textless]
/// is left out of it, which leaves their line starts.
///
/// Only the module's own files lose their text. A kernel also names files of
/// other libraries (a member copied from a mixin keeps its file), and their
/// entries are written as the library that owns them has them: the VM
/// refuses a program whose kernels disagree about one file, and a Flutter
/// link begins with the platform, which holds the SDK's text.
Uint8List _serialize(
  Component component,
  bool Function(Library) filter, {
  bool sources = true,
  Iterable<Uri> textless = const [],
}) {
  final Map<Uri, Source> table = component.uriToSource;
  final saved = <Uri, Source>{};
  for (final Uri file in textless) {
    final Source? source = table[file];
    if (source == null) continue;
    saved[file] = source;
    table[file] = Source.emptySource(
      source.lineStarts,
      source.importUri,
      source.fileUri,
    )..constantCoverageConstructors = source.constantCoverageConstructors;
  }
  final sink = _Bytes();
  try {
    BinaryPrinter(
      sink,
      libraryFilter: filter,
      includeSources: sources,
      includeOffsets: sources,
    ).writeComponentFile(component);
  } finally {
    table.addAll(saved);
  }
  return sink.builder.takeBytes();
}

class _Bytes implements Sink<List<int>> {
  final BytesBuilder builder = BytesBuilder(copy: false);
  @override
  void add(List<int> data) => builder.add(data);
  @override
  void close() {}
}

Future<void> main(List<String> argv) async {
  int? maxRssMb;
  var persistent = false;
  final rest = <String>[];
  for (final String arg in argv) {
    if (arg == '--persistent_worker') {
      persistent = true;
    } else if (arg.startsWith('--max-rss-mb=')) {
      maxRssMb = int.parse(arg.substring('--max-rss-mb='.length));
    } else {
      rest.add(arg);
    }
  }
  final compiler = Compiler(persistent: persistent, maxRssMb: maxRssMb);
  if (persistent) {
    await serveWorker(
      input: stdin,
      output: stdout,
      maxConcurrent: 1,
      handle: (Uint8List frame, _) async {
        final request = WorkerRequest.read(frame);
        final log = StringBuffer();
        final int code = await compiler.compile(
          request.arguments,
          request.inputs,
          log,
        );
        return (exitCode: code, output: log.toString());
      },
    );
    await stdout.flush();
    exit(0);
  }
  final log = StringBuffer();
  final int code = await compiler.compile(
    expandParamFiles(rest),
    const {},
    log,
  );
  if (code != 0) stderr.write(log);
  await stderr.flush();
  exit(code);
}
