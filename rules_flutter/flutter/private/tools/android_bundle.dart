/// The Dart payload tool of `flutter_android_bundle` and `flutter_android_aar`.
///
/// Two commands:
///   - `debug-assets`: Copies the `flutter_assets` tree (dereferencing
///     symlinks), `kernel_blob.bin`, and optional `vm_snapshot_data` /
///     `isolate_snapshot_data` into the debug assets directory.
///   - `aar`: Packs a Flutter module's AOT library per ABI (`jni/<abi>/libapp.so`,
///     ELF-validated), its `flutter_assets` tree (under `assets/`), the
///     manifest, an empty `classes.jar` and an empty `R.txt` into an Android
///     library archive.
library;

import 'dart:io';
import 'dart:typed_data';

import 'zip_writer.dart' show ZipEntry, encodeDeterministicZip;

/// Minimal valid 22-byte ZIP file (End of Central Directory record with zero
/// entries), identical to the output of `zip` on an empty archive.
const List<int> emptyJarBytes = <int>[
  0x50,
  0x4b,
  0x05,
  0x06,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
];

/// Validates that [bytes] (at least the first 20 bytes of [path]) begins with
/// an ELF header whose little-endian `e_machine` at offset 18 matches
/// [wantMachine].
void validateAndroidElf(
  List<int> bytes, {
  required String path,
  required int wantMachine,
  required String abi,
}) {
  if (bytes.length < 20 ||
      bytes[0] != 0x7f ||
      bytes[1] != 0x45 ||
      bytes[2] != 0x4c ||
      bytes[3] != 0x46) {
    throw FormatException(
      'ERROR: $path is not an ELF binary. Android ($abi) cannot load it.',
    );
  }
  final int machine = bytes[18] | (bytes[19] << 8);
  if (machine != wantMachine) {
    throw FormatException(
      'ERROR: $path has ELF machine $machine; $abi requires $wantMachine.',
    );
  }
}

/// Copies [assetsDir] (dereferencing symlinks) into [outputDir] and adds
/// `kernel_blob.bin` plus optional `vm_snapshot_data` and
/// `isolate_snapshot_data`.
void assembleDebugAssets({
  required String assetsDir,
  required String outputDir,
  required String kernelPath,
  String? vmSnapshotPath,
  String? isolateSnapshotPath,
}) {
  final outDir = Directory(outputDir)..createSync(recursive: true);
  _copyDirectoryDereferencingLinks(Directory(assetsDir), outDir);
  File(kernelPath).copySync('$outputDir/kernel_blob.bin');
  if (vmSnapshotPath != null && vmSnapshotPath.isNotEmpty) {
    File(vmSnapshotPath).copySync('$outputDir/vm_snapshot_data');
  }
  if (isolateSnapshotPath != null && isolateSnapshotPath.isNotEmpty) {
    File(isolateSnapshotPath).copySync('$outputDir/isolate_snapshot_data');
  }
}

void _copyDirectoryDereferencingLinks(Directory src, Directory dst) {
  dst.createSync(recursive: true);
  final List<FileSystemEntity> entities = src.listSync(
    recursive: false,
    followLinks: true,
  )..sort((a, b) => a.path.compareTo(b.path));
  for (final entity in entities) {
    final String name = entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
    final dstPath = '${dst.path}/$name';
    if (entity is File) {
      entity.copySync(dstPath);
    } else if (entity is Directory) {
      _copyDirectoryDereferencingLinks(entity, Directory(dstPath));
    } else if (entity is Link) {
      final String resolved = entity.resolveSymbolicLinksSync();
      if (FileSystemEntity.isDirectorySync(resolved)) {
        _copyDirectoryDereferencingLinks(
          Directory(resolved),
          Directory(dstPath),
        );
      } else {
        File(resolved).copySync(dstPath);
      }
    }
  }
}

/// Dispatches the CLI arguments for `android_bundle.dart`.
Future<void> runAndroidBundle(List<String> args) async {
  if (args.isEmpty) {
    throw ArgumentError(
      'Expected subcommand: "debug-assets" or "aar".',
    );
  }
  final String subcommand = args.first;
  final List<String> rest = args.sublist(1);
  switch (subcommand) {
    case 'debug-assets':
      _runDebugAssets(rest);
    case 'aar':
      _runAar(rest);
    default:
      throw ArgumentError('Unknown subcommand: $subcommand');
  }
}

void _runDebugAssets(List<String> args) {
  String? assetsDir;
  String? outputDir;
  String? kernel;
  String? vmSnapshot;
  String? isolateSnapshot;

  for (var i = 0; i < args.length; i++) {
    final String arg = args[i];
    if (i + 1 >= args.length) {
      throw ArgumentError('Missing value for $arg');
    }
    switch (arg) {
      case '--assets-dir':
        assetsDir = args[++i];
      case '--output-dir':
        outputDir = args[++i];
      case '--kernel':
        kernel = args[++i];
      case '--vm-snapshot':
        vmSnapshot = args[++i];
      case '--isolate-snapshot':
        isolateSnapshot = args[++i];
      default:
        throw ArgumentError('Unknown option for debug-assets: $arg');
    }
  }

  if (assetsDir == null || outputDir == null || kernel == null) {
    throw ArgumentError(
      'Usage: android_bundle.dart debug-assets --assets-dir <dir> '
      '--output-dir <dir> --kernel <file> '
      '[--vm-snapshot <file>] [--isolate-snapshot <file>]',
    );
  }

  assembleDebugAssets(
    assetsDir: assetsDir,
    outputDir: outputDir,
    kernelPath: kernel,
    vmSnapshotPath: vmSnapshot,
    isolateSnapshotPath: isolateSnapshot,
  );
}

/// One AOT library of an `aar`: packaged at `jni/[abi]/libapp.so`.
class AarLibrary {
  const new({
    required this.abi,
    required this.machine,
    required this.path,
  });

  /// Android ABI directory name, e.g. `arm64-v8a`.
  final String abi;

  /// ELF `e_machine` the library must have for [abi].
  final int machine;

  /// Source path of the library.
  final String path;
}

/// Lists the files under [dir] as sorted `relative/path` strings, following
/// symlinks.
List<String> _listTreeFiles(Directory dir) {
  final files = <String>[];
  void walk(Directory d, String prefix) {
    final List<FileSystemEntity> entities = d.listSync()
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final entity in entities) {
      final String name = entity.uri.pathSegments
          .where((s) => s.isNotEmpty)
          .last;
      if (entity is Directory) {
        walk(entity, '$prefix$name/');
      } else {
        files.add('$prefix$name');
      }
    }
  }

  walk(dir, '');
  return files;
}

/// Writes the Android library archive [outputPath] from [libraries], the
/// `flutter_assets` tree at [assetsDir] and the manifest at [manifestPath].
void packageAar({
  required String outputPath,
  required String manifestPath,
  required String assetsDir,
  required List<AarLibrary> libraries,
}) {
  final entries = <ZipEntry>[
    ZipEntry(
      path: 'AndroidManifest.xml',
      data: File(manifestPath).readAsBytesSync(),
    ),
    ZipEntry(path: 'classes.jar', data: Uint8List.fromList(emptyJarBytes)),
    ZipEntry(path: 'R.txt', data: Uint8List(0)),
  ];
  final seen = <String>{};
  for (final lib in libraries) {
    if (!seen.add(lib.abi)) {
      throw ArgumentError('ERROR: two libraries for ABI ${lib.abi}.');
    }
    final Uint8List bytes = File(lib.path).readAsBytesSync();
    validateAndroidElf(
      bytes,
      path: lib.path,
      wantMachine: lib.machine,
      abi: lib.abi,
    );
    entries.add(
      ZipEntry(
        path: 'jni/${lib.abi}/libapp.so',
        data: bytes,
        storeOnly: true,
      ),
    );
  }
  for (final String rel in _listTreeFiles(Directory(assetsDir))) {
    entries.add(
      ZipEntry(
        path: 'assets/flutter_assets/$rel',
        data: File('$assetsDir/$rel').readAsBytesSync(),
      ),
    );
  }
  entries.sort((a, b) => a.path.compareTo(b.path));
  File(outputPath).parent.createSync(recursive: true);
  File(outputPath)
      .writeAsBytesSync(encodeDeterministicZip(entries), flush: true);
}

void _runAar(List<String> args) {
  String? output;
  String? manifest;
  String? assetsDir;
  final libraries = <AarLibrary>[];
  for (var i = 0; i < args.length; i++) {
    final String arg = args[i];
    switch (arg) {
      case '--output':
        output = args[++i];
      case '--manifest':
        manifest = args[++i];
      case '--assets-dir':
        assetsDir = args[++i];
      case '--lib':
        libraries.add(
          AarLibrary(
            abi: args[++i],
            machine: int.parse(args[++i]),
            path: args[++i],
          ),
        );
      default:
        throw ArgumentError('Unknown option for aar: $arg');
    }
  }
  if (output == null || manifest == null || assetsDir == null) {
    throw ArgumentError(
      'Usage: android_bundle.dart aar --output <aar> --manifest <xml> '
      '--assets-dir <dir> [--lib <abi> <machine> <libapp.so>]...',
    );
  }
  packageAar(
    outputPath: output,
    manifestPath: manifest,
    assetsDir: assetsDir,
    libraries: libraries,
  );
}

Future<void> main(List<String> args) async {
  try {
    await runAndroidBundle(args);
  } on FormatException catch (e) {
    stderr.writeln(e.message);
    exit(1);
  } on ArgumentError catch (e) {
    stderr.writeln(e);
    exit(1);
  }
}
