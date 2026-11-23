import 'dart:typed_data';

import 'package:analyzer/file_system/file_system.dart' as fs;
import 'package:path/path.dart' as p;
import 'package:rules_dart_worker/worker_tool_fs.dart';

// ---------------------------------------------------------------------------
// Bounded ResourceProvider confining ContextLocator upward walks at staging.
// ---------------------------------------------------------------------------

/// A [fs.ResourceProvider] that wraps [_delegate] so every folder at or under
/// a boundary root reports `isRoot`, stopping `ContextLocator` upward walks.
final class StagingBoundedResourceProvider implements fs.ResourceProvider {
  /// Wraps [_delegate], bounding upward walks at each of [boundaryRoots].
  StagingBoundedResourceProvider(
    this._delegate, {
    required Iterable<String> boundaryRoots,
  }) : _boundaryRoots = {
         for (final r in boundaryRoots)
           _delegate.pathContext.normalize(_delegate.pathContext.absolute(r)),
       };

  final fs.ResourceProvider _delegate;
  final Set<String> _boundaryRoots;

  /// Whether [normPath] is a boundary root or lies within one.
  bool isBoundary(String normPath) {
    if (_boundaryRoots.contains(normPath)) return true;
    for (final String root in _boundaryRoots) {
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
    final fs.Resource res = _delegate.getResource(path);
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

  final StagingBoundedResourceProvider _provider;
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

  final StagingBoundedResourceProvider _provider;
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
