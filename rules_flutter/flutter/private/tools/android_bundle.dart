/// Android application bundling tool for `flutter_android_bundle`.
///
/// Replaces shell actions with hermetic Dart commands:
///   - `native-libs-jar`: Validates that every native library is an ELF binary
///     matching the target Android ABI's `e_machine`, then packages all
///     `lib/<abi>/<basename>=<src>` entries into the output `.jar` via `zipper`.
///   - `empty-jar`: Writes a minimal valid 22-byte empty ZIP (End of Central
///     Directory record) for debug/JIT builds with no native libraries.
///   - `debug-assets`: Copies the `flutter_assets` tree (dereferencing
///     symlinks), `kernel_blob.bin`, and optional `vm_snapshot_data` /
///     `isolate_snapshot_data` into the debug assets directory.
///   - `aar`: Packs a Flutter module's AOT library per ABI (`jni/<abi>/libapp.so`,
///     ELF-validated), its `flutter_assets` tree (under `assets/`), the
///     manifest, an empty `classes.jar` and an empty `R.txt` into an Android
///     library archive.
///   - `apk-overlay`: Injects the Flutter payload (`native_libs.jar` entries
///     plus the `flutter_assets` tree) into an unsigned base APK after
///     resource linking, so Dart edits re-run only this step plus the stock
///     `zipalign`/`apksigner` steps instead of aapt2 and the dex chain.
library;

import 'dart:io';
import 'dart:typed_data';

import 'apk_overlay.dart' show runApkOverlay;

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

/// Writes the 22-byte empty ZIP/JAR to [outputPath].
void writeEmptyJar(String outputPath) {
  final file = File(outputPath);
  file.parent.createSync(recursive: true);
  file.writeAsBytesSync(emptyJarBytes, flush: true);
}

/// Validates each `lib/<abi>/<name>=<src>` entry in [entries] as an ELF shared
/// object for [abi] ([wantMachine]) and packages them into [outputPath] using
/// [zipperPath].
Future<void> packageNativeLibsJar({
  required String outputPath,
  required String abi,
  required int wantMachine,
  String? zipperPath,
  required List<String> entries,
}) async {
  if (entries.isEmpty) {
    writeEmptyJar(outputPath);
    return;
  }

  final zipEntries = <ZipEntry>[];
  for (final spec in entries) {
    final int eq = spec.indexOf('=');
    if (eq <= 0 || eq == spec.length - 1) {
      throw ArgumentError.value(
        spec,
        'entries',
        'expected <jar_entry>=<source_path>',
      );
    }
    final String entryPath = spec.substring(0, eq);
    final String srcPath = spec.substring(eq + 1);
    final RandomAccessFile raf = File(srcPath).openSync();
    final Uint8List header;
    try {
      header = raf.readSync(20);
    } finally {
      raf.closeSync();
    }
    validateAndroidElf(
      header,
      path: srcPath,
      wantMachine: wantMachine,
      abi: abi,
    );

    // Normalize file mode bits: only the executable bit of the source is
    // honoured; all other permission bits come from a fixed, host-independent
    // value (0644 / 0755), matching xtool_pack.dart. Host umask and source
    // stat.mode beyond the executable bit never leak into the jar.
    final int sourceMode = File(srcPath).statSync().mode;
    final isExecutable = (sourceMode & 0x49) != 0;
    final Uint8List bytes = File(srcPath).readAsBytesSync();
    // Stored, never deflated: the APK stores native libraries uncompressed
    // so zipalign can page-align them, and the APK overlay copies them
    // without inflating — which is also what lets libraries over 64 MiB
    // through, at any size below the ZIP32 limits.
    zipEntries.add(
      ZipEntry(
        path: entryPath,
        data: bytes,
        isExecutable: isExecutable,
        storeOnly: true,
      ),
    );
  }

  File(outputPath).parent.createSync(recursive: true);
  final Uint8List zipBytes = encodeDeterministicZip(zipEntries);
  File(outputPath).writeAsBytesSync(zipBytes, flush: true);
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
      'Expected subcommand: "native-libs-jar", "empty-jar", "debug-assets", "aar", or "apk-overlay".',
    );
  }
  final String subcommand = args.first;
  final List<String> rest = args.sublist(1);
  switch (subcommand) {
    case 'native-libs-jar':
      await _runNativeLibsJar(rest);
    case 'empty-jar':
      _runEmptyJar(rest);
    case 'debug-assets':
      _runDebugAssets(rest);
    case 'apk-overlay':
      runApkOverlay(rest);
    case 'aar':
      _runAar(rest);
    default:
      throw ArgumentError('Unknown subcommand: $subcommand');
  }
}

Future<void> _runNativeLibsJar(List<String> args) async {
  String? output;
  String? abi;
  int? machine;
  String? zipper;
  final entries = <String>[];

  for (var i = 0; i < args.length; i++) {
    final String arg = args[i];
    switch (arg) {
      case '--output':
        if (i + 1 >= args.length) {
          throw ArgumentError('Missing value for --output');
        }
        output = args[++i];
      case '--abi':
        if (i + 1 >= args.length) {
          throw ArgumentError('Missing value for --abi');
        }
        abi = args[++i];
      case '--machine':
        if (i + 1 >= args.length) {
          throw ArgumentError('Missing value for --machine');
        }
        machine = int.parse(args[++i]);
      case '--zipper':
        if (i + 1 >= args.length) {
          throw ArgumentError('Missing value for --zipper');
        }
        zipper = args[++i];
      default:
        if (arg.startsWith('--')) {
          throw ArgumentError('Unknown option for native-libs-jar: $arg');
        }
        entries.add(arg);
    }
  }

  if (output == null || abi == null || machine == null) {
    throw ArgumentError(
      'Usage: android_bundle.dart native-libs-jar --output <jar> --abi <abi> '
      '--machine <machine> [<entry=src>...]',
    );
  }

  await packageNativeLibsJar(
    outputPath: output,
    abi: abi,
    wantMachine: machine,
    zipperPath: zipper,
    entries: entries,
  );
}

void _runEmptyJar(List<String> args) {
  String? output;
  for (var i = 0; i < args.length; i++) {
    final String arg = args[i];
    if (arg == '--output') {
      if (i + 1 >= args.length) {
        throw ArgumentError('Missing value for --output');
      }
      output = args[++i];
    } else {
      throw ArgumentError('Unknown option for empty-jar: $arg');
    }
  }
  if (output == null) {
    throw ArgumentError('Usage: android_bundle.dart empty-jar --output <jar>');
  }
  writeEmptyJar(output);
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
