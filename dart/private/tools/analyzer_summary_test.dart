import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:analyzer/file_system/file_system.dart' as fs;
import 'package:analyzer/file_system/physical_file_system.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'analyzer_summary.dart'
    show
        BoundedResourceProvider,
        SummaryByteCache,
        SummaryCachingResourceProvider,
        decodeAnalyzerWorkRequestInputs,
        disposedContextCollectionsCount,
        onContextCollectionDisposed,
        runSingleRequest;

/// Recording wrapper around [PhysicalResourceProvider.INSTANCE] to verify that
/// blocked ancestor probes never reach the underlying filesystem.
final class _RecordingResourceProvider implements fs.ResourceProvider {
  _RecordingResourceProvider(this._delegate);

  final fs.ResourceProvider _delegate;
  final List<String> checkedPaths = <String>[];

  @override
  p.Context get pathContext => _delegate.pathContext;

  @override
  fs.File getFile(String path) => _RecordingFile(this, _delegate.getFile(path));

  @override
  fs.Folder getFolder(String path) =>
      _RecordingFolder(this, _delegate.getFolder(path));

  @override
  fs.Link getLink(String path) => _delegate.getLink(path);

  @override
  fs.Resource getResource(String path) {
    final r = _delegate.getResource(path);
    if (r is fs.File) return _RecordingFile(this, r);
    if (r is fs.Folder) return _RecordingFolder(this, r);
    return r;
  }

  @override
  fs.Folder? getStateLocation(String pluginId) =>
      _delegate.getStateLocation(pluginId);
}

final class _RecordingFolder implements fs.Folder {
  const _RecordingFolder(this._provider, this._delegate);

  final _RecordingResourceProvider _provider;
  final fs.Folder _delegate;

  @override
  bool get exists {
    _provider.checkedPaths.add(p.normalize(p.absolute(_delegate.path)));
    return _delegate.exists;
  }

  @override
  bool get isRoot => _delegate.isRoot;

  @override
  fs.Folder get parent => _RecordingFolder(_provider, _delegate.parent);

  @override
  String get path => _delegate.path;

  @override
  fs.ResourceProvider get provider => _provider;

  @override
  String get shortName => _delegate.shortName;

  @override
  String canonicalizePath(String path) => _delegate.canonicalizePath(path);

  @override
  bool contains(String path) => _delegate.contains(path);

  @override
  fs.Folder copyTo(fs.Folder parentFolder) =>
      _RecordingFolder(_provider, _delegate.copyTo(parentFolder));

  @override
  void create() => _delegate.create();

  @override
  void delete() => _delegate.delete();

  @override
  fs.Resource getChild(String relPath) =>
      _provider.getResource(_provider.pathContext.join(path, relPath));

  @override
  fs.File getChildAssumingFile(String relPath) => getFile(relPath);

  @override
  fs.Folder getChildAssumingFolder(String relPath) => getFolder(relPath);

  @override
  fs.File getFile(String relPath) =>
      _provider.getFile(_provider.pathContext.join(path, relPath));

  @override
  fs.Folder getFolder(String relPath) =>
      _provider.getFolder(_provider.pathContext.join(path, relPath));

  @override
  List<fs.Resource> getChildren() => _delegate.getChildren();

  @override
  bool isOrContains(String path) => _delegate.isOrContains(path);

  @override
  fs.Resource resolveSymbolicLinksSync() =>
      _delegate.resolveSymbolicLinksSync();

  @override
  Uri toUri() => _delegate.toUri();

  @override
  fs.ResourceWatcher watch() => _delegate.watch();
}

final class _RecordingFile implements fs.File {
  const _RecordingFile(this._provider, this._delegate);

  final _RecordingResourceProvider _provider;
  final fs.File _delegate;

  @override
  bool get exists {
    _provider.checkedPaths.add(p.normalize(p.absolute(_delegate.path)));
    return _delegate.exists;
  }

  @override
  int get lengthSync => _delegate.lengthSync;

  @override
  int get modificationStamp => _delegate.modificationStamp;

  @override
  fs.Folder get parent => _RecordingFolder(_provider, _delegate.parent);

  @override
  String get path => _delegate.path;

  @override
  fs.ResourceProvider get provider => _provider;

  @override
  String get shortName => _delegate.shortName;

  @override
  fs.File copyTo(fs.Folder parentFolder) =>
      _RecordingFile(_provider, _delegate.copyTo(parentFolder));

  @override
  void delete() => _delegate.delete();

  @override
  bool isOrContains(String path) => _delegate.isOrContains(path);

  @override
  Uint8List readAsBytesSync() => _delegate.readAsBytesSync();

  @override
  String readAsStringSync() => _delegate.readAsStringSync();

  @override
  fs.File renameSync(String newPath) =>
      _RecordingFile(_provider, _delegate.renameSync(newPath));

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
}

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
      final anc1 = Directory(p.join(tempDir.path, 'anc1'))..createSync();
      final anc2 = Directory(p.join(anc1.path, 'anc2'))..createSync();
      final project = Directory(p.join(anc2.path, 'project'))..createSync();
      final srcDir = Directory(p.join(project.path, 'src', 'lib'))
        ..createSync(recursive: true);

      // Plant poison config/workspace files in ancestor directories.
      final poisonOptions = File(p.join(anc2.path, 'analysis_options.yaml'))
        ..writeAsStringSync('analyzer:\n  exclude:\n    - "**"\n');
      final poisonPubspec = File(p.join(anc1.path, 'pubspec.yaml'))
        ..writeAsStringSync('name: poison_pkg\n');
      final poisonWorkspace = File(p.join(anc1.path, 'WORKSPACE'))
        ..writeAsStringSync('');
      final poisonBuildGn = File(p.join(anc2.path, 'BUILD.gn'))
        ..writeAsStringSync('');
      final poisonDartTool = Directory(p.join(anc2.path, '.dart_tool'))
        ..createSync();
      final poisonPkgConfig = File(
        p.join(poisonDartTool.path, 'package_config.json'),
      )..writeAsStringSync('{"configVersion": 2, "packages": []}');

      final projectOptions = File(p.join(project.path, 'analysis_options.yaml'))
        ..writeAsStringSync('linter:\n  rules: []\n');
      final srcFile = File(p.join(srcDir.path, 'a.dart'))
        ..writeAsStringSync('int x = 1;\n');

      final recorder = _RecordingResourceProvider(
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
        isNot(contains(p.normalize(p.absolute(anc2.path)))),
      );
      expect(
        visitedFolders,
        isNot(contains(p.normalize(p.absolute(anc1.path)))),
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
  });

  group('SummaryByteCache', () {
    test('detects in-place .sum mutation with identical size and mtime when digest is absent', () {
      final sumFile = File(p.join(tempDir.path, 'dep.sum'));
      final fixedTime = DateTime.fromMillisecondsSinceEpoch(1700000000000);

      sumFile.writeAsBytesSync([1, 2, 3, 4, 5, 6, 7, 8]);
      sumFile.setLastModifiedSync(fixedTime);

      final cache = SummaryByteCache();
      final provider = SummaryCachingResourceProvider(
        PhysicalResourceProvider.INSTANCE,
        cache,
      );

      // Request 1 with no digest in WorkRequest.inputs.
      cache.beginRequest(const {});
      expect(provider.getFile(sumFile.path).readAsBytesSync(), [
        1,
        2,
        3,
        4,
        5,
        6,
        7,
        8,
      ]);

      // Mutate `dep.sum` in-place to different bytes of the exact same length
      // and restore the exact same modification timestamp.
      sumFile.writeAsBytesSync([8, 7, 6, 5, 4, 3, 2, 1]);
      sumFile.setLastModifiedSync(fixedTime);
      expect(sumFile.statSync().size, 8);
      expect(sumFile.statSync().modified, fixedTime);

      // Request 2 with no digest in WorkRequest.inputs must NOT return stale bytes.
      cache.beginRequest(const {});
      expect(provider.getFile(sumFile.path).readAsBytesSync(), [
        8,
        7,
        6,
        5,
        4,
        3,
        2,
        1,
      ]);
    });

    test('scales 256 MB total budget across worker instances, enforces strict byte bounds, and unpins WorkRequest buffers', () {
      // 1. Default budget scales 256 MB across 4 persistent worker instances = 64 MB per instance.
      final defaultCache = SummaryByteCache();
      expect(SummaryByteCache.defaultTotalBudgetBytes, 256 * 1024 * 1024);
      expect(SummaryByteCache.defaultWorkerInstances, 4);
      expect(defaultCache.maxCacheBytes, 64 * 1024 * 1024);

      final customScaled = SummaryByteCache(
        totalBudgetBytes: 256 * 1024 * 1024,
        workerInstances: 8,
      );
      expect(customScaled.maxCacheBytes, 32 * 1024 * 1024);

      // 2. Verify decodeAnalyzerWorkRequestInputs and SummaryByteCache unpin slices
      // from a larger WorkRequest buffer.
      final rawReq = _encodeWorkRequestForTest(
        arguments: ['summarize'],
        inputs: {
          'dep.sum': Uint8List.fromList([1, 2, 3, 4]),
        },
      );
      final bigFrame = Uint8List(64 * 1024)
        ..setRange(100, 100 + rawReq.length, rawReq);
      final slice = Uint8List.sublistView(bigFrame, 100, 100 + rawReq.length);
      expect(slice.buffer.lengthInBytes, 64 * 1024);

      final decodedInputs = decodeAnalyzerWorkRequestInputs(slice);
      expect(
        decodedInputs['dep.sum']!.buffer.lengthInBytes,
        decodedInputs['dep.sum']!.lengthInBytes,
        reason: 'decoded digest must not pin the 64 KB WorkRequest buffer',
      );

      // 3. Enforce strict byte bounds and LRU eviction.
      final boundedCache = SummaryByteCache(maxCacheBytes: 100);
      final provider = SummaryCachingResourceProvider(
        PhysicalResourceProvider.INSTANCE,
        boundedCache,
      );

      final s1 = File(p.join(tempDir.path, 's1.sum'))
        ..writeAsBytesSync(List<int>.filled(40, 1));
      final s2 = File(p.join(tempDir.path, 's2.sum'))
        ..writeAsBytesSync(List<int>.filled(40, 2));
      final s3 = File(p.join(tempDir.path, 's3.sum'))
        ..writeAsBytesSync(List<int>.filled(40, 3));
      final oversized = File(p.join(tempDir.path, 'oversized.sum'))
        ..writeAsBytesSync(List<int>.filled(120, 9));

      boundedCache.beginRequest({
        s1.path: Uint8List.fromList([1]),
        s2.path: Uint8List.fromList([2]),
        s3.path: Uint8List.fromList([3]),
        oversized.path: Uint8List.fromList([9]),
      });

      // Oversized entry (> maxCacheBytes = 100) is returned to caller without
      // inserting into the cache or evicting existing entries.
      expect(provider.getFile(s1.path).readAsBytesSync().length, 40);
      expect(provider.getFile(s2.path).readAsBytesSync().length, 40);
      expect(boundedCache.totalBytes, 80);
      expect(boundedCache.entryCount, 2);

      expect(provider.getFile(oversized.path).readAsBytesSync().length, 120);
      expect(boundedCache.totalBytes, 80);
      expect(boundedCache.entryCount, 2);

      // Touch s1 so s2 becomes oldest, then read s3 (40 B): s2 is evicted so totalBytes stays 80 <= 100.
      expect(provider.getFile(s1.path).readAsBytesSync().first, 1);
      expect(provider.getFile(s3.path).readAsBytesSync().first, 3);
      expect(boundedCache.totalBytes, 80);
      expect(boundedCache.entryCount, 2);
    });
  });

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
  });
}

Uint8List _encodeVarintForTest(int value) {
  final out = BytesBuilder();
  var v = value;
  while (v >= 0x80) {
    out.addByte((v & 0x7f) | 0x80);
    v >>= 7;
  }
  out.addByte(v);
  return out.toBytes();
}

Uint8List _encodeWorkRequestForTest({
  required List<String> arguments,
  required Map<String, Uint8List> inputs,
}) {
  final out = BytesBuilder();
  for (final arg in arguments) {
    final argBytes = utf8.encode(arg);
    out.add(_encodeVarintForTest((1 << 3) | 2));
    out.add(_encodeVarintForTest(argBytes.length));
    out.add(argBytes);
  }
  for (final entry in inputs.entries) {
    final inputBuf = BytesBuilder();
    final pathBytes = utf8.encode(entry.key);
    inputBuf.add(_encodeVarintForTest((1 << 3) | 2));
    inputBuf.add(_encodeVarintForTest(pathBytes.length));
    inputBuf.add(pathBytes);
    if (entry.value.isNotEmpty) {
      inputBuf.add(_encodeVarintForTest((2 << 3) | 2));
      inputBuf.add(_encodeVarintForTest(entry.value.length));
      inputBuf.add(entry.value);
    }
    final inputBytes = inputBuf.toBytes();
    out.add(_encodeVarintForTest((2 << 3) | 2));
    out.add(_encodeVarintForTest(inputBytes.length));
    out.add(inputBytes);
  }
  return out.toBytes();
}
