// Build-action runner for the analyzer-summary mode of the `dart_analyze`
// aspect, which `//dart:analyzer_summaries` selects (on by default).
//
// `summarize` writes one package's summary: `package:analyzer`'s bundle of the
// libraries its own sources declare, linked against the summaries of its
// dependencies. `analyze` checks a staged project's own files against those
// summaries, instead of against every dependency's source, and prints each
// diagnostic in `dart analyze`'s format. Both run the pinned `package:analyzer`
// rather than the SDK's copy, so the lint rules come from the vendored linter
// under //third_party/dart_linter, which is the SDK's own set.
//
// Supports both one-shot execution (with `@flagfile` expansion) and Bazel's
// `--persistent_worker` binary protobuf protocol over stdin/stdout.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:analyzer/dart/analysis/analysis_context.dart';
import 'package:analyzer/dart/analysis/analysis_options.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/sdk/build_sdk_summary.dart';
import 'package:analyzer/diagnostic/diagnostic.dart';
import 'package:analyzer/error/error.dart';
import 'package:analyzer/file_system/file_system.dart' as fs;
import 'package:analyzer/file_system/physical_file_system.dart';
import 'package:analyzer/source/error_processor.dart';
import 'package:analyzer/source/line_info.dart';
import 'package:analyzer/source/source.dart';
// ignore: implementation_imports
import 'package:analyzer/src/analysis_options/analysis_options_parser.dart';
// ignore: implementation_imports
import 'package:analyzer/src/context/source.dart' show SourceFactoryImpl;
// ignore: implementation_imports
import 'package:analyzer/src/dart/analysis/analysis_context_collection.dart';
// ignore: implementation_imports
import 'package:analyzer/src/dart/analysis/driver.dart';
// ignore: implementation_imports
import 'package:analyzer/src/dart/analysis/driver_based_analysis_context.dart';
// ignore: implementation_imports
import 'package:analyzer/src/generated/source.dart' show UriResolver;
// ignore: implementation_imports
import 'package:analyzer/src/summary/package_bundle_reader.dart'
    show InSummaryUriResolver;
// ignore: implementation_imports
import 'package:linter/src/rules.dart';
import 'package:path/path.dart' as p;

import 'package:rules_dart_guard/directive_guard.dart';

const _optionsBasename = 'analysis_options.yaml';
const _packageConfig = '.dart_tool/package_config.json';

/// `EX_USAGE`: a bad command line.
const _usage = 64;

/// A check that found problems, or a file that could not be analyzed.
const _failed = 1;

bool _lintRulesRegistered = false;

/// Number of [AnalysisContextCollectionImpl] instances disposed across
/// `summarize` and `analyze` requests in this process.
int disposedContextCollectionsCount = 0;

/// Optional hook invoked after each [AnalysisContextCollectionImpl] is disposed
/// (used by tests to verify driver / context release).
void Function(AnalysisContextCollectionImpl collection)?
onContextCollectionDisposed;

/// Disposes [collection], counting and announcing the release.
///
/// Tear-down failures are swallowed: the request already has its result, so a
/// failure to release the collection must not fail the request. Only
/// [Exception]s are ignored; programming errors still propagate.
Future<void> disposeContextCollection(
  AnalysisContextCollectionImpl collection,
) async {
  try {
    await collection.dispose();
  } on Exception {
    // Swallow tear-down exceptions from any older analyzer internals after
    // scheduling driver disposal.
  } finally {
    disposedContextCollectionsCount++;
    onContextCollectionDisposed?.call(collection);
  }
}

/// Registers the vendored lint rules once per process.
void _ensureLintRulesRegistered() {
  if (!_lintRulesRegistered) {
    registerLintRules();
    _lintRulesRegistered = true;
  }
}

Future<void> main(List<String> rawArgs) async {
  final args = _expandParamFiles(rawArgs);
  if (args.contains('--persistent_worker')) {
    await _runPersistentWorker();
    exit(0);
  }
  final code = await runSingleRequest(
    args,
    outSink: stdout,
    errSink: stderr,
    resourceProvider: PhysicalResourceProvider.INSTANCE,
  );
  exit(code);
}

/// Runs the Bazel persistent worker loop reading `WorkRequest` protobuf frames
/// from `stdin` and writing `WorkResponse` protobuf frames to `stdout`.
Future<void> _runPersistentWorker() async {
  _ensureLintRulesRegistered();
  final disableCache = Platform.environment['ANALYZER_SUMMARY_NO_CACHE'] == '1';
  final envTotalMb = int.tryParse(
    Platform.environment['ANALYZER_SUMMARY_CACHE_MB'] ?? '',
  );
  final envInstances = int.tryParse(
    Platform.environment['ANALYZER_SUMMARY_WORKER_INSTANCES'] ?? '',
  );
  final summaryCache = SummaryByteCache(
    totalBudgetBytes: envTotalMb != null && envTotalMb > 0
        ? envTotalMb * 1024 * 1024
        : SummaryByteCache.defaultTotalBudgetBytes,
    workerInstances: envInstances != null && envInstances > 0
        ? envInstances
        : SummaryByteCache.defaultWorkerInstances,
  );

  await for (final bytes in _Frames(stdin)) {
    final request = _WorkRequest.read(bytes);
    if (request.cancel) {
      continue;
    }
    final output = StringBuffer();
    var exitCode = _failed;
    try {
      final expandedArgs = _expandParamFiles(request.arguments);
      final fs.ResourceProvider provider;
      if (disableCache) {
        provider = PhysicalResourceProvider.INSTANCE;
      } else {
        summaryCache.beginRequest(request.inputs);
        provider = SummaryCachingResourceProvider(
          PhysicalResourceProvider.INSTANCE,
          summaryCache,
        );
      }
      final requestInputPaths = <String>{
        for (final key in request.inputs.keys) p.normalize(p.absolute(key)),
      };
      exitCode = await runSingleRequest(
        expandedArgs,
        outSink: output,
        errSink: output,
        resourceProvider: provider,
        requestInputPaths: requestInputPaths,
      );
    } on Object catch (e, st) {
      output
        ..writeln('analyzer_summary: unhandled exception: $e')
        ..writeln(st);
      exitCode = _failed;
    }
    stdout.add(
      _WorkResponse(
        exitCode: exitCode,
        output: output.toString(),
        requestId: request.requestId,
      ).write(),
    );
    await stdout.flush();
  }
}

/// Executes a single `sdk`, `summarize`, or `analyze` invocation.
Future<int> runSingleRequest(
  List<String> args, {
  required StringSink outSink,
  required StringSink errSink,
  required fs.ResourceProvider resourceProvider,
  Set<String>? requestInputPaths,
}) async {
  _ensureLintRulesRegistered();
  if (args.isEmpty) {
    return _usageError(errSink, 'a mode is required: `summarize` or `analyze`');
  }
  final _Args parsed;
  try {
    parsed = _Args.parse(args.sublist(1));
  } on _UsageException catch (e) {
    return _usageError(errSink, e.message);
  }
  try {
    return switch (args.first) {
      'sdk' => await _sdk(parsed, resourceProvider: resourceProvider),
      'summarize' => await _summarize(
        parsed,
        errSink: errSink,
        resourceProvider: resourceProvider,
      ),
      'analyze' => await _analyze(
        parsed,
        outSink: outSink,
        errSink: errSink,
        resourceProvider: resourceProvider,
        requestInputPaths: requestInputPaths,
      ),
      _ => _usageError(errSink, 'unknown mode `${args.first}`'),
    };
  } on _UsageException catch (e) {
    return _usageError(errSink, e.message);
  }
}

int _usageError(StringSink errSink, String message) {
  errSink.writeln('analyzer_summary: $message');
  return _usage;
}

/// Writes the summary of the SDK's own libraries.
///
/// A dependency's summary refers to the SDK libraries it imports, such as
/// `dart:io`, and those are not in any package's summary. Analysis reads them
/// from this one, which every `summarize` and `analyze` also takes. When
/// `--embedder-yaml` is given, the embedder's libraries (Flutter's `dart:ui`,
/// from `sky_engine`'s `lib/_embedder.yaml`) are built into the summary as
/// well.
Future<int> _sdk(
  _Args args, {
  required fs.ResourceProvider resourceProvider,
}) async {
  final sdkPath = p.normalize(p.absolute(args.single('sdk')));
  final embedder = args.all('embedder-yaml');
  final embedderYamlPath = embedder.isEmpty
      ? null
      : p.normalize(p.absolute(embedder.single));
  final boundedProvider = BoundedResourceProvider(
    resourceProvider,
    primaryRoot: sdkPath,
    boundaryRoots: {
      sdkPath,
      if (embedderYamlPath != null) p.dirname(embedderYamlPath),
    },
    allowedFiles: {if (embedderYamlPath != null) embedderYamlPath},
    blockAnalysisOptions: true,
  );
  final bytes = await buildSdkSummary(
    resourceProvider: boundedProvider,
    sdkPath: sdkPath,
    embedderYamlPath: embedderYamlPath,
  );
  File(args.single('out')).writeAsBytesSync(bytes);
  return 0;
}

/// Infers the staged summary root directory from `--source` and `--uri` pairs.
String inferSummarizeRoot(
  List<String> normSources,
  List<String> uris, {
  p.Context? pathContext,
}) {
  final ctx = pathContext ?? p.context;
  var root = ctx.dirname(normSources.first);
  final firstUri = Uri.tryParse(uris.first);
  if (firstUri != null &&
      firstUri.scheme == 'package' &&
      firstUri.pathSegments.length > 1) {
    final relSegments = firstUri.pathSegments.length - 1;
    var candidate = normSources.first;
    for (var i = 0; i < relSegments; i++) {
      final parent = ctx.dirname(candidate);
      if (parent == candidate) break;
      candidate = parent;
    }
    root = candidate;
  }
  for (final src in normSources) {
    final srcDir = ctx.dirname(src);
    while (!ctx.equals(root, srcDir) && !ctx.isWithin(root, srcDir)) {
      final parent = ctx.dirname(root);
      if (parent == root) break;
      root = parent;
    }
  }
  return root;
}

String? _reanchorThroughSymlink(String rootDir, String targetPath) {
  final String resolvedRoot;
  try {
    resolvedRoot = p.normalize(Directory(rootDir).resolveSymbolicLinksSync());
  } on FileSystemException {
    return null;
  }
  if (p.equals(resolvedRoot, targetPath)) {
    return rootDir;
  }
  if (p.isWithin(resolvedRoot, targetPath)) {
    return p.normalize(
      p.join(rootDir, p.relative(targetPath, from: resolvedRoot)),
    );
  }
  var cur = p.dirname(targetPath);
  while (true) {
    try {
      final resolvedCur = p.normalize(
        Directory(cur).resolveSymbolicLinksSync(),
      );
      if (p.equals(resolvedCur, resolvedRoot)) {
        return p.normalize(p.join(rootDir, p.relative(targetPath, from: cur)));
      }
    } on FileSystemException {
      // Keep walking up until an existing ancestor is found or root is reached.
    }
    final parent = p.dirname(cur);
    if (parent == cur) break;
    cur = parent;
  }
  return null;
}

/// Writes the summary of one package's libraries.
///
/// `--source` and `--uri` pair up in order: the i-th source is the library at
/// the i-th `package:` URI. A `part` file is staged with the others, so its
/// library resolves it, but it is not a library and has no URI in the bundle:
/// naming it as one fails the bundle with "Missing library".
Future<int> _summarize(
  _Args args, {
  required StringSink errSink,
  required fs.ResourceProvider resourceProvider,
}) async {
  final sources = args.all('source');
  final uris = args.all('uri');
  if (sources.isEmpty || sources.length != uris.length) {
    return _usageError(
      errSink,
      'summarize needs a --source for each --uri, and at least one of each',
    );
  }
  final packagesPath = p.normalize(p.absolute(args.single('packages')));
  final packagesDir = p.dirname(packagesPath);

  final normSources = _normalizeSummarizeSources(sources, packagesDir);
  final libraryUris = <String>[
    for (var i = 0; i < normSources.length; i++)
      if (!_isPart(normSources[i])) uris[i],
  ];
  final sdkPath = p.normalize(p.absolute(args.single('sdk')));
  final sdkSummaryPath = p.normalize(p.absolute(args.single('sdk-summary')));
  final summaryPaths = <String>[
    for (final s in args.all('summary')) p.normalize(p.absolute(s)),
  ];
  final normDepSources = <String>{
    for (final s in args.all('dep-source'))
      _normalizeSummarizeSource(s, packagesDir),
  };
  final sourceRoot = inferSummarizeRoot(
    normSources,
    uris,
    pathContext: resourceProvider.pathContext,
  );
  final normSourceSet = normSources.toSet();
  if (!_checkSummarizeSources(normSources, errSink)) return _failed;
  final libRoot = p.normalize(p.join(sourceRoot, 'lib'));
  final depsDir = p.normalize(p.join(sourceRoot, '_deps'));
  final depLibRoots = <String>{
    for (final s in normDepSources)
      if (p.isWithin(depsDir, s))
        p.normalize(
          p.join(depsDir, p.split(p.relative(s, from: depsDir)).first, 'lib'),
        ),
  };
  _pruneSummarizeTree(
    sourceRoot: sourceRoot,
    libRoot: libRoot,
    depLibRoots: depLibRoots,
    normSourceSet: normSourceSet,
    normDepSources: normDepSources,
  );
  if (!_checkSummarizeDirectives(sourceRoot, errSink)) return _failed;
  final boundedProvider = _summarizeResourceProvider(
    resourceProvider: resourceProvider,
    sourceRoot: sourceRoot,
    packagesDir: packagesDir,
    packagesPath: packagesPath,
    sdkPath: sdkPath,
    sdkSummaryPath: sdkSummaryPath,
    summaryPaths: summaryPaths,
    normSources: normSources,
    normDepSources: normDepSources,
    libRoot: libRoot,
    depLibRoots: depLibRoots,
  );
  final collection = AnalysisContextCollectionImpl(
    resourceProvider: boundedProvider,
    includedPaths: [normSources.first],
    sdkPath: sdkPath,
    sdkSummaryPath: sdkSummaryPath,
    packageConfigFile: packagesPath,
    librarySummaryPaths: summaryPaths,
  );
  _installFileAwareSummaryResolver(collection, boundedProvider.pathContext);
  final bytes = await _buildPackageBundle(collection, libraryUris: libraryUris);
  File(args.single('out')).writeAsBytesSync(bytes);
  return 0;
}

/// The `--source` paths normalized under [packagesDir].
List<String> _normalizeSummarizeSources(
  List<String> sources,
  String packagesDir,
) => [for (final s in sources) _normalizeSummarizeSource(s, packagesDir)];

/// One `--source` path normalized under [packagesDir].
String _normalizeSummarizeSource(String raw, String packagesDir) {
  final abs = p.normalize(p.absolute(raw));
  if (p.equals(packagesDir, abs) || p.isWithin(packagesDir, abs)) {
    return abs;
  }
  return _reanchorThroughSymlink(packagesDir, abs) ?? abs;
}

/// Refuses missing staged sources.
bool _checkSummarizeSources(List<String> normSources, StringSink errSink) {
  for (final src in normSources) {
    if (!FileSystemEntity.isFileSync(src)) {
      errSink.writeln('analyzer_summary: missing source $src');
      return false;
    }
  }
  return true;
}

/// Drops staged files the summary request does not list.
void _pruneSummarizeTree({
  required String sourceRoot,
  required String libRoot,
  required Set<String> depLibRoots,
  required Set<String> normSourceSet,
  required Set<String> normDepSources,
}) {
  if (!p.basename(sourceRoot).endsWith('.summary_root')) return;
  _pruneUnlistedUnder(libRoot, normSourceSet);
  for (final depLibRoot in depLibRoots) {
    _pruneUnlistedUnder(depLibRoot, normDepSources);
  }
}

/// Refuses staged sources that read outside their declared inputs.
bool _checkSummarizeDirectives(String sourceRoot, StringSink errSink) {
  // No staged source may read the host: a `file:` URI (in any spelling), any
  // other non-`dart:`/`package:` directive URI, a `package:` URI climbing
  // above its package, or a relative URI climbing out of the staged tree
  // would reach an undeclared file when the analyzer resolves it against the
  // real filesystem. Refuse before summarizing, through the one shared
  // staged-source check. Missing staged files stay allowed here: dependency
  // sources arrive through summaries, not the staged tree, so a relative
  // target with no staged file resolves against a declared summary (or fails
  // in the analyzer with `uri_does_not_exist` — both closed).
  final stagedViolations = findStagedDirectiveViolations(
    [sourceRoot],
    tool: 'analyzer_summary',
    requireTargetsExist: false,
  );
  if (stagedViolations.isNotEmpty) {
    for (final violation in stagedViolations) {
      errSink.writeln(violation);
    }
    return false;
  }
  return true;
}

/// The resource provider bounding the summary request to its staged inputs.
BoundedResourceProvider _summarizeResourceProvider({
  required fs.ResourceProvider resourceProvider,
  required String sourceRoot,
  required String packagesDir,
  required String packagesPath,
  required String sdkPath,
  required String sdkSummaryPath,
  required List<String> summaryPaths,
  required List<String> normSources,
  required Set<String> normDepSources,
  required String libRoot,
  required Set<String> depLibRoots,
}) => BoundedResourceProvider(
  resourceProvider,
  primaryRoot: sourceRoot,
  boundaryRoots: {sourceRoot, packagesDir, sdkPath},
  allowedFiles: {
    packagesPath,
    sdkSummaryPath,
    ...summaryPaths,
    ...normSources,
    ...normDepSources,
  },
  restrictedRoot: libRoot,
  extraRestrictedRoots: depLibRoots,
  allowedUnderRestrictedRoot: {...normSources, ...normDepSources},
  blockAnalysisOptions: true,
);

/// Builds the package bundle, releasing the collection afterwards.
Future<Uint8List> _buildPackageBundle(
  AnalysisContextCollectionImpl collection, {
  required List<String> libraryUris,
}) async {
  try {
    final driver = collection.contexts.single.driver;
    return await driver.buildPackageBundle(
      uriList: [for (final u in libraryUris) Uri.parse(u)],
    );
  } finally {
    await disposeContextCollection(collection);
  }
}

/// Replaces each context's [InSummaryUriResolver] with
/// [_FileAwareInSummaryUriResolver] so `file:` URIs resulting from relative
/// imports into a summarized package's `lib/` directory (such as
/// `import '../lib/foo.dart';` from `test/` or `bin/`) resolve to the
/// summary's `package:` library instead of looking for an unstaged file on
/// disk.
void _installFileAwareSummaryResolver(
  AnalysisContextCollectionImpl collection,
  p.Context pathContext,
) {
  for (final context in collection.contexts) {
    final sourceFactory = context.driver.sourceFactory;
    if (sourceFactory is SourceFactoryImpl) {
      final packageUriResolver =
          context.contextRoot.workspace.packageUriResolver;
      final resolvers = sourceFactory.resolvers;
      for (var i = 0; i < resolvers.length; i++) {
        final resolver = resolvers[i];
        if (resolver is InSummaryUriResolver) {
          resolvers[i] = _FileAwareInSummaryUriResolver(
            resolver,
            packageUriResolver,
            pathContext,
          );
        }
      }
    }
  }
}

final class _FileAwareInSummaryUriResolver extends UriResolver {
  _FileAwareInSummaryUriResolver(
    this._inSummaryResolver,
    this._packageUriResolver,
    this._pathContext,
  );

  final InSummaryUriResolver _inSummaryResolver;
  final UriResolver _packageUriResolver;
  final p.Context _pathContext;

  @override
  Uri? pathToUri(String path) => _inSummaryResolver.pathToUri(path);

  @override
  Source? resolveAbsolute(Uri uri) {
    final direct = _inSummaryResolver.resolveAbsolute(uri);
    if (direct != null) {
      return direct;
    }
    if (uri.isScheme('file')) {
      final String filePath;
      try {
        filePath = _pathContext.normalize(_pathContext.fromUri(uri));
      } on ArgumentError {
        return null;
      }
      final packageUri = _packageUriResolver.pathToUri(filePath);
      if (packageUri != null) {
        return _inSummaryResolver.resolveAbsolute(packageUri);
      }
    }
    return null;
  }
}

/// Whether the Dart file at [path] is a `part` of a library, rather than one.
bool _isPart(String path) {
  final unit = parseString(
    content: File(path).readAsStringSync(),
    path: path,
    throwIfDiagnostics: false,
  ).unit;
  return unit.directives.any((d) => d is PartOfDirective);
}

/// Resolves a `--source` argument against [project], normalizing separators
/// and re-anchoring symlinked ancestor prefixes to [project].
String resolveProjectSource(
  String project,
  String raw, {
  p.Context? pathContext,
}) {
  final ctx = pathContext ?? p.context;
  final normProject = ctx.normalize(ctx.absolute(project));
  final normAbs = ctx.normalize(ctx.absolute(raw));
  if (ctx.equals(normProject, normAbs) || ctx.isWithin(normProject, normAbs)) {
    return normAbs;
  }
  if (!ctx.isAbsolute(raw)) {
    final joined = ctx.normalize(ctx.join(normProject, raw));
    if (pathContext != null ||
        FileSystemEntity.typeSync(joined, followLinks: false) !=
            FileSystemEntityType.notFound) {
      return joined;
    }
  }
  if (pathContext == null) {
    final reanchored = _reanchorThroughSymlink(normProject, normAbs);
    if (reanchored != null) {
      return reanchored;
    }
  }
  return ctx.normalize(ctx.join(normProject, raw));
}

/// Checks a staged project's own files, and writes the stamp if they pass.
Future<int> _analyze(
  _Args args, {
  required StringSink outSink,
  required StringSink errSink,
  required fs.ResourceProvider resourceProvider,
  Set<String>? requestInputPaths,
}) async {
  final prepared = _prepareAnalyzeProject(args, errSink: errSink);
  if (prepared == null) return _failed;
  final project = prepared.project;
  final stamp = prepared.stamp;
  final fatalInfos = prepared.fatalInfos;
  final explicitSources = prepared.explicitSources;
  final allowedSrcPaths = prepared.allowedSrcPaths;
  final sdkPath = p.normalize(p.absolute(args.single('sdk')));
  final sdkSummaryPath = p.normalize(p.absolute(args.single('sdk-summary')));
  final packagesPath = p.normalize(p.join(project, _packageConfig));
  final summaryPaths = <String>[
    for (final s in args.all('summary')) p.normalize(p.absolute(s)),
  ];
  final srcRoot = p.normalize(p.join(project, 'src'));
  final boundedProvider = BoundedResourceProvider(
    resourceProvider,
    primaryRoot: project,
    boundaryRoots: {project, sdkPath},
    allowedFiles: {
      packagesPath,
      sdkSummaryPath,
      ...summaryPaths,
      if (allowedSrcPaths != null) ...allowedSrcPaths,
    },
    restrictedRoot: allowedSrcPaths != null ? srcRoot : null,
    allowedUnderRestrictedRoot: allowedSrcPaths,
    blockAnalysisOptions: false,
  );
  final collection = _openAnalyzeCollection(
    boundedProvider: boundedProvider,
    project: project,
    sdkPath: sdkPath,
    sdkSummaryPath: sdkSummaryPath,
    packagesPath: packagesPath,
    summaryPaths: summaryPaths,
  );
  try {
    final context = collection.contexts.single;
    final analyzed = _analyzedPaths(
      project,
      context,
      allowedSrcPaths: allowedSrcPaths,
    );
    if (!_checkExpectedSources(
      project: project,
      context: context,
      analyzed: analyzed,
      explicitSources: explicitSources,
      allowedSrcPaths: allowedSrcPaths,
      srcRoot: srcRoot,
      errSink: errSink,
    )) {
      return _failed;
    }
    final findings = await _collectAnalyzeFindings(
      project: project,
      context: context,
      analyzed: analyzed,
      boundedProvider: boundedProvider,
      errSink: errSink,
    );
    if (findings == null) return _failed;
    return _reportAnalyzeFindings(
      project: project,
      stamp: stamp,
      findings: findings,
      fatalInfos: fatalInfos,
      outSink: outSink,
    );
  } finally {
    await disposeContextCollection(collection);
  }
}

/// The analysis context collection for a staged project, with the
/// file-aware summary resolver installed.
AnalysisContextCollectionImpl _openAnalyzeCollection({
  required BoundedResourceProvider boundedProvider,
  required String project,
  required String sdkPath,
  required String sdkSummaryPath,
  required String packagesPath,
  required List<String> summaryPaths,
}) {
  final collection = AnalysisContextCollectionImpl(
    resourceProvider: boundedProvider,
    includedPaths: [project],
    sdkPath: sdkPath,
    sdkSummaryPath: sdkSummaryPath,
    packageConfigFile: packagesPath,
    librarySummaryPaths: summaryPaths,
  );
  _installFileAwareSummaryResolver(collection, boundedProvider.pathContext);
  return collection;
}

/// The staged project an analyze request checks, after pruning and guarding.
///
/// Returns null after reporting staged sources that read off-host.
({
  String project,
  String stamp,
  bool fatalInfos,
  List<String> explicitSources,
  Set<String>? allowedSrcPaths,
})?
_prepareAnalyzeProject(_Args args, {required StringSink errSink}) {
  final project = p.normalize(p.absolute(args.single('project')));
  final explicitSources = <String>[
    for (final s in args.all('source')) resolveProjectSource(project, s),
  ];
  final allowedSrcPaths = _pruneOrphanedStagedFiles(project);
  // No staged source may read the host (see `_summarize`): the default
  // summary-mode analysis never ran the directive guard, so a climbing
  // relative import reached undeclared host files wherever the analyzer
  // resolved against the real filesystem. Refuse before analyzing, through
  // the one shared staged-source check. Missing staged files stay allowed:
  // dependency sources arrive through summaries, so a relative target with
  // no staged file resolves against a declared summary (or fails with
  // `uri_does_not_exist` — both closed).
  final stagedViolations = findStagedDirectiveViolations(
    projectStagedRoots(project),
    tool: 'analyzer_summary',
    requireTargetsExist: false,
  );
  if (stagedViolations.isNotEmpty) {
    for (final violation in stagedViolations) {
      errSink.writeln(violation);
    }
    return null;
  }
  return (
    project: project,
    stamp: args.single('stamp'),
    fatalInfos: args.flag('fatal-infos'),
    explicitSources: explicitSources,
    allowedSrcPaths: allowedSrcPaths,
  );
}

/// Refuses expected sources that are unlisted, missing, or unanalyzed.
bool _checkExpectedSources({
  required String project,
  required DriverBasedAnalysisContext context,
  required List<String> analyzed,
  required List<String> explicitSources,
  required Set<String>? allowedSrcPaths,
  required String srcRoot,
  required StringSink errSink,
}) {
  final analyzedSet = analyzed.toSet();
  final expectedDartFiles = <String>{
    for (final s in explicitSources)
      if (s.endsWith('.dart')) s,
    if (allowedSrcPaths != null)
      for (final s in allowedSrcPaths)
        if (s.endsWith('.dart')) s,
  };
  for (final expected in explicitSources) {
    if (allowedSrcPaths != null &&
        p.isWithin(srcRoot, expected) &&
        !allowedSrcPaths.contains(expected)) {
      errSink.writeln(
        'analyzer_summary: source not listed in src_manifest.txt: $expected',
      );
      return false;
    }
  }
  for (final expected in expectedDartFiles) {
    if (!FileSystemEntity.isFileSync(expected)) {
      errSink.writeln(
        'analyzer_summary: expected source does not exist: $expected',
      );
      return false;
    }
    if (!p.isWithin(project, expected) ||
        (context.contextRoot.isAnalyzed(expected) &&
            !analyzedSet.contains(expected))) {
      errSink.writeln(
        'analyzer_summary: expected source was not analyzed: $expected',
      );
      return false;
    }
  }
  if (!analyzed.any((path) => path.endsWith('.dart'))) {
    errSink.writeln(
      'analyzer_summary: no Dart files were analyzed in $project',
    );
    return false;
  }
  return true;
}

/// The diagnostics of every analyzed file, most severe first.
///
/// Returns null after reporting a file the driver cannot analyze.
Future<List<_Finding>?> _collectAnalyzeFindings({
  required String project,
  required DriverBasedAnalysisContext context,
  required List<String> analyzed,
  required BoundedResourceProvider boundedProvider,
  required StringSink errSink,
}) async {
  final driver = context.driver;
  final findings = <_Finding>[];
  for (final path in analyzed) {
    final options = context.getAnalysisOptionsForFile(
      boundedProvider.getFile(path),
    );
    if (p.basename(path) == _optionsBasename) {
      findings.addAll(
        _optionsFindings(project, driver, path, options, boundedProvider),
      );
      continue;
    }
    final result = await driver.getErrors(path);
    if (result is! ErrorsResult) {
      errSink.writeln(
        'analyzer_summary: cannot analyze $path (${result.runtimeType})',
      );
      return null;
    }
    for (final d in result.diagnostics) {
      findings.add(_finding(project, path, result.lineInfo, options, d));
    }
  }
  // Printed as `dart analyze` prints them: most severe first, then by file
  // and position.
  findings.sort();
  return findings;
}

/// Prints the findings and writes the stamp, returning the exit code.
int _reportAnalyzeFindings({
  required String project,
  required String stamp,
  required List<_Finding> findings,
  required bool fatalInfos,
  required StringSink outSink,
}) {
  final shown = [
    for (final f in findings)
      if (f.level != null) f,
  ];
  if (shown.isNotEmpty) {
    outSink.writeln();
    for (final f in shown) {
      outSink.writeln(f.text);
    }
    outSink.writeln();
    outSink.writeln(
      shown.length == 1 ? '1 issue found.' : '${shown.length} issues found.',
    );
  }

  final failing =
      shown.any(
        (f) => f.level == Severity.error || f.level == Severity.warning,
      ) ||
      (fatalInfos && shown.any((f) => f.level == Severity.info));
  if (failing) {
    return _failed;
  }
  File(stamp).writeAsStringSync('analyzed\n');
  return 0;
}

void _pruneUnlistedUnder(String dirPath, Set<String> allowedPaths) {
  final dir = Directory(dirPath);
  if (!dir.existsSync()) return;
  for (final entity in dir.listSync(recursive: true, followLinks: false)) {
    if (entity is Directory) continue;
    final normPath = p.normalize(entity.absolute.path);
    if (!allowedPaths.contains(normPath)) {
      try {
        entity.deleteSync();
      } on FileSystemException {
        // Ignore if read-only or already removed.
      }
    }
  }
}

/// Removes any orphaned symlinks or unlisted files under `<project>/src/` left
/// behind in the shared execroot by previous incremental builds when
/// `.dart_tool/src_manifest.txt` is present, and under sibling `<name>.extpkgs/`
/// when `.dart_tool/extpkgs_manifest.txt` is present. Returns the set of
/// normalized absolute paths allowed under `<project>/src/` (or `null` when no
/// manifest is present). Never prunes without a manifest.
Set<String>? _pruneOrphanedStagedFiles(String project) {
  _pruneExtpkgs(project);

  final srcDir = Directory(p.join(project, 'src'));
  if (!srcDir.existsSync()) return null;

  final manifestFile = File(p.join(project, '.dart_tool', 'src_manifest.txt'));
  if (!manifestFile.existsSync()) return null;

  final lines = [
    for (final line in manifestFile.readAsLinesSync())
      if (line.trim().isNotEmpty) line.trim(),
  ];
  if (lines.contains('*')) return null;

  final allowedPaths = <String>{
    for (final line in lines)
      p.normalize(p.absolute(p.join(srcDir.path, line))),
  };
  _pruneUnlistedUnder(srcDir.path, allowedPaths);
  return allowedPaths;
}

void _pruneExtpkgs(String project) {
  final normProject = p.normalize(p.absolute(project));
  if (!normProject.endsWith('.proj')) return;
  final extDir = Directory(
    '${normProject.substring(0, normProject.length - '.proj'.length)}.extpkgs',
  );
  if (!extDir.existsSync()) return;
  final extManifest = File(
    p.join(normProject, '.dart_tool', 'extpkgs_manifest.txt'),
  );
  if (!extManifest.existsSync()) return;

  final allowedFiles = <String>{};
  final allowedDirs = <String>[];
  for (final raw in extManifest.readAsLinesSync()) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) continue;
    if (trimmed.endsWith('/')) {
      allowedDirs.add(p.normalize(p.absolute(p.join(extDir.path, trimmed))));
    } else {
      allowedFiles.add(p.normalize(p.absolute(p.join(extDir.path, trimmed))));
    }
  }
  for (final entity in extDir.listSync(recursive: true, followLinks: false)) {
    if (entity is Directory) continue;
    final normPath = p.normalize(entity.absolute.path);
    final inAllowedDir = allowedDirs.any((dir) => p.isWithin(dir, normPath));
    if (!inAllowedDir && !allowedFiles.contains(normPath)) {
      try {
        entity.deleteSync();
      } on FileSystemException {
        // Ignore if read-only or already removed.
      }
    }
  }
}

/// Every Dart file and options file under the project that the analyzer
/// analyzes, sorted. The staged tree's excludes apply, as they do to
/// `dart analyze`.
List<String> _analyzedPaths(
  String project,
  AnalysisContext context, {
  Set<String>? allowedSrcPaths,
}) {
  final srcDir = p.normalize(p.join(project, 'src'));
  final paths = <String>[];
  for (final entity in Directory(project).listSync(recursive: true)) {
    // Follows links, so a staged file that is a symlink is still a file.
    final path = p.normalize(entity.absolute.path);
    if (!FileSystemEntity.isFileSync(path)) continue;
    if (p.split(path).contains('.dart_tool')) continue;
    final name = p.basename(path);
    if (!name.endsWith('.dart') && name != _optionsBasename) continue;
    if (p.isWithin(srcDir, path)) {
      if (allowedSrcPaths != null && !allowedSrcPaths.contains(path)) {
        continue;
      }
    }
    if (!context.contextRoot.isAnalyzed(path)) continue;
    paths.add(path);
  }
  paths.sort();
  return paths;
}

/// The diagnostics of one options file: the `include:` and lint-name checks
/// the analysis server runs on it, which the driver does not.
List<_Finding> _optionsFindings(
  String project,
  AnalysisDriver driver,
  String path,
  AnalysisOptions options,
  fs.ResourceProvider resourceProvider,
) {
  final result = AnalysisOptionsParseSession().parse(
    sourceFactory: driver.sourceFactory,
    contextRoot: resourceProvider.getFolder(project),
    file: resourceProvider.getFile(path),
  );
  final lines =
      result.content?.lineInfo ??
      LineInfo.fromContent(File(path).readAsStringSync());
  return [
    for (final d in result.diagnostics)
      _finding(project, path, lines, options, d),
  ];
}

/// One diagnostic as it is printed, at its severity after `analyzer: errors:`.
///
/// The driver reports each diagnostic at its code's own severity and does not
/// apply error processors, so the overrides are applied here. A diagnostic an
/// override sets to `ignore` gets a null level and is not printed. The driver
/// already drops diagnostics suppressed by `// ignore:`.
_Finding _finding(
  String project,
  String path,
  LineInfo lines,
  AnalysisOptions options,
  Diagnostic d,
) {
  final processor = ErrorProcessor.getProcessor(options, d);
  final level = processor == null
      ? d.severity
      : switch (processor.severity) {
          DiagnosticSeverity.ERROR => Severity.error,
          DiagnosticSeverity.WARNING => Severity.warning,
          DiagnosticSeverity.INFO => Severity.info,
          _ => null,
        };
  final location = lines.getLocation(d.offset);
  final where = _display(project, path);
  final message = StringBuffer(
    _unstage(d.problemMessage.messageText(includeUrl: false), project),
  );
  if (d.correctionMessage case final correction?) {
    message
      ..write(' ')
      ..write(_unstage(correction, project));
  }
  // `dart analyze` right-aligns the severity in the width of `warning`, so
  // `error` and `info` are indented.
  final text =
      '${(level?.name ?? '').padLeft(7)} - $where:${location.lineNumber}:'
      '${location.columnNumber} - $message - ${d.diagnosticCode.lowerCaseName}';
  return _Finding(
    level: level,
    path: where,
    line: location.lineNumber,
    column: location.columnNumber,
    text: text,
  );
}

/// The workspace path of a staged file: its path under `src/`, where the
/// workspace's own files sit at their workspace-relative paths.
String _display(String project, String path) {
  final relative = p.relative(path, from: project).replaceAll(r'\', '/');
  return relative.startsWith('src/') ? relative.substring(4) : relative;
}

/// Rewrites staged paths in a message to the workspace paths they were copied
/// from. Some messages quote an absolute path (an unresolvable `include:` names
/// the options file that holds it), so both forms are rewritten.
String _unstage(String text, String project) {
  final absolute = p.absolute(project).replaceAll(r'\', '/');
  return text
      .replaceAll(r'\', '/')
      .replaceAll('$absolute/src/', '')
      .replaceAll('$absolute/src', '.')
      .replaceAll(absolute, '.');
}

/// A diagnostic ready to print, ordered most severe first.
final class _Finding implements Comparable<_Finding> {
  const _Finding({
    required this.level,
    required this.path,
    required this.line,
    required this.column,
    required this.text,
  });

  /// The severity after overrides; null when an override ignores it.
  final Severity? level;
  final String path;
  final int line;
  final int column;

  /// The line as printed.
  final String text;

  @override
  int compareTo(_Finding other) {
    final byLevel = _rank(level).compareTo(_rank(other.level));
    if (byLevel != 0) return byLevel;
    final byPath = path.compareTo(other.path);
    if (byPath != 0) return byPath;
    final byLine = line.compareTo(other.line);
    if (byLine != 0) return byLine;
    return column.compareTo(other.column);
  }

  static int _rank(Severity? level) => switch (level) {
    Severity.error => 0,
    Severity.warning => 1,
    Severity.info => 2,
    null => 3,
  };
}

final class _UsageException implements Exception {
  const _UsageException(this.message);
  final String message;
}

/// Parsed command-line arguments: repeatable `--name value` pairs, and bare
/// `--flag`s.
final class _Args {
  _Args._(this._values, this._flags);

  factory _Args.parse(List<String> args) {
    final values = <String, List<String>>{};
    final flags = <String>{};
    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      if (!arg.startsWith('--')) {
        throw _UsageException('unexpected argument `$arg`');
      }
      final name = arg.substring(2);
      if (name == 'fatal-infos') {
        flags.add(name);
        continue;
      }
      if (i + 1 >= args.length) {
        throw _UsageException('`$arg` needs a value');
      }
      values.putIfAbsent(name, () => []).add(args[++i]);
    }
    return _Args._(values, flags);
  }

  final Map<String, List<String>> _values;
  final Set<String> _flags;

  bool flag(String name) => _flags.contains(name);

  List<String> all(String name) => _values[name] ?? const [];

  String single(String name) {
    final values = all(name);
    if (values.length != 1) {
      throw _UsageException('`--$name` is required exactly once');
    }
    return values.single;
  }
}

/// Expands `@param_file` arguments (multiline format, one argument per line).
List<String> _expandParamFiles(List<String> args) {
  final expanded = <String>[];
  for (final arg in args) {
    if (arg.startsWith('@') && arg.length > 1) {
      final file = File(arg.substring(1));
      if (file.existsSync()) {
        for (final line in file.readAsLinesSync()) {
          if (line.isNotEmpty) {
            expanded.add(line);
          }
        }
        continue;
      }
    }
    expanded.add(arg);
  }
  return expanded;
}

// ---------------------------------------------------------------------------
// Bounded ResourceProvider confining upward ContextLocator directory walks.
// ---------------------------------------------------------------------------

/// Wraps an [fs.ResourceProvider] so `package:analyzer`'s `ContextLocatorImpl`,
/// `BlazeWorkspace.find`, and `PackageConfigWorkspace.find` cannot walk above
/// the action's declared roots (`primaryRoot` and `boundaryRoots`) or probe
/// ambient ancestor workspace/configuration files (`analysis_options.yaml`,
/// `pubspec.yaml`, `BUILD.gn`, `WORKSPACE`, `blaze-out`, `.dart_tool`, etc.).
final class BoundedResourceProvider implements fs.ResourceProvider {
  BoundedResourceProvider(
    this._delegate, {
    required String primaryRoot,
    Set<String> boundaryRoots = const {},
    Set<String> allowedFiles = const {},
    String? restrictedRoot,
    Set<String> extraRestrictedRoots = const {},
    Set<String>? allowedUnderRestrictedRoot,
    this.blockAnalysisOptions = false,
  }) : primaryRoot = _norm(_delegate.pathContext, primaryRoot),
       boundaryRoots = {
         _norm(_delegate.pathContext, primaryRoot),
         for (final r in boundaryRoots) _norm(_delegate.pathContext, r),
       },
       allowedFiles = {
         for (final f in allowedFiles) _norm(_delegate.pathContext, f),
       },
       restrictedRoot = restrictedRoot == null
           ? null
           : _norm(_delegate.pathContext, restrictedRoot),
       restrictedRoots = {
         if (restrictedRoot != null)
           _norm(_delegate.pathContext, restrictedRoot),
         for (final r in extraRestrictedRoots) _norm(_delegate.pathContext, r),
       },
       allowedUnderRestrictedRoot = _computeAllowedRestrictedPaths(
         _delegate.pathContext,
         {
           if (restrictedRoot != null)
             _norm(_delegate.pathContext, restrictedRoot),
           for (final r in extraRestrictedRoots)
             _norm(_delegate.pathContext, r),
         },
         allowedUnderRestrictedRoot,
       );

  static String _norm(p.Context ctx, String path) =>
      ctx.normalize(ctx.absolute(path));

  static Set<String>? _computeAllowedRestrictedPaths(
    p.Context ctx,
    Set<String> restrictedRoots,
    Set<String>? allowedUnderRestrictedRoot,
  ) {
    if (restrictedRoots.isEmpty || allowedUnderRestrictedRoot == null) {
      return null;
    }
    final result = <String>{...restrictedRoots};
    for (final raw in allowedUnderRestrictedRoot) {
      var cur = _norm(ctx, raw);
      while (true) {
        result.add(cur);
        if (restrictedRoots.contains(cur) ||
            !restrictedRoots.any((r) => ctx.isWithin(r, cur))) {
          break;
        }
        final parent = ctx.dirname(cur);
        if (parent == cur) break;
        cur = parent;
      }
    }
    return result;
  }

  final fs.ResourceProvider _delegate;
  final String primaryRoot;
  final Set<String> boundaryRoots;
  final Set<String> allowedFiles;
  final String? restrictedRoot;
  final Set<String> restrictedRoots;
  final Set<String>? allowedUnderRestrictedRoot;
  final bool blockAnalysisOptions;

  static const Set<String> _alwaysBlockedWorkspaceBasenames = {
    'BUILD.gn',
    'WORKSPACE',
    'WORKSPACE.bazel',
    'blaze-out',
    'blaze-bin',
    'blaze-genfiles',
    'READONLY',
  };

  static const Set<String> _ancestorProbeBasenames = {
    'analysis_options.yaml',
    '.analysis_options',
    'pubspec.yaml',
    '.packages',
    'package_config.json',
    '.dart_tool',
    'BUILD',
    'BUILD.bazel',
    'MODULE.bazel',
  };

  String _resolveToPrimaryRoot(String rawPath) {
    final ctx = pathContext;
    final norm = _norm(ctx, rawPath);
    if (ctx.style != p.context.style ||
        ctx.equals(primaryRoot, norm) ||
        ctx.isWithin(primaryRoot, norm)) {
      return norm;
    }
    return _reanchorThroughSymlink(primaryRoot, norm) ?? norm;
  }

  bool isBoundaryFolder(String normPath) =>
      boundaryRoots.contains(normPath) ||
      pathContext.isWithin(normPath, primaryRoot);

  bool isBlockedPath(String rawPath) {
    final ctx = pathContext;
    final normPath = _resolveToPrimaryRoot(rawPath);
    if (_isUnderRestrictedRoot(normPath)) return true;
    if (allowedFiles.contains(normPath)) return false;
    final base = ctx.basename(normPath);
    if (blockAnalysisOptions && _isBlockedOptionsBasename(base)) return true;
    if (ctx.equals(normPath, primaryRoot) ||
        ctx.isWithin(primaryRoot, normPath)) {
      return false;
    }
    return _isBlockedOutsidePrimary(normPath, base);
  }

  /// Whether [normPath] sits under a restricted root without an allowance.
  bool _isUnderRestrictedRoot(String normPath) {
    final ctx = pathContext;
    return restrictedRoots.isNotEmpty &&
        allowedUnderRestrictedRoot != null &&
        restrictedRoots.any((r) => ctx.isWithin(r, normPath)) &&
        !allowedUnderRestrictedRoot!.contains(normPath);
  }

  /// Whether [base] names an options file the analysis must not read.
  bool _isBlockedOptionsBasename(String base) =>
      base == _optionsBasename ||
      base == '.analysis_options' ||
      base == 'pubspec.yaml';

  /// Whether a path outside the primary root probes the workspace.
  bool _isBlockedOutsidePrimary(String normPath, String base) {
    final ctx = pathContext;
    if (_alwaysBlockedWorkspaceBasenames.contains(base)) return true;
    final parentDir = ctx.dirname(normPath);
    if (ctx.isWithin(parentDir, primaryRoot) ||
        boundaryRoots.contains(parentDir)) {
      return _isBlockedAncestorProbe(base, parentDir);
    }
    if (ctx.basename(parentDir) == '.dart_tool') {
      final grandParent = ctx.dirname(parentDir);
      return ctx.isWithin(grandParent, primaryRoot) ||
          boundaryRoots.contains(grandParent);
    }
    return false;
  }

  /// Whether [base] probes an ancestor directory for configuration.
  bool _isBlockedAncestorProbe(String base, String parentDir) {
    final ctx = pathContext;
    if (_ancestorProbeBasenames.contains(base)) return true;
    // Also block `<ancestor>/.dart_tool/package_config.json`.
    if (ctx.basename(parentDir) != '.dart_tool') return false;
    return ctx.isWithin(ctx.dirname(parentDir), primaryRoot) ||
        boundaryRoots.contains(ctx.dirname(parentDir));
  }

  @override
  p.Context get pathContext => _delegate.pathContext;

  @override
  fs.File getFile(String path) =>
      _BoundedFile(this, _delegate.getFile(_resolveToPrimaryRoot(path)));

  @override
  fs.Folder getFolder(String path) =>
      _BoundedFolder(this, _delegate.getFolder(_resolveToPrimaryRoot(path)));

  @override
  fs.Link getLink(String path) =>
      _delegate.getLink(_resolveToPrimaryRoot(path));

  @override
  fs.Resource getResource(String path) {
    final normPath = _resolveToPrimaryRoot(path);
    if (isBlockedPath(normPath)) {
      return _BoundedFile(this, _delegate.getFile(normPath));
    }
    final res = _delegate.getResource(normPath);
    if (res is fs.Folder) {
      return _BoundedFolder(this, res);
    }
    if (res is fs.File) {
      return _BoundedFile(this, res);
    }
    return res;
  }

  @override
  fs.Folder? getStateLocation(String pluginId) =>
      _delegate.getStateLocation(pluginId);
}

final class _BoundedFolder implements fs.Folder {
  const _BoundedFolder(this._provider, this._delegate);

  final BoundedResourceProvider _provider;
  final fs.Folder _delegate;

  String get _normPath =>
      BoundedResourceProvider._norm(_provider.pathContext, _delegate.path);

  @override
  bool get isRoot => _provider.isBoundaryFolder(_normPath) || _delegate.isRoot;

  @override
  fs.Folder get parent =>
      isRoot ? this : _BoundedFolder(_provider, _delegate.parent);

  @override
  bool get exists {
    if (_provider.isBlockedPath(_normPath)) return false;
    return _delegate.exists;
  }

  @override
  String get path => _delegate.path;

  @override
  fs.ResourceProvider get provider => _provider;

  @override
  String get shortName => _delegate.shortName;

  @override
  String canonicalizePath(String relPath) => _provider.pathContext.normalize(
    _provider.pathContext.join(path, relPath),
  );

  @override
  bool contains(String oPath) => _provider.pathContext.isWithin(
    path,
    _provider.pathContext.normalize(oPath),
  );

  @override
  fs.Folder copyTo(fs.Folder parentFolder) =>
      _BoundedFolder(_provider, _delegate.copyTo(parentFolder));

  @override
  void create() => _delegate.create();

  @override
  void delete() => _delegate.delete();

  @override
  fs.Resource getChild(String relPath) =>
      _provider.getResource(canonicalizePath(relPath));

  @override
  fs.File getChildAssumingFile(String relPath) => getFile(relPath);

  @override
  fs.Folder getChildAssumingFolder(String relPath) => getFolder(relPath);

  @override
  fs.File getFile(String relPath) =>
      _provider.getFile(canonicalizePath(relPath));

  @override
  fs.Folder getFolder(String relPath) =>
      _provider.getFolder(canonicalizePath(relPath));

  @override
  List<fs.Resource> getChildren() {
    if (_provider.isBlockedPath(_normPath)) return const [];
    return [
      for (final child in _delegate.getChildren())
        if (!_provider.isBlockedPath(child.path))
          if (child is fs.Folder)
            _BoundedFolder(_provider, child)
          else if (child is fs.File)
            _BoundedFile(_provider, child)
          else
            child,
    ];
  }

  @override
  bool isOrContains(String oPath) {
    final norm = _provider.pathContext.normalize(oPath);
    return path == norm || _provider.pathContext.isWithin(path, norm);
  }

  @override
  fs.Resource resolveSymbolicLinksSync() {
    final resolved = _delegate.resolveSymbolicLinksSync();
    if (resolved is fs.Folder) return _BoundedFolder(_provider, resolved);
    if (resolved is fs.File) return _BoundedFile(_provider, resolved);
    return resolved;
  }

  @override
  Uri toUri() => _delegate.toUri();

  @override
  fs.ResourceWatcher watch() => _delegate.watch();

  @override
  bool operator ==(Object other) => other is fs.Folder && path == other.path;

  @override
  int get hashCode => path.hashCode;
}

final class _BoundedFile implements fs.File {
  const _BoundedFile(this._provider, this._delegate);

  final BoundedResourceProvider _provider;
  final fs.File _delegate;

  bool get _isBlocked => _provider.isBlockedPath(_delegate.path);

  @override
  bool get exists {
    if (_isBlocked) return false;
    return _delegate.exists;
  }

  @override
  int get lengthSync {
    if (_isBlocked) {
      throw fs.FileSystemException(path, 'File does not exist');
    }
    return _delegate.lengthSync;
  }

  @override
  int get modificationStamp {
    if (_isBlocked) {
      throw fs.FileSystemException(path, 'File does not exist');
    }
    return _delegate.modificationStamp;
  }

  @override
  fs.Folder get parent => _BoundedFolder(_provider, _delegate.parent);

  @override
  String get path => _delegate.path;

  @override
  fs.ResourceProvider get provider => _provider;

  @override
  String get shortName => _delegate.shortName;

  @override
  fs.File copyTo(fs.Folder parentFolder) =>
      _BoundedFile(_provider, _delegate.copyTo(parentFolder));

  @override
  void delete() => _delegate.delete();

  @override
  bool isOrContains(String path) => _delegate.isOrContains(path);

  @override
  Uint8List readAsBytesSync() {
    if (_isBlocked) {
      throw fs.FileSystemException(path, 'File does not exist');
    }
    return _delegate.readAsBytesSync();
  }

  @override
  String readAsStringSync() {
    if (_isBlocked) {
      throw fs.FileSystemException(path, 'File does not exist');
    }
    return _delegate.readAsStringSync();
  }

  @override
  fs.File renameSync(String newPath) =>
      _BoundedFile(_provider, _delegate.renameSync(newPath));

  @override
  fs.Resource resolveSymbolicLinksSync() {
    if (_isBlocked) {
      throw fs.FileSystemException(path, 'File does not exist');
    }
    final resolved = _delegate.resolveSymbolicLinksSync();
    if (resolved is fs.File) return _BoundedFile(_provider, resolved);
    if (resolved is fs.Folder) return _BoundedFolder(_provider, resolved);
    return resolved;
  }

  @override
  Uri toUri() => _delegate.toUri();

  @override
  fs.ResourceWatcher watch() => _delegate.watch();

  @override
  void writeAsBytesSync(List<int> bytes) => _delegate.writeAsBytesSync(bytes);

  @override
  void writeAsStringSync(String content) =>
      _delegate.writeAsStringSync(content);

  @override
  bool operator ==(Object other) => other is fs.File && path == other.path;

  @override
  int get hashCode => path.hashCode;
}

// ---------------------------------------------------------------------------
// Per-worker `.sum` byte cache and ResourceProvider wrapper.
// ---------------------------------------------------------------------------

final class _CachedSumEntry {
  _CachedSumEntry({required this.bytes, required this.digest});

  final Uint8List bytes;
  final Uint8List? digest;
}

/// Caches `.sum` bundle bytes (`Uint8List`) across worker requests, keyed by
/// normalized absolute path and validated via `WorkRequest.inputs` digests (or
/// reading fresh bytes from disk when no digest is provided).
///
/// The 256 MB total summary cache budget is scaled across the worker pool
/// (`defaultWorkerInstances = 4` -> 64 MB per worker instance by default), and
/// all stored byte arrays and digests are unpinned from `WorkRequest` buffers.
///
/// Never caches `.dart`, `.yaml`, or `.json` files: those always go directly to
/// `PhysicalResourceProvider.INSTANCE`.
final class SummaryByteCache {
  SummaryByteCache({
    int? maxCacheBytes,
    this.totalBudgetBytes = defaultTotalBudgetBytes,
    int workerInstances = defaultWorkerInstances,
  }) : workerInstances = workerInstances < 1 ? 1 : workerInstances,
       maxCacheBytes =
           maxCacheBytes ??
           (totalBudgetBytes ~/ (workerInstances < 1 ? 1 : workerInstances));

  /// Total summary byte-cache budget across all concurrent worker instances
  /// for the `DartAnalyzerSummary` mnemonic (256 MB).
  static const int defaultTotalBudgetBytes = 256 * 1024 * 1024;

  /// Default Bazel persistent-worker pool size (`--worker_max_instances=4`).
  static const int defaultWorkerInstances = 4;

  /// Per-worker-process summary byte-cache limit (64 MB when 4 worker
  /// instances share the 256 MB total budget).
  static const int defaultMaxCacheBytes =
      defaultTotalBudgetBytes ~/ defaultWorkerInstances;

  final int totalBudgetBytes;
  final int workerInstances;
  final int maxCacheBytes;

  // LinkedHashMap preserves insertion order for simple LRU eviction.
  final Map<String, _CachedSumEntry> _entries = <String, _CachedSumEntry>{};
  final Map<String, Uint8List> _currentInputDigests = <String, Uint8List>{};
  int _totalBytes = 0;

  int get totalBytes => _totalBytes;
  int get entryCount => _entries.length;

  static Uint8List _unpin(Uint8List bytes) =>
      bytes.buffer.lengthInBytes == bytes.lengthInBytes
      ? bytes
      : Uint8List.fromList(bytes);

  void beginRequest(Map<String, Uint8List> requestInputs) {
    _currentInputDigests.clear();
    for (final entry in requestInputs.entries) {
      if (entry.key.endsWith('.sum') && entry.value.isNotEmpty) {
        _currentInputDigests[p.normalize(p.absolute(entry.key))] = _unpin(
          entry.value,
        );
      }
    }
  }

  Uint8List readBytes(fs.File delegate) {
    final path = p.normalize(p.absolute(delegate.path));
    final reqDigest = _currentInputDigests[path];
    final hasReqDigest = reqDigest != null && reqDigest.isNotEmpty;
    final existing = _entries.remove(path);

    if (existing != null) {
      final hasExistingDigest =
          existing.digest != null && existing.digest!.isNotEmpty;
      if (hasReqDigest && hasExistingDigest) {
        if (_bytesEqual(reqDigest, existing.digest!)) {
          // Re-insert as most-recently-used.
          _entries[path] = existing;
          return existing.bytes;
        }
      }
      _totalBytes -= existing.bytes.length;
    }

    final bytes = _unpin(delegate.readAsBytesSync());
    if (bytes.length <= maxCacheBytes) {
      while (_totalBytes + bytes.length > maxCacheBytes &&
          _entries.isNotEmpty) {
        final oldestKey = _entries.keys.first;
        final removed = _entries.remove(oldestKey)!;
        _totalBytes -= removed.bytes.length;
      }
      _entries[path] = _CachedSumEntry(
        bytes: bytes,
        digest: hasReqDigest ? _unpin(reqDigest) : null,
      );
      _totalBytes += bytes.length;
    }
    return bytes;
  }

  static bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Wraps [PhysicalResourceProvider.INSTANCE] to intercept `readAsBytesSync()`
/// on `.sum` files only. All `.dart` sources, `analysis_options.yaml`, and
/// `package_config.json` files return the underlying physical `fs.File`
/// directly with zero cross-request caching.
final class SummaryCachingResourceProvider implements fs.ResourceProvider {
  const SummaryCachingResourceProvider(this._delegate, this._cache);

  final fs.ResourceProvider _delegate;
  final SummaryByteCache _cache;

  @override
  p.Context get pathContext => _delegate.pathContext;

  @override
  fs.File getFile(String path) {
    final file = _delegate.getFile(path);
    if (path.endsWith('.sum')) {
      return _CachedSummaryFile(file, _cache);
    }
    return file;
  }

  @override
  fs.Folder getFolder(String path) => _delegate.getFolder(path);

  @override
  fs.Link getLink(String path) => _delegate.getLink(path);

  @override
  fs.Resource getResource(String path) => _delegate.getResource(path);

  @override
  fs.Folder? getStateLocation(String pluginId) =>
      _delegate.getStateLocation(pluginId);
}

final class _CachedSummaryFile implements fs.File {
  const _CachedSummaryFile(this._delegate, this._cache);

  final fs.File _delegate;
  final SummaryByteCache _cache;

  @override
  Uint8List readAsBytesSync() => _cache.readBytes(_delegate);

  @override
  bool get exists => _delegate.exists;

  @override
  int get lengthSync => _delegate.lengthSync;

  @override
  int get modificationStamp => _delegate.modificationStamp;

  @override
  fs.Folder get parent => _delegate.parent;

  @override
  String get path => _delegate.path;

  @override
  fs.ResourceProvider get provider => _delegate.provider;

  @override
  String get shortName => _delegate.shortName;

  @override
  fs.File copyTo(fs.Folder parentFolder) => _delegate.copyTo(parentFolder);

  @override
  void delete() => _delegate.delete();

  @override
  bool isOrContains(String path) => _delegate.isOrContains(path);

  @override
  String readAsStringSync() => _delegate.readAsStringSync();

  @override
  fs.File renameSync(String newPath) => _delegate.renameSync(newPath);

  @override
  fs.Resource resolveSymbolicLinksSync() =>
      _delegate.resolveSymbolicLinksSync();

  @override
  Uri toUri() => _delegate.toUri();

  @override
  fs.ResourceWatcher watch() => _delegate.watch();

  @override
  void writeAsBytesSync(List<int> bytes) => _delegate.writeAsBytesSync(bytes);

  @override
  void writeAsStringSync(String content) =>
      _delegate.writeAsStringSync(content);

  @override
  bool operator ==(Object other) => other is fs.File && path == other.path;

  @override
  int get hashCode => path.hashCode;
}

// ---------------------------------------------------------------------------
// Bazel worker protocol (`blaze.worker.WorkRequest` / `WorkResponse`)
// ---------------------------------------------------------------------------

/// Decodes the `inputs` map from a raw `WorkRequest` protobuf payload,
/// copying each digest out of [bytes] so the request buffer is not pinned.
Map<String, Uint8List> decodeAnalyzerWorkRequestInputs(Uint8List bytes) =>
    _WorkRequest.read(bytes).inputs;

final class _WorkRequest {
  const _WorkRequest({
    required this.arguments,
    required this.inputs,
    required this.requestId,
    required this.cancel,
  });

  factory _WorkRequest.read(Uint8List bytes) {
    final arguments = <String>[];
    final inputs = <String, Uint8List>{};
    var requestId = 0;
    var cancel = false;
    final r = _Reader(bytes);
    while (!r.isDone) {
      final tag = r.varint();
      switch (tag >> 3) {
        case 1:
          arguments.add(r.string());
        case 2:
          final nested = r.submessage();
          var path = '';
          var digest = Uint8List(0);
          while (!nested.isDone) {
            final inputTag = nested.varint();
            switch (inputTag >> 3) {
              case 1:
                path = nested.string();
              case 2:
                digest = Uint8List.fromList(nested.bytes());
              default:
                nested.skip(inputTag & 7);
            }
          }
          if (path.isNotEmpty) {
            inputs[path] = digest;
          }
        case 3:
          requestId = r.varint();
        case 4:
          cancel = r.varint() != 0;
        default:
          r.skip(tag & 7);
      }
    }
    return _WorkRequest(
      arguments: arguments,
      inputs: inputs,
      requestId: requestId,
      cancel: cancel,
    );
  }

  final List<String> arguments;
  final Map<String, Uint8List> inputs;
  final int requestId;
  final bool cancel;
}

final class _WorkResponse {
  const _WorkResponse({
    required this.exitCode,
    required this.output,
    required this.requestId,
  });

  final int exitCode;
  final String output;
  final int requestId;

  Uint8List write() {
    final body = _Writer();
    if (exitCode != 0) {
      body
        ..varint((1 << 3) | 0)
        ..varint(exitCode);
    }
    if (output.isNotEmpty) {
      final utf8Bytes = utf8.encode(output);
      body
        ..varint((2 << 3) | 2)
        ..varint(utf8Bytes.length)
        ..raw(utf8Bytes);
    }
    if (requestId != 0) {
      body
        ..varint((3 << 3) | 0)
        ..varint(requestId);
    }
    final payload = body.takeBytes();
    final frame = _Writer()
      ..varint(payload.length)
      ..raw(payload);
    return frame.takeBytes();
  }
}

final class _Frames extends Stream<Uint8List> {
  _Frames(this._source);

  final Stream<List<int>> _source;

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    final controller = StreamController<Uint8List>();
    var buf = Uint8List(0);
    late final StreamSubscription<List<int>> sub;
    sub = _source.listen(
      (chunk) {
        final merged = Uint8List(buf.length + chunk.length);
        merged.setRange(0, buf.length, buf);
        merged.setRange(buf.length, merged.length, chunk);
        buf = merged;
        while (true) {
          var len = 0;
          var shift = 0;
          var pos = 0;
          while (true) {
            if (pos >= buf.length) return;
            final b = buf[pos++];
            len |= (b & 0x7f) << shift;
            if ((b & 0x80) == 0) break;
            shift += 7;
          }
          if (buf.length < pos + len) return;
          final frame = Uint8List.fromList(
            Uint8List.sublistView(buf, pos, pos + len),
          );
          final nextStart = pos + len;
          buf = nextStart == buf.length
              ? Uint8List(0)
              : Uint8List.fromList(Uint8List.sublistView(buf, nextStart));
          controller.add(frame);
        }
      },
      onError: controller.addError,
      onDone: controller.close,
      cancelOnError: cancelOnError,
    );
    controller
      ..onPause = sub.pause
      ..onResume = sub.resume
      ..onCancel = sub.cancel;
    return controller.stream.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }
}

final class _Reader {
  _Reader(this._buf);

  final Uint8List _buf;
  int _pos = 0;

  bool get isDone => _pos >= _buf.length;

  int varint() {
    var result = 0;
    var shift = 0;
    while (true) {
      final b = _buf[_pos++];
      result |= (b & 0x7f) << shift;
      if ((b & 0x80) == 0) return result;
      shift += 7;
    }
  }

  Uint8List bytes() {
    final len = varint();
    final slice = Uint8List.sublistView(_buf, _pos, _pos + len);
    _pos += len;
    return slice;
  }

  String string() => utf8.decode(bytes());

  _Reader submessage() => _Reader(bytes());

  void skip(int wireType) {
    switch (wireType) {
      case 0:
        varint();
      case 1:
        _pos += 8;
      case 2:
        _pos += varint();
      case 5:
        _pos += 4;
      default:
        throw FormatException('unsupported wire type: $wireType');
    }
  }
}

final class _Writer {
  final _buf = BytesBuilder(copy: false);

  void varint(int value) {
    var v = value;
    while (v < 0 || v >= 0x80) {
      _buf.addByte((v & 0x7f) | 0x80);
      v = v >>> 7;
    }
    _buf.addByte(v);
  }

  void raw(List<int> bytes) => _buf.add(bytes);

  Uint8List takeBytes() => _buf.takeBytes();
}
