// Patches an SDK AOT snapshot so comma-containing `-D` / `--define` values
// survive the front end.
//
// `Parser._setOption` splits `addMultiOption` values on `,` (`0x2C`), so
// `-DFOO=a,b` arrives as two defines (`FOO=a` and `b`). This file rewrites the
// comparison in the `kernel_worker` and `gen_kernel` AOT snapshots so the
// split never fires, letting the value reach constant evaluation unchanged.
//
// This is the only implementation of the patch. It runs exactly once per SDK
// as a declared Bazel action (the `dart_toolchain` rule patches its snapshots
// into action outputs the compiles take as tool inputs); no compile patches,
// caches, or executes a snapshot from a shared temporary directory. See the
// `dart_toolchain` rule in `dart/toolchain.bzl`.
//
// As a library it exposes the pure pieces (`patchSnapshotSplitCommasBytes`,
// `hasCommaDefineArgs`, `unpatchedCommaDefinesError`), which the compile
// tools use to refuse a comma-containing compile whose snapshot was not
// patched, and which tests use to exercise the patch without a build.
import 'dart:io';
import 'dart:typed_data';

/// Patches `Parser._setOption` in a `kernel_worker` or `gen_kernel` AOT
/// snapshot byte buffer so `addMultiOption` options (`-D` / `--define`) do not
/// split values on `,` (`0x2C`), allowing comma-containing defines to reach
/// the front end's constant evaluation unchanged.
///
/// Returns `true` if the pattern was found and patched in [bytes].
bool patchSnapshotSplitCommasBytes(Uint8List bytes) {
  final x64Idx = _findBytesPattern(bytes, _x64SplitCommasPattern);
  if (x64Idx >= 0) {
    bytes[x64Idx + 11] = 0x90; // nop
    bytes[x64Idx + 12] = 0xe9; // jmp rel32 (+0x13a)
    return true;
  }
  final arm64Idx = _findBytesPattern(bytes, _arm64SplitCommasPattern);
  if (arm64Idx >= 0) {
    bytes[arm64Idx + 8] = 0x4e; // b +0x138
    bytes[arm64Idx + 9] = 0x00;
    bytes[arm64Idx + 10] = 0x00;
    bytes[arm64Idx + 11] = 0x14;
    return true;
  }
  return false;
}

/// Whether any `-D` / `--define` option in [args] carries a comma in its value.
///
/// Only then does the front end need the snapshot patch
/// ([patchSnapshotSplitCommasBytes]).
bool hasCommaDefineArgs(List<String> args) {
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == '-D' || arg == '--define') {
      if (i + 1 < args.length && args[i + 1].contains(',')) return true;
    } else if (arg.startsWith('-D') && arg.length > 2) {
      if (arg.substring(2).contains(',')) return true;
    } else if (arg.startsWith('--define=')) {
      if (arg.substring('--define='.length).contains(',')) return true;
    }
  }
  return false;
}

/// The error refusing a compile whose `-D` / `--define` values contain a
/// comma but whose [snapshotKind] snapshot was not patched, or null when the
/// compile may proceed (no comma define, or [snapshotPatched]).
///
/// A compile that ignored this would silently split `-DFOO=a,b` into two
/// defines, so the check fails loudly instead.
String? unpatchedCommaDefinesError(
  List<String> args, {
  required bool snapshotPatched,
  required String snapshotKind,
  required String toolName,
}) {
  if (snapshotPatched || !hasCommaDefineArgs(args)) return null;
  return '$toolName: a `-D` / `--define` value contains a comma, but the '
      '$snapshotKind snapshot was not comma-patched; compiling it as is would '
      'silently split the value into two defines. Patch the snapshot with '
      'comma_patch.dart first.';
}

/// Copies the SDK snapshot at [inputPath] to [outputPath] with
/// [patchSnapshotSplitCommasBytes] applied.
///
/// Returns null on success, or an error describing why no patched snapshot
/// was written: the input is unreadable, or it matches no known AOT snapshot
/// pattern, in which case comma-containing defines cannot compile with this
/// SDK and the caller fails loudly.
String? patchSnapshotFile({
  required String inputPath,
  required String outputPath,
  required String sdkVersion,
  required String snapshotKind,
}) {
  final Uint8List bytes;
  try {
    bytes = File(inputPath).readAsBytesSync();
  } on FileSystemException catch (error) {
    return 'comma_patch: cannot read the $snapshotKind snapshot at '
        '$inputPath (Dart SDK $sdkVersion): $error';
  }
  if (!patchSnapshotSplitCommasBytes(bytes)) {
    return 'comma_patch: the $snapshotKind snapshot at $inputPath (Dart SDK '
        '$sdkVersion) matches no known comma-split pattern, so '
        'comma-containing `-D` / `--define` values (e.g. `-DFOO=a,b`) cannot '
        'compile with this SDK. The SDK layout changed across versions; the '
        'patch patterns in comma_patch.dart need one for this snapshot.';
  }
  try {
    File(outputPath).writeAsBytesSync(bytes, flush: true);
  } on FileSystemException catch (error) {
    return 'comma_patch: cannot write the patched $snapshotKind snapshot to '
        '$outputPath (Dart SDK $sdkVersion): $error';
  }
  return null;
}

/// The Bazel action entry point: reads one SDK snapshot, writes its patched
/// copy, and fails loudly when the snapshot matches no known pattern.
///
/// Usage: `dart comma_patch.dart --input=<sdk snapshot> --output=<out>
/// --sdk-version=<version> --kind=<snapshotKind>`. Prints nothing on success.
int runPatchCli(List<String> argv) {
  String? input;
  String? output;
  String? sdkVersion;
  String? kind;
  for (final arg in argv) {
    if (arg.startsWith('--input=')) {
      input = arg.substring('--input='.length);
    } else if (arg.startsWith('--output=')) {
      output = arg.substring('--output='.length);
    } else if (arg.startsWith('--sdk-version=')) {
      sdkVersion = arg.substring('--sdk-version='.length);
    } else if (arg.startsWith('--kind=')) {
      kind = arg.substring('--kind='.length);
    } else {
      stderr.writeln('comma_patch: unknown argument $arg');
      _usage();
      return 2;
    }
  }
  if (input == null ||
      input.isEmpty ||
      output == null ||
      output.isEmpty ||
      sdkVersion == null ||
      sdkVersion.isEmpty ||
      kind == null ||
      kind.isEmpty) {
    stderr.writeln(
      'comma_patch: --input, --output, --sdk-version and --kind '
      'are required.',
    );
    _usage();
    return 2;
  }
  final error = patchSnapshotFile(
    inputPath: input,
    outputPath: output,
    sdkVersion: sdkVersion,
    snapshotKind: kind,
  );
  if (error != null) {
    stderr.writeln(error);
    return 1;
  }
  return 0;
}

void _usage() {
  stderr.writeln(
    'usage: dart comma_patch.dart --input=<sdk snapshot> --output=<out> '
    '--sdk-version=<version> --kind=<snapshotKind>',
  );
}

void main(List<String> argv) {
  exit(runPatchCli(argv));
}

const _x64SplitCommasPattern = <int>[
  0x48, 0x8b, 0x45, 0xf0, // mov rax, [rbp-0x10]
  0x48, 0x8b, 0x48, 0x5f, // mov rcx, [rax+0x5f]
  0xf6, 0xc1, 0x10, // test cl, 0x10
  0x0f, 0x85, 0x3a, 0x01, 0x00, 0x00, // jnz +0x13a
  0x48, 0x8b, 0x4d, 0xe8, // mov rcx, [rbp-0x18]
  0x8b, 0x51, 0xff, // mov edx, [rcx-0x1]
];

const _arm64SplitCommasPattern = <int>[
  0xa3, 0x03, 0x5f, 0xf8, // ldur x3, [fp, #-16]
  0x60, 0xf0, 0x45, 0xf8, // ldur x0, [x3, #95]
  0xc0, 0x09, 0x20, 0x37, // tbnz w0, #4, +0x138
  0xa0, 0x83, 0x5e, 0xf8, // ldur x0, [fp, #-24]
  0x01, 0xf0, 0x5f, 0xf8, // ldur w1, [x0, #-1]
];

int _findBytesPattern(Uint8List haystack, List<int> needle) {
  final nLen = needle.length;
  final limit = haystack.length - nLen;
  if (limit < 0) return -1;
  final first = needle[0];
  for (var i = 0; i <= limit; i++) {
    if (haystack[i] != first) continue;
    var match = true;
    for (var j = 1; j < nLen; j++) {
      if (haystack[i + j] != needle[j]) {
        match = false;
        break;
      }
    }
    if (match) return i;
  }
  return -1;
}
