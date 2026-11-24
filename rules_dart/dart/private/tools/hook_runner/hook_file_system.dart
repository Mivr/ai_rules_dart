// The file system `hook_runner.dart` hands `package:hooks_runner`, and the
// path forms it compares. Kept apart from the runner (on `package:file` and
// `package:path` alone) so that a test checks them under Windows rules on any
// host: the runner names its files with `Uri.toFilePath()`, which is
// `C:\...\hook.dill` on Windows and `/.../hook.dill` elsewhere.

import 'dart:io';

import 'package:file/file.dart' as fs;
import 'package:path/path.dart' as p;

/// The file names in the runner's cache that the precompiled hook kernel
/// stands in for. Pinned with the runner version (see `pubspec.yaml`); a
/// runner that looks elsewhere makes [PrecompiledHookFileSystem.kernelServed]
/// false and the action fails rather than compiling the hook a second time.
const hookKernelName = 'hook.dill';

/// The record the runner checks [hookKernelName] against.
const hookKernelHashesName = 'hook.dependencies_hash_file.json';

/// A file of `package:hooks_runner`'s cache that `hook_runner` serves itself.
enum CacheFile {
  /// The hook's compiled kernel.
  kernel,

  /// The record the runner checks the kernel against before it compiles one.
  kernelHashes,
}

/// Which [CacheFile] [path] is, or null.
///
/// That is a file named [kernelName] or [hashesName] in a package's directory
/// under a `hooks_runner` directory (not under `hooks_runner/shared`), in any
/// separator form [context] accepts: `/` and `\` on Windows.
CacheFile? cacheFile(
  String path, {
  required String kernelName,
  required String hashesName,
  p.Context? context,
}) {
  final List<String> parts = (context ?? p.context).split(path);
  final int at = parts.lastIndexOf('hooks_runner');
  if (at < 0 || at + 2 >= parts.length || parts[at + 1] == 'shared') {
    return null;
  }
  final String name = parts.last;
  if (name == kernelName) return CacheFile.kernel;
  if (name == hashesName) return CacheFile.kernelHashes;
  return null;
}

/// Whether [a] and [b] name the same file under [context]'s rules: on
/// Windows, regardless of separator and of the case of the drive letter.
bool samePath(String a, String b, {p.Context? context}) =>
    (context ?? p.context).equals(a, b);

/// [path] made absolute against [cwd], unless it already is (`C:\...` and
/// `\\server\...` included on Windows).
String absolute(String path, String cwd, {p.Context? context}) {
  final p.Context ctx = context ?? p.context;
  return ctx.isAbsolute(path) ? path : ctx.join(cwd, path);
}

/// Whether [path] is the lock file `package:hooks_runner` opens in each
/// directory it locks, and never closes.
bool isLockFile(String path, {p.Context? context}) =>
    (context ?? p.context).basename(path) == '.lock';

/// Serves the precompiled hook kernel, and the workspace pubspec's
/// user-defines slice, where `package:hooks_runner` looks for them, and keeps
/// the lock files the runner opens so that [closeLockFiles] can close them.
class PrecompiledHookFileSystem extends fs.ForwardingFileSystem {
  new(
    super.delegate, {
    required this.kernel,
    required this.kernelHashes,
    required this.pubspec,
    required this.pubspecSlice,
    this.context,
  });

  /// The path rules [file] compares by; the host's when null.
  final p.Context? context;

  final String kernel;
  final String kernelHashes;
  final String? pubspec;
  final String? pubspecSlice;
  bool kernelServed = false;
  final List<RandomAccessFile> _lockFiles = [];

  @override
  fs.File file(dynamic path) {
    final String p = path is Uri ? path.toFilePath() : path.toString();
    final CacheFile? cached = cacheFile(
      p,
      kernelName: hookKernelName,
      hashesName: hookKernelHashesName,
      context: context,
    );
    if (cached == CacheFile.kernel) {
      kernelServed = true;
      return delegate.file(kernel);
    }
    if (cached == CacheFile.kernelHashes) return delegate.file(kernelHashes);
    if (pubspec != null && samePath(p, pubspec!, context: context)) {
      return delegate.file(pubspecSlice ?? '/nonexistent/pubspec.yaml');
    }
    if (isLockFile(p, context: context)) return _LockFile(this, File(p));
    return delegate.file(path);
  }

  /// A directory whose files (the runner's lock file among them) come from
  /// [file] above: the runner names a directory's lock file through the
  /// directory's own file system.
  @override
  fs.Directory directory(dynamic path) =>
      _Directory(this, Directory(delegate.directory(path).path));

  /// Closes the lock files the runner opened. It unlocks each when it is done
  /// with the directory, but never closes one, and on Windows an open file
  /// cannot be deleted.
  Future<void> closeLockFiles() async {
    for (final RandomAccessFile file in _lockFiles) {
      try {
        await file.close();
      } on FileSystemException {
        // Closed already.
      }
    }
    _lockFiles.clear();
  }
}

/// A directory of [PrecompiledHookFileSystem].
class _Directory extends fs.ForwardingFileSystemEntity<fs.Directory, Directory>
    with fs.ForwardingDirectory<fs.Directory> {
  new(this.fileSystem, this.delegate);

  @override
  final PrecompiledHookFileSystem fileSystem;

  @override
  final Directory delegate;

  @override
  String get basename => fileSystem.path.basename(path);

  @override
  String get dirname => fileSystem.path.dirname(path);

  @override
  fs.Directory wrapDirectory(Directory delegate) =>
      _Directory(fileSystem, delegate);

  @override
  fs.File wrapFile(File delegate) => fileSystem.file(delegate.path);

  @override
  fs.Link wrapLink(Link delegate) => fileSystem.link(delegate.path);

  @override
  fs.Directory childDirectory(String basename) =>
      fileSystem.directory(fileSystem.path.join(path, basename));

  @override
  fs.File childFile(String basename) =>
      fileSystem.file(fileSystem.path.join(path, basename));

  @override
  fs.Link childLink(String basename) =>
      fileSystem.link(fileSystem.path.join(path, basename));
}

/// A lock file of the runner: what it opens is recorded for
/// [PrecompiledHookFileSystem.closeLockFiles].
class _LockFile extends fs.ForwardingFileSystemEntity<fs.File, File>
    with fs.ForwardingFile {
  new(this.fileSystem, this.delegate);

  @override
  final PrecompiledHookFileSystem fileSystem;

  @override
  final File delegate;

  @override
  String get basename => fileSystem.path.basename(path);

  @override
  String get dirname => fileSystem.path.dirname(path);

  @override
  fs.Directory wrapDirectory(Directory delegate) =>
      fileSystem.directory(delegate.path);

  @override
  fs.File wrapFile(File delegate) => fileSystem.file(delegate.path);

  @override
  fs.Link wrapLink(Link delegate) => fileSystem.link(delegate.path);

  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) async {
    final RandomAccessFile file = await delegate.open(mode: mode);
    fileSystem._lockFiles.add(file);
    return file;
  }

  @override
  RandomAccessFile openSync({FileMode mode = FileMode.read}) {
    final RandomAccessFile file = delegate.openSync(mode: mode);
    fileSystem._lockFiles.add(file);
    return file;
  }
}
