import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:analyzer/diagnostic/diagnostic.dart' show Severity;
import 'package:analyzer/file_system/file_system.dart' as fs;
import 'package:analyzer/file_system/memory_file_system.dart';
import 'package:analyzer/file_system/physical_file_system.dart';
import 'package:analyzer/src/source/package_map_resolver.dart'
    show PackageMapUriResolver;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'analysis_baseline.dart' show AnalysisBaseline, BaselineException;
import 'analysis_model.dart' show AnalysisFinding;
import 'analyzer_summary.dart'
    show
        BoundedResourceProvider,
        SummaryByteCache,
        SummaryCachingResourceProvider,
        disposedContextCollectionsCount,
        inferSummarizeRoot,
        onContextCollectionDisposed,
        reportAnalyzeFindings,
        resolveProjectSource,
        runSingleRequest;
import 'analyzer_summary_test_support.dart'
    show
        defineDisposeTearDownTests,
        defineSummaryByteCacheTests,
        defineSummaryTripleQuotedImportGuardTest;

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('analyzer_summary_test_');
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  group('BoundedResourceProvider', () {
    test('stops upward folder walks at primaryRoot and blocks ancestor probes without statting disk', () {
      final ancestor1 = Directory(p.join(tempDir.path, 'ancestor1'))
        ..createSync();
      final ancestor2 = Directory(p.join(ancestor1.path, 'ancestor2'))
        ..createSync();
      final project = Directory(p.join(ancestor2.path, 'project'))
        ..createSync();
      final srcDir = Directory(p.join(project.path, 'src', 'lib'))
        ..createSync(recursive: true);

      // Plant poison config/workspace files in ancestor directories.
      final poisonOptions = File(
        p.join(ancestor2.path, 'analysis_options.yaml'),
      )..writeAsStringSync('analyzer:\n  exclude:\n    - "**"\n');
      final poisonPubspec = File(p.join(ancestor1.path, 'pubspec.yaml'))
        ..writeAsStringSync('name: poison_pkg\n');
      final poisonWorkspace = File(p.join(ancestor1.path, 'WORKSPACE'))
        ..writeAsStringSync('');
      final poisonBuildGn = File(p.join(ancestor2.path, 'BUILD.gn'))
        ..writeAsStringSync('');
      final poisonDartTool = Directory(p.join(ancestor2.path, '.dart_tool'))
        ..createSync();
      final poisonPkgConfig = File(
        p.join(poisonDartTool.path, 'package_config.json'),
      )..writeAsStringSync('{"configVersion": 2, "packages": []}');

      final projectOptions = File(p.join(project.path, 'analysis_options.yaml'))
        ..writeAsStringSync('linter:\n  rules: []\n');
      final srcFile = File(p.join(srcDir.path, 'a.dart'))
        ..writeAsStringSync('int x = 1;\n');

      final recorder = RecordingResourceProvider(
        PhysicalResourceProvider.INSTANCE,
      );
      final bounded = BoundedResourceProvider(
        recorder,
        primaryRoot: project.path,
        boundaryRoots: {project.path},
        allowedFiles: {srcFile.path, projectOptions.path},
        blockAnalysisOptions: false,
      );

      // Walking upward from srcFile via `.parent` / `isRoot` must stop at `project`.
      final visitedFolders = <String>[];
      var current = bounded.getFile(srcFile.path).parent;
      while (true) {
        visitedFolders.add(p.normalize(p.absolute(current.path)));
        if (current.isRoot) break;
        current = current.parent;
      }
      expect(visitedFolders, [
        p.normalize(p.absolute(srcDir.path)),
        p.normalize(p.absolute(p.join(project.path, 'src'))),
        p.normalize(p.absolute(project.path)),
      ]);
      expect(
        visitedFolders,
        isNot(contains(p.normalize(p.absolute(ancestor2.path)))),
      );
      expect(
        visitedFolders,
        isNot(contains(p.normalize(p.absolute(ancestor1.path)))),
      );

      // Directly probing poison ancestor files returns false in memory and
      // never reaches the underlying recording provider.
      recorder.checkedPaths.clear();
      expect(bounded.getFile(poisonOptions.path).exists, isFalse);
      expect(bounded.getFile(poisonPubspec.path).exists, isFalse);
      expect(bounded.getFile(poisonWorkspace.path).exists, isFalse);
      expect(bounded.getFile(poisonBuildGn.path).exists, isFalse);
      expect(bounded.getFile(poisonPkgConfig.path).exists, isFalse);
      expect(bounded.getFolder(poisonDartTool.path).exists, isFalse);
      expect(
        recorder.checkedPaths,
        isEmpty,
        reason: 'blocked ancestor paths must not trigger physical stat calls',
      );

      // Staged project's own analysis_options.yaml is allowed in analyze mode.
      expect(bounded.getFile(projectOptions.path).exists, isTrue);

      // In summarize mode (`blockAnalysisOptions: true`), even an
      // analysis_options.yaml or pubspec.yaml inside primaryRoot is blocked.
      final projectPubspec = File(p.join(project.path, 'pubspec.yaml'))
        ..writeAsStringSync('name: project_pkg\n');
      final unlistedFile = File(p.join(srcDir.path, 'unlisted.dart'))
        ..writeAsStringSync('int unlisted = 2;\n');
      final summarizeBounded = BoundedResourceProvider(
        recorder,
        primaryRoot: project.path,
        boundaryRoots: {project.path},
        allowedFiles: {srcFile.path},
        restrictedRoot: srcDir.path,
        allowedUnderRestrictedRoot: {srcFile.path},
        blockAnalysisOptions: true,
      );
      recorder.checkedPaths.clear();
      expect(summarizeBounded.getFile(projectOptions.path).exists, isFalse);
      expect(summarizeBounded.getFile(projectPubspec.path).exists, isFalse);
      expect(summarizeBounded.getFile(unlistedFile.path).exists, isFalse);
      expect(recorder.checkedPaths, isEmpty);
      expect(summarizeBounded.getFile(srcFile.path).exists, isTrue);
      final childrenPaths = [
        for (final c in summarizeBounded.getFolder(srcDir.path).getChildren())
          p.normalize(p.absolute(c.path)),
      ];
      expect(childrenPaths, [p.normalize(p.absolute(srcFile.path))]);
    });

    test('canonicalizes slash-separated relative paths under p.windows so PackageMapUriResolver matches nested lib/ sources', () {
      final winCtx = p.Context(
        style: p.Style.windows,
        current: r'D:\_bazel\execroot\_main',
      );
      final memory = MemoryResourceProvider(context: winCtx);

      // Reproduce the three Windows nested-lib failure shapes:
      // 1. //dart/tests/analyze_aspect_fixture/nested:nested -> lib/loud/loud.dart
      // 2. e2e/dart_test_pkg //:sib_b -> lib/sib/b.dart
      // 3. e2e/ext_exemplar //go_router/_go_router_stub:go_router_stub -> lib/src/route_data.dart
      final cases = <({String pkg, String stageRel, String libSubpath})>[
        (
          pkg: 'nested',
          stageRel: 'bazel-out/x64_windows-fastbuild/bin/dart/tests/analyze_aspect_fixture/nested/_nested.analyze',
          libSubpath: 'loud/loud.dart',
        ),
        (
          pkg: 'dart_test_pkg',
          stageRel: 'bazel-out/x64_windows-fastbuild/bin/_sib_b.analyze',
          libSubpath: 'sib/b.dart',
        ),
        (
          pkg: 'go_router_stub',
          stageRel: 'bazel-out/x64_windows-fastbuild/bin/go_router/_go_router_stub/_go_router_stub.analyze',
          libSubpath: 'src/route_data.dart',
        ),
      ];

      for (final c in cases) {
        final projectDir = winCtx.normalize(winCtx.absolute(c.stageRel));
        final srcArg = '${c.stageRel}/src/lib/${c.libSubpath}';
        final resolvedSource = resolveProjectSource(
          projectDir,
          srcArg,
          pathContext: winCtx,
        );
        final resolvedRelSource = resolveProjectSource(
          projectDir,
          'src/lib/${c.libSubpath}',
          pathContext: winCtx,
        );
        expect(resolvedRelSource, resolvedSource);
        expect(
          resolvedSource,
          isNot(contains('/')),
          reason: 'resolved Windows source path must use only backslashes',
        );

        memory.newFile(resolvedSource, 'class C {}\n');

        final libDir = winCtx.join(projectDir, 'src', 'lib');
        final summarizeRoot = inferSummarizeRoot(
          [resolvedSource],
          ['package:${c.pkg}/${c.libSubpath}'],
          pathContext: winCtx,
        );
        expect(summarizeRoot, libDir);

        final bounded = BoundedResourceProvider(
          memory,
          primaryRoot: projectDir,
          boundaryRoots: {projectDir},
          allowedFiles: {resolvedSource},
          restrictedRoot: libDir,
          allowedUnderRestrictedRoot: {resolvedSource},
          blockAnalysisOptions: false,
        );

        final libFolder = bounded.getFolder(libDir);
        // PackageMapUriResolver joins URI segments with '/' and passes the
        // slash-separated subpath (e.g. 'loud/loud.dart') to getFile().
        final viaGetFile = libFolder.getFile(c.libSubpath);
        final viaGetChild = libFolder.getChild(c.libSubpath);
        final parentRel = c.libSubpath.split('/').first;
        final viaGetFolder = libFolder.getFolder('$parentRel/nested_dir');

        expect(viaGetFile.path, resolvedSource);
        expect(viaGetFile.exists, isTrue);
        expect(viaGetChild.path, resolvedSource);
        expect(viaGetFolder.path, isNot(contains('/')));

        final resolver = PackageMapUriResolver(bounded, {c.pkg: libFolder});
        final pkgUri = Uri.parse('package:${c.pkg}/${c.libSubpath}');
        final resolvedUriSource = resolver.resolveAbsolute(pkgUri);
        expect(resolvedUriSource, isNotNull);
        expect(
          resolvedUriSource!.fullName,
          resolvedSource,
          reason: 'PackageMapUriResolver source fullName must match resolvedSource so driver.getErrors does not return NotPathOfUriResult',
        );
        expect(
          resolver.pathToUri(resolvedSource),
          pkgUri,
          reason: 'pathToUri round-trip must recover the package: URI',
        );
      }
    });
  });

  defineSummaryByteCacheTests(() => tempDir);

  group('AnalysisContextCollectionImpl disposal and worker cache eviction', () {
    test('drives several summarize and analyze requests through the same worker cache instance, exercising eviction and context disposal', () async {
      final sdkDir = File(Platform.resolvedExecutable).parent.parent;
      final sdkSummary = File(p.join(tempDir.path, 'sdk.sum'));
      final outSink = StringBuffer();
      final errSink = StringBuffer();

      expect(
        await runSingleRequest(
          ['sdk', '--sdk', sdkDir.path, '--out', sdkSummary.path],
          outSink: outSink,
          errSink: errSink,
          resourceProvider: PhysicalResourceProvider.INSTANCE,
        ),
        0,
        reason: errSink.toString(),
      );

      final sdkSumBytes = sdkSummary.lengthSync();
      final disposedRoots = <List<String>>[];
      final prevHook = onContextCollectionDisposed;
      final beforeCount = disposedContextCollectionsCount;
      onContextCollectionDisposed = (collection) {
        disposedRoots.add([
          for (final ctx in collection.contexts) ctx.contextRoot.root.path,
        ]);
      };
      try {
        // Summarize three packages (pkg_0, pkg_1, pkg_2), then analyze pkg_app
        // against all three summaries through the same SummaryByteCache and
        // SummaryCachingResourceProvider instance.
        final pkgDirs = <Directory>[];
        final sumFiles = <File>[];
        for (var i = 0; i < 3; i++) {
          final pkgDir = Directory(p.join(tempDir.path, 'pkg_$i'))
            ..createSync(recursive: true);
          pkgDirs.add(pkgDir);
          final src = File(p.join(pkgDir.path, 'lib', 'p$i.dart'))
            ..parent.createSync(recursive: true)
            ..writeAsStringSync('class P$i {\n  final int value$i = $i;\n}\n');
          final pkgConfig = File(p.join(pkgDir.path, 'package_config.json'))
            ..writeAsStringSync(
              jsonEncode({
                'configVersion': 2,
                'packages': [
                  {
                    'name': 'pkg_$i',
                    'rootUri': p.toUri(pkgDir.path).toString(),
                    'packageUri': 'lib/',
                    'languageVersion': '3.0',
                  },
                ],
              }),
            );
          final sumFile = File(p.join(tempDir.path, 'pkg_$i.sum'));
          sumFiles.add(sumFile);

          expect(
            await runSingleRequest(
              [
                'summarize',
                '--sdk',
                sdkDir.path,
                '--sdk-summary',
                sdkSummary.path,
                '--packages',
                pkgConfig.path,
                '--source',
                src.path,
                '--uri',
                'package:pkg_$i/p$i.dart',
                '--out',
                sumFile.path,
              ],
              outSink: outSink,
              errSink: errSink,
              resourceProvider: PhysicalResourceProvider.INSTANCE,
            ),
            0,
            reason: errSink.toString(),
          );
          await pumpEventQueue();
        }
        expect(disposedContextCollectionsCount, beforeCount + 3);

        // Size the shared worker cache so it fits sdk.sum plus at most ONE
        // package summary at a time, forcing LRU eviction as requests read
        // pkg_0.sum, pkg_1.sum, and pkg_2.sum.
        final maxPkgSumBytes = [for (final f in sumFiles) f.lengthSync()]
            .reduce((a, b) => a > b ? a : b);
        final minPkgSumBytes = [for (final f in sumFiles) f.lengthSync()]
            .reduce((a, b) => a < b ? a : b);
        final cacheBudget =
            sdkSumBytes + maxPkgSumBytes + (minPkgSumBytes ~/ 2);
        final workerCache = SummaryByteCache(maxCacheBytes: cacheBudget);
        final workerProvider = SummaryCachingResourceProvider(
          PhysicalResourceProvider.INSTANCE,
          workerCache,
        );

        // Drive two sequential analyze requests through the same workerProvider.
        for (var reqIdx = 0; reqIdx < 2; reqIdx++) {
          final appDir = Directory(p.join(tempDir.path, 'pkg_app_$reqIdx'))
            ..createSync(recursive: true);
          final srcApp = File(p.join(appDir.path, 'lib', 'app.dart'))
            ..parent.createSync(recursive: true)
            ..writeAsStringSync(
              "import 'package:pkg_0/p0.dart';\n"
              "import 'package:pkg_1/p1.dart';\n"
              "import 'package:pkg_2/p2.dart';\n"
              'int sumAll(P0 a, P1 b, P2 c) => a.value0 + b.value1 + c.value2;\n',
            );
          File(p.join(appDir.path, '.dart_tool', 'package_config.json'))
            ..parent.createSync(recursive: true)
            ..writeAsStringSync(
              jsonEncode({
                'configVersion': 2,
                'packages': [
                  for (var i = 0; i < 3; i++)
                    {
                      'name': 'pkg_$i',
                      'rootUri': p.toUri(pkgDirs[i].path).toString(),
                      'packageUri': 'lib/',
                      'languageVersion': '3.0',
                    },
                  {
                    'name': 'pkg_app_$reqIdx',
                    'rootUri': p.toUri(appDir.path).toString(),
                    'packageUri': 'lib/',
                    'languageVersion': '3.0',
                  },
                ],
              }),
            );

          workerCache.beginRequest({
            sdkSummary.path: Uint8List.fromList([10]),
            for (var i = 0; i < 3; i++)
              sumFiles[i].path: Uint8List.fromList([20 + i]),
          });
          expect(
            await runSingleRequest(
              [
                'analyze',
                '--sdk',
                sdkDir.path,
                '--sdk-summary',
                sdkSummary.path,
                for (final sum in sumFiles) ...['--summary', sum.path],
                '--project',
                appDir.path,
                '--source',
                srcApp.path,
                '--stamp',
                p.join(tempDir.path, 'pkg_app_$reqIdx.analyzed'),
              ],
              outSink: outSink,
              errSink: errSink,
              resourceProvider: workerProvider,
            ),
            0,
            reason: '${outSink.toString()}\n${errSink.toString()}',
          );
          await pumpEventQueue();
          expect(
            workerCache.totalBytes,
            lessThanOrEqualTo(cacheBudget),
            reason: 'SummaryByteCache must stay within maxCacheBytes after eviction',
          );
          // 4 summaries were read (sdk.sum + 3 pkg summaries), but budget only
          // fits at most 2 of them at once.
          expect(workerCache.entryCount, lessThanOrEqualTo(2));
        }

        expect(disposedContextCollectionsCount, beforeCount + 5);
        expect(disposedRoots.length, 5);
      } finally {
        onContextCollectionDisposed = prevHook;
      }
    });

    defineDisposeTearDownTests();

    test('handles symlinked staging roots for nested lib/ sources and fails closed with result type on NotPathOfUriResult', () async {
      final sdkDir = File(Platform.resolvedExecutable).parent.parent;
      final realBase = Directory(p.join(tempDir.path, 'real_execroot'))
        ..createSync(recursive: true);
      final symlinkBase = Link(p.join(tempDir.path, 'symlink_execroot'))
        ..createSync(realBase.path);

      final sdkSummary = File(p.join(symlinkBase.path, 'sdk.sum'));
      final outSink = StringBuffer();
      final errSink = StringBuffer();

      expect(
        await runSingleRequest(
          ['sdk', '--sdk', sdkDir.path, '--out', sdkSummary.path],
          outSink: outSink,
          errSink: errSink,
          resourceProvider: PhysicalResourceProvider.INSTANCE,
        ),
        0,
        reason: errSink.toString(),
      );

      // Build a staged nested package through the symlinked execroot path.
      final realLibFile = File(
        p.join(realBase.path, 'workspace', 'lib', 'loud', 'loud.dart'),
      )..parent.createSync(recursive: true);
      realLibFile.writeAsStringSync('int loudValue() => 42;\n');

      final stageAnalyze = Directory(
        p.join(symlinkBase.path, 'bazel-out', '_nested.analyze'),
      );
      final stagedLibFile = Link(
        p.join(stageAnalyze.path, 'src', 'lib', 'loud', 'loud.dart'),
      )..parent.createSync(recursive: true);
      stagedLibFile.createSync(realLibFile.path);

      File(p.join(stageAnalyze.path, '.dart_tool', 'package_config.json'))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(
          jsonEncode({
            'configVersion': 2,
            'packages': [
              {
                'name': 'nested',
                'rootUri': '../src',
                'packageUri': 'lib/',
                'languageVersion': '3.0',
              },
            ],
          }),
        );

      final nestedSummary = File(p.join(symlinkBase.path, 'nested.sum'));
      expect(
        await runSingleRequest(
          [
            'summarize',
            '--sdk',
            sdkDir.path,
            '--sdk-summary',
            sdkSummary.path,
            '--packages',
            p.join(stageAnalyze.path, '.dart_tool', 'package_config.json'),
            '--source',
            stagedLibFile.path,
            '--uri',
            'package:nested/loud/loud.dart',
            '--out',
            nestedSummary.path,
          ],
          outSink: outSink,
          errSink: errSink,
          resourceProvider: PhysicalResourceProvider.INSTANCE,
        ),
        0,
        reason: errSink.toString(),
      );

      // Analyze the staged nested package cleanly through the symlinked root.
      final cleanStamp = File(p.join(symlinkBase.path, 'nested.analyzed'));
      outSink.clear();
      errSink.clear();
      expect(
        await runSingleRequest(
          [
            'analyze',
            '--sdk',
            sdkDir.path,
            '--sdk-summary',
            sdkSummary.path,
            '--project',
            stageAnalyze.path,
            '--source',
            stagedLibFile.path,
            '--stamp',
            cleanStamp.path,
          ],
          outSink: outSink,
          errSink: errSink,
          resourceProvider: PhysicalResourceProvider.INSTANCE,
        ),
        0,
        reason: '${outSink.toString()}\n${errSink.toString()}',
      );
      expect(cleanStamp.existsSync(), isTrue);

      // Now pass nested.sum as an input `--summary` while ALSO analyzing the
      // same package's `src/lib/loud/loud.dart`: InSummaryUriResolver claims
      // `package:nested/loud/loud.dart`, causing `driver.getErrors` to return
      // `NotPathOfUriResult`. Verify `analyze` fails closed and includes the
      // result runtimeType in the error message.
      final failStamp = File(p.join(symlinkBase.path, 'nested_fail.analyzed'));
      outSink.clear();
      errSink.clear();
      expect(
        await runSingleRequest(
          [
            'analyze',
            '--sdk',
            sdkDir.path,
            '--sdk-summary',
            sdkSummary.path,
            '--summary',
            nestedSummary.path,
            '--project',
            stageAnalyze.path,
            '--source',
            stagedLibFile.path,
            '--stamp',
            failStamp.path,
          ],
          outSink: outSink,
          errSink: errSink,
          resourceProvider: PhysicalResourceProvider.INSTANCE,
        ),
        1,
      );
      expect(failStamp.existsSync(), isFalse);
      expect(errSink.toString(), contains('analyzer_summary: cannot analyze '));
      expect(errSink.toString(), contains('(NotPathOfUriResult)'));

      // Verify a staged test/executable project without `src/lib/` on disk
      // resolves relative `../lib/...` imports and exports against the
      // dependency summary (`nested.sum`), and still reports `uri_does_not_exist`
      // for a nonexistent relative `../lib/...` target.
      final stageTestAnalyze = Directory(
        p.join(symlinkBase.path, 'bazel-out', '_nested_test.analyze'),
      );
      File(p.join(stageTestAnalyze.path, '.dart_tool', 'package_config.json'))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(
          jsonEncode({
            'configVersion': 2,
            'packages': [
              {
                'name': 'nested',
                'rootUri': '../src',
                'packageUri': 'lib/',
                'languageVersion': '3.0',
              },
            ],
          }),
        );
      final stagedTestFile = File(
        p.join(stageTestAnalyze.path, 'src', 'test', 'loud_test.dart'),
      )..parent.createSync(recursive: true);
      stagedTestFile.writeAsStringSync('''
import '../lib/loud/loud.dart';
export '../lib/loud/loud.dart';

int checkLoud() => loudValue();
''');
      final relImportStamp = File(
        p.join(symlinkBase.path, 'nested_rel_import.analyzed'),
      );
      outSink.clear();
      errSink.clear();
      expect(
        await runSingleRequest(
          [
            'analyze',
            '--sdk',
            sdkDir.path,
            '--sdk-summary',
            sdkSummary.path,
            '--summary',
            nestedSummary.path,
            '--project',
            stageTestAnalyze.path,
            '--source',
            stagedTestFile.path,
            '--stamp',
            relImportStamp.path,
          ],
          outSink: outSink,
          errSink: errSink,
          resourceProvider: PhysicalResourceProvider.INSTANCE,
        ),
        0,
        reason: '${outSink.toString()}\n${errSink.toString()}',
      );
      expect(relImportStamp.existsSync(), isTrue);

      // A relative import into `../lib/` for a file absent from the summary
      // must still fail with `uri_does_not_exist`.
      stagedTestFile.writeAsStringSync("import '../lib/loud/missing.dart';\n");
      final missingRelStamp = File(
        p.join(symlinkBase.path, 'nested_missing_rel.analyzed'),
      );
      outSink.clear();
      errSink.clear();
      expect(
        await runSingleRequest(
          [
            'analyze',
            '--sdk',
            sdkDir.path,
            '--sdk-summary',
            sdkSummary.path,
            '--summary',
            nestedSummary.path,
            '--project',
            stageTestAnalyze.path,
            '--source',
            stagedTestFile.path,
            '--stamp',
            missingRelStamp.path,
          ],
          outSink: outSink,
          errSink: errSink,
          resourceProvider: PhysicalResourceProvider.INSTANCE,
        ),
        1,
      );
      expect(missingRelStamp.existsSync(), isFalse);
      expect(outSink.toString(), contains('uri_does_not_exist'));
    });

    defineSummaryTripleQuotedImportGuardTest(() => tempDir);
  });

  _defineSummaryBaselineVerdictTests();
}

AnalysisBaseline _parseSummaryBaseline(String json) =>
    AnalysisBaseline.parse(json, source: 'baseline.json');

AnalysisFinding _summaryFinding(
  String path,
  String code, {
  Severity level = Severity.info,
  int line = 1,
}) => AnalysisFinding(
  level: level,
  path: path,
  code: code,
  line: line,
  column: 3,
  text: '${level.name.padLeft(7)} - $path:$line:3 - msg - $code',
);

({int code, String output, bool stamped}) _runSummaryVerdict(
  List<AnalysisFinding> findings,
  AnalysisBaseline? baseline,
) {
  final dir = Directory.systemTemp.createTempSync('summary_baseline_test_');
  try {
    final stamp = File('${dir.path}/stamp.txt');
    final out = StringBuffer();
    final exitCode = reportAnalyzeFindings(
      stamp: stamp.path,
      findings: findings,
      fatalInfos: true,
      baseline: baseline,
      outSink: out,
    );
    return (
      code: exitCode,
      output: out.toString(),
      stamped: stamp.existsSync(),
    );
  } finally {
    dir.deleteSync(recursive: true);
  }
}

/// Recording wrapper around [PhysicalResourceProvider.INSTANCE] to verify that
/// blocked ancestor probes never reach the underlying filesystem.
final class RecordingResourceProvider implements fs.ResourceProvider {
  RecordingResourceProvider(this._delegate, {p.Context? pathContext})
    : _pathContext = pathContext;

  final fs.ResourceProvider _delegate;
  final p.Context? _pathContext;
  final List<String> checkedPaths = <String>[];

  void _record(String rawPath) {
    checkedPaths.add(pathContext.normalize(pathContext.absolute(rawPath)));
  }

  @override
  p.Context get pathContext => _pathContext ?? _delegate.pathContext;

  @override
  fs.File getFile(String path) => _RecordingFile(this, _delegate.getFile(path));

  @override
  fs.Folder getFolder(String path) =>
      _RecordingFolder(this, _delegate.getFolder(path));

  @override
  fs.Resource getResource(String path) => switch (_delegate.getResource(path)) {
    final fs.File f => _RecordingFile(this, f),
    final fs.Folder d => _RecordingFolder(this, d),
    final other => other,
  };

  @override
  Never noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName}');
}

final class _RecordingFolder implements fs.Folder {
  const _RecordingFolder(this._provider, this._delegate);

  final RecordingResourceProvider _provider;
  final fs.Folder _delegate;

  @override
  String get path => _delegate.path;

  @override
  bool get isRoot => _delegate.isRoot;

  @override
  fs.Folder get parent => _RecordingFolder(_provider, _delegate.parent);

  @override
  bool get exists {
    _provider._record(_delegate.path);
    return _delegate.exists;
  }

  @override
  List<fs.Resource> getChildren() => _delegate.getChildren();

  @override
  Never noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName}');
}

final class _RecordingFile implements fs.File {
  const _RecordingFile(this._provider, this._delegate);

  final RecordingResourceProvider _provider;
  final fs.File _delegate;

  @override
  String get path => _delegate.path;

  @override
  fs.Folder get parent => _RecordingFolder(_provider, _delegate.parent);

  @override
  bool get exists {
    _provider._record(_delegate.path);
    return _delegate.exists;
  }

  @override
  Never noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName}');
}

void _defineSummaryBaselineVerdictTests() {
  group('analysis baseline verdict', () {
    _defineSummaryCeilingTest();
    _defineSummaryUnkeyedAndErrorTests();
    _defineSummaryMalformedBaselineTests(_parseSummaryBaseline);
  });
}

void _defineSummaryCeilingTest() {
  test('passes a group at its ceiling and fails one above it', () {
    final baseline = _parseSummaryBaseline('{"lib/a.dart":{"AVOID_PRINT":2}}');

    final atCeiling = _runSummaryVerdict([
      _summaryFinding('lib/a.dart', 'avoid_print', line: 1),
      _summaryFinding('lib/a.dart', 'avoid_print', line: 2),
    ], baseline);
    expect(atCeiling.code, 0);
    expect(atCeiling.stamped, isTrue);
    expect(atCeiling.output, contains('baselined (2/2)'));

    final above = _runSummaryVerdict([
      _summaryFinding('lib/a.dart', 'avoid_print', line: 1),
      _summaryFinding('lib/a.dart', 'avoid_print', line: 2),
      _summaryFinding('lib/a.dart', 'avoid_print', line: 3),
    ], baseline);
    expect(above.code, isNonZero);
    expect(above.stamped, isFalse);
    expect(
      above.output,
      contains('baseline: lib/a.dart avoid_print: observed 3, ceiling 2'),
    );
  });
}

void _defineSummaryUnkeyedAndErrorTests() {
  test(
    'an unkeyed code fails and an entry for another file does not apply',
    () {
      final baseline = _parseSummaryBaseline(
        '{"lib/a.dart":{"avoid_print":1}}',
      );

      final unkeyedCode = _runSummaryVerdict([
        _summaryFinding('lib/a.dart', 'unused_import'),
      ], baseline);
      expect(unkeyedCode.code, isNonZero);
      expect(unkeyedCode.stamped, isFalse);
      expect(unkeyedCode.output, contains('observed 1, ceiling 0'));

      final otherFile = _runSummaryVerdict([
        _summaryFinding('lib/b.dart', 'avoid_print'),
      ], baseline);
      expect(otherFile.code, isNonZero);
      expect(otherFile.stamped, isFalse);
      expect(
        otherFile.output,
        contains('baseline: lib/b.dart avoid_print: observed 1, ceiling 0'),
      );
      expect(baseline.sliceFor(['lib/b.dart']), isEmpty);
    },
  );

  test('exempts a keyed error-level diagnostic but never an unkeyed one', () {
    final baseline = _parseSummaryBaseline(
      '{"lib/a.dart":{"undefined_identifier":1,"avoid_print":2},'
      '"pkg/analysis_options.yaml":{"parse_error":1}}',
    );

    final keyedErrors = _runSummaryVerdict([
      _summaryFinding(
        'lib/a.dart',
        'undefined_identifier',
        level: Severity.error,
      ),
      _summaryFinding(
        'pkg/analysis_options.yaml',
        'parse_error',
        level: Severity.error,
      ),
    ], baseline);
    expect(keyedErrors.code, 0);
    expect(keyedErrors.stamped, isTrue);
    expect(keyedErrors.output, contains('baselined (1/1)'));

    final unkeyedError = _runSummaryVerdict([
      _summaryFinding(
        'lib/a.dart',
        'uri_does_not_exist',
        level: Severity.error,
      ),
    ], baseline);
    expect(unkeyedError.code, isNonZero);
    expect(unkeyedError.stamped, isFalse);
    expect(unkeyedError.output, contains('observed 1, ceiling 0'));
  });
}

void _defineSummaryMalformedBaselineTests(
  AnalysisBaseline Function(String) parse,
) {
  test('names the baseline file and offending entry on malformed inputs', () {
    void expectRejected(String json, String entry) {
      expect(
        () => parse(json),
        throwsA(
          isA<BaselineException>().having(
            (e) => e.message,
            'message',
            allOf(contains('baseline.json'), contains(entry)),
          ),
        ),
        reason: json,
      );
    }

    expectRejected('{"lib/a.dart":', 'lib/a.dart');
    expectRejected('{"lib/a.dart":{"avoid_print":01}}', 'avoid_print');
    expectRejected('[]', '<root>');
    expectRejected('{"lib/a.dart":[]}', 'lib/a.dart');
    expectRejected('{"lib/a.dart":{"avoid_print":-1}}', 'avoid_print');
    expectRejected('{"lib/a.dart":{"avoid_print":1.5}}', 'avoid_print');
    expectRejected('{"lib/a.dart":{"avoid_print":"2"}}', 'avoid_print');
    expectRejected('{"/tmp/a.dart":{"avoid_print":1}}', '/tmp/a.dart');
    expectRejected('{"C:/tmp/a.dart":{"avoid_print":1}}', 'C:/tmp/a.dart');
    expectRejected('{"lib/../a.dart":{"avoid_print":1}}', 'lib/../a.dart');
    expectRejected(r'{"lib\\a.dart":{"avoid_print":1}}', r'lib\a.dart');
    expectRejected('{"lib/a.dart":{},"lib/a.dart":{}}', 'lib/a.dart');
    expectRejected(
      '{"lib/a.dart":{"avoid_print":1,"AVOID_PRINT":2}}',
      'AVOID_PRINT',
    );
  });
}
