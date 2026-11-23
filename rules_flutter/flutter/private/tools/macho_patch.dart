/// Mach-O patching: the `patch` subcommand and its core.
///
/// Rewrites load commands (`LC_BUILD_VERSION`, identities, rpaths) in thin
/// and Fat binaries via [patchMachO], resigning the embedded code signature.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'macho_cli.dart';
import 'macho_codesign.dart' show resignEmbeddedSignature;
import 'macho_constants.dart';
import 'macho_fat.dart'
    show
        FatSlice,
        buildFatMachO,
        cpuTypeForArch,
        extractFatSlices,
        isFatMachO,
        isMachO32,
        isMachO64,
        thinFatMachO;
import 'macho_parse.dart'
    show
        FirstPayload,
        LoadCommand,
        buildLcBuildVersion,
        buildLcIdDylib,
        buildLcRpath,
        findFirstPayload,
        parseLoadCommands;
import 'macho_strip.dart' show StrippedSymbols, stripLocalSymbols;

/// Writes [bytes] to [outputPath], creating parent directories as needed.
void _writePatchedOutput(Uint8List bytes, String outputPath) {
  final outFile = File(outputPath);
  outFile.parent.createSync(recursive: true);
  outFile.writeAsBytesSync(bytes);
}

/// Parsed `patch` subcommand flags.
class _PatchArgs {
  new({
    required this.inputPath,
    required this.outputPath,
    required this.platformName,
    required this.minOsStr,
    required this.sdkVersionStr,
    required this.installName,
    required this.arch,
    required this.rpaths,
    required this.allowNonMacho,
    required this.stripSymbols,
  });

  final String? inputPath;
  final String? outputPath;
  final String? platformName;
  final String? minOsStr;
  final String? sdkVersionStr;
  final String? installName;
  final String? arch;
  final List<String> rpaths;
  final Set<String> allowNonMacho;

  /// Whether to drop local and stab symbols, `strip -x` style.
  final bool stripSymbols;
}

/// Parses `patch` flags; unknown flags fail usage.
_PatchArgs _parsePatchArgs(List<String> args) {
  String? inputPath;
  String? outputPath;
  String? platformName;
  String? minOsStr;
  String? sdkVersionStr;
  String? installName;
  String? arch;
  final rpaths = <String>[];
  final allowNonMacho = <String>{};
  var stripSymbols = false;
  final flags = FlagCursor(args);
  while (flags.moveNext()) {
    final String arg = flags.current;
    if (arg.startsWith('--allow-non-macho=')) {
      addCommaParts(
        allowNonMacho,
        arg.substring('--allow-non-macho='.length),
      );
      continue;
    }
    switch (arg) {
      case '--strip-symbols':
        stripSymbols = true;
      case '--input':
        inputPath = flags.take('--input');
      case '--output':
        outputPath = flags.take('--output');
      case '--platform':
        platformName = flags.take('--platform');
      case '--min-os':
        minOsStr = flags.take('--min-os');
      case '--sdk-version':
        sdkVersionStr = flags.take('--sdk-version');
      case '--install-name':
        installName = flags.take('--install-name');
      case '--arch':
        arch = flags.take('--arch');
      case '--rpath':
        for (final String part in flags.take('--rpath').split(',')) {
          if (part.isNotEmpty) rpaths.add(part);
        }
      case '--allow-non-macho':
        final String? next = flags.peek();
        if (next == null || next.startsWith('--')) {
          usageError(
            '--allow-non-macho requires an explicit binary or framework name',
          );
        }
        addCommaParts(allowNonMacho, flags.take('--allow-non-macho'));
      default:
        usageError('Unknown flag for patch: $arg');
    }
  }
  return _PatchArgs(
    inputPath: inputPath,
    outputPath: outputPath,
    platformName: platformName,
    minOsStr: minOsStr,
    sdkVersionStr: sdkVersionStr,
    installName: installName,
    arch: arch,
    rpaths: rpaths,
    allowNonMacho: allowNonMacho,
    stripSymbols: stripSymbols,
  );
}

/// Runs the `patch` subcommand: parses [args] and writes a patched Mach-O file.
void runPatch(List<String> args) {
  final _PatchArgs parsed = _parsePatchArgs(args);
  final String? inputPath = parsed.inputPath;
  final String? outputPath = parsed.outputPath;
  if (inputPath == null || outputPath == null) {
    usageError('patch requires --input and --output');
  }

  final ({int? minOs, int? platform, int? sdkVersion}) versions =
      parsePlatformVersions(
        parsed.platformName,
        parsed.minOsStr,
        parsed.sdkVersionStr,
      );

  final Uint8List inputBytes = File(inputPath).readAsBytesSync();
  final bool isAllowed = isAllowedNonMacho(
    parsed.allowNonMacho,
    inputPath: inputPath,
    outputPath: outputPath,
    installName: parsed.installName,
  );

  if (!isMachO64(inputBytes) && !isFatMachO(inputBytes)) {
    _passThroughOrRejectPatchInput(
      inputBytes,
      inputPath,
      outputPath,
      isAllowed,
    );
    return;
  }

  final Uint8List patched;
  try {
    patched = patchMachO(
      inputBytes,
      PatchOptions(
        platform: versions.platform,
        minOs: versions.minOs,
        sdkVersion: versions.sdkVersion,
        installName: parsed.installName,
        rpaths: parsed.rpaths,
        arch: parsed.arch,
        stripSymbols: parsed.stripSymbols,
      ),
    );
  } on FormatException catch (e) {
    throw FormatException('Input file "$inputPath": ${e.message}');
  }

  _writePatchedOutput(patched, outputPath);
}

/// Handles a non-64-bit `patch` input: passes it through when explicitly
/// allowed, otherwise throws the 32-bit or non-Mach-O error.
void _passThroughOrRejectPatchInput(
  Uint8List inputBytes,
  String inputPath,
  String outputPath,
  bool isAllowed,
) {
  if (isAllowed) {
    _writePatchedOutput(inputBytes, outputPath);
    return;
  }
  if (isMachO32(inputBytes)) {
    throw FormatException(
      'Input file "$inputPath" is an unsupported 32-bit Mach-O binary '
      '(0xfeedface). Only 64-bit Mach-O binaries are supported unless '
      'explicitly listed in allow_non_macho.',
    );
  }
  throw FormatException(
    'Input file "$inputPath" is a non-Mach-O file (not a 64-bit or '
    'universal Mach-O binary). Only Mach-O binaries are permitted unless '
    'explicitly listed in allow_non_macho.',
  );
}

/// Extracts the NUL-terminated string starting at [offset] in [bytes].
String _readLcString(Uint8List bytes, int offset) {
  if (offset < 0 || offset >= bytes.length) return '';
  var end = offset;
  while (end < bytes.length && bytes[end] != 0) {
    end++;
  }
  return utf8.decode(bytes.sublist(offset, end), allowMalformed: true);
}

/// Resolved `patchMachO` options: platform versions, identity, and search
/// paths applied to the binary. Grouped so the patch entry points stay small.
class PatchOptions {
  const new({
    this.platform,
    this.minOs,
    this.sdkVersion,
    this.installName,
    this.rpaths = const [],
    this.arch,
    this.stripSymbols = false,
  });

  /// The `LC_BUILD_VERSION` platform constant, if any.
  final int? platform;

  /// The packed minimum-OS version, if any.
  final int? minOs;

  /// The packed SDK version, if any.
  final int? sdkVersion;

  /// The new `LC_ID_DYLIB` install name, if any.
  final String? installName;

  /// The `LC_RPATH` entries to add.
  final List<String> rpaths;

  /// The fat slice to thin (`"arm64"` or `"x86_64"`), if any.
  final String? arch;

  /// Whether to drop local and stab symbols from `LC_SYMTAB`, `strip -x`
  /// style, keeping only exported and undefined symbols.
  final bool stripSymbols;
}

/// Patches a 64-bit or universal (fat) Mach-O binary in memory and recomputes
/// its embedded `LC_CODE_SIGNATURE` SHA-256 page hashes if present.
///
/// When [inputBytes] is a universal (fat) Mach-O binary:
/// - If [arch] is provided (`"arm64"` or `"x86_64"`), the fat binary is thinned
///   to that slice and the slice is patched.
/// - Otherwise, every slice in the fat binary is patched and reassembled into
///   a universal (fat) Mach-O binary.
///
/// Throws [FormatException] if [inputBytes] (or any slice being patched) is a
/// 32-bit Mach-O binary or non-Mach-O data.
Uint8List patchMachO(
  Uint8List inputBytes, [
  PatchOptions options = const PatchOptions(),
]) {
  final String? arch = options.arch;
  if (isFatMachO(inputBytes)) {
    if (arch != null) {
      final Uint8List thinSlice = thinFatMachO(inputBytes, arch);
      return _patchSingleMachO64(thinSlice, options);
    }
    return _patchFatMachO(inputBytes, options);
  }

  if (isMachO32(inputBytes)) {
    throw const FormatException(
      'Unsupported 32-bit Mach-O binary (0xfeedface); only 64-bit Mach-O '
      'binaries are supported.',
    );
  }

  if (!isMachO64(inputBytes)) {
    throw const FormatException(
      'Not a Mach-O binary (expected 64-bit or universal Mach-O).',
    );
  }

  if (arch != null) {
    _checkThinArch(inputBytes, arch);
  }

  return _patchSingleMachO64(inputBytes, options);
}

/// Patches every slice of a universal (fat) Mach-O binary and reassembles it,
/// preserving the fat32/fat64 header width.
Uint8List _patchFatMachO(Uint8List inputBytes, PatchOptions options) {
  final List<FatSlice> slices = extractFatSlices(inputBytes);
  final bd = ByteData.sublistView(inputBytes);
  final bool isFat64 =
      bd.getUint32(0, Endian.big) == fatMagic64 ||
      bd.getUint32(0, Endian.little) == fatMagic64;
  final patchedSlices = <FatSlice>[];
  for (var i = 0; i < slices.length; i++) {
    final FatSlice s = slices[i];
    if (isMachO32(s.bytes) || (s.cputype & cpuArchAbi64) == 0) {
      throw FormatException(
        'Fat Mach-O slice $i (cputype 0x${s.cputype.toRadixString(16)}) is '
        'an unsupported 32-bit Mach-O binary.',
      );
    }
    if (!isMachO64(s.bytes)) {
      throw FormatException(
        'Fat Mach-O slice $i is not a valid 64-bit Mach-O binary.',
      );
    }
    final Uint8List patchedBytes = _patchSingleMachO64(
      s.bytes,
      options,
      'slice $i (${_archNameForCpuType(s.cputype)})',
    );
    patchedSlices.add(
      FatSlice(
        cputype: s.cputype,
        cpusubtype: s.cpusubtype,
        align: s.align,
        bytes: patchedBytes,
      ),
    );
  }
  return buildFatMachO(patchedSlices, fat64: isFat64);
}

/// The architecture name for a fat slice's [cputype] (`arm64`, `x86_64`, or a
/// hex fallback), so a refused slice is named by index and architecture.
String _archNameForCpuType(int cputype) {
  if (cputype == cpuTypeArm64) return 'arm64';
  if (cputype == cpuTypeX86_64) return 'x86_64';
  return 'cputype 0x${cputype.toRadixString(16)}';
}

/// Throws when a thin binary's cputype is not the requested [arch].
void _checkThinArch(Uint8List inputBytes, String arch) {
  final int targetCpu = cpuTypeForArch(arch);
  final int actualCpu = ByteData.sublistView(
    inputBytes,
  ).getUint32(4, Endian.little);
  if (actualCpu != targetCpu) {
    throw FormatException(
      'Mach-O cputype 0x${actualCpu.toRadixString(16)} does not match '
      'requested architecture "$arch".',
    );
  }
}

Uint8List _patchSingleMachO64(
  Uint8List inputBytes,
  PatchOptions options, [
  String? sliceLabel,
]) {
  // Locals: PatchOptions' public fields do not promote on null checks.
  final int? platform = options.platform;
  final int? minOs = options.minOs;
  final String? installName = options.installName;
  var workBytes = inputBytes;
  List<LoadCommand> originalCommands = parseLoadCommands(workBytes);
  if (options.stripSymbols) {
    final StrippedSymbols stripped = stripLocalSymbols(
      workBytes,
      originalCommands,
    );
    workBytes = stripped.bytes;
    originalCommands = stripped.commands;
  }
  final bdIn = ByteData.sublistView(workBytes);
  final int oldSizeofcmds = bdIn.getUint32(20, Endian.little);
  final FirstPayload firstPayload = findFirstPayload(
    originalCommands,
    workBytes.length,
  );

  final state = _PatchRewrite();
  for (final lc in originalCommands) {
    _rewriteLoadCommand(lc, options, state);
  }

  if (platform != null && minOs != null && !state.wroteBuildVersion) {
    state.updatedCommands.add(
      buildLcBuildVersion(
        platform: platform,
        minos: minOs,
        sdk: options.sdkVersion ?? minOs,
      ),
    );
  }

  if (installName != null && !state.wroteIdDylib) {
    state.updatedCommands.add(buildLcIdDylib(installName));
  }

  for (final String rpath in options.rpaths) {
    if (state.existingRpaths.add(rpath)) {
      state.updatedCommands.add(buildLcRpath(rpath));
    }
  }

  if (state.codeSigCommand != null) {
    state.updatedCommands.add(state.codeSigCommand!);
  }

  return _emitPatchedMachO(
    workBytes,
    _PayloadCeiling(
      oldSizeofcmds: oldSizeofcmds,
      firstPayload: firstPayload,
      sliceLabel: sliceLabel,
    ),
    state.updatedCommands,
    state.codeSigCommand != null,
  );
}

/// Mutable rewrite state for [_patchSingleMachO64].
class _PatchRewrite {
  final updatedCommands = <LoadCommand>[];
  var wroteBuildVersion = false;
  var wroteIdDylib = false;
  final existingRpaths = <String>{};
  LoadCommand? codeSigCommand;
}

/// Rewrites one load command into [state], stripping legacy version-minimum
/// commands and holding `LC_CODE_SIGNATURE` last.
void _rewriteLoadCommand(
  LoadCommand lc,
  PatchOptions options,
  _PatchRewrite state,
) {
  // Locals: PatchOptions' public fields do not promote on null checks.
  final int? platform = options.platform;
  final int? minOs = options.minOs;
  final int? sdkVersion = options.sdkVersion;
  final String? installName = options.installName;
  // Strip legacy LC_VERSION_MIN_* commands when setting LC_BUILD_VERSION.
  if (platform != null &&
      (lc.cmd == lcVersionMinMacosx ||
          lc.cmd == lcVersionMinIphoneos ||
          lc.cmd == lcVersionMinTvos ||
          lc.cmd == lcVersionMinWatchos)) {
    return;
  }

  if (lc.cmd == lcBuildVersion && platform != null && minOs != null) {
    if (!state.wroteBuildVersion) {
      state.updatedCommands.add(
        buildLcBuildVersion(
          platform: platform,
          minos: minOs,
          sdk: sdkVersion ?? minOs,
        ),
      );
      state.wroteBuildVersion = true;
    }
    return;
  }

  if (lc.cmd == lcIdDylib && installName != null) {
    if (!state.wroteIdDylib) {
      final ({int compatibilityVersion, int currentVersion, int timestamp})
      versions = _idDylibVersions(lc);
      state.updatedCommands.add(
        buildLcIdDylib(
          installName,
          timestamp: versions.timestamp,
          currentVersion: versions.currentVersion,
          compatibilityVersion: versions.compatibilityVersion,
        ),
      );
      state.wroteIdDylib = true;
    }
    return;
  }

  if (lc.cmd == lcRpath && lc.bytes.length >= 12) {
    final lcBd = ByteData.sublistView(lc.bytes);
    final int pathOffset = lcBd.getUint32(8, Endian.little);
    state.existingRpaths.add(_readLcString(lc.bytes, pathOffset));
    state.updatedCommands.add(lc);
    return;
  }

  // Hold LC_CODE_SIGNATURE so any newly added load commands are placed
  // before LC_CODE_SIGNATURE (matching ld64 / vtool conventions).
  if (lc.cmd == lcCodeSignature && state.codeSigCommand == null) {
    state.codeSigCommand = lc;
    return;
  }

  state.updatedCommands.add(lc);
}

/// The version fields an `LC_ID_DYLIB` rewrite preserves, defaulting as new.
({int timestamp, int currentVersion, int compatibilityVersion})
_idDylibVersions(LoadCommand lc) {
  if (lc.bytes.length < 24) {
    return (
      timestamp: 2,
      currentVersion: 0x00010000,
      compatibilityVersion: 0x00010000,
    );
  }
  final lcBd = ByteData.sublistView(lc.bytes);
  return (
    timestamp: lcBd.getUint32(12, Endian.little),
    currentVersion: lcBd.getUint32(16, Endian.little),
    compatibilityVersion: lcBd.getUint32(20, Endian.little),
  );
}

/// The ceiling rewritten load commands must fit under: the old command size
/// (for the header-only growth check), the first payload and its owner (for
/// the refusal), and the fat slice label when patching a universal binary.
/// Grouped so the emit entry point stays small.
class _PayloadCeiling {
  const new({
    required this.oldSizeofcmds,
    required this.firstPayload,
    this.sliceLabel,
  });

  /// The input's old `sizeofcmds`, for the header-only growth check.
  final int oldSizeofcmds;

  /// The first file byte any segment, section or linkedit table names, and
  /// what owns it.
  final FirstPayload firstPayload;

  /// The fat slice being patched (`slice 1 (arm64)`), or null for thin input.
  final String? sliceLabel;
}

/// Serializes [updatedCommands] over [inputBytes], growing a header-only
/// buffer or fitting before the first payload offset, then rebuilds the
/// embedded signature over the new layout when [hasSignature] is set.
///
/// Refuses with a [FormatException] when the rewritten commands do not fit:
/// the refusal keeps both byte offsets and names what starts at the payload
/// offset (and the fat slice, when [ceiling] names one).
Uint8List _emitPatchedMachO(
  Uint8List inputBytes,
  _PayloadCeiling ceiling,
  List<LoadCommand> updatedCommands,
  bool hasSignature,
) {
  var newSizeofcmds = 0;
  for (final lc in updatedCommands) {
    newSizeofcmds += lc.cmdsize;
  }

  final int newLoadCmdEnd = mhHeaderSize64 + newSizeofcmds;
  final int maxLoadCommandEnd = ceiling.firstPayload.offset;
  final int oldSizeofcmds = ceiling.oldSizeofcmds;
  // If the file has no payload sections/segments at all (header-only fixture)
  // and grows past EOF, extend the buffer; otherwise verify we fit before
  // the first payload offset.
  final bool isHeaderOnly =
      maxLoadCommandEnd == inputBytes.length &&
      mhHeaderSize64 + oldSizeofcmds == inputBytes.length;

  if (!isHeaderOnly && newLoadCmdEnd > maxLoadCommandEnd) {
    throw FormatException(_noRoomMessage(ceiling, newLoadCmdEnd));
  }

  final int outLength = isHeaderOnly
      ? math.max<int>(inputBytes.length, newLoadCmdEnd)
      : inputBytes.length;
  final out = Uint8List(outLength);
  out.setRange(0, inputBytes.length, inputBytes);

  // Zero the old load command region first so any shrinkage leaves clean zeroes.
  final int clearEnd = math.min<int>(
    out.length,
    mhHeaderSize64 + math.max<int>(oldSizeofcmds, newSizeofcmds),
  );
  out.fillRange(mhHeaderSize64, clearEnd, 0);

  // Write updated header fields (ncmds, sizeofcmds) and load commands.
  final bdOut = ByteData.sublistView(out);
  bdOut.setUint32(16, updatedCommands.length, Endian.little);
  bdOut.setUint32(20, newSizeofcmds, Endian.little);

  int writeOffset = mhHeaderSize64;
  for (final lc in updatedCommands) {
    out.setRange(writeOffset, writeOffset + lc.cmdsize, lc.bytes);
    writeOffset += lc.cmdsize;
  }

  if (hasSignature) {
    return resignEmbeddedSignature(out);
  }

  return out;
}

/// The no-room refusal for [ceiling]: where the rewritten commands would end,
/// where the first payload starts, what starts there, and the fat slice when
/// patching a universal binary. A [FormatException], the patch's refusal for
/// an input it cannot patch; `runPatch` prefixes the input path.
String _noRoomMessage(_PayloadCeiling ceiling, int newLoadCmdEnd) {
  final int payloadOffset = ceiling.firstPayload.offset;
  final where = ceiling.sliceLabel == null
      ? 'first payload is at $payloadOffset'
      : 'first payload is at $payloadOffset in fat ${ceiling.sliceLabel}';
  final String? what = ceiling.firstPayload.owner;
  if (what == null) {
    return 'Not enough header padding for load commands: need $newLoadCmdEnd '
        'bytes, $where (end of file).';
  }
  return 'Not enough header padding for load commands: need $newLoadCmdEnd '
      'bytes, $where: $what starts at $payloadOffset.';
}
