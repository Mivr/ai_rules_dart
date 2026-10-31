// Fakes and summary-cache / tear-down test helpers for `analyzer_summary_test`.
import 'dart:io';
import 'dart:typed_data';

import 'package:analyzer/file_system/physical_file_system.dart';
// ignore: implementation_imports
import 'package:analyzer/src/dart/analysis/analysis_context_collection.dart'
    show AnalysisContextCollectionImpl;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'analyzer_summary.dart'
    show
        SummaryByteCache,
        SummaryCachingResourceProvider,
        decodeAnalyzerWorkRequestInputs,
        disposeContextCollection,
        disposedContextCollectionsCount,
        onContextCollectionDisposed,
        runSingleRequest;
import 'worker_test_encode.dart' show encodeWorkRequestForTest;

export 'worker_test_encode.dart' show encodeWorkRequestForTest;

/// A collection whose tear-down raises a trappable failure.
final class ThrowingCollection extends AnalysisContextCollectionImpl {
  ThrowingCollection() : super(includedPaths: const []);

  @override
  Future<void> dispose({bool forTesting = false}) async {
    throw const FormatException('simulated tear-down failure');
  }
}

/// A collection whose tear-down raises a programming error.
final class ErroringCollection extends AnalysisContextCollectionImpl {
  ErroringCollection() : super(includedPaths: const []);

  @override
  Future<void> dispose({bool forTesting = false}) async {
    throw StateError('simulated programming error');
  }
}

/// Registers the `SummaryByteCache` unit test group.
void defineSummaryByteCacheTests(Directory Function() currentTmp) {
  group('SummaryByteCache', () {
    _defineMutationWithoutDigestTest(currentTmp);
    _defineBudgetAndEvictionTest(currentTmp);
  });
}

void _defineMutationWithoutDigestTest(Directory Function() currentTmp) {
  test('detects in-place .sum mutation with identical size and mtime when digest is absent', () {
    final sumFile = File(p.join(currentTmp().path, 'dep.sum'));
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
}

void _defineBudgetAndEvictionTest(Directory Function() currentTmp) {
  test('scales 256 MB total budget across worker instances, enforces strict byte bounds, and unpins WorkRequest buffers', () {
    final defaultCache = SummaryByteCache();
    expect(SummaryByteCache.defaultTotalBudgetBytes, 256 * 1024 * 1024);
    expect(SummaryByteCache.defaultWorkerInstances, 4);
    expect(defaultCache.maxCacheBytes, 64 * 1024 * 1024);

    final customScaled = SummaryByteCache(
      totalBudgetBytes: 256 * 1024 * 1024,
      workerInstances: 8,
    );
    expect(customScaled.maxCacheBytes, 32 * 1024 * 1024);

    final rawReq = encodeWorkRequestForTest(
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

    final boundedCache = SummaryByteCache(maxCacheBytes: 100);
    final provider = SummaryCachingResourceProvider(
      PhysicalResourceProvider.INSTANCE,
      boundedCache,
    );

    final tmpPath = currentTmp().path;
    final s1 = File(p.join(tmpPath, 's1.sum'))
      ..writeAsBytesSync(List<int>.filled(40, 1));
    final s2 = File(p.join(tmpPath, 's2.sum'))
      ..writeAsBytesSync(List<int>.filled(40, 2));
    final s3 = File(p.join(tmpPath, 's3.sum'))
      ..writeAsBytesSync(List<int>.filled(40, 3));
    final oversized = File(p.join(tmpPath, 'oversized.sum'))
      ..writeAsBytesSync(List<int>.filled(120, 9));

    boundedCache.beginRequest({
      s1.path: Uint8List.fromList([1]),
      s2.path: Uint8List.fromList([2]),
      s3.path: Uint8List.fromList([3]),
      oversized.path: Uint8List.fromList([9]),
    });

    expect(provider.getFile(s1.path).readAsBytesSync().length, 40);
    expect(provider.getFile(s2.path).readAsBytesSync().length, 40);
    expect(boundedCache.totalBytes, 80);
    expect(boundedCache.entryCount, 2);

    expect(provider.getFile(oversized.path).readAsBytesSync().length, 120);
    expect(boundedCache.totalBytes, 80);
    expect(boundedCache.entryCount, 2);

    expect(provider.getFile(s1.path).readAsBytesSync().first, 1);
    expect(provider.getFile(s3.path).readAsBytesSync().first, 3);
    expect(boundedCache.totalBytes, 80);
    expect(boundedCache.entryCount, 2);
  });
}

/// Registers tear-down failure handling tests for `disposeContextCollection`.
void defineDisposeTearDownTests() {
  group('disposeContextCollection tear-down failures', () {
    test('still releases a collection whose dispose throws', () async {
      final beforeCount = disposedContextCollectionsCount;
      final released = <AnalysisContextCollectionImpl>[];
      final prevHook = onContextCollectionDisposed;
      onContextCollectionDisposed = released.add;
      try {
        await disposeContextCollection(ThrowingCollection());
        expect(disposedContextCollectionsCount, beforeCount + 1);
        expect(released, hasLength(1));
      } finally {
        onContextCollectionDisposed = prevHook;
      }
    });

    test('lets a programming error from dispose propagate', () {
      expect(disposeContextCollection(ErroringCollection()), throwsStateError);
    });
  });
}

/// Registers the staged triple-quoted directive guard test on `analyze`.
void defineSummaryTripleQuotedImportGuardTest(Directory Function() currentTmp) {
  test('refuses a triple-quoted import before analyzing', () async {
    // A multi-line first line the guard keeps but the front end drops
    // would read an undeclared host file through the analyzer's working
    // directory. The staged check refuses it before any SDK or summary is
    // read, so this needs no summaries.
    final tmpPath = currentTmp().path;
    final stageAnalyze = Directory(p.join(tmpPath, 'tq.analyze'))
      ..createSync(recursive: true);
    final stagedMain =
        File(p.join(stageAnalyze.path, 'src', 'pkg', 'main.dart'))
          ..parent.createSync(recursive: true)
          ..writeAsStringSync(
            "import '''   \n/secret/s.dart''';\n"
            'void main() => print(hostSecret);\n',
          );
    File(p.join(stageAnalyze.path, 'src', 'pkg', 'ok.dart'))
        .writeAsStringSync('const ok = 1;\n');
    final stamp = File(p.join(tmpPath, 'tq.analyzed'));
    final outSink = StringBuffer();
    final errSink = StringBuffer();
    expect(
      await runSingleRequest(
        [
          'analyze',
          '--project',
          stageAnalyze.path,
          '--source',
          stagedMain.path,
          '--stamp',
          stamp.path,
        ],
        outSink: outSink,
        errSink: errSink,
        resourceProvider: PhysicalResourceProvider.INSTANCE,
      ),
      1,
      reason: '${outSink.toString()}\n${errSink.toString()}',
    );
    expect(stamp.existsSync(), isFalse);
    expect(
      errSink.toString(),
      contains("import '   \n/secret/s.dart' is not a declared input"),
    );
  });
}
