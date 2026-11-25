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
import 'package:crypto/crypto.dart' show sha256;
import 'package:data_assets/data_assets.dart';
import 'package:file/file.dart'
    show ForwardingDirectory, ForwardingFileSystem, ForwardingFileSystemEntity;
import 'package:file/local.dart';
import 'package:flutter_tools/src/artifacts.dart';
import 'package:flutter_tools/src/asset.dart';
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
import 'package:flutter_tools/src/bundle_builder.dart';
import 'package:flutter_tools/src/cache.dart';
import 'package:flutter_tools/src/dart/package_map.dart';
import 'package:flutter_tools/src/devfs.dart';
import 'package:flutter_tools/src/device.dart' show ImpellerStatus;
import 'package:flutter_tools/src/git.dart';
import 'package:flutter_tools/src/isolated/native_assets/dart_hook_result.dart';
import 'package:flutter_tools/src/isolated/native_assets/native_assets.dart'
    show FlutterCodeAsset;
import 'package:flutter_tools/src/localizations/localizations_utils.dart'
    show parseLocalizationsOptionsFromYAML;
import 'package:flutter_tools/src/project.dart';
import 'package:flutter_tools/src/version.dart';
import 'package:flutter_tools/src/web_template.dart';
import 'package:flutter_tools/src/web/bootstrap.dart'
    show generateDefaultFlutterBootstrapScript;
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
  // `<impellerc|font_subset>=<file>`: engine tools, placed where
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
  // `<package>=<name>=<file>`: a data asset a link hook emitted, bundled at
  // `packages/<package>/<name>` as the tool bundles a hook's data asset.
  ..addMultiOption('data-asset', splitCommas: false)
  // A compiled web file (`main.dart.js`, its parts, `main.dart.wasm`, ...),
  // or a directory of them.
  ..addMultiOption('web-build', splitCommas: false)
  // gen-l10n: a file, by its path under the project, that the build declared
  // as an output. gen-l10n must write exactly these.
  ..addMultiOption('output', splitCommas: false)
  ..addOption(
    'project',
    help: 'The project directory, as the project files name it.',
  )
  ..addOption(
    'package-graph',
    help: "The lock's package graph, in the shape of pub's `.dart_tool/package_graph.json`.",
  )
  // The project's language version, when no `--package` names the project.
  ..addOption('language-version')
  ..addOption('flutter-version', mandatory: true)
  ..addOption('engine-revision', mandatory: true)
  ..addOption('dart-version', defaultsTo: 'unknown')
  ..addOption('out', mandatory: true)
  ..addOption('label', defaultsTo: 'this target')
  ..addOption('platform', defaultsTo: 'android')
  ..addOption('mode', defaultsTo: 'debug')
  ..addOption('flavor')
  // What the AOT compile recorded of the app's uses, for the icon tree shaker.
  ..addOption('recorded-uses')
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
  // `<name>=<value>`: `--web-define`, substituted into the web templates.
  ..addMultiOption('web-define', splitCommas: false)
  // Where to write the bootstrap the dev loop serves beside a DDC build.
  ..addOption('dev-bootstrap')
  ..addFlag('use-local-canvaskit')
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
    command,
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
              await _genL10n(environment, args);
          }
        } on ToolExit catch (e) {
          logger.printError(e.message ?? 'flutter_assets_tool failed');
          if (command != 'gen-l10n') {
            _explainMissingFiles(fs, project, args, logger);
          }
          return e.exitCode ?? 1;
        } on Exception catch (e) {
          // `copyAssets` reports what failed through the logger first.
          logger.printError('$e');
          if (e is FileSystemException && e.path != null) {
            _describePath(fs, e.path!, logger);
          } else if (e is io.ProcessException) {
            _describePath(fs, e.executable, logger);
          }
          if (command != 'gen-l10n') {
            _explainMissingFiles(fs, project, args, logger);
          }
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
      // The tool made the project directory its current directory, and
      // Windows does not delete a directory a process stands in: leave it
      // first, or the failure to delete hides why the action failed.
      fs.currentDirectory = _execRoot;
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

/// One file of the project at [at]: a link to the input, and on Windows a
/// copy. A staged link there is one the tool's own `File.copy` could not open
/// ("cannot find the file specified") in the first run of this tool on
/// Windows, whatever the listing said of it; the project files are the
/// pubspec's assets and sources, which the tool reads or copies anyway.
void _stageProjectFile(FileSystem fs, String at, String target) {
  if (!const LocalPlatform().isWindows) {
    _link(fs, at, target);
    return;
  }
  fs.file(at).parent.createSync(recursive: true);
  fs.file(_abs(target)).copySync(at);
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
  // Made here, so `Cache` does not make it and `chmod` it in a process: the
  // action has no `PATH` to find `chmod` on.
  fs
      .directory(fs.path.join(root.path, 'bin', 'cache', 'artifacts'))
      .createSync(recursive: true);
  final engine = <String, String>{
    'impellerc': artifacts.getHostArtifact(HostArtifact.impellerc).path,
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
Directory _stageProject(
  FileSystem fs,
  Directory staged,
  ArgResults args,
  String command,
) {
  final String source = _abs(args.option('project') ?? '.');
  _pairs(args.multiOption('project-file')).forEach((String rel, String file) {
    if (rel.startsWith('/') || fs.path.split(rel).contains('..')) {
      throw ArgumentError('project file "$rel" is not inside the project');
    }
    _stageProjectFile(fs, fs.path.join(staged.path, rel), file);
  });
  final Directory dartTool = staged.childDirectory('.dart_tool')
    ..createSync(recursive: true);
  final String rootName = _pubspecName(fs, staged.childFile('pubspec.yaml'));
  final packages = <Package>[];
  Package packageAt(String name, Uri rootUri, String languageVersion) =>
      Package(
        name,
        rootUri,
        packageUriRoot: rootUri.resolve('lib/'),
        languageVersion: languageVersion.isEmpty
            ? null
            : LanguageVersion.parse(languageVersion),
        relativeRoot: false,
      );
  final seen = <String>{};
  for (final String entry in args.multiOption('package')) {
    final List<String> parts = entry.split('=');
    if (parts.length != 3) {
      throw ArgumentError(
        'expected <name>=<root>=<language version>, got "$entry"',
      );
    }
    // A package reached in two configurations comes twice; the first wins.
    if (!seen.add(parts[0])) {
      continue;
    }
    final String root = _abs(parts[1]);
    // The project's own package is the staged copy, so code that finds a
    // file's package by its path (dart format's language version) finds it.
    final bool own = root == source || parts[0] == rootName;
    final Uri rootUri = fs.directory(own ? staged.path : root).uri;
    packages.add(packageAt(parts[0], rootUri, parts[2]));
  }
  // As `pub get` writes it, the config lists the project's own package even
  // when no library of it is built.
  if (!packages.any((Package p) => p.name == rootName)) {
    packages.add(
      packageAt(rootName, staged.uri, args.option('language-version') ?? ''),
    );
  }
  final buffer = StringBuffer();
  PackageConfig.writeString(PackageConfig(packages), buffer);
  dartTool
      .childFile('package_config.json')
      .writeAsStringSync(buffer.toString());
  final String? graph = args.option('package-graph');
  dartTool
      .childFile('package_graph.json')
      .writeAsStringSync(
        _packageGraph(
          fs,
          staged,
          packages,
          graph == null ? null : fs.file(_abs(graph)),
          // gen-l10n reads no package of the project.
          command == 'gen-l10n' ? null : '${args.option('label')}',
        ),
      );
  return staged;
}

/// pub's `package_graph.json` for the project.
///
/// The lock's packages come from the hub's graph (`--package-graph`), which
/// pub's resolution planned: each package's dependencies. Every other package
/// of the config (the project itself, with its dev dependencies, the members
/// of its workspace, hand-written packages, the Flutter SDK's packages, whose
/// dependencies the lock does not plan, or every package when there is no
/// hub) comes from its pubspec.
///
/// A regular dependency of the project missing from the config is left in,
/// so the tool reports it the way it reports a stale `pub get`. Any other
/// missing package (a dev dependency of the project, or a package another
/// package depends on that the lock or the target leaves out) is left out:
/// none of its files are inputs, so there is nothing of it to bundle.
String _packageGraph(
  FileSystem fs,
  Directory project,
  List<Package> packages,
  File? lockGraph,
  String? label,
) {
  List<String> names(Object? section) => section is YamlMap
      ? (section.keys.cast<String>().toList()..sort())
      : <String>[];
  final Set<String> known = {for (final package in packages) package.name};
  final String rootName = _pubspecName(fs, project.childFile('pubspec.yaml'));
  final planned = <String, Map<String, Object?>>{
    if (lockGraph != null)
      for (final Object? entry
          in (jsonDecode(lockGraph.readAsStringSync())
                  as Map<String, Object?>)['packages']!
              as List<Object?>)
        if (entry case {'name': final String name})
          name: entry as Map<String, Object?>,
  };
  final entries = <Map<String, Object>>[];
  for (final package in packages) {
    final Map<String, Object?>? fromLock = package.name == rootName
        ? null
        : planned[package.name];
    if (fromLock != null) {
      entries.add(<String, Object>{
        'name': package.name,
        'version': '${fromLock['version'] ?? '0.0.0'}',
        'dependencies': (fromLock['dependencies']! as List<Object?>)
            .cast<String>()
            .where(known.contains)
            .toList(),
      });
      continue;
    }
    final File pubspec = fs.file(package.root.resolve('pubspec.yaml'));
    final Object? yaml = pubspec.existsSync()
        ? loadYaml(pubspec.readAsStringSync())
        : null;
    final YamlMap map = yaml is YamlMap ? yaml : YamlMap();
    entries.add(<String, Object>{
      'name': package.name,
      'version': '${map['version'] ?? '0.0.0'}',
      'dependencies': package.name == rootName
          ? names(map['dependencies'])
          : names(map['dependencies']).where(known.contains).toList(),
      if (package.name == rootName)
        'devDependencies': names(
          map['dev_dependencies'],
        ).where(known.contains).toList(),
    });
  }
  // The tool reads the graph from the root and stops at the first package it
  // has no entry for, saying to run `pub get`; here the fix is a BUILD edit.
  final List<String> absent = <String>[
    for (final entry in entries)
      if (entry['name'] == rootName)
        for (final dep in entry['dependencies']! as List<String>)
          if (!known.contains(dep)) dep,
  ];
  if (label != null && absent.isNotEmpty) {
    throwToolExit(
      '$label: pubspec.yaml depends on ${absent.join(', ')}, which no '
      'package of the target provides. Add ${absent.length == 1 ? 'its target' : 'their targets'} '
      'to `deps`, or name the lock\'s packages with `pub_packages = "@<hub>//packages"`.',
    );
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
    if (web && args.flag('use-local-canvaskit')) kUseLocalCanvasKitFlag: 'true',
    if (web)
      for (final MapEntry<String, String>(:key, :value) in _pairs(
        args.multiOption('web-define'),
      ).entries)
        '$kWebDefinePrefix$key': value,
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

/// The AOT compile's recorded uses, where the icon tree shaker reads them:
/// the name `KernelSnapshot` writes.
void _placeRecordedUses(Environment environment, ArgResults args) {
  final String? file = args.option('recorded-uses');
  if (file != null) {
    environment.fileSystem
        .file(_abs(file))
        .copySync(environment.buildDir.childFile('recorded_uses.json').path);
  }
}

/// What a platform's bundle target writes into `flutter_assets/`:
/// `CopyAssets.build` without the kernel and hooks targets it depends on,
/// plus the files each platform target passes as additional content.
Future<void> _assets(Environment environment, ArgResults args) async {
  final FileSystem fs = environment.fileSystem;
  final TargetPlatform targetPlatform = TargetPlatform.fromName(
    args.option('platform')!,
  );
  final buildMode = BuildMode.fromCliName(args.option('mode')!);
  if (targetPlatform == TargetPlatform.tester) {
    return _testerAssets(environment, args, buildMode);
  }
  _placeRecordedUses(environment, args);
  final String? nativeAssets = args.option('native-assets-manifest');
  await copyAssets(
    environment,
    environment.outputDir,
    dartHookResult: _hookResult(args),
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

/// What `flutter test` writes into its `unit_test_assets/` (`_buildTestAsset`
/// in `commands/test.dart`): unlike a platform bundle, it holds the assets of
/// the project's dev dependencies too.
Future<void> _testerAssets(
  Environment environment,
  ArgResults args,
  BuildMode buildMode,
) async {
  final AssetBundle bundle = AssetBundleFactory.defaultInstance(
    logger: environment.logger,
    fileSystem: environment.fileSystem,
    platform: environment.platform,
  ).createBundle();
  final int result = await bundle.build(
    flutterHookResult: _hookResult(args).asFlutterResult,
    manifestPath: environment.projectDir.childFile('pubspec.yaml').path,
    packageConfigPath: findPackageConfigFileOrDefault(
      environment.projectDir,
    ).path,
    flavor: environment.defines[kFlavor],
    includeAssetsFromDevDependencies: true,
    targetPlatform: TargetPlatform.tester,
  );
  if (result != 0) {
    throwToolExit('Error: Failed to build asset bundle');
  }
  await writeBundle(
    environment.outputDir,
    bundle.entries,
    targetPlatform: TargetPlatform.tester,
    impellerStatus: ImpellerStatus.platformDefault,
    processManager: environment.processManager,
    fileSystem: environment.fileSystem,
    artifacts: environment.artifacts,
    logger: environment.logger,
    projectDir: environment.projectDir,
    buildMode: buildMode,
    platform: environment.platform,
  );
  // As `flutter test` copies it beside the bundle: flutter_tester resolves
  // `@Native` assets through the manifest in its assets directory.
  final String? nativeAssets = args.option('native-assets-manifest');
  if (nativeAssets != null) {
    environment.fileSystem
        .file(_abs(nativeAssets))
        .copySync(
          environment.outputDir.childFile('NativeAssetsManifest.json').path,
        );
  }
}

/// The link hooks' data assets, as the tool's hook runner reports them.
DartHooksResult _hookResult(ArgResults args) {
  final List<String> entries = args.multiOption('data-asset');
  if (entries.isEmpty) {
    return DartHooksResult.empty();
  }
  final DateTime now = DateTime.now();
  return DartHooksResult(
    buildStart: now,
    buildEnd: now,
    codeAssets: const <FlutterCodeAsset>[],
    dataAssets: <DataAsset>[
      for (final entry in entries)
        if (entry.split('=') case [final package, final name, final file])
          DataAsset(
            file: Uri.file(_abs(file)),
            name: name,
            package: package,
          )
        else
          throw ArgumentError('expected <package>=<name>=<file>, got "$entry"'),
    ],
    dependencies: const <Uri>[],
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
  if (!environment.projectDir.childDirectory('web').existsSync()) {
    throwToolExit(
      '${args.option('label')}: the project has no web/ directory, so it is '
      'not configured for the web. `flutter create --platforms=web .` writes '
      'one; list its files in pubspec_srcs.',
    );
  }
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
  // As `WebReleaseBundle`'s compile target does after dart2js: the uses the
  // compiler wrote are the shaker's `recorded_uses_js.json`.
  final File resources = environment.buildDir.childFile(
    'main.dart.js.resources.json',
  );
  if (resources.existsSync()) {
    resources.renameSync(
      environment.buildDir.childFile('recorded_uses_js.json').path,
    );
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
  final String? devBootstrap = args.option('dev-bootstrap');
  if (devBootstrap != null) {
    _writeDevBootstrap(environment, args, fs.file(_abs(devBootstrap)));
  }
}

/// The `flutter_bootstrap.js` that `flutter run -d chrome` serves beside its
/// DDC build: the project's template (or the default one) substituted as the
/// tool's web dev server substitutes it (`WebAssetServer`), with no service
/// worker and a build config naming DDC's output.
void _writeDevBootstrap(Environment environment, ArgResults args, File out) {
  final FileSystem fs = environment.fileSystem;
  final File template = environment.projectDir
      .childDirectory('web')
      .childFile('flutter_bootstrap.js');
  final Directory webSdk = fs.directory(
    environment.artifacts.getHostArtifact(HostArtifact.flutterWebSdk).path,
  );
  final Directory canvasKit = webSdk.childDirectory('canvaskit');
  final wasmHashes = <String, String>{
    if (canvasKit.existsSync())
      for (final File file
          in canvasKit.listSync(recursive: true).whereType<File>())
        if (file.path.endsWith('.wasm'))
          fs.path
              .relative(file.path, from: canvasKit.path)
              .replaceAll(r'\', '/'): sha256
              .convert(file.readAsBytesSync())
              .toString(),
  };
  final String? rendererName = args.option('renderer');
  final buildConfig = <String, Object>{
    'engineRevision': args.option('engine-revision')!,
    'wasmHashes': wasmHashes,
    'builds': <Object>[
      <String, Object>{
        'compileTarget': 'dartdevc',
        'renderer': rendererName ?? WebRendererMode.canvaskit.name,
        'mainJsPath': 'main.dart.js',
      },
    ],
    if (args.flag('use-local-canvaskit')) 'useLocalCanvasKit': true,
  };
  final content =
      WebTemplate(
        template.existsSync()
            ? template.readAsStringSync()
            : generateDefaultFlutterBootstrapScript(
                includeServiceWorkerSettings: false,
              ),
      ).withSubstitutions(
        baseHref: '/',
        serviceWorkerVersion: null,
        buildConfig:
            '''
if (!window._flutter) {
  window._flutter = {};
}
_flutter.buildConfig = ${jsonEncode(buildConfig)};
''',
        flutterJsFile: webSdk
            .childDirectory('flutter_js')
            .childFile('flutter.js'),
        logger: environment.logger,
        webDefines: _pairs(args.multiOption('web-define')),
      );
  out
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(content);
}

/// `GenerateLocalizationsTarget`, as `flutter build` and `flutter pub get` run
/// it; the files it writes are copied to the output directory at their paths
/// in the project.
///
/// The build declares those files before the tool runs, from `l10n.yaml` and
/// the names of the `.arb` files (`--output`). The tool's own record of what
/// it wrote is checked against them, so a file the build did not expect, or
/// an expected one the tool did not write, fails here, naming it.
Future<void> _genL10n(Environment environment, ArgResults args) async {
  const target = GenerateLocalizationsTarget();
  if (await target.canSkip(environment)) {
    throwToolExit('${args.option('label')}: the project has no l10n.yaml');
  }
  final FileSystem fs = environment.fileSystem;
  // `format: true` runs `dart format`, which takes `formatter:` from
  // analysis_options.yaml but drops every option when an `include:` names a
  // package it cannot resolve, and the action has none of the packages an
  // include names. The staged file keeps the project's own `formatter:`
  // section only (written as JSON, which is YAML).
  final File options = environment.projectDir.childFile(
    'analysis_options.yaml',
  );
  if (options.existsSync()) {
    final Object? yaml = loadYaml(options.readAsStringSync());
    final Object? formatter = yaml is YamlMap ? yaml['formatter'] : null;
    if (fs.isLinkSync(options.path)) {
      fs.link(options.path).deleteSync();
    }
    options.writeAsStringSync(
      jsonEncode(<String, Object?>{
        if (formatter != null) 'formatter': formatter,
      }),
    );
  }
  await target.build(environment);
  final String project = environment.projectDir.path;
  final record = jsonDecode(
    environment.buildDir
        .childFile('gen_l10n_inputs_and_outputs.json')
        .readAsStringSync(),
  ) as Map<String, Object?>;
  final Set<String> written = <String>{
    for (final String output
        in (record['outputs']! as List<Object?>).cast<String>())
      fs.path.relative(output, from: project),
  };
  final List<String> expected = args.multiOption('output');
  // The record lists the untranslated messages file only when there are no
  // untranslated messages; the file is written either way.
  final String? untranslated = parseLocalizationsOptionsFromYAML(
    file: environment.projectDir.childFile('l10n.yaml'),
    logger: environment.logger,
    fileSystem: fs,
    defaultArbDir: fs.path.join('lib', 'l10n'),
  ).untranslatedMessagesFile;
  if (untranslated != null &&
      fs.isFileSync(fs.path.join(project, untranslated))) {
    written.add(fs.path.normalize(untranslated));
  }
  final List<String> missing = <String>[
    for (final rel in expected)
      if (!written.contains(rel)) rel,
  ];
  final List<String> extra = <String>[
    for (final rel in written.toList()..sort())
      if (!expected.contains(rel)) rel,
  ];
  if (missing.isNotEmpty || extra.isNotEmpty) {
    throwToolExit(
      '${args.option('label')}: gen-l10n '
      '${extra.isEmpty ? '' : 'wrote ${extra.join(', ')}'}'
      '${extra.isNotEmpty && missing.isNotEmpty ? ' and ' : ''}'
      '${missing.isEmpty ? '' : 'did not write ${missing.join(', ')}'}, '
      'unlike what the build read from l10n.yaml and the names of the .arb '
      'files. The build takes an .arb file\'s language from its "@@locale" '
      'or, without one, from its name (`app_en.arb`, `app_pt_BR.arb`); give '
      'the .arb file the tool reads differently a "@@locale", or a name that '
      'says its locale.',
    );
  }
  for (final rel in expected) {
    fs
        .file(fs.path.join(project, rel))
        .copySync(
          (fs.file(
            fs.path.join(environment.outputDir.path, rel),
          )..parent.createSync(recursive: true)).path,
        );
  }
}

/// What a path the tool failed on is, as the host sees it: its type without
/// following links, its target when it is a link, and whether it reads.
void _describePath(FileSystem fs, String path, Logger logger) {
  final FileSystemEntityType type = fs.typeSync(path, followLinks: false);
  final b = StringBuffer('$path: ${type.toString()} (not following links)');
  if (type == FileSystemEntityType.link) {
    try {
      b.write(', a link to ${fs.link(path).targetSync()}');
    } on FileSystemException catch (e) {
      b.write(', its target unreadable: $e');
    }
  }
  b.write(', exists following links: ${fs.typeSync(path) != FileSystemEntityType.notFound}');
  try {
    b.write(', reads ${fs.file(path).readAsBytesSync().length} bytes');
  } on FileSystemException catch (e) {
    b.write(', does not read: ${e.osError?.message ?? e.message}');
  }
  logger.printError(b.toString());
}

/// A project file staged as a link whose target is not there: the action was
/// given the path of a file the host cannot open. Names each, so a copy that
/// "cannot find the file specified" says which file and where it pointed.
void _explainDanglingLinks(FileSystem fs, Directory project, Logger logger) {
  try {
    for (final FileSystemEntity entity in project.listSync(recursive: true)) {
      if (entity is! Link) {
        continue;
      }
      final String target = entity.targetSync();
      if (!fs.isFileSync(target) && !fs.isDirectorySync(target)) {
        logger.printError(
          'The staged file ${fs.path.relative(entity.path, from: project.path)} '
          'is a link to $target, which does not exist.',
        );
      }
    }
  } on FileSystemException catch (e) {
    logger.printError('Listing the staged project failed: $e');
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
  _explainDanglingLinks(fs, project, logger);
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

  @override
  File file(dynamic path) => _ReadingCopyFile(this, delegate.file(path));
}

/// A file whose copy, on Windows, reads and writes the bytes.
///
/// A staged file is a link to its input. Windows' `CopyFileW`, which
/// `File.copy` calls, reports a link to an input under the execution root
/// as missing ("cannot find the file specified") although the same link
/// reads: the first run of this tool on Windows failed to copy the material
/// fonts that way. Reading and writing is what a copy of a file amounts to.
class _ReadingCopyFile extends ForwardingFileSystemEntity<File, io.File>
    with ForwardingFile {
  _ReadingCopyFile(this.fileSystem, this.delegate);

  @override
  final _SortedListings fileSystem;

  @override
  final io.File delegate;

  @override
  File wrapFile(io.File delegate) => _ReadingCopyFile(fileSystem, delegate);

  @override
  Directory wrapDirectory(io.Directory delegate) =>
      _SortedDirectory(fileSystem, delegate);

  @override
  Link wrapLink(io.Link delegate) => fileSystem.delegate.link(delegate.path);

  @override
  File copySync(String newPath) {
    if (!const LocalPlatform().isWindows) {
      return super.copySync(newPath);
    }
    final File copy = fileSystem.file(newPath)
      ..writeAsBytesSync(readAsBytesSync());
    return copy;
  }

  @override
  Future<File> copy(String newPath) async {
    if (!const LocalPlatform().isWindows) {
      return super.copy(newPath);
    }
    return copySync(newPath);
  }
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
  File wrapFile(io.File delegate) => _ReadingCopyFile(fileSystem, delegate);

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
