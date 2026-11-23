// Runs the Flutter tool's own asset, licence, web bootstrap and gen-l10n code
// as one Bazel action.
//
// Every output is written by `package:flutter_tools`, compiled from the tag of
// the Flutter SDK the build uses. This program copies none of its logic: it
// builds the objects that code expects (a Flutter root, a project directory
// with its package config, an `Environment` and the context globals) out of
// the files the action declares, and calls it.
//
// Usage: flutter_assets_tool <assets|web|gen-l10n> @<params file>
//
// The params file holds one option per line; see `_parser` for the options.

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:args/args.dart';
import 'package:file/file.dart'
    show ForwardingDirectory, ForwardingFileSystem, ForwardingFileSystemEntity;
import 'package:file/local.dart';
import 'package:flutter_tools/src/artifacts.dart';
import 'package:flutter_tools/src/base/common.dart';
import 'package:flutter_tools/src/base/context.dart';
import 'package:flutter_tools/src/base/file_system.dart' hide LocalFileSystem;
import 'package:flutter_tools/src/base/io.dart' show Stdio;
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/base/os.dart';
import 'package:flutter_tools/src/base/platform.dart';
import 'package:flutter_tools/src/base/process.dart';
import 'package:flutter_tools/src/base/terminal.dart';
import 'package:flutter_tools/src/build_info.dart';
import 'package:flutter_tools/src/build_system/build_system.dart';
import 'package:flutter_tools/src/build_system/targets/assets.dart';
import 'package:flutter_tools/src/build_system/targets/linux.dart';
import 'package:flutter_tools/src/build_system/targets/localizations.dart';
import 'package:flutter_tools/src/build_system/targets/web.dart';
import 'package:flutter_tools/src/cache.dart';
import 'package:flutter_tools/src/devfs.dart';
import 'package:flutter_tools/src/git.dart';
import 'package:flutter_tools/src/isolated/native_assets/dart_hook_result.dart';
import 'package:flutter_tools/src/project.dart';
import 'package:flutter_tools/src/version.dart';
import 'package:flutter_tools/src/web/compiler_config.dart';
import 'package:flutter_tools/src/web/compile.dart';
import 'package:package_config/package_config.dart';
import 'package:process/process.dart';
import 'package:unified_analytics/unified_analytics.dart';
import 'package:yaml/yaml.dart';

ArgParser get _parser => ArgParser()
  // `<path under the Flutter root>=<file>`: SDK files at fixed places
  // (the Dart SDK, the material fonts, the framework's shaders, the web SDK).
  ..addMultiOption('sdk', splitCommas: false)
  // `<impellerc|const_finder|font_subset>=<file>`: engine tools, placed where
  // the tool's own `Artifacts` looks for them on this host.
  ..addMultiOption('engine', splitCommas: false)
  // `<path under shader_lib/>=<file>`: impellerc's include files.
  ..addMultiOption('shader-lib', splitCommas: false)
  // `<path under the project>=<file>`: the project's own files.
  ..addMultiOption('project-file', splitCommas: false)
  // `<name>=<root directory>=<language version>`: every package of the
  // package config, the project's own included.
  ..addMultiOption('package', splitCommas: false)
  // `<package>=<executable>`: what `dart run <package>` runs for an asset
  // transformer.
  ..addMultiOption('transformer', splitCommas: false)
  // A compiled web file (`main.dart.js`, its parts, `main.dart.wasm`, ...),
  // or a directory of them.
  ..addMultiOption('web-build', splitCommas: false)
  ..addOption(
    'project',
    help: 'The project directory, as the project files name it.',
  )
  ..addOption('package-graph', help: "pub's `.dart_tool/package_graph.json`.")
  ..addOption('flutter-version', mandatory: true)
  ..addOption('engine-revision', mandatory: true)
  ..addOption('dart-version', mandatory: true)
  ..addOption('out', mandatory: true)
  ..addOption('label', defaultsTo: 'this target')
  ..addOption('platform', defaultsTo: 'android')
  ..addOption('mode', defaultsTo: 'debug')
  ..addOption('flavor')
  ..addOption('app-dill')
  ..addOption('native-assets-manifest')
  ..addFlag('tree-shake-icons')
  ..addFlag('deferred-components')
  ..addOption('base-href')
  ..addOption('static-assets-url')
  ..addOption('build-name')
  ..addOption('build-number')
  ..addOption('pwa-strategy')
  ..addOption('renderer')
  ..addFlag('wasm')
  ..addFlag('wasm-dry-run', defaultsTo: true)
  ..addFlag('source-maps')
  ..addFlag('verbose');

Future<void> main(List<String> argv) async {
  if (argv.isEmpty ||
      !const <String>{'assets', 'web', 'gen-l10n'}.contains(argv.first)) {
    io.stderr.writeln(
      'usage: flutter_assets_tool <assets|web|gen-l10n> @<params file>',
    );
    io.exit(64);
  }
  final ArgResults args = _parser.parse(<String>[
    for (final String arg in argv.skip(1))
      if (arg.startsWith('@'))
        ...io.File(arg.substring(1))
            .readAsLinesSync()
            .where((String l) => l.isNotEmpty)
      else
        arg,
  ]);
  final int code = await _run(argv.first, args);
  await io.stdout.flush();
  await io.stderr.flush();
  io.exit(code);
}

/// The action's working directory. The tool reads the current directory as
/// the project's, so it changes; every path argument is resolved against this.
late final String _execRoot;

String _abs(String path) => const LocalFileSystem().path.normalize(
  const LocalFileSystem().path.isAbsolute(path)
      ? path
      : const LocalFileSystem().path.join(_execRoot, path),
);

Future<int> _run(String command, ArgResults args) async {
  final FileSystem fs = _SortedListings(const LocalFileSystem());
  _execRoot = fs.currentDirectory.path;
  const Platform platform = LocalPlatform();
  final bool verbose = args.flag('verbose');
  final terminal = AnsiTerminal(stdio: Stdio(), platform: platform);
  final StdoutLogger stdoutLogger = StdoutLogger(
    terminal: terminal,
    stdio: Stdio(),
    outputPreferences: OutputPreferences(wrapText: false),
  );
  final Logger logger = verbose ? VerboseLogger(stdoutLogger) : stdoutLogger;
  // Everything this action writes outside its output goes under one
  // temporary directory: the Flutter root, the project and the tool's own
  // build directory.
  final Directory scratch = fs.systemTempDirectory.createTempSync(
    'flutter_assets_tool',
  );
  final String out = _abs(args.option('out')!);

  final Directory flutterRoot = scratch.childDirectory('flutter')..createSync();
  Cache.flutterRoot = flutterRoot.path;
  final os = OperatingSystemUtils(
    fileSystem: fs,
    logger: logger,
    platform: platform,
    processManager: const LocalProcessManager(),
  );
  final cache = Cache(
    logger: logger,
    fileSystem: fs,
    platform: platform,
    osUtils: os,
  );
  final Artifacts artifacts = CachedArtifacts(
    fileSystem: fs,
    platform: platform,
    cache: cache,
    operatingSystemUtils: os,
  );
  _stageFlutterRoot(fs, flutterRoot, artifacts, args);
  final String dartBinary = artifacts.getArtifactPath(
    Artifact.engineDartBinary,
  );
  final ProcessManager processManager = _TransformerShim(
    const LocalProcessManager(),
    dartBinary: dartBinary,
    transformers: _pairs(args.multiOption('transformer'), _abs),
  );
  final Directory project = _stageProject(
    fs,
    scratch.childDirectory('project'),
    args,
  );

  try {
    return await context.run<int>(
      overrides: <Type, Generator>{
        FileSystem: () => fs,
        Platform: () => platform,
        ProcessManager: () => processManager,
        Logger: () => logger,
        OperatingSystemUtils: () => os,
        Cache: () => cache,
        Artifacts: () => artifacts,
        Analytics: () => const NoOpAnalytics(),
        // Read from the version file the Flutter root holds: git never runs.
        FlutterVersion: () => FlutterVersion(
          fs: fs,
          flutterRoot: flutterRoot.path,
          git: Git(
            currentPlatform: platform,
            runProcessWith: ProcessUtils(
              processManager: processManager,
              logger: logger,
            ),
          ),
        ),
        FlutterProjectFactory: () =>
            FlutterProjectFactory(logger: logger, fileSystem: fs),
        Terminal: () => terminal,
      },
      body: () async {
        final Environment environment = _environment(
          fs: fs,
          logger: logger,
          platform: platform,
          processManager: processManager,
          artifacts: artifacts,
          project: project,
          flutterRoot: flutterRoot,
          buildDir: scratch.childDirectory('build'),
          outputDir: fs.directory(out)..createSync(recursive: true),
          defines: _defines(command, args),
        );
        // The tool reads the current directory as the project's
        // (`FlutterProject.current()`) in the version file and gen-l10n code.
        fs.currentDirectory = project;
        final Stopwatch watch = Stopwatch()..start();
        try {
          switch (command) {
            case 'assets':
              await _assets(environment, args);
            case 'web':
              await _web(environment, args);
            case 'gen-l10n':
              await _genL10n(environment);
          }
        } on ToolExit catch (e) {
          logger.printError(e.message ?? 'flutter_assets_tool failed');
          _explainMissingFiles(fs, project, args, logger);
          return e.exitCode ?? 1;
        } on Exception catch (e) {
          // `copyAssets` reports what failed through the logger first.
          logger.printError('$e');
          _explainMissingFiles(fs, project, args, logger);
          return 1;
        }
        if (verbose) {
          logger.printStatus('$command took ${watch.elapsedMilliseconds} ms');
        }
        return 0;
      },
    );
  } finally {
    if (!verbose) {
      scratch.deleteSync(recursive: true);
    }
  }
}

Map<String, String> _pairs(
  List<String> values, [
  String Function(String)? value,
]) {
  final result = <String, String>{};
  for (final entry in values) {
    final int eq = entry.indexOf('=');
    if (eq <= 0) {
      throw ArgumentError('expected <key>=<value>, got "$entry"');
    }
    final String v = entry.substring(eq + 1);
    result[entry.substring(0, eq)] = value == null ? v : value(v);
  }
  return result;
}

void _link(FileSystem fs, String at, String target) {
  final Link link = fs.link(at);
  link.parent.createSync(recursive: true);
  link.createSync(_abs(target));
}

/// A Flutter root holding only the files this action declares, each where
/// the tool's own `Cache` and `Artifacts` look for it.
void _stageFlutterRoot(
  FileSystem fs,
  Directory root,
  Artifacts artifacts,
  ArgResults args,
) {
  _pairs(args.multiOption('sdk')).forEach((String rel, String file) {
    _link(fs, fs.path.join(root.path, rel), file);
  });
  final engine = <String, String>{
    'impellerc': artifacts.getHostArtifact(HostArtifact.impellerc).path,
    'const_finder': artifacts.getArtifactPath(Artifact.constFinder),
    'font_subset': artifacts.getArtifactPath(Artifact.fontSubset),
  };
  _pairs(args.multiOption('engine')).forEach((String name, String file) {
    final String? at = engine[name];
    if (at == null) {
      throw ArgumentError('unknown engine tool "$name"');
    }
    _link(fs, at, file);
  });
  final String shaderLib = fs.path.join(
    fs.path.dirname(engine['impellerc']!),
    'shader_lib',
  );
  _pairs(args.multiOption('shader-lib')).forEach((String rel, String file) {
    _link(fs, fs.path.join(shaderLib, rel), file);
  });
  // The version the tool reports. Only the engine revision reaches an output
  // (web's `flutter_bootstrap.js`); the other fields are required by its
  // reader.
  fs.file(fs.path.join(root.path, 'bin', 'cache', 'flutter.version.json'))
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(
      jsonEncode(<String, String>{
        'frameworkVersion': args.option('flutter-version')!,
        'channel': 'stable',
        'repositoryUrl': 'https://github.com/flutter/flutter.git',
        'frameworkRevision': 'unknown',
        'frameworkCommitDate': 'unknown',
        'engineRevision': args.option('engine-revision')!,
        'dartSdkVersion': args.option('dart-version')!,
        'devToolsVersion': 'unknown',
        'flutterVersion': args.option('flutter-version')!,
      }),
    );
}

/// A project directory the tool can read as `flutter build` reads one: a link
/// per declared file, and `.dart_tool/` holding the package config and the
/// package graph that `pub get` writes. The tool writes into it (gen-l10n
/// does), so nothing it writes reaches the sources.
Directory _stageProject(FileSystem fs, Directory staged, ArgResults args) {
  final String source = _abs(args.option('project') ?? '.');
  _pairs(args.multiOption('project-file')).forEach((String rel, String file) {
    if (rel.startsWith('/') || fs.path.split(rel).contains('..')) {
      throw ArgumentError('project file "$rel" is not inside the project');
    }
    _link(fs, fs.path.join(staged.path, rel), file);
  });
  final Directory dartTool = staged.childDirectory('.dart_tool')
    ..createSync(recursive: true);
  final packages = <Package>[];
  for (final String entry in args.multiOption('package')) {
    final List<String> parts = entry.split('=');
    if (parts.length != 3) {
      throw ArgumentError(
        'expected <name>=<root>=<language version>, got "$entry"',
      );
    }
    final String root = _abs(parts[1]);
    // The project's own package is the staged copy, so code that finds a
    // file's package by its path (dart format's language version) finds it.
    final Uri rootUri = fs.directory(root == source ? staged.path : root).uri;
    packages.add(
      Package(
        parts[0],
        rootUri,
        packageUriRoot: rootUri.resolve('lib/'),
        languageVersion: parts[2].isEmpty
            ? null
            : LanguageVersion.parse(parts[2]),
        relativeRoot: false,
      ),
    );
  }
  final buffer = StringBuffer();
  PackageConfig.writeString(PackageConfig(packages), buffer);
  dartTool
      .childFile('package_config.json')
      .writeAsStringSync(buffer.toString());
  final String? graph = args.option('package-graph');
  final File graphFile = dartTool.childFile('package_graph.json');
  if (graph != null) {
    _link(fs, graphFile.path, graph);
  } else {
    graphFile.writeAsStringSync(_packageGraph(fs, staged, packages));
  }
  return staged;
}

/// pub's `package_graph.json`, from the pubspecs of the packages in the
/// config: each package's dependencies, and the project's dev dependencies.
///
/// Stands in until the pub layer writes the file (then `--package-graph`
/// passes it). A dependency missing from the config is left in, so the tool
/// reports it the way it reports a stale `pub get`.
String _packageGraph(FileSystem fs, Directory project, List<Package> packages) {
  List<String> names(Object? section) => section is YamlMap
      ? (section.keys.cast<String>().toList()..sort())
      : <String>[];
  final String rootName = _pubspecName(fs, project.childFile('pubspec.yaml'));
  final entries = <Map<String, Object>>[];
  for (final package in packages) {
    final File pubspec = fs.file(package.root.resolve('pubspec.yaml'));
    final Object? yaml = pubspec.existsSync()
        ? loadYaml(pubspec.readAsStringSync())
        : null;
    final YamlMap map = yaml is YamlMap ? yaml : YamlMap();
    entries.add(<String, Object>{
      'name': package.name,
      'version': '${map['version'] ?? '0.0.0'}',
      'dependencies': names(map['dependencies']),
      if (package.name == rootName)
        'devDependencies': names(map['dev_dependencies']),
    });
  }
  return jsonEncode(<String, Object>{
    'roots': <String>[rootName],
    'packages': entries,
    'configVersion': 1,
  });
}

String _pubspecName(FileSystem fs, File pubspec) {
  if (!pubspec.existsSync()) {
    throwToolExit('No pubspec.yaml among the project files');
  }
  final Object? yaml = loadYaml(pubspec.readAsStringSync());
  return yaml is YamlMap ? '${yaml['name']}' : '';
}

Map<String, String> _defines(String command, ArgResults args) {
  final bool web = command == 'web';
  return <String, String>{
    kBuildMode: args.option('mode')!,
    kTargetPlatform: web ? 'web-javascript' : args.option('platform')!,
    kIconTreeShakerFlag: '${args.flag('tree-shake-icons')}',
    if (args.flag('deferred-components')) kDeferredComponents: 'true',
    if (args.option('flavor') != null) kFlavor: args.option('flavor')!,
    if (args.option('build-name') != null)
      kBuildName: args.option('build-name')!,
    if (args.option('build-number') != null)
      kBuildNumber: args.option('build-number')!,
    if (web) kBaseHref: args.option('base-href') ?? '/',
    if (args.option('static-assets-url') != null)
      kStaticAssetsUrl: args.option('static-assets-url')!,
    if (args.option('pwa-strategy') != null)
      kServiceWorkerStrategy: args.option('pwa-strategy')!,
  };
}

Environment _environment({
  required FileSystem fs,
  required Logger logger,
  required Platform platform,
  required ProcessManager processManager,
  required Artifacts artifacts,
  required Directory project,
  required Directory flutterRoot,
  required Directory buildDir,
  required Directory outputDir,
  required Map<String, String> defines,
}) {
  final environment = Environment(
    projectDir: project,
    packageConfigPath: project
        .childDirectory('.dart_tool')
        .childFile('package_config.json')
        .path,
    outputDir: outputDir,
    cacheDir: flutterRoot.childDirectory('bin').childDirectory('cache'),
    flutterRootDir: flutterRoot,
    fileSystem: fs,
    logger: logger,
    artifacts: artifacts,
    processManager: processManager,
    platform: platform,
    analytics: const NoOpAnalytics(),
    generateDartPluginRegistry: false,
    buildDir: buildDir,
    defines: defines,
  );
  environment.buildDir.createSync(recursive: true);
  return environment;
}

/// The app's kernel, where the icon tree shaker reads it.
void _placeAppDill(Environment environment, ArgResults args) {
  final String? appDill = args.option('app-dill');
  if (appDill != null) {
    environment.fileSystem
        .file(_abs(appDill))
        .copySync(environment.buildDir.childFile('app.dill').path);
  }
}

/// What a platform's bundle target writes into `flutter_assets/`:
/// `CopyAssets.build` without the kernel and hooks targets it depends on,
/// plus the files each platform target passes as additional content.
Future<void> _assets(Environment environment, ArgResults args) async {
  final FileSystem fs = environment.fileSystem;
  final TargetPlatform targetPlatform = getTargetPlatformForName(
    args.option('platform')!,
  );
  final buildMode = BuildMode.fromCliName(args.option('mode')!);
  _placeAppDill(environment, args);
  final String? nativeAssets = args.option('native-assets-manifest');
  await copyAssets(
    environment,
    environment.outputDir,
    dartHookResult: DartHooksResult.empty(),
    additionalContent: <String, DevFSContent>{
      // Only the Linux bundle target adds version.json (targets/linux.dart).
      if (targetPlatform
          case TargetPlatform.linux_x64 ||
              TargetPlatform.linux_arm64 ||
              TargetPlatform.linux_riscv64)
        'version.json': DevFSStringContent(
          DebugBundleLinuxAssets(targetPlatform)
              .getVersionInfo(environment.defines),
        ),
      // As every platform target passes the link hooks' manifest.
      if (nativeAssets != null)
        'NativeAssetsManifest.json': DevFSFileContent(
          fs.file(_abs(nativeAssets)),
        ),
    },
    targetPlatform: targetPlatform,
    buildMode: buildMode,
    flavor: environment.defines[kFlavor],
  );
}

/// What `flutter build web` writes besides the compiled program: the
/// release bundle (assets, `version.json`, the `web/` resources), the
/// templated `index.html` and `flutter_bootstrap.js`, CanvasKit and
/// `flutter.js`, and the service worker. The compiled files come in from
/// the rules' own compile actions, where the tool's compile targets would
/// have left them.
Future<void> _web(Environment environment, ArgResults args) async {
  final FileSystem fs = environment.fileSystem;
  _placeAppDill(environment, args);
  for (final String path in args.multiOption('web-build').map(_abs)) {
    final FileSystemEntity entity = fs.isDirectorySync(path)
        ? fs.directory(path)
        : fs.file(path);
    final Iterable<File> files = entity is Directory
        ? entity.listSync(recursive: true).whereType<File>()
        : <File>[entity as File];
    for (final file in files) {
      final String rel = entity is Directory
          ? fs.path.relative(file.path, from: entity.path)
          : fs.path.basename(file.path);
      file.copySync(
        (environment.buildDir.childFile(
          rel,
        )..parent.createSync(recursive: true)).path,
      );
    }
  }
  final bool wasm = args.flag('wasm');
  final String? rendererName = args.option('renderer');
  final WebRendererMode renderer = rendererName == null
      ? WebRendererMode.getDefault(useWasm: wasm)
      : WebRendererMode.values.byName(rendererName);
  final bool sourceMaps = args.flag('source-maps');
  // As `BuildWebCommand` lists them; only what reaches `buildConfig` and the
  // names of the compiled files matters here.
  final compileConfigs = <WebCompilerConfig>[
    if (wasm) ...<WebCompilerConfig>[
      WasmCompilerConfig(sourceMaps: sourceMaps),
      JsCompilerConfig(sourceMaps: sourceMaps),
    ] else ...<WebCompilerConfig>[
      JsCompilerConfig(sourceMaps: sourceMaps, renderer: renderer),
      if (args.flag('wasm-dry-run'))
        WasmCompilerConfig(sourceMaps: sourceMaps, dryRun: true),
    ],
  ];
  final bundle = WebReleaseBundle(compileConfigs, const NoOpAnalytics());
  // In the order the build system runs them: the release bundle and the
  // templated files, then the built-in assets, then the service worker,
  // which hashes everything before it.
  await bundle.build(environment);
  await bundle.templatedFilesTarget.build(environment);
  await WebBuiltInAssets(fs).build(environment);
  await WebServiceWorker(
    fs,
    compileConfigs,
    const NoOpAnalytics(),
  ).build(environment);
}

/// `GenerateLocalizationsTarget`, as `flutter build` runs it before compiling;
/// its outputs are copied to the output directory at their paths in the
/// project.
Future<void> _genL10n(Environment environment) async {
  const target = GenerateLocalizationsTarget();
  if (await target.canSkip(environment)) {
    return;
  }
  await target.build(environment);
  final FileSystem fs = environment.fileSystem;
  final record = jsonDecode(
    environment.buildDir
        .childFile('gen_l10n_inputs_and_outputs.json')
        .readAsStringSync(),
  ) as Map<String, Object?>;
  for (final String output
      in (record['outputs']! as List<Object?>).cast<String>()) {
    final String rel = fs.path.relative(
      output,
      from: environment.projectDir.path,
    );
    fs
        .file(output)
        .copySync(
          (fs.file(
            fs.path.join(environment.outputDir.path, rel),
          )..parent.createSync(recursive: true)).path,
        );
  }
}

/// Names the files `pubspec.yaml` lists that the action did not declare,
/// after the tool has reported the first of them its own way.
void _explainMissingFiles(
  FileSystem fs,
  Directory project,
  ArgResults args,
  Logger logger,
) {
  final File pubspec = project.childFile('pubspec.yaml');
  if (!pubspec.existsSync()) {
    return;
  }
  final Object? yaml = loadYaml(pubspec.readAsStringSync());
  final Object? flutter = yaml is YamlMap ? yaml['flutter'] : null;
  if (flutter is! YamlMap) {
    return;
  }
  Iterable<Object?> list(Object? value) =>
      value is YamlList ? value : const <Object?>[];
  final named = <String>[
    for (final Object? asset in list(flutter['assets']))
      if (asset is String) asset else if (asset is YamlMap) '${asset['path']}',
    for (final Object? shader in list(flutter['shaders'])) '$shader',
    for (final Object? family in list(flutter['fonts']))
      if (family is YamlMap)
        for (final Object? font in list(family['fonts']))
          if (font is YamlMap) '${font['asset']}',
  ];
  final missing = <String>[
    for (final path in named)
      if (!path.startsWith('packages/') &&
          !fs.isFileSync(fs.path.join(project.path, path)) &&
          !(path.endsWith('/') &&
              fs.isDirectorySync(fs.path.join(project.path, path))))
        path,
  ];
  if (missing.isNotEmpty) {
    logger.printError(
      '${args.option('label')}: pubspec.yaml names ${missing.join(', ')}, which '
      '${missing.length == 1 ? 'is' : 'are'} not among the files of the target. '
      'Add ${missing.length == 1 ? 'it' : 'them'} to `pubspec_srcs`.',
    );
  }
}

/// Runs an asset transformer's `dart run <package>` as the Bazel-built
/// executable of that package. Every other process runs as asked.
///
/// `dart run` resolves the package against pub's own package config and
/// cache, and re-resolves (with the network) when it sees another; the
/// action has neither. The tool itself is not changed: this sits between it
/// and the processes it starts.
class _TransformerShim implements ProcessManager {
  _TransformerShim(
    this._delegate, {
    required this.dartBinary,
    required this.transformers,
  });

  final ProcessManager _delegate;
  final String dartBinary;
  final Map<String, String> transformers;

  List<Object> _map(List<Object> command) {
    if (command.length < 3 ||
        '${command[0]}' != dartBinary ||
        '${command[1]}' != 'run') {
      return command;
    }
    final package = '${command[2]}';
    final String? executable = transformers[package];
    if (executable == null) {
      throwToolExit(
        'Asset transformer "$package" has no executable: name a binary of it in '
        '`asset_transformers`.',
      );
    }
    return <Object>[executable, ...command.skip(3)];
  }

  @override
  Future<io.Process> start(
    List<Object> command, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    io.ProcessStartMode mode = io.ProcessStartMode.normal,
  }) => _delegate.start(
    _map(command),
    workingDirectory: workingDirectory,
    environment: environment,
    includeParentEnvironment: includeParentEnvironment,
    runInShell: runInShell,
    mode: mode,
  );

  @override
  Future<io.ProcessResult> run(
    List<Object> command, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    Encoding? stdoutEncoding = io.systemEncoding,
    Encoding? stderrEncoding = io.systemEncoding,
  }) => _delegate.run(
    _map(command),
    workingDirectory: workingDirectory,
    environment: environment,
    includeParentEnvironment: includeParentEnvironment,
    runInShell: runInShell,
    stdoutEncoding: stdoutEncoding,
    stderrEncoding: stderrEncoding,
  );

  @override
  io.ProcessResult runSync(
    List<Object> command, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    Encoding? stdoutEncoding = io.systemEncoding,
    Encoding? stderrEncoding = io.systemEncoding,
  }) => _delegate.runSync(
    _map(command),
    workingDirectory: workingDirectory,
    environment: environment,
    includeParentEnvironment: includeParentEnvironment,
    runInShell: runInShell,
    stdoutEncoding: stdoutEncoding,
    stderrEncoding: stderrEncoding,
  );

  @override
  bool canRun(dynamic executable, {String? workingDirectory}) =>
      _delegate.canRun(executable, workingDirectory: workingDirectory);

  @override
  bool killPid(int pid, [io.ProcessSignal signal = io.ProcessSignal.sigterm]) =>
      _delegate.killPid(pid, signal);
}

/// Lists every directory in path order.
///
/// The tool takes directory listings in the order the file system returns
/// them: the order of resolution variants in `AssetManifest.bin`, of files in
/// an asset directory, and of CanvasKit's `wasmHashes` in
/// `flutter_bootstrap.js`. That order is the file system's (creation order on
/// a small XFS or ext4 directory, hash order on a large ext4 one), so the same
/// inputs could give other bytes on another machine. Sorted, it is the same
/// everywhere, and equal to stock on a checkout whose files were written in
/// path order, as git writes them.
class _SortedListings extends ForwardingFileSystem {
  _SortedListings(super.delegate);

  @override
  Directory directory(dynamic path) =>
      _SortedDirectory(this, delegate.directory(path));

  @override
  Directory get currentDirectory =>
      _SortedDirectory(this, delegate.currentDirectory);

  @override
  Directory get systemTempDirectory =>
      _SortedDirectory(this, delegate.systemTempDirectory);
}

class _SortedDirectory
    extends ForwardingFileSystemEntity<Directory, io.Directory>
    with ForwardingDirectory<Directory> {
  _SortedDirectory(this.fileSystem, this.delegate);

  @override
  final _SortedListings fileSystem;

  @override
  final io.Directory delegate;

  @override
  Directory wrapDirectory(io.Directory delegate) =>
      _SortedDirectory(fileSystem, delegate);

  @override
  File wrapFile(io.File delegate) => fileSystem.delegate.file(delegate.path);

  @override
  Link wrapLink(io.Link delegate) => fileSystem.delegate.link(delegate.path);

  @override
  Directory childDirectory(String basename) =>
      fileSystem.directory(fileSystem.path.join(path, basename));

  @override
  File childFile(String basename) =>
      fileSystem.file(fileSystem.path.join(path, basename));

  @override
  Link childLink(String basename) =>
      fileSystem.link(fileSystem.path.join(path, basename));

  @override
  List<FileSystemEntity> listSync({
    bool recursive = false,
    bool followLinks = true,
  }) => super.listSync(
    recursive: recursive,
    followLinks: followLinks,
  )..sort((FileSystemEntity a, FileSystemEntity b) => a.path.compareTo(b.path));

  @override
  Stream<FileSystemEntity> list({
    bool recursive = false,
    bool followLinks = true,
  }) => Stream<FileSystemEntity>.fromIterable(
    listSync(recursive: recursive, followLinks: followLinks),
  );
}
