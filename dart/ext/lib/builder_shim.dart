/// Shim-runner: turns a single `package:build` Builder into a CLI tool that
/// matches the `dart_codegen` rule's `--input` / `--output` contract.
///
/// Per-builder shim binaries import this library and call [runShim] in their
/// `main()`. The generic plumbing (arg parsing, in-memory asset reader/writer,
/// analyzer-driven Resolver, BuildStep adapter) lives here; per-builder shims
/// stay ~10 lines.
///
/// The shim depends only on `package:build` (interfaces) and `package:analyzer`
/// (resolver). `build_resolvers` and `build_runner_core` were both
/// discontinued; their resolver/runBuilder functionality is reimplemented
/// here over the public analyzer API.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/session.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/file_system/file_system.dart' as fs;
import 'package:analyzer/file_system/physical_file_system.dart';
import 'package:analyzer/source/file_source.dart';
import 'package:analyzer/source/source.dart';
// ignore: implementation_imports
import 'package:analyzer/src/context/source.dart';
// ignore: implementation_imports
import 'package:analyzer/src/dart/analysis/analysis_context_collection.dart';
// ignore: implementation_imports
import 'package:analyzer/src/dart/analysis/driver_based_analysis_context.dart';
// ignore: implementation_imports
import 'package:analyzer/src/generated/source.dart';
// ignore: implementation_imports
import 'package:analyzer/src/source/package_map_resolver.dart';
// ignore: implementation_imports
import 'package:analyzer/src/utilities/uri_cache.dart';
// ignore: implementation_imports
import 'package:analyzer/src/workspace/pub.dart';
import 'package:args/args.dart';
import 'package:build/build.dart';
import 'package:crypto/crypto.dart';
import 'package:glob/glob.dart';
import 'package:logging/logging.dart';
import 'package:package_config/package_config.dart';
import 'package:path/path.dart' as p;
import 'package:rules_dart_guard/directive_guard.dart';
import 'package:rules_dart_worker/worker_tool_fs.dart';

/// Parsed shim CLI arguments.
class ShimArgs {
  ShimArgs({
    required this.inputPath,
    required this.inputAssetPath,
    required this.outputPaths,
    required this.packageName,
    required this.depPaths,
    required this.config,
    required this.rootLanguageVersion,
    this.packageConfigUri,
    this.sdkPath,
    this.summaryPaths = const [],
    this.sdkSummaryPath,
    this.pkgRootsDir,
    this.pkgRootsManifest,
  });

  final String inputPath;

  /// In-package path (e.g. `lib/src/models/user.dart`); preserves subdirs
  /// that `p.basename(inputPath)` would drop.
  final String inputAssetPath;

  /// Declared Bazel output paths (one per builder-produced extension).
  /// The shim routes each builder-emitted asset to the matching declared
  /// path by suffix; any declared path with no emitted asset is written
  /// empty.
  final List<String> outputPaths;
  final String packageName;

  /// Pairs of `(exec_path, in_package_asset_path)`.
  final List<({String exec, String asset})> depPaths;

  final Map<String, dynamic> config;

  /// Path to a `package_config.json`; null falls back to `Isolate.packageConfig`.
  final String? packageConfigUri;

  /// Dart SDK root — AOT shims can't auto-detect this.
  final String? sdkPath;

  /// Analyzer summaries of the libraries outside the input's own package
  /// (`--summary`, repeatable). Empty leaves the analysis context as it was.
  final List<String> summaryPaths;

  /// The analyzer summary of the SDK's own libraries (`--sdk-summary`), read
  /// alongside [summaryPaths]. Null when not given.
  final String? sdkSummaryPath;

  /// Exec path of the target's own `<name>.pkg_roots` stage: the symlinks
  /// `synth_package_config` staged for this target's dependency sources, which
  /// the upstream `package_config.json` resolves `package:` URIs through. Null
  /// when the flag was not passed; then no pruning happens.
  final String? pkgRootsDir;

  /// Exec path of the stage manifest listing the stage-relative entries the
  /// current build declares. Null when the flag was not passed; then no
  /// pruning happens.
  final String? pkgRootsManifest;

  final LanguageVersion rootLanguageVersion;

  static void _addInputOptions(ArgParser parser) {
    parser
      ..addOption('input', help: 'Input file exec-root path.', mandatory: true)
      ..addMultiOption(
        'output',
        help:
            'Declared output file path (repeatable). Each builder-'
            'produced asset is routed to the declared output whose '
            'basename shares the input stem + matching suffix. At least '
            'one `--output` is required.',
      )
      ..addOption(
        'input-asset',
        help:
            'Asset path for the input within its package, relative to the '
            "package root (e.g. `lib/src/models/user.dart`). Preserves "
            "subdirectory structure that `p.basename(--input)` would drop. "
            "Required.",
        mandatory: true,
      )
      ..addOption(
        'package',
        help:
            'Owning Dart package name (matches consumer pubspec `name:`). '
            'Required — the shim builds AssetIds from this.',
        mandatory: true,
      );
  }

  static void _addDepOptions(ArgParser parser) {
    parser
      ..addMultiOption(
        'dep',
        help:
            'Additional source file visible to the Resolver. '
            'Format: `<exec_path>|<asset_path>` (asset path is the path '
            'within the owning package, e.g. `lib/base.dart`). Repeatable.',
      )
      ..addMultiOption(
        'input-asset-extra',
        help:
            'Extra aggregate inputs beyond the primary `--input`. Same '
            '`<exec>|<asset>` form as `--dep`, but these are exposed to '
            'the Builder as primary asset inputs (used by aggregate / '
            'PackageBuilder-style shims). Repeatable.',
      );
  }

  static void _addConfigOptions(ArgParser parser) {
    parser
      ..addOption(
        'config',
        help: 'Builder options as JSON. Defaults to "{}".',
        defaultsTo: '{}',
      )
      ..addOption(
        'package-config',
        help:
            'Path to package_config.json for third-party import resolution. '
            "Defaults to the running process's package_config.",
        defaultsTo: '',
      )
      ..addOption(
        'root-language-version',
        help:
            'Dart language version (in `<major>.<minor>` form) for the '
            'root package, propagated from the consuming dart_library. '
            'Required — no default.',
        mandatory: true,
      )
      ..addOption(
        'sdk-path',
        help:
            'Path to the Dart SDK installation root (the directory '
            'containing `lib/_internal/libraries.dart`). Required when '
            "the shim runs as an AOT-compiled binary so the analyzer's "
            "context collection can locate the SDK's libraries. The "
            "rules_dart codegen rules pass this from the toolchain.",
        defaultsTo: '',
      );
  }

  static void _addSummaryOptions(ArgParser parser) {
    parser
      ..addMultiOption(
        'summary',
        help:
            'Analyzer summary (`.sum`) of a library outside the input\'s '
            'package. Repeatable. The analysis context resolves those '
            'libraries from the summary instead of their source.',
      )
      ..addOption(
        'sdk-summary',
        help:
            'Analyzer summary of the Dart SDK\'s own libraries. Read with '
            'each `--summary`, since a dependency summary refers to them.',
        defaultsTo: '',
      );
  }

  static void _addPkgRootsOptions(ArgParser parser) {
    parser
      ..addOption(
        'pkg-roots-dir',
        help:
            'Exec path of the target\'s own `<name>.pkg_roots` stage. '
            'Entries the stage manifest does not list are pruned before '
            'analysis so `package:` URIs cannot resolve through stale '
            'symlinks an earlier build staged. Empty (the default) prunes '
            'nothing.',
        defaultsTo: '',
      )
      ..addOption(
        'pkg-roots-manifest',
        help:
            'Exec path of the stage manifest: one stage-relative entry per '
            'line. Empty (the default) prunes nothing.',
        defaultsTo: '',
      );
  }

  static ArgParser _buildParser() {
    final parser = ArgParser()
      ..addFlag(
        'help',
        abbr: 'h',
        negatable: false,
        help: 'Print this usage information.',
      );
    _addInputOptions(parser);
    _addDepOptions(parser);
    _addConfigOptions(parser);
    _addSummaryOptions(parser);
    _addPkgRootsOptions(parser);
    return parser;
  }

  /// Parses `<exec_path>|<asset_path>` entries of [--dep] or
  /// [--input-asset-extra] into (exec, asset) records.
  static List<({String exec, String asset})> _parsePipeList(
    List<String> raws,
    String flag,
  ) {
    final out = <({String exec, String asset})>[];
    for (final raw in raws) {
      final sep = raw.indexOf('|');
      if (sep < 0) {
        throw FormatException(
          '$flag must be `<exec_path>|<asset_path>`; got "$raw"',
        );
      }
      out.add((exec: raw.substring(0, sep), asset: raw.substring(sep + 1)));
    }
    return out;
  }

  /// Parses `--root-language-version` (`<major>.<minor>`) the way the
  /// analyzer's [LanguageVersion] needs it.
  static LanguageVersion _parseRootLanguageVersion(String rootLvRaw) {
    final rootLvParts = rootLvRaw.split('.');
    if (rootLvParts.length != 2) {
      throw FormatException(
        '--root-language-version must be `<major>.<minor>`, got '
        '"$rootLvRaw"',
      );
    }
    final rootLvMajor = int.tryParse(rootLvParts[0]);
    final rootLvMinor = int.tryParse(rootLvParts[1]);
    if (rootLvMajor == null ||
        rootLvMinor == null ||
        rootLvMajor < 0 ||
        rootLvMinor < 0) {
      throw FormatException(
        '--root-language-version components must be non-negative ints, '
        'got "$rootLvRaw"',
      );
    }
    return LanguageVersion(rootLvMajor, rootLvMinor);
  }

  /// Parses `--config` into builder options. Empty and `{}` mean no options;
  /// anything else must decode to a JSON object.
  static Map<String, dynamic> _parseConfig(String configJson) {
    final trimmed = configJson.trim();
    if (trimmed.isEmpty || trimmed == '{}') {
      return <String, dynamic>{};
    }
    Object? decoded;
    try {
      decoded = jsonDecode(configJson);
    } on FormatException catch (e) {
      throw FormatException(
        '--config must be a JSON object string. Parse error: ${e.message}',
      );
    }
    if (decoded is! Map) {
      throw FormatException(
        '--config must be a JSON object (got ${decoded.runtimeType}).',
      );
    }
    return decoded.map((k, v) => MapEntry(k.toString(), v));
  }

  factory ShimArgs.parse(List<String> argv) {
    final parser = _buildParser();

    final ArgResults parsed;
    try {
      parsed = parser.parse(argv);
    } on ArgParserException catch (e) {
      throw FormatException(
        'Invalid shim arguments: ${e.message}\n${parser.usage}',
      );
    }

    if (parsed.rest.isNotEmpty) {
      throw FormatException(
        'Unexpected positional arguments: ${parsed.rest}\n${parser.usage}',
      );
    }

    // Mandatory options in the `args` package throw ArgumentError on read
    // when absent. Wrap every mandatory read and surface as FormatException
    // so callers get a consistent error type.
    final String input;
    final List<String> outputs;
    final String inputAsset;
    final String pkg;
    final String rootLvRaw;
    try {
      input = parsed['input'] as String;
      outputs = (parsed['output'] as List).cast<String>();
      inputAsset = parsed['input-asset'] as String;
      pkg = parsed['package'] as String;
      rootLvRaw = parsed['root-language-version'] as String;
    } on ArgumentError catch (e) {
      throw FormatException('${e.message}\n${parser.usage}');
    }
    if (outputs.isEmpty) {
      throw FormatException(
        'At least one --output is required.\n${parser.usage}',
      );
    }
    // Aggregate-codegen extras are staged identically to deps so the
    // Builder sees them via AssetReader / findAssets.
    final deps = [
      ..._parsePipeList((parsed['dep'] as List).cast<String>(), '--dep'),
      ..._parsePipeList(
        (parsed['input-asset-extra'] as List).cast<String>(),
        '--input-asset-extra',
      ),
    ];
    final configJson = parsed['config'] as String;
    final pkgConfig = parsed['package-config'] as String;
    final sdkPath = parsed['sdk-path'] as String;
    final summaries = (parsed['summary'] as List).cast<String>();
    final sdkSummary = parsed['sdk-summary'] as String;
    final pkgRootsDir = parsed['pkg-roots-dir'] as String;
    final pkgRootsManifest = parsed['pkg-roots-manifest'] as String;

    return ShimArgs(
      inputPath: input,
      inputAssetPath: inputAsset,
      outputPaths: outputs,
      packageName: pkg,
      depPaths: deps,
      config: _parseConfig(configJson),
      packageConfigUri: pkgConfig.isEmpty ? null : pkgConfig,
      sdkPath: sdkPath.isEmpty ? null : sdkPath,
      summaryPaths: summaries,
      sdkSummaryPath: sdkSummary.isEmpty ? null : sdkSummary,
      pkgRootsDir: pkgRootsDir.isEmpty ? null : pkgRootsDir,
      pkgRootsManifest: pkgRootsManifest.isEmpty ? null : pkgRootsManifest,
      rootLanguageVersion: _parseRootLanguageVersion(rootLvRaw),
    );
  }
}

/// Type alias for a `package:build` Builder factory — a function that
/// constructs a Builder given its BuilderOptions.
typedef BuilderFactory = Builder Function(BuilderOptions options);

/// Runs one or more Builder factories over the inputs described by
/// [argv]. Pass a single [BuilderFactory] for the common one-Builder
/// case, or a list for multi-stage shims (e.g. drift's discover →
/// analyzer → driftBuilder pipeline; all three share one BuildStep).
///
/// Example per-builder shim main:
/// ```dart
/// import 'package:rules_dart_ext/builder_shim.dart';
/// import 'package:json_serializable/builder.dart' show jsonSerializable;
/// Future<void> main(List<String> args) => runShim(args, jsonSerializable);
/// ```
///
/// Multi-stage:
/// ```dart
/// Future<void> main(List<String> args) =>
///     runShim(args, [discover, analyzer, driftBuilder]);
/// ```
///
/// Sets `exitCode` to 0 on success, 1 on builder failure, 2 on argument
/// parsing failure.
Future<void> runShim(
  List<String> argv,
  Object factoryOrFactories, {
  Directory? stagingRoot,
  AnalysisContextBuilder? buildAnalysisContext,
  DiagnosticSink? writeDiagnostic,
}) async {
  final sink = writeDiagnostic ?? _stderrSink;
  try {
    final parser = ShimArgs._buildParser();
    final parsed = parser.parse(argv);
    if (parsed['help'] as bool) {
      sink(parser.usage);
      return;
    }
  } on ArgParserException {
    // Fall through to ShimArgs.parse to report FormatException with usage.
  }
  final ShimArgs args;
  try {
    args = ShimArgs.parse(argv);
  } on FormatException catch (e) {
    sink(e.message);
    exitCode = 2;
    return;
  }
  try {
    final absArgs = _absoluteArgs(args);
    final stagingDir = await (stagingRoot ?? Directory.systemTemp).createTemp(
      'shim_${args.packageName}_',
    );
    final originalCwd = Directory.current;
    try {
      final packageStagingDir = await prepareSourceGenCwd(
        baseDir: stagingDir,
        packageName: args.packageName,
      );
      await _runWithStaging(
        absArgs,
        _normaliseFactories(factoryOrFactories),
        packageStagingDir,
        buildAnalysisContext: buildAnalysisContext,
        writeDiagnostic: sink,
      );
    } finally {
      Directory.current = originalCwd;
      if (await stagingDir.exists()) {
        await stagingDir.delete(recursive: true);
      }
    }
  } on Exception catch (e, st) {
    // Builders, the analyzer and staging I/O signal expected failures as
    // Exceptions (StateError for refused staged entries, FileSystemException
    // for vanished inputs, FormatException for bad flags): report the failure
    // and fail the action instead of crashing the isolate.
    _reportShimFailure(sink, args.inputPath, e, st);
    exitCode = 1;
  } on Error catch (e, st) {
    // Errors (failed assertions, analyzer bugs) still fail the action with a
    // diagnostic rather than an unhandled dump: in one-shot mode Bazel needs
    // the exit code, in worker mode the loop reads it per request. Anything
    // that is neither (a builder throwing a bare string, say) escapes to the
    // caller, which reports it.
    _reportShimFailure(sink, args.inputPath, e, st);
    exitCode = 1;
  }
}

/// Receives per-request diagnostic lines. One-shot callers use the default
/// (writes to the process stderr). Worker-mode callers pass a closure that
/// appends to `WorkResponse.output` so diagnostics surface in Bazel's
/// action-failure output instead of the shared worker stderr.
typedef DiagnosticSink = void Function(String message);

/// Reports a failed shim run to the diagnostic sink: the failing input plus
/// the error and its stack trace. The caller fails the action via `exitCode`.
void _reportShimFailure(
  DiagnosticSink sink,
  String inputPath,
  Object error,
  StackTrace stack,
) {
  sink('Builder failed for $inputPath: $error');
  sink(stack.toString());
}

void _stderrSink(String message) => stderr.writeln(message);

List<BuilderFactory> _normaliseFactories(Object factoryOrFactories) {
  if (factoryOrFactories is BuilderFactory) return [factoryOrFactories];
  if (factoryOrFactories is List) {
    return factoryOrFactories.cast<BuilderFactory>();
  }
  throw ArgumentError(
    'runShim expects a BuilderFactory or List<BuilderFactory>, got '
    '${factoryOrFactories.runtimeType}',
  );
}

/// Writes a `pubspec.yaml` in [baseDir], chdirs into [baseDir], and returns
/// the package-specific staging directory `<baseDir>/<packageName>`.
///
/// `package:source_gen`'s `rootPackageName` (in `source_gen/src/utils.dart`) is
/// a top-level `final` that reads `File('pubspec.yaml')` from CWD once per
/// isolate and computes `p.join(rootPackageName, p.relative(url.path))` in
/// `_fileToAssetUrl`. In a persistent worker serving multiple packages, putting
/// a concrete package name in CWD's `pubspec.yaml` would freeze the first
/// request's package name for the lifetime of the isolate. Writing `name: ""`
/// in [baseDir] and staging files under `<baseDir>/<packageName>/...` makes
/// `rootPackageName` evaluate to `""` while `p.relative(url.path)` evaluates to
/// `<packageName>/<assetPath>`, so `p.join("", "<packageName>/<assetPath>")`
/// yields `<packageName>/<assetPath>` for every package in any order.
///
/// Also drops an empty `stacked.json` so `stacked_generator`'s
/// `ConfigHelper.composeAndLoadConfigFile()` — invoked unconditionally
/// by its dialog + bottomsheet generators via `getStackedAppFileName()`
/// — finds the config file it hard-codes at CWD and loads its defaults
/// silently. Without this the helper hits a `PathNotFoundException` and
/// writes a diagnostic to stdout, which corrupts Bazel's worker
/// protocol. An empty JSON object is the sentinel that means "use
/// defaults"; benign for non-stacked builders.
Future<Directory> prepareSourceGenCwd({
  required Directory baseDir,
  required String packageName,
}) async {
  await baseDir.create(recursive: true);
  final canonicalBasePath = p.normalize(await baseDir.resolveSymbolicLinks());
  final canonicalBaseDir = Directory(canonicalBasePath);
  await File(
    p.join(canonicalBasePath, 'pubspec.yaml'),
  ).writeAsString('name: ""\nenvironment:\n  sdk: ^3.0.0\n');
  await File(p.join(canonicalBasePath, 'stacked.json')).writeAsString('{}\n');
  Directory.current = canonicalBaseDir;
  final currentPath = p.normalize(Directory.current.path);
  final packageStagingDir = Directory(p.join(currentPath, packageName));
  await packageStagingDir.create(recursive: true);
  return packageStagingDir;
}

/// Same as [runShim] but takes pre-parsed [args] and propagates errors as
/// exceptions. Intended for unit tests.
Future<void> runShimWithArgs(
  ShimArgs args,
  Object factoryOrFactories, {
  Directory? stagingRoot,
}) async {
  // Relative paths in `args` are resolved against the process CWD. We
  // chdir into the staging dir below for source_gen's benefit, so resolve
  // everything up-front here; after chdir, any still-relative path would
  // resolve against the staging dir and break.
  final absArgs = _absoluteArgs(args);
  final stagingDir = await (stagingRoot ?? Directory.systemTemp).createTemp(
    'shim_${args.packageName}_',
  );
  final originalCwd = Directory.current;
  try {
    final packageStagingDir = await prepareSourceGenCwd(
      baseDir: stagingDir,
      packageName: args.packageName,
    );
    await _runWithStaging(
      absArgs,
      _normaliseFactories(factoryOrFactories),
      packageStagingDir,
    );
  } finally {
    Directory.current = originalCwd;
    if (await stagingDir.exists()) {
      await stagingDir.delete(recursive: true);
    }
  }
}

/// Absolute + normalized path. The normalize is critical on Windows: paths
/// arrive from Bazel using `/` separators, but `p.absolute` only prefixes
/// the cwd (with native `\`) without normalizing the remainder, leaving
/// mixed-separator paths that `package:build`'s path validator rejects
/// with "Only absolute normalized paths are supported". On POSIX,
/// `p.normalize` is a no-op for already-clean paths.
String _absAndNormalize(String path) => p.normalize(p.absolute(path));

/// Native on-disk path for a POSIX `AssetId` path under a native staging dir.
///
/// `assetPath` is a `package:build` `AssetId` path — always `/`-separated. The
/// staging dir is native. The correct url→native conversion splits the asset in
/// the posix context and re-joins the segments in [ctx] (the platform context in
/// production): a plain `p.join(nativeDir, posixPath)` leaves the asset's inner
/// `/` untouched, yielding a mixed-separator path the analyzer rejects on Windows
/// (`NotPathOfUriResult`). [ctx] is injected so this is host-testable per platform.
String stagedPath(p.Context ctx, String stagingDir, String assetPath) =>
    ctx.joinAll([stagingDir, ...p.posix.split(assetPath)]);

ShimArgs _absoluteArgs(ShimArgs a) => ShimArgs(
  inputPath: _absAndNormalize(a.inputPath),
  inputAssetPath: a.inputAssetPath,
  outputPaths: [for (final o in a.outputPaths) _absAndNormalize(o)],
  packageName: a.packageName,
  depPaths: [
    for (final d in a.depPaths)
      (exec: _absAndNormalize(d.exec), asset: d.asset),
  ],
  config: a.config,
  packageConfigUri: a.packageConfigUri != null
      ? _absAndNormalize(a.packageConfigUri!)
      : null,
  sdkPath: a.sdkPath != null ? _absAndNormalize(a.sdkPath!) : null,
  summaryPaths: [for (final s in a.summaryPaths) _absAndNormalize(s)],
  sdkSummaryPath: a.sdkSummaryPath != null
      ? _absAndNormalize(a.sdkSummaryPath!)
      : null,
  pkgRootsDir: a.pkgRootsDir != null ? _absAndNormalize(a.pkgRootsDir!) : null,
  pkgRootsManifest: a.pkgRootsManifest != null
      ? _absAndNormalize(a.pkgRootsManifest!)
      : null,
  rootLanguageVersion: a.rootLanguageVersion,
);

/// Signature of a function that returns an [AnalysisContextCollection]
/// for the given inclusion + SDK settings. Tests can inject a stub; the
/// shim's default is [_defaultBuildAnalysisContext].
typedef AnalysisContextBuilder =
    Future<AnalysisContextCollection> Function({
      required List<String> includedPaths,
      required String? sdkPath,
      String? sdkSummaryPath,
      required List<String> librarySummaryPaths,
    });

/// With no [sdkSummaryPath] or [librarySummaryPaths] this is the public
/// constructor, as it always was. With summaries, the analyzer resolves the SDK
/// and dependency libraries from their summary bundles; the `Impl` constructor
/// is the only one that takes them.
Future<AnalysisContextCollection> _defaultBuildAnalysisContext({
  required List<String> includedPaths,
  required String? sdkPath,
  String? sdkSummaryPath,
  required List<String> librarySummaryPaths,
}) async {
  final boundedProvider = _StagingBoundedResourceProvider(
    PhysicalResourceProvider.INSTANCE,
    boundaryRoots: includedPaths,
  );
  if (sdkSummaryPath == null && librarySummaryPaths.isEmpty) {
    return AnalysisContextCollection(
      resourceProvider: boundedProvider,
      includedPaths: includedPaths,
      sdkPath: sdkPath,
    );
  }
  return AnalysisContextCollectionImpl(
    resourceProvider: boundedProvider,
    includedPaths: includedPaths,
    sdkPath: sdkPath,
    sdkSummaryPath: sdkSummaryPath,
    librarySummaryPaths: librarySummaryPaths,
  );
}

Future<void> _runWithStaging(
  ShimArgs args,
  List<Builder Function(BuilderOptions)> builderFactories,
  Directory stagingDir, {
  AnalysisContextBuilder? buildAnalysisContext,
  DiagnosticSink writeDiagnostic = _stderrSink,
}) async {
  // Paths in [args] are pre-absolutised by _absoluteArgs so the chdir below
  // doesn't invalidate them. Resolve symbolic links (and Windows 8.3 short
  // names) on [stagingDir] so staged paths, package_config.json, library URIs,
  // and `Directory.current` all share one canonical spelling.
  await stagingDir.create(recursive: true);
  final stagingPath = p.normalize(await stagingDir.resolveSymbolicLinks());
  final canonicalStagingDir = Directory(stagingPath);
  final absOutputPaths = args.outputPaths;

  final execByAsset = _dedupeExecByAsset(args);
  final staged = await _stageExecAssets(
    execByAsset,
    stagingPath,
    args.packageName,
    p.posix.normalize(args.inputAssetPath),
  );
  final inputId = staged.inputId;

  // Build a PackageConfig that maps the synthetic root package to the
  // staging dir, and merges in every package from the upstream config so
  // third-party `package:` imports resolve.
  final packageConfig = await _prepareStagingConfig(
    args,
    canonicalStagingDir,
    stagingPath,
  );

  // Include ONLY the staging dir. Cross-package imports (`package:drift/...`,
  // `package:json_annotation/...`, …) are resolved through the
  // package_config.json we wrote above — the analyzer loads pub-cache
  // libraries lazily, but into the SAME AnalysisContext as the user's
  // code so their element models share one identity space.
  //
  // Previously we listed every pub-cache package root in `includedPaths`.
  // That produced one AnalysisContext per root, and a SEPARATE element
  // model per context. Cross-context `asInstanceOf` calls then silently
  // returned null — the visible symptom was drift_dev's
  // `readTypeConverter` reporting `"Not a type converter"` on a
  // `.map(const MyConverter())` expression whose static type resolved
  // (from the staging context) to a `MyConverter` element whose
  // `TypeConverter` supertype was NOT identical to the `TypeConverter`
  // element drift loaded via `backend.readDart(drift2Uri)` (from the
  // drift pub-cache context). Forcing one context canonicalises them.
  final contextBuilder = buildAnalysisContext ?? _defaultBuildAnalysisContext;
  final collection = await contextBuilder(
    includedPaths: [stagingPath],
    sdkPath: args.sdkPath != null ? p.absolute(args.sdkPath!) : null,
    sdkSummaryPath: args.sdkSummaryPath,
    librarySummaryPaths: args.summaryPaths,
  );

  // CWD must contain a valid pubspec before any Builder runs; the shim
  // entry pre-populates it via [prepareSourceGenCwd].
  final writer = _ShimAssetWriter();
  final reader = _ShimAssetReader(staged.assetIdToPath, packageConfig, writer);
  final resolver = _ShimAnalyzerResolver(
    collection,
    staged.assetIdToPath,
    packageConfig,
  );
  // One ResourceManager per shim invocation, shared by every pipeline
  // stage — mirrors build_runner, which shares one manager per build
  // session so a Resource fetched in stage 1 is the same instance in
  // stage 2. Disposed once after the whole pipeline (see finally below).
  final resourceManager = ResourceManager();

  // The last Builder's allowedOutputs are derived from the rule-declared
  // `--output` paths (one AssetId per declared file, placed in the input's
  // directory). This makes the rule layer authoritative: users control the
  // Bazel output filenames via `output_suffixes` / `outputs`, and the
  // builder writes to whatever the rule declared — regardless of any
  // name the Builder's internal `buildExtensions` map might suggest.
  // (`SharedPartBuilder('copyWith', ...)` internally sets
  // `.copyWith.g.part`, but build_runner and build.yaml override it to
  // `copy_with_extension_gen.g.part`; rules_dart takes that same approach
  // by letting the declared outputs win.)
  //
  // Earlier Builders in multi-stage pipelines keep their own
  // `buildExtensions`-derived allowedOutputs so findAssets sees
  // intermediate writes.
  final builders = builderFactories
      .map((f) => f(BuilderOptions(args.config)))
      .toList();
  final allowedOutputs = _allowedOutputsFromDeclaredPaths(
    inputId,
    absOutputPaths,
  );

  await _runBuilderPipeline((
    builders: builders,
    inputId: inputId,
    reader: reader,
    writer: writer,
    resolver: resolver,
    packageConfig: packageConfig,
    resourceManager: resourceManager,
    collection: collection,
    allowedOutputs: allowedOutputs,
    writeDiagnostic: writeDiagnostic,
  ));
  await _routeDeclaredOutputs(writer, allowedOutputs, inputId, absOutputPaths);
}

/// Dedupes staged inputs by asset path before staging. The same logical file
/// can arrive via more than one exec path — the input is also listed among
/// the deps (e.g. drift passes the `.drift` src in `asset_deps`), and a
/// co-located package may surface a file both as a source and as its
/// bazel-out copy. Staging the same asset twice races to one dest: a harmless
/// overwrite on POSIX, but a hard error on Windows (`File.copy` won't
/// overwrite). The input asset wins.
Map<String, String> _dedupeExecByAsset(ShimArgs args) {
  final execByAsset = <String, String>{
    p.posix.normalize(args.inputAssetPath): args.inputPath,
  };
  for (final dep in args.depPaths) {
    execByAsset.putIfAbsent(p.posix.normalize(dep.asset), () => dep.exec);
  }
  return execByAsset;
}

/// Copies every exec path into the staging dir under its asset path.
///
/// Same-package deps land in the synthetic root; cross-package deps need
/// a PackageConfig entry (currently unsupported). Bytes are written rather
/// than `File.copy`ied so read-only mode bits (`0444`/`0555`) from remote
/// execution, sandboxes, or `bazel-out` are not carried onto staged files.
Future<({Map<AssetId, String> assetIdToPath, AssetId inputId})>
_stageExecAssets(
  Map<String, String> execByAsset,
  String stagingPath,
  String packageName,
  String inputAsset,
) async {
  final assetIdToPath = <AssetId, String>{};
  await Future.wait(
    execByAsset.entries.map((entry) async {
      final dest = stagedPath(p.context, stagingPath, entry.key);
      await Directory(p.dirname(dest)).create(recursive: true);
      await File(dest).writeAsBytes(await File(entry.value).readAsBytes());
      assetIdToPath[AssetId(packageName, entry.key)] = dest;
    }),
  );
  return (
    assetIdToPath: assetIdToPath,
    inputId: AssetId(packageName, inputAsset),
  );
}

/// Writes the support files the analyzer expects at the staging root:
/// `.dart_tool/package_config.json` (so the AnalysisContextCollection picks
/// it up via Dart's standard package-resolution lookup), a minimal
/// `pubspec.yaml` (so the analyzer recognises the staging dir as a Dart
/// package root, unless the caller already staged one), and an empty
/// `analysis_options.yaml` bounding the analyzer's upward options discovery
/// at the staging root (without a file of its own, whichever stray options
/// file happens to sit in a temp ancestor would silently configure codegen,
/// differently on different machines — an empty file is equivalent to no
/// file at all when nothing above interferes, so this changes nothing except
/// the ancestor read).
Future<void> _writeStagingSupportFiles(
  String stagingPath,
  PackageConfig packageConfig,
  String packageName,
) async {
  final dartTool = Directory(p.join(stagingPath, '.dart_tool'));
  await dartTool.create(recursive: true);
  final pcFile = File(p.join(dartTool.path, 'package_config.json'));
  await pcFile.writeAsString(_serializePackageConfig(packageConfig));

  final pubspecFile = File(p.join(stagingPath, 'pubspec.yaml'));
  if (!await pubspecFile.exists()) {
    await pubspecFile.writeAsString(
      'name: $packageName\nenvironment:\n  sdk: ^3.0.0\n',
    );
  }

  final analysisOptionsFile = File(
    p.join(stagingPath, 'analysis_options.yaml'),
  );
  if (!await analysisOptionsFile.exists()) {
    await analysisOptionsFile.writeAsString(
      '# rules_dart: bounds analysis_options.yaml discovery\n',
    );
  }
}

/// Refuses staged entries whose directives would read outside the staging dir
/// before the analyzer or any Builder can. This is the shim-world half of the
/// shared staged-source check: the staging dir holds only declared inputs, so
/// a schemeless relative (or `/`-absolute) URI that resolves outside it, a
/// `file:` or other foreign scheme, or a `package:` URI climbing above its
/// package would read an undeclared host file.
Future<void> _refuseEscapingStagedEntries(Directory stagingDir) async {
  final stagedViolations = await findStagedShimViolations(
    stagingDir,
    tool: 'builder_shim',
  );
  if (stagedViolations.isNotEmpty) {
    throw StateError(
      'builder_shim refuses to run builders on staged entries that read '
      'files outside the declared inputs:\n${stagedViolations.join('\n')}',
    );
  }
}

/// Runs every pipeline stage with a Logger listener so Builder-emitted
/// warnings/errors reach the diagnostic sink (without this, `package:build`'s
/// `log` sinks into a silent fallback), then releases per-invocation state:
/// Resources are drained so they don't leak across sequential worker
/// requests (disposal-phase log records still flow to the listener because
/// it is cancelled *after* disposal), and analyzer drivers, file-watching
/// handles and thread-pool workers are released so a long-running worker
/// doesn't accumulate drivers until it exhausts file descriptors.
/// One multi-stage builder pipeline invocation.
typedef _PipelineRun = ({
  List<Builder> builders,
  AssetId inputId,
  _ShimAssetReader reader,
  _ShimAssetWriter writer,
  _ShimAnalyzerResolver resolver,
  PackageConfig packageConfig,
  ResourceManager resourceManager,
  AnalysisContextCollection collection,
  Iterable<AssetId> allowedOutputs,
  DiagnosticSink writeDiagnostic,
});

Future<void> _runBuilderPipeline(_PipelineRun run) async {
  final builders = run.builders;
  final inputId = run.inputId;
  final reader = run.reader;
  final writer = run.writer;
  final resolver = run.resolver;
  final packageConfig = run.packageConfig;
  final resourceManager = run.resourceManager;
  final collection = run.collection;
  final allowedOutputs = run.allowedOutputs;
  final writeDiagnostic = run.writeDiagnostic;
  final originalLevel = Logger.root.level;
  final logger = Logger('rules_dart_ext');
  final logSub = Logger.root.onRecord.listen((rec) {
    writeDiagnostic(
      '[${rec.level.name}] ${rec.loggerName}: ${rec.message}'
      '${rec.error != null ? " error=${rec.error}" : ""}'
      '${rec.stackTrace != null ? "\n${rec.stackTrace}" : ""}',
    );
  });
  final lastIndex = builders.length - 1;
  try {
    // Set the level inside the try so the `finally` below always
    // restores it — even if anything between here and the `for` loop
    // throws. Builders that elevate the root level (for their own
    // diagnostics) can't poison later worker requests.
    Logger.root.level = Level.WARNING;
    for (var i = 0; i < builders.length; i++) {
      final builder = builders[i];
      final allowedForThisStep = i == lastIndex
          ? allowedOutputs
          : _expectedOutputsFor(inputId, builder.buildExtensions);
      final step = _ShimBuildStep(
        inputId: inputId,
        reader: reader,
        writer: writer,
        resolver: resolver,
        allowedOutputsValue: allowedForThisStep,
        packageConfig: packageConfig,
        resourceManager: resourceManager,
      );
      // Run each Builder in a zone where `package:build`'s `log` resolves
      // to our listener-equipped Logger (see the `logKey` constant in
      // `package:build/src/logging.dart`).
      await runZoned(
        () => builder.build(step),
        zoneValues: {#buildLog: logger},
      );
    }
  } finally {
    // Drain any Resources a Builder held via `fetchResource` so they don't
    // leak across sequential worker requests. One disposeAll for the whole
    // pipeline — the manager is shared across stages. Disposal-phase log
    // records still flow to the listener because we cancel *after* disposal.
    try {
      await resourceManager.disposeAll();
    } on Exception catch (e, st) {
      // A Resource that fails to dispose must neither fail the build (the
      // outputs are already written) nor poison the next worker request:
      // report and continue.
      writeDiagnostic('ResourceManager.disposeAll failed: $e\n$st');
    } on Error catch (e, st) {
      // Same as above for Errors from Resource.dispose implementations.
      writeDiagnostic('ResourceManager.disposeAll failed: $e\n$st');
    }
    await logSub.cancel();
    Logger.root.level = originalLevel;
    // Release analyzer drivers, file-watching handles, and thread-pool
    // workers. Without this, a long-running worker accumulates drivers
    // across every request until it exhausts file descriptors.
    try {
      await collection.dispose();
    } on Exception catch (e, st) {
      // A failing context-collection dispose must neither fail the build
      // (the outputs are already written) nor hide: report and continue.
      // `collection` is statically an AnalysisContextCollection, whose pinned
      // interface always exposes dispose, so no missing-method guard applies.
      writeDiagnostic('AnalysisContextCollection.dispose failed: $e\n$st');
    } on Error catch (e, st) {
      // Same as above for Errors from driver teardown.
      writeDiagnostic('AnalysisContextCollection.dispose failed: $e\n$st');
    }
  }
}

/// Routes each builder-emitted asset to the declared Bazel output file whose
/// basename matches the same `input_stem + <extension>` pattern. Multi-output
/// builders (e.g. a builder emitting both `.config.dart` and `.module.dart`)
/// declare one `--output` per extension and the shim writes each emitted
/// asset to the correct declared path. For multi-stage pipelines only the
/// last (primary) Builder's outputs matter; anything else is an intermediate
/// from an earlier stage visible only via `findAssets`. A declared path with
/// no matching emission (the builder saw no relevant annotations) is written
/// empty, since Bazel still requires the declared output.
Future<void> _routeDeclaredOutputs(
  _ShimAssetWriter writer,
  Iterable<AssetId> allowedOutputs,
  AssetId inputId,
  List<String> absOutputPaths,
) async {
  final allowedSet = allowedOutputs.toSet();
  final emitted = <AssetId, List<int>>{
    for (final e in writer.assets.entries)
      if (allowedSet.contains(e.key)) e.key: e.value,
  };

  final claimed = <AssetId>{};
  for (final outPath in absOutputPaths) {
    final match = _matchEmittedAssetFor(outPath, inputId, emitted, claimed);
    // No matching emission (the builder saw no relevant annotations):
    // write an empty file, since Bazel still requires the declared output.
    if (match != null) claimed.add(match);
    await File(
      outPath,
    ).writeAsBytes(match != null ? emitted[match]! : const <int>[]);
  }
}

/// Picks the emitted AssetId from [emitted] that corresponds to the
/// declared Bazel output at [declaredPath], excluding any already-[claimed]
/// matches.
///
/// Matching precedence:
/// 1. Suffix match: the declared file's basename must equal
///    `inputStem + suffix` for some `suffix`, and the emitted AssetId
///    path must equal `inputId.path_stem + suffix`.
/// 2. Basename match: the emitted AssetId's basename equals the declared
///    file's basename (handles builders that rewrite the stem entirely).
///
/// Returns `null` when no unclaimed candidate matches (caller writes an
/// empty file).
AssetId? _matchEmittedAssetFor(
  String declaredPath,
  AssetId inputId,
  Map<AssetId, List<int>> emitted,
  Set<AssetId> claimed,
) {
  final declaredBasename = p.basename(declaredPath);
  final inputStem = p.basenameWithoutExtension(inputId.path);
  if (declaredBasename.startsWith('$inputStem.')) {
    final suffix = declaredBasename.substring(inputStem.length);
    final inputPathStem = inputId.path.substring(
      0,
      inputId.path.length - p.extension(inputId.path).length,
    );
    final candidate = AssetId(inputId.package, '$inputPathStem$suffix');
    if (emitted.containsKey(candidate) && !claimed.contains(candidate)) {
      return candidate;
    }
  }
  for (final id in emitted.keys) {
    if (claimed.contains(id)) continue;
    if (p.basename(id.path) == declaredBasename) return id;
  }
  return null;
}

/// Builds allowedOutputs AssetIds from the rule-declared `--output` paths.
/// Each declared file maps to an AssetId in the input's directory, named
/// by the file's basename. This is the authoritative allowedOutputs set
/// for the *last* Builder in a pipeline — it overrides whatever
/// `buildExtensions` the Builder class advertises internally, matching
/// build_runner's behavior of letting build.yaml declared extensions win.
Iterable<AssetId> _allowedOutputsFromDeclaredPaths(
  AssetId inputId,
  List<String> declaredPaths,
) {
  final dir = p.posix.dirname(inputId.path);
  return [
    for (final path in declaredPaths)
      AssetId(
        inputId.package,
        dir == '.' ? p.basename(path) : '$dir/${p.basename(path)}',
      ),
  ];
}

/// Derives intermediate AssetIds for a NON-final pipeline stage from the
/// Builder's own `buildExtensions` (final-stage outputs are rule-declared;
/// see `_allowedOutputsFromDeclaredPaths`). Only plain suffix keys are
/// supported: an empty-string key (the PackageBuilder pattern) makes
/// `endsWith('')` always true, and `$lib$`/`$package$` placeholder keys
/// never match a real path suffix — both would silently corrupt the
/// derived AssetId, so they are rejected loudly.
Iterable<AssetId> _expectedOutputsFor(
  AssetId inputId,
  Map<String, List<String>> buildExtensions,
) {
  final outputs = <AssetId>[];
  for (final entry in buildExtensions.entries) {
    final inputExt = entry.key;
    if (inputExt.isEmpty || inputExt.contains(r'$')) {
      throw StateError(
        'buildExtensions key "$inputExt" is unsupported for intermediate '
        'pipeline stages: empty-string keys and \$-placeholder keys '
        '(\$lib\$, \$package\$) cannot be mapped onto an input-relative '
        'AssetId. Final-stage outputs are rule-declared and unaffected; '
        'make this builder the final stage or give it a plain suffix key.',
      );
    }
    if (!inputId.path.endsWith(inputExt)) continue;
    final stem = inputId.path.substring(
      0,
      inputId.path.length - inputExt.length,
    );
    for (final outExt in entry.value) {
      outputs.add(AssetId(inputId.package, '$stem$outExt'));
    }
  }
  return outputs;
}

/// Prunes the target's own `<name>.pkg_roots` stage down to the manifest's
/// entries, then builds the staging package config and support files.
///
/// Pruning runs before any analysis so a `package:` URI the upstream config
/// resolves through the stage can only reach a declared input — never a
/// symlink an earlier build staged and the current build dropped. With
/// neither flag passed this only builds the config, exactly as before.
Future<PackageConfig> _prepareStagingConfig(
  ShimArgs args,
  Directory canonicalStagingDir,
  String stagingPath,
) async {
  prunePkgRootsFromManifest(
    stageDir: args.pkgRootsDir,
    manifestPath: args.pkgRootsManifest,
  );
  final packageConfig = await _buildPackageConfig(args, canonicalStagingDir);
  await _writeStagingSupportFiles(stagingPath, packageConfig, args.packageName);
  await _refuseEscapingStagedEntries(canonicalStagingDir);
  return packageConfig;
}

Future<PackageConfig> _buildPackageConfig(
  ShimArgs args,
  Directory stagingDir,
) async {
  // packageConfigUri may be relative to Bazel's exec root; resolve while
  // we still have the original CWD.
  final upstreamUri = args.packageConfigUri != null
      ? Uri.file(p.absolute(args.packageConfigUri!))
      : await Isolate.packageConfig;
  // If neither the caller nor the running isolate provides a package_config,
  // fall back to an empty one — the synthetic root entry is still added below
  // so builders that only touch the input file (no third-party imports) work.
  final PackageConfig upstream = upstreamUri == null
      ? PackageConfig.empty
      : await loadPackageConfigUri(upstreamUri);

  // Synthetic entry for the input's own package, rooted at the staging dir.
  // Prefer the upstream package_config's entry for our package (looked up by
  // name; path-based lookup wouldn't match: upstream points at the consumer's
  // sources, not our staging dir). Fall back to the explicit
  // --root-language-version flag.
  final rootDir = Uri.directory(stagingDir.absolute.path);
  final upstreamRoot = upstream[args.packageName];
  final rootLanguageVersion =
      upstreamRoot?.languageVersion ?? args.rootLanguageVersion;
  final synthetic = Package(
    args.packageName,
    rootDir,
    packageUriRoot: rootDir.resolve('lib/'),
    languageVersion: rootLanguageVersion,
  );

  return PackageConfig([
    synthetic,
    for (final pkg in upstream.packages)
      if (pkg.name != args.packageName) pkg,
  ]);
}

String _serializePackageConfig(PackageConfig config) {
  final entries = <Map<String, dynamic>>[];
  for (final pkg in config.packages) {
    // `packageUri` is the `packageUriRoot` expressed as a URI relative to
    // `rootUri`. Almost every pub package uses `lib/`, but some workspace
    // layouts (or the synthetic root for the shim's own staging dir) set
    // it differently. Compute it from the Package rather than hardcoding.
    var packageUri = pkg.packageUriRoot.toString();
    final rootUri = pkg.root.toString();
    if (packageUri.startsWith(rootUri)) {
      packageUri = packageUri.substring(rootUri.length);
      if (!packageUri.endsWith('/')) packageUri = '$packageUri/';
      if (packageUri.isEmpty) packageUri = './';
    } else {
      packageUri = 'lib/';
    }
    final entry = <String, dynamic>{
      'name': pkg.name,
      'rootUri': rootUri,
      'packageUri': packageUri,
    };
    final lv = pkg.languageVersion;
    if (lv != null) {
      entry['languageVersion'] = '${lv.major}.${lv.minor}';
    }
    entries.add(entry);
  }
  return const JsonEncoder.withIndent(
    '  ',
  ).convert({'configVersion': 2, 'packages': entries});
}

// ---------------------------------------------------------------------------
// AssetReader implementation.
// ---------------------------------------------------------------------------

/// Returns the on-disk path for [id], either from the staged-asset map or
/// (for third-party packages) by walking the package_config. `lib/` paths
/// resolve against `packageUriRoot`; anything else resolves against the
/// package root directory. Returns null only when neither lookup succeeds.
String? _resolveAssetPath(
  Map<AssetId, String> assetIdToPath,
  PackageConfig packageConfig,
  AssetId id,
) {
  final direct = assetIdToPath[id];
  if (direct != null) return direct;
  // Fall through: look up via the PackageConfig (e.g. for transitively-
  // imported third-party files the analyzer queries). `lib/` paths resolve
  // against `packageUriRoot` (which points at the package's `lib/`);
  // anything else (`bin/`, `test/`, `web/`, top-level files like
  // `pubspec.yaml`) resolves against the package root directory.
  final pkg = packageConfig[id.package];
  if (pkg == null) return null;
  if (id.path.startsWith('lib/')) {
    final rel = id.path.substring(4);
    return p.fromUri(pkg.packageUriRoot.resolve(rel));
  }
  return p.fromUri(pkg.root.resolve(id.path));
}

/// AssetReader backed by a Map<AssetId, file path> plus the shim's
/// in-memory writer (so multi-stage pipelines can read prior stages'
/// outputs via `findAssets`/`readAsString`).
class _ShimAssetReader extends AssetReader {
  _ShimAssetReader(this._assetIdToPath, this._packageConfig, this._writer);

  final Map<AssetId, String> _assetIdToPath;
  final PackageConfig _packageConfig;
  final _ShimAssetWriter _writer;

  String? _pathFor(AssetId id) =>
      _resolveAssetPath(_assetIdToPath, _packageConfig, id);

  @override
  Future<bool> canRead(AssetId id) async {
    if (_writer.assets.containsKey(id)) return true;
    final path = _pathFor(id);
    return path != null && await File(path).exists();
  }

  @override
  Future<List<int>> readAsBytes(AssetId id) async {
    final fromWriter = _writer.assets[id];
    if (fromWriter != null) return fromWriter;
    final path = _pathFor(id);
    if (path == null) throw AssetNotFoundException(id);
    final f = File(path);
    if (!await f.exists()) throw AssetNotFoundException(id);
    return f.readAsBytes();
  }

  @override
  Future<String> readAsString(AssetId id, {Encoding encoding = utf8}) async {
    final fromWriter = _writer.assets[id];
    if (fromWriter != null) return encoding.decode(fromWriter);
    final path = _pathFor(id);
    if (path == null) throw AssetNotFoundException(id);
    final f = File(path);
    if (!await f.exists()) throw AssetNotFoundException(id);
    return f.readAsString(encoding: encoding);
  }

  @override
  Stream<AssetId> findAssets(Glob glob) async* {
    final seen = <AssetId>{};
    for (final id in _assetIdToPath.keys) {
      if (glob.matches(id.path) && seen.add(id)) yield id;
    }
    for (final id in _writer.assets.keys) {
      if (glob.matches(id.path) && seen.add(id)) yield id;
    }
  }

  @override
  Future<Digest> digest(AssetId id) async {
    final sink = AccumulatorSink<Digest>();
    md5.startChunkedConversion(sink)
      ..add(await readAsBytes(id))
      ..add(id.toString().codeUnits)
      ..close();
    return sink.events.first;
  }
}

// ---------------------------------------------------------------------------
// AssetWriter implementation.
// ---------------------------------------------------------------------------

/// In-memory AssetWriter. The shim runner flushes captured outputs to disk
/// after the Builder returns.
class _ShimAssetWriter implements AssetWriter {
  final Map<AssetId, List<int>> assets = {};

  @override
  Future<void> writeAsBytes(AssetId id, FutureOr<List<int>> bytes) async {
    assets[id] = await bytes;
  }

  @override
  Future<void> writeAsString(
    AssetId id,
    FutureOr<String> contents, {
    Encoding encoding = utf8,
  }) async {
    assets[id] = encoding.encode(await contents);
  }
}

// ---------------------------------------------------------------------------
// BuildStep implementation.
// ---------------------------------------------------------------------------

/// BuildStep adapter wrapping our reader, writer, and resolver. Resource
/// lifecycle, stage tracking, and unused-asset reporting are no-ops.
class _ShimBuildStep implements BuildStep {
  _ShimBuildStep({
    required this.inputId,
    required _ShimAssetReader reader,
    required _ShimAssetWriter writer,
    required _ShimAnalyzerResolver resolver,
    required Iterable<AssetId> allowedOutputsValue,
    required PackageConfig packageConfig,
    required ResourceManager resourceManager,
  }) : _reader = reader,
       _writer = writer,
       _resolver = resolver,
       _allowedOutputs = allowedOutputsValue,
       _packageConfig = packageConfig,
       _resourceManager = resourceManager;

  @override
  final AssetId inputId;

  final _ShimAssetReader _reader;
  final _ShimAssetWriter _writer;
  final _ShimAnalyzerResolver _resolver;
  final Iterable<AssetId> _allowedOutputs;
  final PackageConfig _packageConfig;

  @override
  Resolver get resolver => _resolver;

  @override
  Future<LibraryElement> get inputLibrary => _resolver.libraryFor(inputId);

  @override
  Future<List<int>> readAsBytes(AssetId id) => _reader.readAsBytes(id);

  @override
  Future<String> readAsString(AssetId id, {Encoding encoding = utf8}) =>
      _reader.readAsString(id, encoding: encoding);

  @override
  Future<bool> canRead(AssetId id) => _reader.canRead(id);

  @override
  Stream<AssetId> findAssets(Glob glob) => _reader.findAssets(glob);

  @override
  Future<Digest> digest(AssetId id) => _reader.digest(id);

  @override
  Iterable<AssetId> get allowedOutputs => _allowedOutputs;

  @override
  Future<void> writeAsBytes(AssetId id, FutureOr<List<int>> bytes) =>
      _writer.writeAsBytes(id, bytes);

  @override
  Future<void> writeAsString(
    AssetId id,
    FutureOr<String> contents, {
    Encoding encoding = utf8,
  }) => _writer.writeAsString(id, contents, encoding: encoding);

  // Session-shared Resource cache, injected by `_runWithStaging`: every
  // pipeline stage in one shim invocation sees the same manager, so a
  // Resource fetched in stage 1 is the same instance in stage 2 — matching
  // build_runner's one-manager-per-build-session semantics. The owner
  // disposes it once after the whole pipeline; cross-invocation sharing
  // still isn't possible (each invocation builds a fresh manager).
  final ResourceManager _resourceManager;

  @override
  Future<T> fetchResource<T>(Resource<T> resource) =>
      _resourceManager.fetch(resource);

  @override
  T trackStage<T>(
    String label,
    T Function() action, {
    bool isExternal = false,
  }) => action();

  @override
  void reportUnusedAssets(Iterable<AssetId> ids) {}

  @override
  Future<PackageConfig> get packageConfig async => _packageConfig;
}

// ---------------------------------------------------------------------------
// Resolver implementation, backed by package:analyzer.
// ---------------------------------------------------------------------------

/// Resolver implementation that delegates to an [AnalysisContextCollection].
/// AssetIds map to staged file paths via [_assetIdToPath]; the analyzer
/// resolves `package:` imports from the staging dir's package_config.
class _ShimAnalyzerResolver implements Resolver {
  _ShimAnalyzerResolver(
    this._collection,
    this._assetIdToPath,
    this._packageConfig,
  ) {
    _installAssetUriResolver(_collection, _packageConfig, _assetIdToPath);
  }

  final AnalysisContextCollection _collection;
  final Map<AssetId, String> _assetIdToPath;
  final PackageConfig _packageConfig;

  AnalysisSession _sessionFor(String filePath) {
    // All lookups use the single includedPath's context. Only staging is
    // listed in `includedPaths`; pub-cache packages are resolved lazily
    // through that context's package_config so every element lives in
    // one element model. Using `contextFor(filePath)` on a pub-cache path
    // would throw "Unable to find the context to …" because the path
    // isn't inside any included root.
    return _collection.contexts.first.currentSession;
  }

  /// Returns the on-disk path for [id], either from the staged-asset map or
  /// (for third-party packages) by walking the package_config. `lib/` paths
  /// resolve against `packageUriRoot`; anything else resolves against the
  /// package root directory. Returns null only when neither lookup succeeds.
  String? _pathFor(AssetId id) =>
      _resolveAssetPath(_assetIdToPath, _packageConfig, id);

  @override
  Future<bool> isLibrary(AssetId id) async {
    final path = _pathFor(id);
    if (path == null) return false;
    final session = _sessionFor(path);
    final parsed = session.getParsedUnit(path);
    if (parsed is! ParsedUnitResult || parsed.isPart) {
      return false;
    }
    final libResult = await session.getLibraryByUri(id.uri.toString());
    return libResult is LibraryElementResult;
  }

  @override
  Future<LibraryElement> libraryFor(
    AssetId id, {
    bool allowSyntaxErrors = false,
  }) async {
    final path = _pathFor(id);
    if (path == null) {
      throw NonLibraryAssetException(id);
    }
    final session = _sessionFor(path);
    final parsed = session.getParsedUnit(path);
    if (parsed is! ParsedUnitResult || parsed.isPart) {
      throw NonLibraryAssetException(id);
    }
    // Resolve every asset by its canonical `package:` (`lib/`) or `asset:`
    // (non-`lib/`) URI via [_ShimAssetUriResolver] so the returned
    // LibraryElement and its fragments carry package/asset URIs rather than
    // physical `file://` staging paths, matching `build_runner`.
    final libResult = await session.getLibraryByUri(id.uri.toString());
    if (libResult is! LibraryElementResult) {
      throw NonLibraryAssetException(id);
    }
    return libResult.element;
  }

  @override
  Future<CompilationUnit> compilationUnitFor(
    AssetId id, {
    bool allowSyntaxErrors = false,
  }) async {
    final path = _pathFor(id);
    if (path == null) {
      throw NonLibraryAssetException(id);
    }
    final result = _sessionFor(path).getParsedUnit(path);
    if (result is! ParsedUnitResult) {
      throw NonLibraryAssetException(id);
    }
    return result.unit;
  }

  @override
  Stream<LibraryElement> get libraries async* {
    // Yield same-package staged libraries first — the input + each
    // `--dep` file the shim copies into the staging dir. These appear
    // directly in _assetIdToPath.
    final yielded = <Uri>{};
    for (final id in _assetIdToPath.keys) {
      // Filter by extension rather than relying on `libraryFor` to reject
      // non-Dart assets: it does not. The analyzer parses whatever bytes it
      // is handed, so a staged `lib/data.txt` comes back as a real (empty,
      // error-riddled) LibraryElement and lands in a stream whose element
      // type promises Dart libraries.
      if (!id.path.endsWith('.dart')) continue;
      try {
        final lib = await libraryFor(id);
        if (yielded.add(lib.firstFragment.source.uri)) yield lib;
      } on NonLibraryAssetException {
        // A `.dart` asset that is a `part of`, or that fails to resolve.
      }
    }

    // Plus cross-package public re-export libraries — `package:<name>/<name>.dart`
    // for every package in the synthesized PackageConfig. Without this, the
    // stream is bounded by `_assetIdToPath` (same-package siblings only) and
    // misses any third-party library the input transitively imports.
    //
    // build_runner's Resolver yields every library the analysis session has
    // loaded, including the transitive import closure. Generators that walk
    // `Resolver.libraries` to locate elements via their public re-exporting
    // library (e.g. stacked_generator's ImportResolver) silently fail under
    // the narrower set, either returning null for reachable elements or
    // computing wrong import paths.
    //
    // Enumerating each package's conventional main library covers the
    // re-export use case at negligible cost (libraryFor lazily materializes
    // only the packages the consumer iterates).
    for (final pkg in _packageConfig.packages) {
      final id = AssetId(pkg.name, 'lib/${pkg.name}.dart');
      try {
        final lib = await libraryFor(id);
        if (yielded.add(lib.firstFragment.source.uri)) yield lib;
      } on NonLibraryAssetException {
        // The file at the conventional path is a `part of`, or the URI does
        // not resolve — skip and keep going, so one oddly-laid-out package
        // does not truncate the stream for the packages after it.
        //
        // Only this exception needs catching: `libraryFor` throws nothing
        // else. A package declared in the config with no file at all does
        // not land here — the analyzer answers with an empty library and it
        // is yielded (pinned by the test of that name).
      }
    }
  }

  @override
  Future<LibraryElement?> findLibraryByName(String libraryName) async {
    // SDK libraries are queryable by Uri ('dart:async') via
    // session.getLibraryByUri. drift's backend calls findLibraryByName with
    // names like 'dart.async' (dotted), so try the dart: form first.
    if (libraryName.startsWith('dart.')) {
      final uri = 'dart:${libraryName.substring(5)}';
      try {
        // Use any context's session — they all share the SDK.
        final session = _collection.contexts.first.currentSession;
        final result = await session.getLibraryByUri(uri);
        if (result is LibraryElementResult) return result.element;
      } on ArgumentError {
        // Malformed URI — fall through to the library scan below.
      } on StateError {
        // Unknown dart: URI — fall through.
      }
      // Anything else (e.g. `InconsistentAnalysisException`, which
      // signals a stale analysis session) propagates — silently masking
      // those would let drift et al. produce silently-wrong code.
    }
    await for (final lib in libraries) {
      if (lib.name == libraryName) return lib;
    }
    return null;
  }

  @override
  Future<AssetId> assetIdForElement(Element element) async {
    final source = element.library?.firstFragment.source;
    if (source == null) {
      throw UnresolvableAssetException(element.toString());
    }
    final uri = source.uri;
    if (uri.scheme == 'package') {
      final segments = uri.pathSegments;
      if (segments.isEmpty) {
        throw UnresolvableAssetException(uri.toString());
      }
      final pkg = segments.first;
      final relPath = p.posix.joinAll(['lib', ...segments.skip(1)]);
      return AssetId(pkg, relPath);
    }
    if (uri.scheme == 'asset') {
      final segments = uri.pathSegments;
      if (segments.length < 2) {
        throw UnresolvableAssetException(uri.toString());
      }
      final pkg = segments.first;
      final relPath = p.posix.joinAll(segments.skip(1));
      return AssetId(pkg, relPath);
    }
    if (uri.scheme == 'file') {
      // Reverse-map a `file://` URI back to an AssetId by locating the owning
      // package in the PackageConfig. This fires when a builder calls
      // `assetIdForElement` for an element reached through import walking
      // (the primary `libraryFor` path resolves `lib/` inputs via `package:`
      // URIs specifically to avoid this, but elements discovered transitively
      // can still carry `file://` URIs).
      final filePath = p.normalize(p.fromUri(uri));
      for (final pkg in _packageConfig.packages) {
        final libRoot = p.normalize(p.fromUri(pkg.packageUriRoot));
        final rootDir = p.normalize(p.fromUri(pkg.root));
        if (p.isWithin(libRoot, filePath) || p.equals(libRoot, filePath)) {
          final rel = p.posix.joinAll(
            p.split(p.relative(filePath, from: libRoot)),
          );
          return AssetId(pkg.name, p.posix.join('lib', rel));
        }
        if (p.isWithin(rootDir, filePath) || p.equals(rootDir, filePath)) {
          final rel = p.posix.joinAll(
            p.split(p.relative(filePath, from: rootDir)),
          );
          return AssetId(pkg.name, rel);
        }
      }
    }
    throw UnresolvableAssetException(uri.toString());
  }

  @override
  Future<AstNode?> astNodeFor(Fragment fragment, {bool resolve = false}) async {
    // Returns the AST for [fragment] — a CompilationUnit for the defining
    // library fragment, the matching class/method/field/etc declaration for
    // any other fragment. Drift's resolvers (e.g. `DartTableResolver`) cast
    // this to the specific node type (`MethodDeclaration`, `FieldDeclaration`),
    // so returning the wrong subtype surfaces as cast errors during drift
    // analysis.
    //
    // Resolution MUST go through the library's own session via
    // `getResolvedLibraryByElement`: the expressions inside getter/method
    // bodies only pick up `staticType` when the library is resolved through
    // the same session that produced its Element model. A path-based
    // `_sessionFor(path).getResolvedLibrary(path)` lookup is superficially
    // equivalent but the `AnalysisContextCollection` returns a session whose
    // element model can drift from the library's own — the visible symptom is
    // drift_dev's `readTypeConverter` reporting "Not a type converter" on a
    // `.map(const MyConverter())` argument because the Expression's
    // `staticType` comes back null. Matches drift's own `TestBackend`.
    final libFragment = fragment.libraryFragment;
    if (libFragment == null) return null;
    final library = libFragment.element;
    if (resolve) {
      final libResult = await library.session.getResolvedLibraryByElement(
        library,
      );
      if (libResult is! ResolvedLibraryResult) return null;
      if (identical(fragment, libFragment)) {
        final path = libFragment.source.fullName;
        for (final u in libResult.units) {
          if (u.path == path) return u.unit;
        }
        return null;
      }
      return libResult.getFragmentDeclaration(fragment)?.node;
    }
    final path = libFragment.source.fullName;
    final parsedLib = _sessionFor(path).getParsedLibrary(path);
    if (parsedLib is! ParsedLibraryResult) return null;
    if (identical(fragment, libFragment)) {
      for (final u in parsedLib.units) {
        if (u.path == path) return u.unit;
      }
      return null;
    }
    return parsedLib.getFragmentDeclaration(fragment)?.node;
  }
}

void _installAssetUriResolver(
  AnalysisContextCollection collection,
  PackageConfig packageConfig,
  Map<AssetId, String> assetIdToPath,
) {
  for (final context in collection.contexts) {
    if (context is! DriverBasedAnalysisContext) continue;
    final sourceFactory = context.driver.sourceFactory;
    if (sourceFactory is! SourceFactoryImpl) continue;
    final resolvers = sourceFactory.resolvers;
    if (resolvers.any((r) => r is _ShimAssetUriResolver)) continue;
    final resolver = _ShimAssetUriResolver(
      context.resourceProvider,
      packageConfig,
      assetIdToPath,
    );
    final pkgIdx = resolvers.indexWhere(
      (r) => r is PackageConfigPackageUriResolver || r is PackageMapUriResolver,
    );
    if (pkgIdx >= 0) {
      resolvers.insert(pkgIdx + 1, resolver);
    } else {
      resolvers.insert(0, resolver);
    }
  }
}

/// Resolves `asset:<pkg>/<path>` URIs and maps non-`lib/` package files back
/// to their canonical `asset:` URI, matching `build_resolvers`'s
/// `AssetUriResolver`. Placed immediately after `packageUriResolver` in the
/// driver's `SourceFactory` so `lib/` files continue to canonicalize to
/// `package:<pkg>/<rel>` while files outside `lib/` (`bin/`, `web/`, `test/`,
/// `tool/`, etc.) canonicalize to `asset:<pkg>/<path>` instead of falling
/// through to `file:///<TMPDIR>/shim_<pkg>_<RANDOM>/...`.
final class _ShimAssetUriResolver extends UriResolver {
  _ShimAssetUriResolver(
    this.resourceProvider,
    this._packageConfig,
    this._assetIdToPath,
  ) : _packageRoots = {
        for (final pkg in _packageConfig.packages)
          pkg.name: resourceProvider.getFolder(
            resourceProvider.pathContext.normalize(
              resourceProvider.pathContext.fromUri(pkg.root),
            ),
          ),
      };

  final fs.ResourceProvider resourceProvider;
  final PackageConfig _packageConfig;
  final Map<AssetId, String> _assetIdToPath;
  final Map<String, fs.Folder> _packageRoots;

  @override
  Uri? pathToUri(String path) {
    final pathContext = resourceProvider.pathContext;
    Uri? bestUri;
    var bestLength = -1;
    for (final entry in _packageRoots.entries) {
      final pkgName = entry.key;
      final pkgFolderPath = entry.value.path;
      if (path.length >= pkgFolderPath.length + pathContext.separator.length &&
          path.startsWith(pkgFolderPath) &&
          path.startsWith(pathContext.separator, pkgFolderPath.length)) {
        if (pkgFolderPath.length > bestLength) {
          final relPath = path.substring(
            pkgFolderPath.length + pathContext.separator.length,
          );
          final relPathComponents = pathContext.split(relPath);
          final candidate = Uri(
            scheme: 'asset',
            pathSegments: [pkgName, ...relPathComponents],
          );
          bestUri = uriCache.parse(candidate.toString());
          bestLength = pkgFolderPath.length;
        }
      }
    }
    return bestUri;
  }

  @override
  Source? resolveAbsolute(Uri uri) {
    if (!uri.isScheme('asset')) {
      return null;
    }
    final pathSegments = uri.pathSegments;
    if (pathSegments.length < 2) {
      return null;
    }
    final pkgName = pathSegments.first;
    final relSegments = pathSegments.skip(1).toList();
    if (relSegments.any((s) => s.isEmpty || s == '.' || s == '..')) {
      return null;
    }
    final relPosixPath = p.posix.joinAll(relSegments);
    final pathContext = resourceProvider.pathContext;
    String? filePath;
    try {
      filePath = _assetIdToPath[AssetId(pkgName, relPosixPath)];
    } on ArgumentError {
      return null;
    }
    if (filePath == null) {
      final pkg = _packageConfig[pkgName];
      if (pkg == null) {
        return null;
      }
      if (relPosixPath.startsWith('lib/')) {
        final rel = relPosixPath.substring(4);
        filePath = pathContext.normalize(
          pathContext.fromUri(pkg.packageUriRoot.resolve(rel)),
        );
      } else {
        filePath = pathContext.normalize(
          pathContext.fromUri(pkg.root.resolve(relPosixPath)),
        );
      }
    }
    final file = resourceProvider.getFile(filePath);
    return FileSource(file, uri);
  }
}

// ---------------------------------------------------------------------------
// Bounded ResourceProvider confining ContextLocator upward walks at staging.
// ---------------------------------------------------------------------------

final class _StagingBoundedResourceProvider implements fs.ResourceProvider {
  _StagingBoundedResourceProvider(
    this._delegate, {
    required Iterable<String> boundaryRoots,
  }) : _boundaryRoots = {
         for (final r in boundaryRoots)
           _delegate.pathContext.normalize(_delegate.pathContext.absolute(r)),
       };

  final fs.ResourceProvider _delegate;
  final Set<String> _boundaryRoots;

  bool isBoundary(String normPath) {
    if (_boundaryRoots.contains(normPath)) return true;
    for (final root in _boundaryRoots) {
      if (_delegate.pathContext.isWithin(normPath, root)) return true;
    }
    return false;
  }

  @override
  p.Context get pathContext => _delegate.pathContext;

  @override
  fs.File getFile(String path) =>
      _StagingBoundedFile(this, _delegate.getFile(path));

  @override
  fs.Folder getFolder(String path) =>
      _StagingBoundedFolder(this, _delegate.getFolder(path));

  @override
  fs.Link getLink(String path) => _delegate.getLink(path);

  @override
  fs.Resource getResource(String path) {
    final res = _delegate.getResource(path);
    if (res is fs.Folder) return _StagingBoundedFolder(this, res);
    if (res is fs.File) return _StagingBoundedFile(this, res);
    return res;
  }

  @override
  fs.Folder? getStateLocation(String pluginId) =>
      _delegate.getStateLocation(pluginId);
}

final class _StagingBoundedFolder
    with BoundedFolderForwards
    implements fs.Folder {
  const _StagingBoundedFolder(this._provider, this._delegate);

  final _StagingBoundedResourceProvider _provider;
  final fs.Folder _delegate;

  @override
  fs.Folder get folderDelegate => _delegate;

  @override
  fs.ResourceProvider get folderProvider => _provider;

  @override
  fs.Folder wrapFolder(fs.Folder folder) =>
      _StagingBoundedFolder(_provider, folder);

  @override
  fs.File wrapFile(fs.File file) => _StagingBoundedFile(_provider, file);

  String get _normPath => _provider.pathContext.normalize(
    _provider.pathContext.absolute(_delegate.path),
  );

  @override
  bool get isRoot => _provider.isBoundary(_normPath) || _delegate.isRoot;

  @override
  bool get exists => _delegate.exists;

  @override
  bool contains(String path) => _delegate.contains(path);

  @override
  List<fs.Resource> getChildren() => [
    for (final child in _delegate.getChildren())
      if (child is fs.Folder)
        _StagingBoundedFolder(_provider, child)
      else if (child is fs.File)
        _StagingBoundedFile(_provider, child)
      else
        child,
  ];

  @override
  bool isOrContains(String path) => _delegate.isOrContains(path);
}

final class _StagingBoundedFile with BoundedFileForwards implements fs.File {
  const _StagingBoundedFile(this._provider, this._delegate);

  final _StagingBoundedResourceProvider _provider;
  final fs.File _delegate;

  @override
  fs.File get fileDelegate => _delegate;

  @override
  fs.Folder wrapFolder(fs.Folder folder) =>
      _StagingBoundedFolder(_provider, folder);

  @override
  fs.File wrapFile(fs.File file) => _StagingBoundedFile(_provider, file);

  @override
  bool get exists => _delegate.exists;

  @override
  int get lengthSync => _delegate.lengthSync;

  @override
  int get modificationStamp => _delegate.modificationStamp;

  @override
  fs.ResourceProvider get provider => _provider;

  @override
  Uint8List readAsBytesSync() => _delegate.readAsBytesSync();

  @override
  String readAsStringSync() => _delegate.readAsStringSync();
}

// ---------------------------------------------------------------------------
// Local AccumulatorSink (avoiding an explicit dep on `package:convert`).
// ---------------------------------------------------------------------------

class AccumulatorSink<T> implements ChunkedConversionSink<T> {
  final List<T> events = [];
  @override
  void add(T chunk) => events.add(chunk);
  @override
  void close() {}
}

/// One URI-bearing directive of a staged source: its kind (`import`,
/// `export`, `part`, `part of`) and its URI.
class _ShimDirectiveRef {
  _ShimDirectiveRef(this.kind, this.uri);

  final String kind;
  final String uri;
}

/// The URI-bearing directives the analyzer parses from the staged file [file]
/// holding [source]: each `import` and `export` contributes its declared URI
/// and every `if` alternative without evaluating conditions, each `part` and
/// `part of` its URI.
///
/// Fail-closed: a source that does not parse, or a directive URI with no
/// static `stringValue` (an interpolation), throws a [StateError] naming
/// [file]. Either names no file the staged-source check can confine: an
/// unchecked directive could read an undeclared host file, so the caller
/// reports the message as a violation and no Builder runs. A `part of` that
/// names a library instead of a URI contributes nothing: it names no file.
List<_ShimDirectiveRef> _parseShimDirectives(String source, String file) {
  final refs = <_ShimDirectiveRef>[];
  void add(String kind, String? uri, String spelling) {
    if (uri == null) {
      throw StateError(
        "$file $kind $spelling names no static file, so it cannot be checked.",
      );
    }
    refs.add(_ShimDirectiveRef(kind, uri));
  }

  late final ParseStringResult parsed;
  try {
    parsed = parseString(content: source, throwIfDiagnostics: false);
  } catch (_) {
    throw StateError(
      "$file could not be parsed, so its directives cannot be checked.",
    );
  }
  for (final directive in parsed.unit.directives) {
    if (directive is ImportDirective) {
      add('import', directive.uri.stringValue, directive.uri.toSource());
      for (final alternative in directive.configurations) {
        add('import', alternative.uri.stringValue, alternative.uri.toSource());
      }
    } else if (directive is ExportDirective) {
      add('export', directive.uri.stringValue, directive.uri.toSource());
      for (final alternative in directive.configurations) {
        add('export', alternative.uri.stringValue, alternative.uri.toSource());
      }
    } else if (directive is PartDirective) {
      add('part', directive.uri.stringValue, directive.uri.toSource());
    } else if (directive is PartOfDirective) {
      final uri = directive.uri;
      if (uri != null) add('part of', uri.stringValue, uri.toSource());
    }
  }
  return refs;
}

/// The diagnostics for every staged directive under [stagingDir] that would
/// read a file outside it, in path order. Empty when clean. The builder-shim
/// front of the shared staged-source check ([_runWithStaging] refuses these
/// before any Builder runs): `dart:`, `package:` URIs that stay inside their
/// package, and schemeless relatives that stay inside the staging dir pass,
/// while `file:` and other schemes, `package:` URIs climbing above their
/// package ([isEscapingPackageUri]), relatives escaping the staging dir
/// (resolved by [resolveStagedRelativeTarget] against the importing file's
/// staged path, the way the analyzer resolves them), URIs spanning lines
/// ([hasLineBreak]), URIs resolving to no
/// file at all (`//` authorities, fragments, decoded `/`), sources that do
/// not parse, and directive URIs with no static value (interpolations) are
/// refused. Each
/// diagnostic names the file, the directive and the URI, in the same shape as
/// the shared check's.
Future<List<String>> findStagedShimViolations(
  Directory stagingDir, {
  required String tool,
}) async {
  final allowed = <String>{normalizeStagedPath(stagingDir.path)};
  try {
    allowed.add(normalizeStagedPath(await stagingDir.resolveSymbolicLinks()));
  } on FileSystemException {
    // Unresolvable; the passed spelling still applies.
  }
  bool declared(String target) =>
      allowed.any((root) => target == root || target.startsWith('$root/'));
  final errors = <String>[];
  for (final path in await _collectStagedDartPaths(stagingDir)) {
    final content = await _readStagedText(path);
    // Gone between listing and reading; the analyzer reports it.
    if (content == null) continue;
    final key = path.replaceAll(r'\', '/');
    final from = normalizeStagedPath(key);
    // A source whose directives cannot be listed (it does not parse, or a
    // directive URI has no static value) is refused before any Builder runs:
    // an unchecked directive could read outside the staging dir.
    late final List<_ShimDirectiveRef> refs;
    try {
      refs = _parseShimDirectives(content, key);
    } on StateError catch (e) {
      errors.add('$tool: ${e.message}');
      continue;
    }
    for (final ref in refs) {
      final violation = _shimRefViolation(tool, key, ref, from, declared);
      if (violation != null) errors.add(violation);
    }
  }
  return errors;
}

/// Every `.dart` file under [stagingDir] in path order.
Future<List<String>> _collectStagedDartPaths(Directory stagingDir) async {
  final paths = <String>[];
  await for (final entity in stagingDir.list(
    recursive: true,
    followLinks: false,
  )) {
    if (entity is File || entity is Link) {
      if (entity.path.endsWith('.dart')) paths.add(entity.path);
    }
  }
  paths.sort();
  return paths;
}

/// The staged file at [path] with malformed sequences replaced, or null when
/// it vanished between listing and reading (the analyzer reports those
/// itself). Malformed sequences become U+FFFD, never a skipped file: the
/// analyzer accepts the file, so the guard scans what it can.
Future<String?> _readStagedText(String path) async {
  try {
    return utf8.decode(await File(path).readAsBytes(), allowMalformed: true);
  } on FileSystemException {
    return null;
  }
}

/// The violation line for one staged directive reference, or null when the
/// reference stays inside the staging dir: `dart:`, `package:` URIs that stay
/// inside their package, and schemeless relatives that stay inside the staging
/// dir pass, while `file:` and other schemes, `package:` URIs climbing above
/// their package ([isEscapingPackageUri]), relatives escaping the staging dir
/// (resolved by [resolveStagedRelativeTarget] against the importing file's
/// staged path, the way the analyzer resolves them), URIs spanning lines
/// ([hasLineBreak]), and URIs resolving to no file at all (`//` authorities,
/// fragments, decoded `/`) are refused. The staging dir holds every entry the
/// builders may read, so a resolved target outside it is undeclared; a missing
/// file inside it fails in the builder, never on the host.
String? _shimRefViolation(
  String tool,
  String key,
  _ShimDirectiveRef ref,
  String from,
  bool Function(String) declared,
) {
  final uri = ref.uri;
  // A URI spanning lines is refused however it spells its target: the
  // front end's multi-line first-line rule reads a different file than
  // the resolvers below see (see [hasLineBreak]).
  if (hasLineBreak(uri)) {
    return "$tool: $key ${ref.kind} '$uri' is not a declared input.";
  }
  // The resolvers below skip empty segments, but the front end resolves
  // some such spellings absolutely: refuse them before resolving.
  if (hasEmptyPathSegment(uri)) {
    return "$tool: $key ${ref.kind} '$uri' is not a declared input.";
  }
  if (uri.startsWith('dart:')) return null;
  if (uri.startsWith('package:')) {
    if (isEscapingPackageUri(uri)) {
      return "$tool: $key ${ref.kind} '$uri' is not a declared input.";
    }
    return null;
  }
  if (isFileSchemeDirectiveUri(uri) || isDisallowedDirectiveUri(uri)) {
    return "$tool: $key ${ref.kind} '$uri' is not a declared input.";
  }
  final target = resolveStagedRelativeTarget(uri, from);
  // A null resolution names no declared file (a `//` authority, a
  // fragment, or a decoded `/`): it is refused, never passed. The staging
  // dir holds every entry the builders may read, so a resolved target
  // outside it is undeclared; a missing file inside it fails in the
  // builder, never on the host.
  if (target == null || !declared(target)) {
    return "$tool: $key ${ref.kind} '$uri' is not a declared input.";
  }
  return null;
}
