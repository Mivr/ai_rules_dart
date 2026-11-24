// The `--aot` command-line arguments of `app_jit_snapshot.dart`: their
// parsing and the cross-compilation toolchain check, split out so the tool
// keeps one concern per file.
import 'dart:io';

/// The parsed `--aot` arguments (see [parseAotArgs]).
final class AotArgs {
  /// The `--dart` executable.
  String? dart;

  /// The `--mode`: `aot-snapshot` or `exe`.
  String? mode;

  /// The `--recorded-uses` file, when given.
  String? recordedUses;

  /// The `-o` output path.
  String? outputPath;

  /// The input kernel `.dill`.
  String? dillPath;

  /// The `--gen-snapshot` override, for cross-compilation.
  String? customGenSnapshot;

  /// The `--dartaotruntime` override, for cross-compiled executables.
  String? customDartaotruntime;

  /// The `--target-os` value, when given.
  String? targetOs;

  /// The `--target-arch` value, when given.
  String? targetArch;

  /// Whether `--enable-asserts` was passed.
  bool enableAsserts = false;

  /// The extra `--gen-snapshot-option` values, in order.
  final extraGenSnapshotOptions = <String>[];
}

/// Parses the `--aot` arguments.
AotArgs parseAotArgs(List<String> argv) {
  final args = AotArgs();
  for (var i = 0; i < argv.length; i++) {
    i = _applyAotArg(args, argv, i);
  }
  return args;
}

/// Applies the argument at [i], returning the index of the last argument it
/// consumed (the same index, or one further when it takes a separate value).
int _applyAotArg(AotArgs args, List<String> argv, int i) {
  final String arg = argv[i];
  final int? toolchainIndex = _applyAotToolchainOption(args, argv, i);
  if (toolchainIndex != null) return toolchainIndex;
  if (arg == '--enable-asserts') {
    args.enableAsserts = true;
    return i;
  }
  if (arg == '--verbosity=error') {
    // Ignored: gen_snapshot is silent on success.
    return i;
  }
  if (arg.startsWith('--extra-gen-snapshot-options=')) {
    final String opts = arg.substring('--extra-gen-snapshot-options='.length);
    for (final String opt in opts.split(',')) {
      if (opt.isNotEmpty) args.extraGenSnapshotOptions.add(opt);
    }
    return i;
  }
  if (arg == '-o') {
    args.outputPath = argv[++i];
    return i;
  }
  if (arg.startsWith('-o=')) {
    args.outputPath = arg.substring('-o='.length);
    return i;
  }
  if (!arg.startsWith('-')) {
    args.dillPath = arg;
    return i;
  }
  stderr.writeln('app_jit_snapshot --aot: unknown argument $arg');
  exit(64);
}

/// Applies a toolchain or target option at [i], returning the index of the
/// last argument it consumed, or null when `argv[i]` is no such option.
int? _applyAotToolchainOption(AotArgs args, List<String> argv, int i) {
  final String arg = argv[i];
  if (arg.startsWith('--dart=')) {
    args.dart = arg.substring('--dart='.length);
    return i;
  }
  if (arg.startsWith('--mode=')) {
    args.mode = arg.substring('--mode='.length);
    return i;
  }
  if (arg.startsWith('--recorded-uses=')) {
    args.recordedUses = arg.substring('--recorded-uses='.length);
    return i;
  }
  if (arg.startsWith('--gen-snapshot=')) {
    args.customGenSnapshot = arg.substring('--gen-snapshot='.length);
    return i;
  }
  if (arg == '--gen-snapshot') {
    args.customGenSnapshot = argv[++i];
    return i;
  }
  if (arg.startsWith('--dartaotruntime=')) {
    args.customDartaotruntime = arg.substring('--dartaotruntime='.length);
    return i;
  }
  if (arg == '--dartaotruntime') {
    args.customDartaotruntime = argv[++i];
    return i;
  }
  if (arg.startsWith('--target-os=')) {
    args.targetOs = arg.substring('--target-os='.length);
    return i;
  }
  if (arg == '--target-os') {
    args.targetOs = argv[++i];
    return i;
  }
  if (arg.startsWith('--target-arch=')) {
    args.targetArch = arg.substring('--target-arch='.length);
    return i;
  }
  if (arg == '--target-arch') {
    args.targetArch = argv[++i];
    return i;
  }
  return null;
}

/// Exits unless a cross-compilation has the toolchain it needs: a custom
/// `gen_snapshot`, and a custom `dartaotruntime` for executables.
void checkAotCrossRequirements(
  AotArgs args,
  String mode, {
  required bool isCross,
}) {
  if (!isCross) return;
  if (args.customGenSnapshot == null || args.customGenSnapshot!.isEmpty) {
    stderr.writeln(
      'app_jit_snapshot --aot: cross-compilation to '
      '${args.targetOs}-${args.targetArch} requires --gen-snapshot',
    );
    exit(64);
  }
  if (mode == 'exe' &&
      (args.customDartaotruntime == null ||
          args.customDartaotruntime!.isEmpty)) {
    stderr.writeln(
      'app_jit_snapshot --aot: cross-compiling exe to '
      '${args.targetOs}-${args.targetArch} requires --dartaotruntime',
    );
    exit(64);
  }
}

/// Runs `gen_snapshot` over [activeDill] into [elfPath], returning its exit
/// code (echoing a failed run's output, as the caller fails the action with
/// that code).
int runGenSnapshotElf({
  required String genSnapshot,
  required String elfPath,
  required bool enableAsserts,
  required List<String> extraGenSnapshotOptions,
  required String activeDill,
  required Map<String, String> homeEnv,
}) {
  final ProcessResult gsRes = Process.runSync(
    genSnapshot,
    [
      '--deterministic',
      '--snapshot_kind=app-aot-elf',
      '--elf=$elfPath',
      if (enableAsserts) '--enable_asserts',
      ...extraGenSnapshotOptions,
      activeDill,
    ],
    environment: homeEnv,
    includeParentEnvironment: false,
  );
  if (gsRes.exitCode != 0) {
    stdout.write(gsRes.stdout as String);
    stderr.write(gsRes.stderr as String);
    return gsRes.exitCode;
  }
  return 0;
}
