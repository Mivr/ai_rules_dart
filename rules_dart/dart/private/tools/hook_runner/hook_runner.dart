// Runs one package's build or link hook through `package:hooks_runner`, the
// library `dart build` and `flutter build` drive, and writes the app's
// native-assets manifest from the results.
//
// Nothing of the hook protocol is written here: the runner compiles nothing
// (the hook's kernel comes from its own action), writes the hook input,
// validates the output and reads the user defines. This program decides only
// what a launcher decides in a stock build: the target, the C toolchain, the
// package layout, where results go, and (for `manifest`) where each library
// lands in the app.
//
//   hook_runner compile  --dart <dart> --record ... --script <path> --out <dill>
//   hook_runner build    --dart <dart> --package <name> --hook-kernel <dill>
//                        --record <name|root|languageVersion>... --target-os <os>
//                        --target-arch <arch> [--cc <clang> --ar <ar> --ld <ld>]
//                        [--user-defines <json> --pubspec <path>] --out <dir>
//   hook_runner link     ... --build-assets <dir>... [--recorded-uses <json>]
//                        [--declare <name>=<file>...] --out <dir>
//   hook_runner manifest --target <os_arch> --assets <dir>... --manifest <file>
//                        [--bundle <dir> --style <style>]
//
// The output of `build` and `link` is one directory: `assets.json` (the
// runner's own `BuildResult` / `LinkResult` JSON, file paths relative to the
// directory) and the files the hook produced.
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:code_assets/code_assets.dart';
import 'package:data_assets/data_assets.dart';
import 'package:file/file.dart' as fs;
import 'package:file/local.dart';
import 'package:hooks/hooks.dart';
import 'package:hooks_runner/hooks_runner.dart';
import 'package:logging/logging.dart';
import 'package:package_config/package_config.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.isEmpty) {
    stderr.writeln('usage: hook_runner build|link|manifest ...');
    exitCode = 64;
    return;
  }
  final String command = arguments.first;
  final List<String> rest = await _expandParamsFile(arguments.sublist(1));
  switch (command) {
    case 'build':
    case 'link':
      exitCode = await _runHook(command, _hookParser().parse(rest));
    case 'compile':
      exitCode = await _compileHook(_compileParser().parse(rest));
    case 'manifest':
      exitCode = writeManifest(_manifestParser().parse(rest));
    default:
      stderr.writeln('hook_runner: unknown command "$command"');
      exitCode = 64;
  }
}

/// Bazel passes long argument lists as `@file`, one argument per line.
Future<List<String>> _expandParamsFile(List<String> args) async {
  if (args.length == 1 && args.single.startsWith('@')) {
    return File(args.single.substring(1)).readAsLinesSync();
  }
  return args;
}

ArgParser _hookParser() => ArgParser()
  ..addOption('dart', mandatory: true)
  ..addOption('package', mandatory: true)
  ..addOption('hook-kernel', mandatory: true)
  ..addMultiOption('record', splitCommas: false)
  ..addOption('target-os')
  ..addOption('target-arch')
  ..addOption('android-api')
  ..addOption('ios-sdk')
  ..addOption('ios-version')
  ..addOption('macos-version')
  ..addOption('cc')
  ..addOption('ar')
  ..addOption('ld')
  ..addOption('path', defaultsTo: '/nonexistent')
  ..addMultiOption('env', splitCommas: false)
  ..addOption('user-defines')
  ..addOption('pubspec')
  ..addFlag('linking')
  ..addFlag('network')
  ..addMultiOption('build-assets', splitCommas: false)
  ..addOption('recorded-uses')
  ..addMultiOption('declare', splitCommas: false)
  ..addOption('out', mandatory: true);

ArgParser _compileParser() => ArgParser()
  ..addOption('dart', mandatory: true)
  ..addMultiOption('record', splitCommas: false)
  ..addOption('script', mandatory: true)
  ..addOption('out', mandatory: true);

/// Compiles a hook to kernel with the command the runner itself runs
/// (`dart compile kernel`), as its own action: the kernel then depends only on
/// the hook's Dart closure and the SDK, not on the target or the toolchain,
/// and a cold hook run does not compile it again.
Future<int> _compileHook(ArgResults args) async {
  final String cwd = Directory.current.absolute.path;
  final Directory work = Directory.systemTemp.createTempSync('hook_compile_');
  try {
    final config = File('${work.path}/package_config.json')
      ..writeAsStringSync(
        packageConfigJson(args['record'] as List<String>, cwd),
      );
    final ProcessResult result = await Process.run(
      args['dart'] as String,
      [
        '--suppress-analytics',
        'compile',
        'kernel',
        '--packages=${config.path}',
        '--output=${args['out']}',
        args['script'] as String,
      ],
      environment: {'HOME': work.path, 'PUB_CACHE': '${work.path}/pub'},
      includeParentEnvironment: false,
    );
    if (result.exitCode != 0) {
      stderr
        ..write(result.stdout)
        ..write(result.stderr);
    }
    return result.exitCode;
  } finally {
    work.deleteSync(recursive: true);
  }
}

ArgParser _manifestParser() => ArgParser()
  ..addOption('target', mandatory: true)
  ..addMultiOption('assets', splitCommas: false)
  ..addOption('manifest', mandatory: true)
  ..addOption('bundle')
  ..addOption(
    'style',
    allowed: ['relative', 'basename', 'runfiles', 'framework'],
    defaultsTo: 'relative',
  )
  ..addOption('lib-dir', defaultsTo: '')
  ..addOption('format', allowed: ['dart', 'flutter'], defaultsTo: 'dart')
  ..addOption('relative-to')
  ..addOption('runfiles-prefix', defaultsTo: '');

/// The file names in the runner's cache that the precompiled hook kernel
/// stands in for. Pinned with the runner version (see `pubspec.yaml`); a
/// runner that looks elsewhere makes [_PrecompiledHookFileSystem.kernelServed]
/// false and the action fails rather than compiling the hook a second time.
const _hookKernelName = 'hook.dill';
const _hookKernelHashesName = 'hook.dependencies_hash_file.json';

Future<int> _runHook(String hook, ArgResults args) async {
  final String cwd = Directory.current.absolute.path;
  String abs(String p) => p.startsWith('/') ? p : '$cwd/$p';
  final packageName = args['package'] as String;
  final Directory work = Directory.systemTemp.createTempSync('hook_runner_');
  final logs = <LogRecord>[];
  try {
    // The runner keeps its state next to the package config and reads pub's
    // `package_graph.json` from there. The graph holds only this package, so
    // only its hook runs.
    final dartTool = Directory('${work.path}/.dart_tool')..createSync();
    final config = File('${dartTool.path}/package_config.json')
      ..writeAsStringSync(
        packageConfigJson(args['record'] as List<String>, cwd),
      );
    File('${dartTool.path}/package_graph.json').writeAsStringSync(
      jsonEncode({
        'roots': [packageName],
        'packages': [
          {'name': packageName, 'version': '0.0.0', 'dependencies': <String>[]},
        ],
      }),
    );

    final logger = Logger.detached('hook')
      ..level = Level.ALL
      ..onRecord.listen(logs.add);

    final pubspec = args['pubspec'] as String?;
    final userDefines = args['user-defines'] as String?;
    final Uri? pubspecUri = pubspec == null ? null : Uri.file(abs(pubspec));
    File? slice;
    if (pubspecUri != null && userDefines != null) {
      // The runner reads `hooks.user_defines` from the workspace pubspec and
      // resolves relative paths against its directory. Only this package's
      // slice is an input of the action (so an unrelated pubspec edit runs no
      // hook); it is served where the pubspec is. JSON is YAML.
      slice = File('${work.path}/user_defines.json')
        ..writeAsStringSync(
          jsonEncode({
            'hooks': {
              'user_defines': {
                packageName: jsonDecode(File(userDefines).readAsStringSync()),
              },
            },
          }),
        );
    }
    final hashes = File('${work.path}/$_hookKernelHashesName')
      ..writeAsStringSync(
        jsonEncode({'file_system': <String>[], 'environment': <String>[]}),
      );
    final fileSystem = _PrecompiledHookFileSystem(
      const LocalFileSystem(),
      kernel: abs(args['hook-kernel'] as String),
      kernelHashes: hashes.path,
      pubspec: pubspecUri?.toFilePath(),
      pubspecSlice: slice?.path,
    );

    final PackageConfig packageConfig = await loadPackageConfigUri(config.uri);
    final layout = PackageLayout.fromPackageConfig(
      fileSystem,
      packageConfig,
      config.uri,
      packageName,
      includeDevDependencies: false,
    );
    final tmp = Directory('${work.path}/tmp')..createSync();
    final environment = <String, String>{
      'PATH': args['path'] as String,
      'TMPDIR': tmp.path,
      // For the generated compiler wrappers, which run Bazel's toolchain by
      // exec-root-relative path while the hook runs in its package root.
      'BAZEL_EXECROOT': cwd,
      for (final e in args['env'] as List<String>)
        e.substring(0, e.indexOf('=')): e.substring(e.indexOf('=') + 1),
    };
    final runner = NativeAssetsBuildRunner(
      logger: logger,
      dartExecutable: Uri.file(abs(args['dart'] as String)),
      fileSystem: fileSystem,
      packageLayout: layout,
      hookEnvironment: environment,
      userDefines: pubspecUri == null
          ? null
          : UserDefines(workspacePubspec: pubspecUri),
    );
    final extensions = [
      if (args['target-os'] != null) _codeAssetExtension(args, abs),
      DataAssetsExtension(),
    ];

    final out = Directory(args['out'] as String)..createSync(recursive: true);
    final Object? failure;
    final Map<String, Object?> json;
    if (hook == 'build') {
      final result = await runner.build(
        extensions: extensions,
        linkingEnabled: args['linking'] as bool,
      );
      failure = result.isFailure ? result.failure : null;
      json = result.isFailure ? const {} : result.success.toJson();
    } else {
      final recordedUses = args['recorded-uses'] as String?;
      final result = await runner.link(
        extensions: extensions,
        recordUse: recordedUses == null
            ? null
            : RecordUseConfig(
                file: Uri.file(abs(recordedUses)),
                entryPoints: const [],
                compiler: 'dart2native',
              ),
        buildResult: _buildResultFor(
          packageName,
          (args['build-assets'] as List<String>).map(abs),
        ),
      );
      failure = result.isFailure ? result.failure : null;
      // The runner's one result type implements both interfaces; only the
      // build side has the JSON form.
      json = result.isFailure
          ? const {}
          : (result.success as BuildResult).toJson();
    }
    if (failure != null) {
      stderr.write(
        hookFailureMessage(
          packageName,
          hook,
          logs.map((r) => r.message).join('\n'),
          networkAllowed: args['network'] as bool,
        ),
      );
      return 1;
    }
    if (!fileSystem.kernelServed) {
      stderr.writeln(
        'hook_runner: package:hooks_runner did not ask for the precompiled '
        'kernel of $packageName\'s hook (it looks for "$_hookKernelName" in '
        'its cache directory). The runner version in rules_dart\'s '
        'hook_runner/pubspec.yaml no longer matches this program.',
      );
      return 1;
    }
    _writeAssetDirectory(json, out, packageName);
    return _copyDeclaredDataAssets(
      json,
      packageName,
      args['declare'] as List<String>,
    );
  } finally {
    work.deleteSync(recursive: true);
  }
}

CodeAssetExtension _codeAssetExtension(
  ArgResults args,
  String Function(String) abs,
) {
  final os = OS.fromString(args['target-os'] as String);
  final cc = args['cc'] as String?;
  final androidApi = args['android-api'] as String?;
  final iosSdk = args['ios-sdk'] as String?;
  final macosVersion = args['macos-version'] as String?;
  return CodeAssetExtension(
    targetArchitecture: Architecture.fromString(args['target-arch'] as String),
    targetOS: os,
    linkModePreference: LinkModePreference.dynamic,
    android: androidApi == null
        ? null
        : AndroidCodeConfig(targetNdkApi: int.parse(androidApi)),
    iOS: iosSdk == null
        ? null
        : IOSCodeConfig(
            targetSdk: IOSSdk.fromString(iosSdk),
            targetVersion: int.parse(args['ios-version'] as String),
          ),
    macOS: macosVersion == null
        ? null
        : MacOSCodeConfig(targetVersion: int.parse(macosVersion)),
    cCompiler: cc == null
        ? null
        : CCompilerConfig(
            compiler: Uri.file(abs(cc)),
            linker: Uri.file(abs(args['ld'] as String)),
            archiver: Uri.file(abs(args['ar'] as String)),
          ),
  );
}

/// The `package_config.json` of the hook's closure, from Bazel's package
/// records (`name|root|languageVersion`, the root relative to [execRoot]).
/// The first record of a name wins, as in every other package config the
/// rules write.
String packageConfigJson(List<String> records, String execRoot) {
  final seen = <String>{};
  final packages = <Map<String, Object?>>[];
  for (final record in records) {
    final parts = record.split('|');
    if (!seen.add(parts[0])) continue;
    // A package from another repository has the short path `../repo/x` and
    // lives at `external/repo/x` under the exec root.
    final path = parts[1].startsWith('../')
        ? 'external/${parts[1].substring(3)}'
        : parts[1];
    packages.add({
      'name': parts[0],
      'rootUri': Uri.directory(path.isEmpty ? execRoot : '$execRoot/$path')
          .toString(),
      'packageUri': 'lib/',
      if (parts.length > 2 && parts[2].isNotEmpty) 'languageVersion': parts[2],
    });
  }
  return const JsonEncoder.withIndent('  ')
      .convert({'configVersion': 2, 'packages': packages});
}

/// The build result a link hook sees: every build hook's assets routed to
/// [package] for linking, read from their asset directories.
BuildResult _buildResultFor(String package, Iterable<String> directories) {
  final forLinking = <EncodedAsset>[];
  for (final dir in directories) {
    final json = readAssetDirectory(dir);
    final routed = (json['encodedAssetsForLinking'] as Map?)?[package];
    for (final asset in (routed as List?) ?? const []) {
      forLinking.add(EncodedAsset.fromJson(asset as Map<String, Object?>));
    }
  }
  return BuildResult.fromJson({
    'encodedAssetsForLinking': {
      package: [for (final a in forLinking) a.toJson()],
    },
  });
}

/// Reads the assets of a hook's output directory (its `assets.json`), or of
/// a `*.assets.json` file a `dart_code_asset` writes, with each file path made
/// absolute against the JSON file's directory.
Map<String, Object?> readAssetDirectory(String path) {
  final index = File(path.endsWith('.json') ? path : '$path/assets.json');
  final base = index.absolute.parent.uri;
  final json = jsonDecode(index.readAsStringSync()) as Map<String, Object?>;
  return _mapFiles(json, (file) => base.resolve(file).toFilePath());
}

/// Copies the files [json] names into [out] and writes `assets.json` with
/// paths relative to [out]. Files are numbered so two assets with one file
/// name cannot collide; the original name is kept.
void _writeAssetDirectory(
  Map<String, Object?> json,
  Directory out,
  String packageName,
) {
  var n = 0;
  final copied = <String, String>{};
  final relative = _mapFiles(json, (file) {
    final existing = copied[file];
    if (existing != null) return existing;
    final source = File(file);
    final rel = '${n++}/${source.uri.pathSegments.last}';
    final target = File('${out.path}/$rel')..parent.createSync(recursive: true);
    source.copySync(target.path);
    return copied[file] = rel;
  });
  // The runner's dependency list names absolute sandbox paths: Bazel tracks
  // the inputs itself, and the paths would make the output differ per build.
  relative.remove('dependencies');
  File('${out.path}/assets.json')
      .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(relative));
}

/// Copies each data asset [json] holds to the file its name is declared at
/// (`--declare <name>=<file>`): Bazel names every output before the action
/// runs. An asset emitted but not declared, or declared but not emitted,
/// fails the run and lists both sets.
int _copyDeclaredDataAssets(
  Map<String, Object?> json,
  String packageName,
  List<String> declarations,
) {
  if (declarations.isEmpty) return 0;
  final declared = {
    for (final d in declarations)
      d.substring(0, d.indexOf('=')): d.substring(d.indexOf('=') + 1),
  };
  final emitted = <String, DataAsset>{
    for (final raw in (json['encodedAssets'] as List?) ?? const [])
      if (EncodedAsset.fromJson(raw as Map<String, Object?>).isDataAsset)
        DataAsset.fromEncoded(EncodedAsset.fromJson(raw))
            .name: DataAsset.fromEncoded(
          EncodedAsset.fromJson(raw),
        ),
  };
  final missing = declared.keys.where((n) => !emitted.containsKey(n)).toList()
    ..sort();
  final extra = emitted.keys.where((n) => !declared.containsKey(n)).toList()
    ..sort();
  if (missing.isNotEmpty || extra.isNotEmpty) {
    stderr.writeln(
      'The link hook of package:$packageName emitted the data assets '
      '${(emitted.keys.toList()..sort()).map((n) => 'package:$packageName/$n')}, '
      'but ${(declared.keys.toList()..sort()).map((n) => 'package:$packageName/$n')} '
      'are declared in `data_assets`.'
      '${missing.isEmpty ? '' : ' Not emitted: ${missing.join(', ')}.'}'
      '${extra.isEmpty ? '' : ' Not declared: ${extra.join(', ')}.'}',
    );
    return 1;
  }
  for (final entry in declared.entries) {
    File.fromUri(emitted[entry.key]!.file).copySync(entry.value);
  }
  return 0;
}

/// Rewrites the `file` of every encoded asset in a `BuildResult` /
/// `LinkResult` JSON.
Map<String, Object?> _mapFiles(
  Map<String, Object?> json,
  String Function(String) map,
) {
  Object? asset(Object? a) {
    final m = Map<String, Object?>.from(a! as Map);
    final encoding = m['encoding'];
    if (encoding is Map && encoding['file'] is String) {
      m['encoding'] = <String, Object?>{
        ...encoding.cast<String, Object?>(),
        'file': map(encoding['file'] as String),
      };
    }
    return m;
  }

  return {
    ...json,
    if (json['encodedAssets'] is List)
      'encodedAssets': [
        for (final a in json['encodedAssets']! as List) asset(a),
      ],
    if (json['encodedAssetsForLinking'] is Map)
      'encodedAssetsForLinking': {
        for (final e in (json['encodedAssetsForLinking']! as Map).entries)
          e.key: [for (final a in e.value as List) asset(a)],
      },
  };
}

/// Words that mean a hook tried the network. The action has none unless the
/// package was opted in, so the attempt fails in one of these ways.
const _networkSignals = [
  'Failed host lookup',
  'SocketException',
  'HandshakeException',
  'Network is unreachable',
  'ClientException',
  'HttpException',
];

/// The message of a failed hook: the runner's log, then what to do.
String hookFailureMessage(
  String package,
  String hook,
  String log, {
  required bool networkAllowed,
}) {
  final out = StringBuffer()
    ..writeln(log.trimRight())
    ..writeln();
  final triedNetwork = _networkSignals.any(log.contains);
  if (triedNetwork && !networkAllowed) {
    out
      ..writeln(
        'The $hook hook of package:$package tried to download at build time. '
        'Build hooks run offline in a sandbox, so this download is refused.',
      )
      ..writeln(
        'Either make the hook build without the network: many packages that '
        'download a prebuilt library offer a user define that compiles it '
        'from source or uses a system library instead (set it under '
        '`hooks: user_defines: $package:` in the pubspec.yaml next to your '
        'pubspec.lock; the hook\'s own message above says which).',
      )
      ..writeln(
        'Or let this one hook use the network: list "$package" in '
        '`hook_network` of your `pub.from_lock` (or `flutter.pub`) tag. That '
        'action then fetches whatever the hook asks for at build time, which '
        'Bazel neither pins nor caches by content.',
      );
  } else {
    out.writeln(
      'The $hook hook of package:$package failed (log above). Hooks run in a '
      'sandbox: no network${networkAllowed ? ' (allowed for this package)' : ''}, '
      'no HOME, a PATH with no tools, only the package\'s own files, the C '
      'toolchain Bazel resolved and the files listed in `hook_data`.',
    );
  }
  return out.toString();
}

/// Serves the precompiled hook kernel, and the workspace pubspec's
/// user-defines slice, where `package:hooks_runner` looks for them.
class _PrecompiledHookFileSystem extends fs.ForwardingFileSystem {
  _PrecompiledHookFileSystem(
    super.delegate, {
    required this.kernel,
    required this.kernelHashes,
    required this.pubspec,
    required this.pubspecSlice,
  });

  final String kernel;
  final String kernelHashes;
  final String? pubspec;
  final String? pubspecSlice;
  bool kernelServed = false;

  @override
  fs.File file(dynamic path) {
    final p = path is Uri ? path.toFilePath() : path.toString();
    if (p.contains('/hooks_runner/') && !p.contains('/hooks_runner/shared/')) {
      if (p.endsWith('/$_hookKernelName')) {
        kernelServed = true;
        return delegate.file(kernel);
      }
      if (p.endsWith('/$_hookKernelHashesName')) {
        return delegate.file(kernelHashes);
      }
    }
    if (pubspec != null && p == pubspec) {
      return delegate.file(pubspecSlice ?? '/nonexistent/pubspec.yaml');
    }
    return delegate.file(path);
  }
}

/// Writes the native-assets manifest the compiler embeds, and copies each
/// bundled library to where the app loads it from.
int writeManifest(ArgResults args) {
  final target = Target.fromString(args['target'] as String);
  final style = args['style'] as String;
  final bundle = args['bundle'] as String?;
  final libDir = args['lib-dir'] as String;
  final relativeTo = args['relative-to'] as String?;
  if (bundle != null) Directory(bundle).createSync(recursive: true);
  final assets = <KernelAsset>[];
  final owners = <String, String>{};
  for (final dir in args['assets'] as List<String>) {
    final json = readAssetDirectory(dir);
    for (final raw in (json['encodedAssets'] as List?) ?? const []) {
      final encoded = EncodedAsset.fromJson(raw as Map<String, Object?>);
      if (!encoded.isCodeAsset) continue;
      final asset = encoded.asCodeAsset;
      final previous = owners[asset.id];
      if (previous != null) {
        stderr.writeln(
          'Duplicate code asset id "${asset.id}", from $previous and $dir. '
          'The Dart VM resolves an id to exactly one library.',
        );
        return 1;
      }
      owners[asset.id] = dir;
      assets.add(
        KernelAsset(
          id: asset.id,
          target: target,
          path: _kernelPath(
            asset,
            style: style,
            bundle: bundle,
            libDir: libDir,
            relativeTo: relativeTo,
            runfilesPrefix: args['runfiles-prefix'] as String,
          ),
        ),
      );
    }
  }
  File(args['manifest'] as String).writeAsStringSync(
    args['format'] == 'flutter'
        ? flutterNativeAssetsJson(assets)
        : '${KernelAssets(assets).toNativeAssetsFile()}\n',
  );
  return 0;
}

/// The manifest as the Flutter tool writes it (`native_assets.json`, bundled
/// as `NativeAssetsManifest.json`): compact JSON, the assets grouped by
/// target in their order. The engine reads the bundled copy as it is.
String flutterNativeAssetsJson(List<KernelAsset> assets) {
  final perTarget = <String, Map<String, List<String>>>{};
  for (final asset in assets) {
    (perTarget[asset.target.toString()] ??= {})[asset.id] = asset.path.toJson();
  }
  return jsonEncode({
    'format-version': const [1, 0, 0],
    'native-assets': perTarget,
  });
}

KernelAssetPath _kernelPath(
  CodeAsset asset, {
  required String style,
  required String? bundle,
  required String libDir,
  required String? relativeTo,
  required String runfilesPrefix,
}) {
  switch (asset.linkMode) {
    case DynamicLoadingSystem(:final uri):
      return KernelAssetSystemPath(uri);
    case LookupInExecutable():
      return KernelAssetInExecutable();
    case LookupInProcess():
      return KernelAssetInProcess();
    case DynamicLoadingBundled():
      break;
    default:
      throw StateError(
        'Code asset "${asset.id}" has link mode ${asset.linkMode}, which an '
        'app cannot load. Only dynamic libraries are supported.',
      );
  }
  final source = File.fromUri(asset.file!);
  final name = source.uri.pathSegments.last;
  final inBundle = libDir.isEmpty ? name : '$libDir/$name';
  if (bundle != null) {
    final target = File('$bundle/$inBundle')
      ..parent.createSync(recursive: true);
    if (!target.existsSync()) source.copySync(target.path);
  }
  switch (style) {
    case 'basename':
      return KernelAssetAbsolutePath(Uri.file(name));
    case 'framework':
      final framework = frameworkName(name);
      return KernelAssetAbsolutePath(
        Uri.file('$framework.framework/$framework'),
      );
    case 'runfiles':
      return KernelAssetAbsolutePath(Uri.file('$runfilesPrefix$inBundle'));
    default:
      final from = Directory(relativeTo!).absolute.uri.pathSegments
          .where((s) => s.isNotEmpty)
          .toList();
      final to = File('${bundle!}/$inBundle').absolute.uri.pathSegments
          .where((s) => s.isNotEmpty)
          .toList();
      var common = 0;
      while (common < from.length &&
          common < to.length - 1 &&
          from[common] == to[common]) {
        common++;
      }
      final rel = [
        for (var i = common; i < from.length; i++) '..',
        ...to.sublist(common),
      ].join('/');
      return KernelAssetRelativePath(Uri.file(rel));
  }
}

/// The framework an Apple app wraps a bundled library in, as flutter_tools
/// names it (`frameworkUri`): `.dylib` and a leading `lib` dropped, then only
/// `[A-Za-z0-9_-]` kept.
String frameworkName(String fileName) {
  var name = fileName;
  if (name.endsWith('.dylib')) {
    name = name.substring(0, name.length - '.dylib'.length);
    if (name.startsWith('lib')) name = name.substring(3);
  }
  return name.replaceAll(RegExp('[^A-Za-z0-9_-]'), '');
}
