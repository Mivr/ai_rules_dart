import 'dart:io';

import 'package:file/file.dart' as fs;
import 'package:file/local.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'hook_file_system.dart';

final p.Context windows = p.Context(style: p.Style.windows, current: r'C:\w');
final p.Context posix = p.Context(style: p.Style.posix, current: '/w');

CacheFile? cached(String path, p.Context context) => cacheFile(
  path,
  kernelName: hookKernelName,
  hashesName: hookKernelHashesName,
  context: context,
);

void main() {
  group('cacheFile', () {
    // Where the runner looks, as `Uri.toFilePath()` spells it on each host.
    const windowsDir =
        r'C:\b\execroot\_main\bazel-out\x64_windows-fastbuild\bin'
        r'\glyphs.link.work\.dart_tool\hooks_runner\glyphs\5f0c2a';
    const posixDir =
        '/b/execroot/_main/bazel-out/k8-fastbuild/bin'
        '/glyphs.link.work/.dart_tool/hooks_runner/glyphs/5f0c2a';

    test('finds the kernel and its hashes in Windows form', () {
      expect(cached('$windowsDir\\hook.dill', windows), CacheFile.kernel);
      expect(
        cached('$windowsDir\\hook.dependencies_hash_file.json', windows),
        CacheFile.kernelHashes,
      );
    });

    test('takes forward and mixed separators on Windows', () {
      final String forward = windowsDir.replaceAll(r'\', '/');
      expect(cached('$forward/hook.dill', windows), CacheFile.kernel);
      expect(cached('$windowsDir/hook.dill', windows), CacheFile.kernel);
    });

    test('finds them in POSIX form', () {
      expect(cached('$posixDir/hook.dill', posix), CacheFile.kernel);
      expect(
        cached('$posixDir/hook.dependencies_hash_file.json', posix),
        CacheFile.kernelHashes,
      );
    });

    test('a backslash is no separator on POSIX', () {
      expect(cached('$windowsDir\\hook.dill', posix), isNull);
    });

    test('leaves shared files, other names and other directories alone', () {
      expect(
        cached(
          r'C:\b\.dart_tool\hooks_runner\shared\glyphs\hook.dill',
          windows,
        ),
        isNull,
      );
      expect(cached('$windowsDir\\hook.dill.d', windows), isNull);
      expect(cached(r'C:\b\.dart_tool\glyphs\hook.dill', windows), isNull);
      expect(
        cached(r'C:\b\.dart_tool\hooks_runner\hook.dill', windows),
        isNull,
      );
    });
  });

  group('samePath', () {
    test('ignores separators and drive-letter case on Windows', () {
      expect(
        samePath(
          r'C:\w\app\pubspec.yaml',
          'c:/w/app/pubspec.yaml',
          context: windows,
        ),
        isTrue,
      );
      expect(
        samePath(
          r'C:\w\app\pubspec.yaml',
          r'C:\w\pubspec.yaml',
          context: windows,
        ),
        isFalse,
      );
    });

    test('is exact on POSIX', () {
      expect(
        samePath('/w/a/pubspec.yaml', '/w/a/pubspec.yaml', context: posix),
        isTrue,
      );
      expect(
        samePath('/w/A/pubspec.yaml', '/w/a/pubspec.yaml', context: posix),
        isFalse,
      );
    });
  });

  group('absolute', () {
    test('joins an exec-root-relative path on Windows', () {
      expect(
        absolute(
          'bazel-out/x/hook.dill',
          r'C:\b\execroot\_main',
          context: windows,
        ),
        r'C:\b\execroot\_main\bazel-out/x/hook.dill',
      );
    });

    test('keeps a Windows absolute path, which has no leading slash', () {
      expect(
        absolute(r'C:\sdk\bin\dart.exe', r'C:\b', context: windows),
        r'C:\sdk\bin\dart.exe',
      );
      expect(
        absolute('C:/sdk/bin/dart.exe', r'C:\b', context: windows),
        'C:/sdk/bin/dart.exe',
      );
      expect(
        absolute(r'\\host\share\x', r'C:\b', context: windows),
        r'\\host\share\x',
      );
    });

    test('joins and keeps on POSIX', () {
      expect(
        absolute('bazel-out/x', '/b/_main', context: posix),
        '/b/_main/bazel-out/x',
      );
      expect(absolute('/sdk/dart', '/b/_main', context: posix), '/sdk/dart');
    });
  });

  group('PrecompiledHookFileSystem', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('hook_fs_test'));
    tearDown(() => tmp.deleteSync(recursive: true));

    PrecompiledHookFileSystem make({String? pubspec, p.Context? context}) {
      File('${tmp.path}/kernel.dill').writeAsStringSync('kernel');
      File('${tmp.path}/hashes.json').writeAsStringSync('{}');
      File('${tmp.path}/slice.json').writeAsStringSync('{"hooks":{}}');
      return PrecompiledHookFileSystem(
        const LocalFileSystem(),
        kernel: '${tmp.path}/kernel.dill',
        kernelHashes: '${tmp.path}/hashes.json',
        pubspec: pubspec,
        pubspecSlice: '${tmp.path}/slice.json',
        context: context,
      );
    }

    test('serves the kernel where the runner asks for it on Windows', () {
      final PrecompiledHookFileSystem files = make(context: windows);
      expect(
        files
            .file(r'C:\w\.dart_tool\hooks_runner\glyphs\5f0c2a\hook.dill')
            .readAsStringSync(),
        'kernel',
      );
      expect(files.kernelServed, isTrue);
      expect(
        files
            .file(
              r'C:\w\.dart_tool\hooks_runner\glyphs\5f0c2a'
              r'\hook.dependencies_hash_file.json',
            )
            .readAsStringSync(),
        '{}',
      );
    });

    test('serves the pubspec slice for another spelling on Windows', () {
      final PrecompiledHookFileSystem files = make(
        pubspec: r'C:\w\app\pubspec.yaml',
        context: windows,
      );
      expect(
        files.file('c:/w/app/pubspec.yaml').readAsStringSync(),
        '{"hooks":{}}',
      );
    });

    test('closes the lock files the runner leaves open', () async {
      final PrecompiledHookFileSystem files = make();
      // As package:hooks_runner names a directory's lock file: through the
      // directory's own file system, with the host's separator.
      final fs.Directory directory = files.directory(tmp.uri);
      expect(directory.fileSystem, same(files));
      final fs.File lock = directory.fileSystem.file(
        '${directory.path}${Platform.pathSeparator}.lock',
      );
      await lock.create(recursive: true);
      final RandomAccessFile open = await lock.open(mode: FileMode.write);
      await open.lock();
      await open.writeString('held');
      await open.unlock();

      await files.closeLockFiles();
      expect(
        () => open.writeStringSync('x'),
        throwsA(isA<FileSystemException>()),
      );
      // A second call has nothing left to close.
      await files.closeLockFiles();
    });

    test("a file listed in a directory is the file system's own", () {
      final PrecompiledHookFileSystem files = make();
      File('${tmp.path}/sub/.lock').createSync(recursive: true);
      final fs.FileSystemEntity lock = files
          .directory('${tmp.path}/sub')
          .listSync()
          .single;
      expect(lock.fileSystem, same(files));
    });
  });
}
