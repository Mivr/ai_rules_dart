// Fakes and wire encoders shared by `analyzer_summary_test.dart`.
import 'dart:convert';
import 'dart:typed_data';

import 'package:analyzer/file_system/file_system.dart' as fs;
import 'package:analyzer/file_system/physical_file_system.dart';
// ignore: implementation_imports
import 'package:analyzer/src/dart/analysis/analysis_context_collection.dart'
    show AnalysisContextCollectionImpl;
import 'package:path/path.dart' as p;

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

/// Recording wrapper around [PhysicalResourceProvider.INSTANCE] to verify that
/// blocked ancestor probes never reach the underlying filesystem.
final class RecordingResourceProvider implements fs.ResourceProvider {
  RecordingResourceProvider(this._delegate, {p.Context? pathContext})
    : _pathContext = pathContext;

  final fs.ResourceProvider _delegate;
  final p.Context? _pathContext;
  final List<String> checkedPaths = <String>[];

  @override
  p.Context get pathContext => _pathContext ?? _delegate.pathContext;

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

  final RecordingResourceProvider _provider;
  final fs.Folder _delegate;

  @override
  bool get exists {
    _provider.checkedPaths.add(
      _provider.pathContext.normalize(
        _provider.pathContext.absolute(_delegate.path),
      ),
    );
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
  String canonicalizePath(String relPath) => _provider.pathContext.normalize(
    _provider.pathContext.join(path, relPath),
  );

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

  final RecordingResourceProvider _provider;
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

/// Encodes a protobuf varint for worker-protocol test frames.
Uint8List encodeVarintForTest(int value) {
  final out = BytesBuilder();
  var v = value;
  while (v >= 0x80) {
    out.addByte((v & 0x7f) | 0x80);
    v >>= 7;
  }
  out.addByte(v);
  return out.toBytes();
}

/// Encodes a Bazel `WorkRequest` protobuf frame for worker tests.
Uint8List encodeWorkRequestForTest({
  required List<String> arguments,
  required Map<String, Uint8List> inputs,
}) {
  final out = BytesBuilder();
  for (final arg in arguments) {
    final argBytes = utf8.encode(arg);
    out.add(encodeVarintForTest((1 << 3) | 2));
    out.add(encodeVarintForTest(argBytes.length));
    out.add(argBytes);
  }
  for (final entry in inputs.entries) {
    final inputBuf = BytesBuilder();
    final pathBytes = utf8.encode(entry.key);
    inputBuf.add(encodeVarintForTest((1 << 3) | 2));
    inputBuf.add(encodeVarintForTest(pathBytes.length));
    inputBuf.add(pathBytes);
    if (entry.value.isNotEmpty) {
      inputBuf.add(encodeVarintForTest((2 << 3) | 2));
      inputBuf.add(encodeVarintForTest(entry.value.length));
      inputBuf.add(entry.value);
    }
    final inputBytes = inputBuf.toBytes();
    out.add(encodeVarintForTest((2 << 3) | 2));
    out.add(encodeVarintForTest(inputBytes.length));
    out.add(inputBytes);
  }
  return out.toBytes();
}
