/// Runs `build_runner`'s own build engine as a Bazel action.
///
/// The builders, their `build.yaml` and their order come from the generated
/// entry point (written by `bin/gen_entry.dart` from the `build.yaml` of every
/// builder package in the user's lock, the way `build_runner` writes
/// `.dart_tool/build/entrypoint/build.dart`) and from `build_runner`'s own
/// planning code. Nothing here names a builder.
///
/// One request builds the declared outputs of one Dart package. Its arguments
/// (one per line in a parameter file):
///
///   --target <label>                identity of the Bazel target
///   --pubspec <path>                the package's pubspec.yaml; its directory
///                                   is the package root
///   --pkg <name>=<dir>=<version>    where a dependency's files live, and its
///                                   language version (may be empty)
///   --bin-dir <path>                Bazel's output directory: each package
///                                   directory is also looked up below it
///   --package-graph <path>          the lock's package graph, as pub writes
///                                   `.dart_tool/package_graph.json`
///   --sdk-summary <path>            the SDK summary the analyzer uses
///   --in <path>                     a declared input
///   --out <asset path>=<path>       a declared output of the package
///   --undeclared <asset path>       a file of the package that is not an
///                                   input; a builder glob that could see it
///                                   fails the action
///   --arg <flag>                    a `build_runner build` flag (`--release`,
///                                   `--define=...`, `--config=...`)
///
/// Inputs are read from disk on demand and everything the build writes is
/// kept in memory; only the declared outputs are written out. Outputs are
/// selected with build filters, so `build_runner` builds exactly them plus
/// whatever its own phases need, as `build_runner build --build-filter` does.
///
/// With `--persistent_worker` it serves Bazel's JSON worker protocol and keeps
/// `build_runner`'s build series per target, the state `build_runner watch`
/// keeps between builds. A request whose inputs differ from the previous
/// request for the same target by their digests is built incrementally from
/// that state, as `watch` builds after a file change. Anything else (a first
/// request, a changed `pubspec.yaml` or `build.yaml`, other arguments, a run
/// outside a worker) builds from nothing.
///
/// `--emit-sdk-summary <path>` (with `--embedder <label>` and the
/// `--embedder-yaml <path>` of Flutter's `sky_engine`) writes the SDK summary
/// instead, with the analyzer's own
/// `buildSdkSummary`, as `build_runner` does under `.dart_tool`.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:analyzer/dart/sdk/build_sdk_summary.dart';
import 'package:analyzer/file_system/physical_file_system.dart';
import 'package:build/build.dart';
// The internal entry points `build_runner`'s generated build script and
// `package:build_test` use: build_runner has no public in-process API.
// ignore_for_file: implementation_imports
import 'package:build_runner/src/bootstrap/build_process_state.dart';
import 'package:build_runner/src/build/build_result.dart';
import 'package:build_runner/src/build/build_series.dart';
import 'package:build_runner/src/build/resolver/analysis_driver_model.dart';
import 'package:build_runner/src/build/resolver/resolvers_impl.dart';
import 'package:build_runner/src/build_plan/build_filter.dart';
import 'package:build_runner/src/build_plan/build_options.dart';
import 'package:build_runner/src/build_plan/build_package.dart';
import 'package:build_runner/src/build_plan/build_packages.dart';
import 'package:build_runner/src/build_plan/build_paths.dart';
import 'package:build_runner/src/build_plan/build_plan.dart';
import 'package:build_runner/src/build_plan/build_spec.dart';
import 'package:build_runner/src/build_plan/builder_factories.dart';
import 'package:build_runner/src/build_plan/testing_overrides.dart';
import 'package:build_runner/src/build_runner_command_line.dart';
import 'package:build_runner/src/commands/watch/asset_change.dart';
import 'package:build_runner/src/io/asset_finder.dart';
import 'package:build_runner/src/io/filesystem.dart';
import 'package:build_runner/src/io/reader_writer.dart';
import 'package:build_runner/src/logging/build_log.dart';
import 'package:built_collection/built_collection.dart';
import 'package:glob/glob.dart';
import 'package:logging/logging.dart';
import 'package:package_config/package_config.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';
import 'package:watcher/watcher.dart' show ChangeType;
import 'package:yaml/yaml.dart';

/// Entry point called by the generated `entry.dart`.
///
/// [buildYamls] maps each builder package to the text of its `build.yaml`,
/// captured when the entry point was generated.
Future<void> runnerMain(
  List<String> args,
  BuilderFactories factories,
  Map<String, String> buildYamls,
) async {
  final runner = _Runner(factories, buildYamls);
  if (args.contains('--persistent_worker')) {
    await runner.serveJsonWorker();
    exit(0);
  }
  final response = await runner.handle(await _expandArgs(args), null);
  if (response.output.isNotEmpty) stderr.write(response.output);
  await runner.close();
  exit(response.exitCode);
}

class _Response {
  final int exitCode;
  final String output;
  _Response(this.exitCode, this.output);
}

/// One request's arguments, every path made absolute against the directory
/// the process started in (the execution root).
class _Request {
  final String execRoot;
  String? target;
  String? pubspec;
  String? binDir;
  String? packageGraph;
  String? sdkSummary;
  String? emitSdkSummary;
  String? embedder;
  final List<String> embedderYamls = [];
  final packageDirs = <_PackageDir>[];
  final languageVersions = <String, String>{};
  final inputs = <String>[];
  final outputs = <String, String>{};
  final undeclared = <String>[];
  final buildRunnerArgs = <String>[];
  bool timings = false;

  /// Everything that, when it changes, needs a build from nothing: all
  /// arguments but the inputs, outputs and undeclared files.
  final _signature = StringBuffer();

  String get signature => _signature.toString();

  _Request(this.execRoot);

  static _Request parse(List<String> args, String execRoot) {
    String abs(String path) => p.normalize(p.join(execRoot, path));
    final r = _Request(execRoot);
    for (var i = 0; i < args.length; i++) {
      final a = args[i];
      String next() {
        if (i + 1 >= args.length) throw ArgumentError('$a needs a value');
        return args[++i];
      }

      switch (a) {
        case '--in':
          r.inputs.add(abs(next()));
          continue;
        case '--out':
          final kv = next();
          final eq = kv.indexOf('=');
          r.outputs[kv.substring(0, eq)] = abs(kv.substring(eq + 1));
          continue;
        case '--undeclared':
          r.undeclared.add(next());
          continue;
        case '--timings':
          r.timings = true;
          continue;
      }
      final value = next();
      r._signature.writeln('$a $value');
      switch (a) {
        case '--target':
          r.target = value;
        case '--pubspec':
          r.pubspec = abs(value);
        case '--bin-dir':
          r.binDir = abs(value);
        case '--package-graph':
          r.packageGraph = abs(value);
        case '--sdk-summary':
          r.sdkSummary = abs(value);
        case '--emit-sdk-summary':
          r.emitSdkSummary = abs(value);
        case '--embedder':
          r.embedder = value;
        case '--embedder-yaml':
          r.embedderYamls.add(abs(value));
        case '--arg':
          r.buildRunnerArgs.add(value);
        case '--pkg':
          final parts = value.split('=');
          if (parts.length != 3) {
            throw ArgumentError('--pkg wants <name>=<dir>=<language version>');
          }
          r.packageDirs.add(_PackageDir(parts[0], abs(parts[1])));
          if (parts[2].isNotEmpty) r.languageVersions[parts[0]] = parts[2];
        default:
          throw ArgumentError('Unknown argument: $a');
      }
    }
    if (r.emitSdkSummary != null) return r;
    for (final (name, value) in [
      ('--target', r.target),
      ('--pubspec', r.pubspec),
      ('--package-graph', r.packageGraph),
    ]) {
      if (value == null) throw ArgumentError('$name is required');
    }
    return r;
  }
}

class _PackageDir {
  final String package;
  final String dir;
  _PackageDir(this.package, this.dir);
}

Future<List<String>> _expandArgs(List<String> args) async {
  // Bazel passes a params file as the only argument; elsewhere an argument
  // starting with `@` is a value (a label).
  if (args.length != 1 || !args.single.startsWith('@')) return args;
  return (await File(args.single.substring(1)).readAsLines())
      .where((l) => l.isNotEmpty)
      .toList();
}

class _Runner {
  final BuilderFactories factories;
  final Map<String, String> buildYamls;

  /// Where relative paths in requests point: the directory Bazel started the
  /// process in. The process itself works in [_scratch], because
  /// `build_runner` keeps its SDK summary under `.dart_tool` of the current
  /// directory.
  final String _execRoot = Directory.current.path;
  late final Directory _scratch = _makeScratch();

  /// The SDK summary currently under `.dart_tool/build_resolvers`.
  String? _seededSummary;

  /// Numbers the scratch directories of target states.
  var _stateCount = 0;

  /// Build series of recent targets, least recently used first.
  final _targets = LinkedHashMap<String, _TargetState>();

  /// How many targets keep their build series in one process. Each holds an
  /// analysis driver over its package's closure.
  static const _maxTargets = 8;

  _Runner(this.factories, this.buildYamls);

  Directory _makeScratch() {
    final dir = Directory.systemTemp.createTempSync('dart_build_runner');
    Directory(p.join(dir.path, '.dart_tool')).createSync();
    // What the parent `build_runner` process hands its child: the package
    // config. Only the SDK summary check reads it (for where `analyzer` and
    // `build_runner` are); every build gets its own package config.
    final config = File(p.join(dir.path, 'process_package_config.json'));
    config.writeAsStringSync(
      json.encode({
        'configVersion': 2,
        'packages': [
          for (final name in ['analyzer', 'build_runner'])
            {
              'name': name,
              'rootUri': Uri.directory(p.join(dir.path, 'process', name)).toString(),
              'packageUri': 'lib/',
            },
        ],
      }),
    );
    buildProcessState.deserializeAndSet(
      json.encode({'packageConfigUri': p.toUri(config.path).toString()}),
    );
    Directory.current = dir;
    return dir;
  }

  Future<void> close() async {
    for (final state in _targets.values) {
      await state.series.close();
    }
    _targets.clear();
    try {
      _scratch.deleteSync(recursive: true);
    } on FileSystemException {
      // Best effort: the directory is under the system temp.
    }
  }

  Future<void> serveJsonWorker() async {
    final lines = stdin.transform(utf8.decoder).transform(const LineSplitter());
    await for (final line in lines) {
      if (line.trim().isEmpty) continue;
      final request = json.decode(line) as Map<String, Object?>;
      final args = (request['arguments'] as List? ?? const []).cast<String>();
      final id = request['requestId'] ?? 0;
      final digests = <String, String>{};
      for (final input in (request['inputs'] as List? ?? const [])) {
        final map = input as Map<String, Object?>;
        digests[p.normalize(p.join(_execRoot, map['path'] as String))] =
            (map['digest'] as String?) ?? '';
      }
      _Response response;
      try {
        // Bazel sends a worker the lines of the parameter file as arguments.
        response = await handle(args, digests);
      } catch (e, s) {
        response = _Response(1, '$e\n$s\n');
      }
      stdout.writeln(
        json.encode({
          'exitCode': response.exitCode,
          'output': response.output,
          'requestId': id,
        }),
      );
      await stdout.flush();
    }
    await close();
  }

  /// Runs one request. [digests] are the request's input digests in a
  /// worker, or `null` when there is no previous state to build on.
  Future<_Response> handle(List<String> args, Map<String, String>? digests) async {
    final log = StringBuffer();
    final sw = Stopwatch()..start();
    final request = _Request.parse(args, _execRoot);
    final ok = await IOOverrides.runZoned(
      () => request.emitSdkSummary != null
          ? _emitSdkSummary(request)
          : _build(request, digests, log),
      stdout: () => _BufferStdout(log),
      stderr: () => _BufferStdout(log),
    );
    if (request.timings) {
      log.writeln('dart_build_runner: ${sw.elapsedMilliseconds} ms');
    }
    return _Response(ok ? 0 : 1, log.toString());
  }

  Future<bool> _emitSdkSummary(_Request request) async {
    final embedder = request.embedder;
    if (embedder != null && request.embedderYamls.length != 1) {
      stderr.writeln(
        '`embedder` $embedder ships ${request.embedderYamls.length} '
        '`lib/_embedder.yaml` files in its closure; '
        'it needs exactly one (Flutter\'s `sky_engine`).',
      );
      return false;
    }
    final sdk = p.dirname(p.dirname(Platform.resolvedExecutable));
    final bytes = await buildSdkSummary(
      sdkPath: sdk,
      resourceProvider: PhysicalResourceProvider.INSTANCE,
      embedderYamlPath: embedder == null ? null : request.embedderYamls.single,
    );
    File(request.emitSdkSummary!).writeAsBytesSync(bytes);
    return true;
  }

  Future<bool> _build(
    _Request request,
    Map<String, String>? digests,
    StringBuffer log,
  ) async {
    final model = _PackageModel.load(request, buildYamls);
    final root = model.root;

    var state = _targets.remove(request.target);
    final changes = state == null || digests == null
        ? null
        : state.changesTo(request, digests, model);
    if (changes == null && state != null) {
      await state.series.close();
      state = null;
    }

    final records = <LogRecord>[];
    buildLog.configuration = buildLog.configuration.rebuild((b) {
      b.mode = BuildLogMode.build;
      b.verbose = false;
      b.verboseDurations = request.timings;
      b.onLog = records.add;
    });

    final filters = {
      for (final asset in request.outputs.keys)
        BuildFilter(Glob(_escape(root)), Glob(_escape(asset))),
    }.build();

    BuildResult result;
    if (state == null) {
      state = await _TargetState.create(
        request: request,
        model: model,
        factories: factories,
        scratch: p.join(_scratch.path, 'targets', '${_stateCount++}'),
        filters: filters,
        onLog: records.add,
      );
      await _seedSdkSummary(request);
      result = await state.series.run(
        {},
        recentlyBootstrapped: true,
        buildFilters: filters,
      );
    } else {
      state.updateInputs(model);
      final filtered = await state.series.filterChanges(changes!);
      result = await state.series.run(
        {for (final c in filtered.accepted) c.id},
        recentlyBootstrapped: false,
        buildFilters: filters,
      );
    }
    state.digests = digests ?? const {};
    if (digests != null) {
      _targets[request.target!] = state;
      while (_targets.length > _maxTargets) {
        final oldest = _targets.keys.first;
        await _targets.remove(oldest)!.series.close();
      }
    } else {
      await state.series.close();
    }

    for (final r in records) {
      if (r.level >= Level.WARNING || request.timings) {
        log.writeln('[${r.level}] ${r.loggerName}: ${r.message}');
        if (r.error != null) log.writeln(r.error);
        if (r.stackTrace != null) log.writeln(r.stackTrace);
      }
    }
    if (result.status != BuildStatus.success) {
      // Start the next build of this target from nothing.
      await _targets.remove(request.target)?.series.close();
      log.writeln(
        'build_runner failed${result.errors.isEmpty ? '' : ':\n${result.errors.join('\n')}'}',
      );
      return false;
    }

    final globErrors = state.undeclaredGlobMatches(result, request.undeclared);
    if (globErrors.isNotEmpty) {
      log.writeln(globErrors.join('\n'));
      return false;
    }

    // Copy the declared outputs out of memory.
    final missing = <String>[];
    for (final entry in request.outputs.entries) {
      final bytes = state.fs.outputBytes(state.rootPath, root, entry.key);
      final out = File(entry.value);
      if (out.existsSync()) out.deleteSync();
      if (bytes == null) {
        missing.add(entry.key);
        continue;
      }
      out.parent.createSync(recursive: true);
      out.writeAsBytesSync(bytes);
    }
    if (missing.isNotEmpty) {
      log.writeln(
        'No builder wrote ${missing.map((m) => '`$m`').join(', ')} of package '
        '$root. `build_runner build` writes no file there either, so it is '
        'not an output: remove it from `outs`.',
      );
      return false;
    }
    return true;
  }

  /// Puts the request's SDK summary where `build_runner`'s
  /// `defaultSdkSummaryGenerator` looks for it, with the dependency file that
  /// generator writes beside it, so it is taken as fresh and not rebuilt.
  Future<void> _seedSdkSummary(_Request request) async {
    final summary = request.sdkSummary;
    if (summary == null || summary == _seededSummary) return;
    final dir = Directory(p.join('.dart_tool', 'build_resolvers'))
      ..createSync(recursive: true);
    final target = p.join(dir.path, 'sdk.sum');
    File(summary).copySync(target);
    final config = await loadPackageConfigUri(
      Uri.parse(buildProcessState.packageConfigUri),
    );
    String packagePath(String name) =>
        p.dirname(p.fromUri(config.resolve(Uri.parse('package:$name/'))!));
    File('$target.deps').writeAsStringSync(
      jsonEncode({
        'sdk': Platform.version,
        'analyzer': packagePath('analyzer'),
        'build_runner': packagePath('build_runner'),
      }),
    );
    _seededSummary = summary;
  }
}

/// The packages of one request: where their files are, their language
/// versions and dependencies, and which declared input is which asset.
class _PackageModel {
  final String root;
  final String rootDir;

  /// Package name to its directories (source tree and output tree).
  final Map<String, List<String>> dirs;
  final Map<String, LanguageVersion?> languageVersions;
  final Map<String, List<String>> dependencies;

  /// Declared input path to its asset.
  final Map<String, AssetId> assets;

  /// Package name to the `build.yaml` text its build uses, if any.
  final Map<String, String> buildYamls;

  /// The root package's other `build.<config>.yaml` files, by asset path.
  final Map<String, String> rootConfigYamls;

  _PackageModel._(
    this.root,
    this.rootDir,
    this.dirs,
    this.languageVersions,
    this.dependencies,
    this.assets,
    this.buildYamls,
    this.rootConfigYamls,
  );

  static _PackageModel load(_Request request, Map<String, String> builderYamls) {
    final pubspec = _readYaml(request.pubspec!);
    final root = pubspec['name'] as String;
    final rootDir = p.dirname(request.pubspec!);

    final dirs = <String, List<String>>{};
    void addDir(String name, String dir) {
      final list = dirs.putIfAbsent(name, () => []);
      if (!list.contains(dir)) list.add(dir);
      // Generated files of a package live below Bazel's output directory.
      final bin = request.binDir;
      if (bin != null && dir != bin && !p.isWithin(bin, dir)) {
        final rel = p.relative(dir, from: request.execRoot);
        final inBin = p.normalize(p.join(bin, rel));
        if (!list.contains(inBin)) list.add(inBin);
      }
    }

    addDir(root, rootDir);
    for (final d in request.packageDirs) {
      if (d.package == root) continue;
      addDir(d.package, d.dir);
    }

    // Each input belongs to the package with the longest matching directory.
    final roots = [
      for (final e in dirs.entries)
        for (final d in e.value) MapEntry(e.key, d),
    ]..sort((a, b) => b.value.length.compareTo(a.value.length));
    final assets = <String, AssetId>{};
    for (final input in request.inputs) {
      MapEntry<String, String>? owner;
      for (final r in roots) {
        if (p.isWithin(r.value, input)) {
          owner = r;
          break;
        }
      }
      if (owner == null) continue;
      final rel = p.posix.joinAll(p.split(p.relative(input, from: owner.value)));
      assets[input] = AssetId(owner.key, rel);
    }

    String? inputText(String package, String path) {
      for (final e in assets.entries) {
        if (e.value.package == package && e.value.path == path) {
          return File(e.key).readAsStringSync();
        }
      }
      return null;
    }

    final graph = json.decode(File(request.packageGraph!).readAsStringSync())
        as Map<String, Object?>;
    final dependencies = <String, List<String>>{};
    for (final entry in (graph['packages'] as List? ?? const []).cast<Map>()) {
      dependencies[entry['name'] as String] = [
        ...(entry['dependencies'] as List? ?? const []).cast<String>(),
      ];
    }

    // Packages outside the lock (the user's own) state their dependencies in
    // their pubspec; the root's dev dependencies count, as in pub's graph.
    List<String> pubspecDeps(Map<Object?, Object?> spec, {required bool dev}) => [
      ...((spec['dependencies'] as Map?)?.keys.cast<String>() ?? const []),
      if (dev)
        ...((spec['dev_dependencies'] as Map?)?.keys.cast<String>() ?? const []),
    ];
    dependencies[root] = pubspecDeps(pubspec, dev: true);
    final languageVersions = <String, LanguageVersion?>{
      root: _languageVersionOf(pubspec),
    };
    for (final name in dirs.keys) {
      if (name == root) continue;
      final declared = request.languageVersions[name];
      languageVersions[name] = declared == null ? null : LanguageVersion.parse(declared);
      if (!dependencies.containsKey(name)) {
        final text = inputText(name, 'pubspec.yaml');
        dependencies[name] = text == null
            ? const []
            : pubspecDeps(loadYaml(text) as Map, dev: false);
      }
    }

    // A package's own build.yaml when it is an input (the root's, or a
    // dependency of the user's given in `data`), else the one captured from
    // a builder package in the entry point.
    final buildYamls = <String, String>{};
    for (final name in {...dirs.keys, ...dependencies.keys, ...builderYamls.keys}) {
      final yaml = inputText(name, 'build.yaml') ?? builderYamls[name];
      if (yaml != null) buildYamls[name] = yaml;
    }
    final rootConfigYamls = <String, String>{
      for (final e in assets.entries)
        if (e.value.package == root &&
            RegExp(r'^build\.[^/]+\.yaml$').hasMatch(e.value.path))
          e.value.path: File(e.key).readAsStringSync(),
    };

    return _PackageModel._(
      root,
      rootDir,
      dirs,
      languageVersions,
      dependencies,
      assets,
      buildYamls,
      rootConfigYamls,
    );
  }
}

Map<Object?, Object?> _readYaml(String path) =>
    loadYaml(File(path).readAsStringSync()) as Map<Object?, Object?>;

/// The language version pub gives a package: the lower bound of its SDK
/// constraint.
LanguageVersion? _languageVersionOf(Map<Object?, Object?> pubspec) {
  final env = pubspec['environment'];
  final sdk = env is Map ? env['sdk'] : null;
  if (sdk is! String) return null;
  final constraint = VersionConstraint.parse(sdk);
  if (constraint is VersionRange && constraint.min != null) {
    return LanguageVersion(constraint.min!.major, constraint.min!.minor);
  }
  return null;
}

/// One target's build series and what it was built from.
class _TargetState {
  final String signature;
  final String rootPath;
  final _DeclaredFilesystem fs;
  final BuildSeries series;
  final BuildPlan plan;

  /// Package name to the assets of its declared inputs, for the asset finder.
  final Map<String, Set<AssetId>> assetsByPackage;

  /// Input path to its digest, from the request that built this state.
  Map<String, String> digests = const {};

  /// Input path to its asset, from the request that built this state.
  Map<String, AssetId> assets;

  final Map<String, String> packagePaths;

  _TargetState._(
    this.signature,
    this.rootPath,
    this.fs,
    this.series,
    this.plan,
    this.assetsByPackage,
    this.assets,
    this.packagePaths,
  );

  static Future<_TargetState> create({
    required _Request request,
    required _PackageModel model,
    required BuilderFactories factories,
    required String scratch,
    required BuiltSet<BuildFilter> filters,
    required void Function(LogRecord) onLog,
  }) async {
    final root = model.root;
    final fs = _DeclaredFilesystem();
    final packages = <String, BuildPackage>{};
    final packagePaths = <String, String>{};
    final configPackages = <Package>[];
    // Every package of the lock is in the build, as in a stock build, whether
    // or not this target reads its files: a builder applies to the root
    // because the root depends on the builder's package.
    final names = {...model.dirs.keys, ...model.dependencies.keys}.toList()
      ..sort();
    for (final name in names) {
      final dir = p.canonicalize(p.join(scratch, 'packages', name));
      Directory(dir).createSync(recursive: true);
      packagePaths[name] = dir;
      // `build_config` reads build.yaml files from disk.
      final yaml = model.buildYamls[name];
      if (yaml != null) {
        final file = p.join(dir, 'build.yaml');
        File(file).writeAsStringSync(yaml);
        fs.addDisk(file, file);
      }
      if (name == root) {
        for (final e in model.rootConfigYamls.entries) {
          final file = p.join(dir, e.key);
          File(file).writeAsStringSync(e.value);
          fs.addDisk(file, file);
        }
      }
      packages[name] = BuildPackage(
        name: name,
        path: dir,
        languageVersion: model.languageVersions[name],
        isOutput: name == root,
        // A lock package can depend on an SDK package no file of which is in
        // this build (Flutter's); it is left out, as nothing here reads it.
        dependencies: [
          for (final d in model.dependencies[name] ?? const <String>[])
            if (model.dirs.containsKey(d) || model.dependencies.containsKey(d)) d,
        ],
      );
      configPackages.add(
        Package(
          name,
          Uri.directory(dir),
          packageUriRoot: Uri.parse('lib/'),
          languageVersion: model.languageVersions[name],
        ),
      );
    }

    final assetsByPackage = <String, Set<AssetId>>{};
    _fillInputs(fs, assetsByPackage, packagePaths, model);
    final buildPackages = BuildPackages.compute(
      currentPackage: root,
      singlePackageToBuild: root,
      outputRoot: root,
      packages: packages.build(),
    );
    final readerWriter = ReaderWriter.using(
      assetFinder: FunctionAssetFinder((glob, {required package}) {
        final ids = assetsByPackage[package] ?? const <AssetId>{};
        return Stream.fromIterable(ids.where((id) => glob.matches(id.path)));
      }),
      assetPathProvider: buildPackages,
      filesystem: fs,
    );

    final commandLine = await BuildRunnerCommandLine.parse([
      'build',
      ...request.buildRunnerArgs,
    ]);
    if (commandLine == null) {
      throw ArgumentError('Not `build_runner build` flags: ${request.buildRunnerArgs}');
    }
    if (commandLine.rest.isNotEmpty ||
        (commandLine.outputs?.isNotEmpty ?? false) ||
        (commandLine.buildFilter?.isNotEmpty ?? false)) {
      throw ArgumentError(
        '`build_runner_args` may not name directories, outputs or build '
        'filters: the target\'s `outs` are what is built. Got '
        '${request.buildRunnerArgs}',
      );
    }
    final options = BuildOptions.parse(
      commandLine,
      buildPaths: BuildPaths(packagePath: packagePaths[root]!, buildWorkspace: false),
      currentPackage: root,
      restIsBuildDirs: true,
    ).copyWith(buildFilters: filters);

    final spec = await BuildSpec.load(
      builderFactories: factories,
      buildOptions: options,
      testingOverrides: TestingOverrides(
        buildPackages: buildPackages,
        readerWriter: readerWriter,
        checkBuilderFreshness: false,
        onLog: onLog,
        // Each target gets its own analysis driver: its package config is
        // the target's closure, and its driver keeps that closure analyzed
        // between this target's builds.
        resolvers: ResolversImpl.custom(
          packageConfig: PackageConfig(configPackages),
          analysisDriverModel: AnalysisDriverModel(),
        ),
      ),
    );
    final plan = await BuildPlan.load(spec);
    final state = _TargetState._(
      request.signature,
      packagePaths[root]!,
      fs,
      BuildSeries(plan),
      plan,
      assetsByPackage,
      model.assets,
      packagePaths,
    );
    return state;
  }

  /// Points [fs] and the asset finder's [assetsByPackage] at the declared
  /// inputs of [model].
  static void _fillInputs(
    _DeclaredFilesystem fs,
    Map<String, Set<AssetId>> assetsByPackage,
    Map<String, String> packagePaths,
    _PackageModel model,
  ) {
    fs.clearDisk();
    assetsByPackage.clear();
    for (final e in model.assets.entries) {
      final path = packagePaths[e.value.package];
      if (path == null) continue;
      fs.addDisk(p.join(path, e.value.path), e.key);
      assetsByPackage.putIfAbsent(e.value.package, () => {}).add(e.value);
    }
  }

  /// Points the filesystem at this request's inputs.
  void updateInputs(_PackageModel model) {
    _fillInputs(fs, assetsByPackage, packagePaths, model);
    assets = model.assets;
  }

  /// The asset changes from the previous request to [request], or `null`
  /// when the previous state cannot be built on.
  List<AssetChange>? changesTo(
    _Request request,
    Map<String, String> newDigests,
    _PackageModel model,
  ) {
    if (request.signature != signature) return null;
    final changes = <AssetChange>[];
    final paths = {...digests.keys, ...newDigests.keys};
    for (final path in paths) {
      final before = digests[path];
      final after = newDigests[path];
      if (before == after) continue;
      final id = model.assets[path] ?? assets[path];
      if (id == null) {
        // Not a package file: the package graph, the SDK summary or the
        // runner itself.
        return null;
      }
      if (id.path == 'pubspec.yaml' ||
          RegExp(r'^build(\.[^/]+)?\.yaml$').hasMatch(id.path)) {
        return null;
      }
      changes.add(
        AssetChange(
          id,
          before == null
              ? ChangeType.ADD
              : after == null
              ? ChangeType.REMOVE
              : ChangeType.MODIFY,
        ),
      );
    }
    return changes;
  }

  /// Builder globs of this build that could match a file of the root package
  /// that is not an input, or a file a builder would generate from one.
  List<String> undeclaredGlobMatches(BuildResult result, List<String> undeclared) {
    if (undeclared.isEmpty) return const [];
    final root = plan.buildSpec.buildPackages.outputRoot;
    final shadow = <AssetId, AssetId>{
      for (final path in undeclared) AssetId(root, path): AssetId(root, path),
    };
    for (final phase in plan.buildStepPlan.buildPhases.inBuildPhases) {
      if (phase.package != root) continue;
      for (final entry in shadow.entries.toList()) {
        final id = entry.key;
        if (!phase.targetSources.matches(id) || !phase.generateFor.matches(id)) {
          continue;
        }
        for (final out in expectedOutputs(phase.builder, id)) {
          shadow.putIfAbsent(out, () => entry.value);
        }
      }
    }
    final errors = <String>[];
    final globs = result.buildState?.incremental.globResults.keys ?? const [];
    for (final globId in globs) {
      if (globId.package != root) continue;
      final glob = Glob(globId.glob);
      for (final entry in shadow.entries) {
        if (!glob.matches(entry.key.path)) continue;
        final from = entry.value == entry.key
            ? '`${entry.key.path}`'
            : '`${entry.key.path}` (generated from `${entry.value.path}`)';
        errors.add(
          'A builder searched package $root for `${globId.glob}`, which '
          'matches $from, and `${entry.value.path}` is not an input of '
          'this target. Add it to `srcs`.',
        );
      }
    }
    return errors;
  }
}

String _escape(String s) =>
    s.replaceAllMapped(RegExp(r'[*?\[\]{}\\,]'), (m) => '\\${m[0]}');


/// Declared inputs, read from disk on demand, plus an in-memory overlay for
/// everything the build writes or deletes.
class _DeclaredFilesystem implements Filesystem {
  final Map<String, String> _disk = {};
  final Map<String, Uint8List> written = {};
  final Set<String> _deleted = {};

  void addDisk(String path, String diskPath) {
    _disk[path] = diskPath;
    _deleted.remove(path);
  }

  /// Forgets the inputs; written files stay.
  void clearDisk() {
    final keep = {
      for (final e in _disk.entries)
        if (e.key == e.value) e.key: e.value,
    };
    _disk
      ..clear()
      ..addAll(keep);
  }

  /// The bytes the build wrote for [asset] of [root], at its package path or
  /// in the artifact tree.
  Uint8List? outputBytes(String rootPath, String root, String asset) =>
      written[p.join(rootPath, asset)] ??
      written[p.join(rootPath, '.dart_tool', 'build', 'generated', root, asset)];

  @override
  bool existsSync(String path) =>
      written.containsKey(path) ||
      (_disk.containsKey(path) && !_deleted.contains(path));

  @override
  Uint8List readAsBytesSync(String path) {
    final w = written[path];
    if (w != null) return w;
    if (_deleted.contains(path)) throw FileSystemException('deleted', path);
    final d = _disk[path];
    if (d == null) throw FileSystemException('not a declared input', path);
    return File(d).readAsBytesSync();
  }

  @override
  String readAsStringSync(String path, {Encoding encoding = utf8}) =>
      encoding.decode(readAsBytesSync(path));

  @override
  void deleteSync(String path) {
    written.remove(path);
    if (_disk.containsKey(path)) _deleted.add(path);
  }

  @override
  void deleteDirectorySync(String path) {
    final prefix = '$path/';
    written.removeWhere((k, _) => k.startsWith(prefix));
    _deleted.addAll(_disk.keys.where((k) => k.startsWith(prefix)));
  }

  @override
  void writeAsBytesSync(String path, List<int> contents) {
    written[path] = Uint8List.fromList(contents);
    _deleted.remove(path);
  }

  @override
  void writeAsStringSync(
    String path,
    String contents, {
    Encoding encoding = utf8,
  }) => writeAsBytesSync(path, encoding.encode(contents));
}

/// Collects what `build_runner` prints, so the worker protocol on stdout stays
/// clean and the text reaches Bazel's action output.
class _BufferStdout implements Stdout {
  final StringBuffer _buffer;
  _BufferStdout(this._buffer);

  @override
  Encoding encoding = utf8;
  @override
  String lineTerminator = '\n';

  @override
  void write(Object? object) => _buffer.write(object);
  @override
  void writeln([Object? object = '']) => _buffer.writeln(object);
  @override
  void writeAll(Iterable objects, [String sep = '']) =>
      _buffer.writeAll(objects, sep);
  @override
  void writeCharCode(int charCode) => _buffer.writeCharCode(charCode);
  @override
  void add(List<int> data) =>
      _buffer.write(utf8.decode(data, allowMalformed: true));
  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _buffer.writeln(error);
  @override
  Future addStream(Stream<List<int>> stream) => stream.forEach(add);
  @override
  Future close() async {}
  @override
  Future get done => Future.value();
  @override
  Future flush() async {}
  @override
  bool get hasTerminal => false;
  @override
  IOSink get nonBlocking => this;
  @override
  bool get supportsAnsiEscapes => false;
  @override
  int get terminalColumns => 80;
  @override
  int get terminalLines => 24;
}
