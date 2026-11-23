/// The `verify` subcommand: Mach-O and framework verification.
///
/// Checks patched binaries, framework layouts and archives, stamping a
/// `verified` marker file when every check passes.

import 'dart:io';
import 'dart:typed_data';

import 'macho_cli.dart' show FlagCursor, usageError;
import 'macho_fat.dart' show FatSlice, extractFatSlices, isFatMachO, isMachO64;
import 'macho_framework.dart'
    show readRawFrameworkZipEntries, verifyMacosFramework;
import 'macho_parse.dart' show parseLoadCommands;

Map<String, Uint8List> _readZipArchiveEntries(Uint8List zipBytes) {
  final bd = ByteData.sublistView(zipBytes);
  var eocdOffset = -1;
  for (int i = zipBytes.length - 22; i >= 0; i--) {
    if (bd.getUint32(i, Endian.little) == 0x06054b50) {
      eocdOffset = i;
      break;
    }
  }
  if (eocdOffset == -1) {
    throw const FormatException(
      'Invalid ZIP archive: EOCD signature not found.',
    );
  }
  final int entryCount = bd.getUint16(eocdOffset + 10, Endian.little);
  final int cdOffset = bd.getUint32(eocdOffset + 16, Endian.little);
  return {
    for (final entry in readRawFrameworkZipEntries(
      bd,
      zipBytes,
      entryCount,
      cdOffset,
    ))
      entry.path: entry.data,
  };
}

/// Parsed `verify` subcommand flags.
class _VerifyArgs {
  new({
    required this.inputPath,
    required this.binaryRelpath,
    required this.frameworkZipPath,
    required this.objdumpPath,
    required this.outputPath,
    required this.expectedSubstrings,
    required this.expectedEntries,
    required this.forbiddenEntries,
  });

  final String? inputPath;
  final String? binaryRelpath;
  final String? frameworkZipPath;
  final String? objdumpPath;
  final String? outputPath;
  final List<String> expectedSubstrings;
  final List<String> expectedEntries;
  final List<String> forbiddenEntries;
}

/// Parses `verify` flags; unknown flags fail usage.
_VerifyArgs _parseVerifyArgs(List<String> args) {
  String? inputPath;
  String? binaryRelpath;
  String? frameworkZipPath;
  String? objdumpPath;
  String? outputPath;
  final expectedSubstrings = <String>[];
  final expectedEntries = <String>[];
  final forbiddenEntries = <String>[];
  final flags = FlagCursor(args);
  while (flags.moveNext()) {
    final String arg = flags.current;
    switch (arg) {
      case '--input':
        inputPath = flags.take('--input');
      case '--binary-relpath':
        binaryRelpath = flags.take('--binary-relpath');
      case '--framework-zip':
        frameworkZipPath = flags.take('--framework-zip');
      case '--objdump':
        objdumpPath = flags.take('--objdump');
      case '--expect':
        expectedSubstrings.add(flags.take('--expect'));
      case '--expect-entry':
        expectedEntries.add(flags.take('--expect-entry'));
      case '--forbid-entry':
        forbiddenEntries.add(flags.take('--forbid-entry'));
      case '--output':
        outputPath = flags.take('--output');
      default:
        usageError('Unknown flag for verify: $arg');
    }
  }
  return _VerifyArgs(
    inputPath: inputPath,
    binaryRelpath: binaryRelpath,
    frameworkZipPath: frameworkZipPath,
    objdumpPath: objdumpPath,
    outputPath: outputPath,
    expectedSubstrings: expectedSubstrings,
    expectedEntries: expectedEntries,
    forbiddenEntries: forbiddenEntries,
  );
}

/// Runs the `verify` subcommand: parses [args] and checks Mach-O and framework inputs.
void runVerify(List<String> args) {
  final _VerifyArgs parsed = _parseVerifyArgs(args);
  final String? inputPath = parsed.inputPath;
  final String? outputPath = parsed.outputPath;
  if (inputPath == null || outputPath == null) {
    usageError('verify requires --input and --output');
  }

  final String? binaryRelpath = parsed.binaryRelpath;
  final String? frameworkZipPath = parsed.frameworkZipPath;
  final bool isZipArchive =
      FileSystemEntity.isFileSync(inputPath) &&
      (inputPath.endsWith('.ipa') || inputPath.endsWith('.zip'));

  if (!isZipArchive &&
      ((binaryRelpath != null &&
              binaryRelpath.contains('.framework/Versions/')) ||
          (frameworkZipPath != null && frameworkZipPath.isNotEmpty))) {
    var fwName = 'App';
    if (binaryRelpath != null && binaryRelpath.contains('.framework/')) {
      final String seg = binaryRelpath
          .split('/')
          .firstWhere((s) => s.endsWith('.framework'));
      fwName = seg.substring(0, seg.length - '.framework'.length);
    }
    verifyMacosFramework(
      inputPath,
      frameworkName: fwName,
      frameworkZipPath: frameworkZipPath,
    );
  }

  String? tempExtractedBinaryPath;
  try {
    final String targetPath;
    final Uint8List bytes;
    if (isZipArchive) {
      final ({Uint8List bytes, String targetPath, String tempPath}) loaded =
          _loadZipVerifyTarget(parsed, inputPath, outputPath);
      targetPath = loaded.targetPath;
      bytes = loaded.bytes;
      tempExtractedBinaryPath = loaded.tempPath;
    } else {
      final ({Uint8List bytes, String targetPath}) loaded =
          _loadBundleVerifyTarget(parsed, inputPath);
      targetPath = loaded.targetPath;
      bytes = loaded.bytes;
    }

    _checkParsedMachO(targetPath, bytes);
    _checkObjdumpOutput(
      parsed.objdumpPath,
      targetPath,
      parsed.expectedSubstrings,
    );
    _writeVerifyStamp(outputPath);
  } finally {
    if (tempExtractedBinaryPath != null) {
      final f = File(tempExtractedBinaryPath);
      if (f.existsSync()) {
        f.deleteSync();
      }
    }
  }
}

/// Loads the verified binary from a ZIP/IPA archive, staging it at a
/// temporary path next to the stamp output.
({String targetPath, Uint8List bytes, String tempPath}) _loadZipVerifyTarget(
  _VerifyArgs parsed,
  String inputPath,
  String outputPath,
) {
  final Map<String, Uint8List> zipEntries = _readZipArchiveEntries(
    File(inputPath).readAsBytesSync(),
  );
  _checkZipVerifyEntries(
    zipEntries,
    inputPath,
    parsed.expectedEntries,
    parsed.forbiddenEntries,
  );
  final String? binaryRelpath = parsed.binaryRelpath;
  if (binaryRelpath == null || binaryRelpath.isEmpty) {
    throw ArgumentError(
      '--binary-relpath is required when verifying a ZIP/IPA archive.',
    );
  }
  final Uint8List? entryBytes = zipEntries[binaryRelpath];
  if (entryBytes == null) {
    throw StateError(
      'Binary "$binaryRelpath" not found in archive "$inputPath". '
      'Entries: ${zipEntries.keys.toList()}',
    );
  }
  final tempPath = '$outputPath.extracted_macho';
  final tempFile = File(tempPath);
  tempFile.parent.createSync(recursive: true);
  tempFile.writeAsBytesSync(entryBytes);
  return (targetPath: tempPath, bytes: entryBytes, tempPath: tempPath);
}

/// Loads the verified binary from a staged bundle directory or file.
({String targetPath, Uint8List bytes}) _loadBundleVerifyTarget(
  _VerifyArgs parsed,
  String inputPath,
) {
  _checkBundleVerifyEntries(
    inputPath,
    parsed.expectedEntries,
    parsed.forbiddenEntries,
  );
  final String? binaryRelpath = parsed.binaryRelpath;
  final targetPath = binaryRelpath != null && binaryRelpath.isNotEmpty
      ? '$inputPath/$binaryRelpath'
      : inputPath;
  return (
    targetPath: targetPath,
    bytes: File(targetPath).readAsBytesSync(),
  );
}

/// Throws when an expected archive entry is missing or a forbidden one hits.
void _checkZipVerifyEntries(
  Map<String, Uint8List> zipEntries,
  String inputPath,
  List<String> expectedEntries,
  List<String> forbiddenEntries,
) {
  for (final expectedEntry in expectedEntries) {
    if (!zipEntries.containsKey(expectedEntry) &&
        !zipEntries.containsKey('$expectedEntry/')) {
      throw StateError(
        'Expected archive entry "$expectedEntry" not found in "$inputPath". '
        'Entries: ${zipEntries.keys.toList()}',
      );
    }
  }
  for (final forbiddenEntry in forbiddenEntries) {
    final Iterable<String> matching = zipEntries.keys.where(
      (k) =>
          k == forbiddenEntry ||
          k.startsWith('$forbiddenEntry/') ||
          k.contains(forbiddenEntry),
    );
    if (matching.isNotEmpty) {
      throw StateError(
        'Forbidden archive entry "$forbiddenEntry" found in "$inputPath": '
        '${matching.toList()}',
      );
    }
  }
}

/// Throws when an expected bundle entry is missing or a forbidden one hits.
void _checkBundleVerifyEntries(
  String inputPath,
  List<String> expectedEntries,
  List<String> forbiddenEntries,
) {
  for (final expectedEntry in expectedEntries) {
    final candidate = '$inputPath/$expectedEntry';
    if (FileSystemEntity.typeSync(candidate, followLinks: false) ==
        FileSystemEntityType.notFound) {
      throw StateError(
        'Expected bundle entry "$expectedEntry" not found under "$inputPath".',
      );
    }
  }
  for (final forbiddenEntry in forbiddenEntries) {
    final candidate = '$inputPath/$forbiddenEntry';
    if (FileSystemEntity.typeSync(candidate, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw StateError(
        'Forbidden bundle entry "$forbiddenEntry" found under "$inputPath".',
      );
    }
  }
}

/// Parses the loaded binary's load commands, failing unless it is Mach-O.
void _checkParsedMachO(String targetPath, Uint8List bytes) {
  if (!isMachO64(bytes) && !isFatMachO(bytes)) {
    throw FormatException(
      'File "$targetPath" is not a 64-bit or universal Mach-O binary.',
    );
  }
  if (isFatMachO(bytes)) {
    for (final FatSlice s in extractFatSlices(bytes)) {
      parseLoadCommands(s.bytes);
    }
  } else {
    parseLoadCommands(bytes);
  }
}

/// Runs llvm-objdump on [targetPath] and checks the expected substrings.
void _checkObjdumpOutput(
  String? objdumpPath,
  String targetPath,
  List<String> expectedSubstrings,
) {
  if (objdumpPath == null || objdumpPath.isEmpty) return;
  final ProcessResult res = Process.runSync(objdumpPath, [
    '--macho',
    '--private-headers',
    '--dylib-id',
    '--arch=all',
    targetPath,
  ]);
  if (res.exitCode != 0) {
    throw StateError(
      'llvm-objdump failed on "$targetPath" (exit ${res.exitCode}):\n'
      '${res.stderr}',
    );
  }
  final stdoutStr = res.stdout as String;
  for (final expected in expectedSubstrings) {
    if (!stdoutStr.contains(expected)) {
      throw StateError(
        'Expected substring "$expected" not found in llvm-objdump output for '
        '"$targetPath":\n$stdoutStr',
      );
    }
  }
}

/// Writes the `verified` stamp file for a successful `verify` run.
void _writeVerifyStamp(String outputPath) {
  final outFile = File(outputPath);
  outFile.parent.createSync(recursive: true);
  outFile.writeAsStringSync('verified\n');
}
