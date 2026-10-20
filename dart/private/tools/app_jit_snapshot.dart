// Trains an app-JIT snapshot, so that the snapshot does not depend on where or
// how it was built.
//
// Two rules use it: `dart_binary` in `jit-snapshot` mode, which trains on the
// program itself, and `dart_test_runner_snapshot`, which trains the
// `package:test` runner on one real test. It is pure Dart (no shell), so it
// runs on any host the rules support. The exec SDK's `dart` runs it from
// source, so it needs no build of its own.
//
// Usage:
//   dart app_jit_snapshot.dart --dart=<dart> --sdk-version=<version> \
//       --snapshot=<out> [--dartvm=<dartvm>] [--enable-asserts] \
//       [--env=KEY=VALUE]... [--copy=DEST=SOURCE]... [--copy-tree=DEST=DIR]... \
//       -- <dart arguments>
//
// The `<dart arguments>` are what `dart` runs in the training: the script
// first, then its own arguments. Paths in them are relative to the scratch
// directory, where each `--copy` and `--copy-tree` places its files.
//
// The snapshot should not depend on how it was built. Four things aim at that:
//  * `--deterministic` makes the VM's own choices repeat, so one training run
//    and the next write the same bytes. `--no-background-compilation` keeps
//    optimizing compiles on the training thread.
//  * The absolute length of the directory the training runs in changes the
//    snapshot. So the training runs in a scratch directory whose name has a
//    fixed length (a random suffix of fixed length), under relative arguments.
//    The scratch directory is private to the run, so concurrent actions that
//    share a `/tmp` cannot collide. On Windows there is no such root, and the
//    rules build no snapshot there.
//  * The environment names nothing but paths relative to the scratch directory.
//  * The training VM runs from a fixed path, `/tmp/rules_dart_vm-<version>/bin`,
//    which holds a copy of the SDK's `dart` (and `dartvm`). The absolute path of
//    the training binary changes the snapshot, so a copy at one path per SDK
//    version is what makes the snapshot the same across SDK installs. Every
//    copy is byte-identical, so concurrent actions may write the same file.
//
// A program whose own training run is not deterministic (it reads the clock,
// random numbers, or files outside the build) yields a snapshot that differs
// between builds, whatever this tool does.
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

void main(List<String> argv) {
  if (argv.isNotEmpty && argv.first == '--aot') {
    _runAot(argv.sublist(1));
    return;
  }
  if (argv.isNotEmpty && argv.first == '--gen-kernel') {
    _runGenKernel(argv.sublist(1));
    return;
  }
  String? dart;
  String? dartvm;
  String? sdkVersion;
  String? snapshot;
  var enableAsserts = false;
  final env = <String, String>{};
  final copies = <_Pair>[];
  final trees = <_Pair>[];

  var i = 0;
  for (; i < argv.length; i++) {
    final arg = argv[i];
    if (arg == '--') {
      i++;
      break;
    }
    if (arg == '--enable-asserts') {
      enableAsserts = true;
      continue;
    }
    final eq = arg.indexOf('=');
    if (eq < 0) _usage('unknown argument $arg');
    final name = arg.substring(0, eq);
    final value = arg.substring(eq + 1);
    switch (name) {
      case '--dart':
        dart = value;
      case '--dartvm':
        dartvm = value;
      case '--sdk-version':
        sdkVersion = value;
      case '--snapshot':
        snapshot = value;
      case '--env':
        final pair = _Pair.parse(value, arg);
        env[pair.key] = pair.value;
      case '--copy':
        copies.add(_Pair.parse(value, arg));
      case '--copy-tree':
        trees.add(_Pair.parse(value, arg));
      default:
        _usage('unknown argument $arg');
    }
  }
  final dartArgs = argv.sublist(i);
  if (dart == null ||
      sdkVersion == null ||
      snapshot == null ||
      dartArgs.isEmpty) {
    _usage(
      '--dart, --sdk-version, --snapshot and the dart arguments are required',
    );
  }

  final out = File(snapshot).absolute;
  final trainingVm = _stableVm(
    dart: File(dart).absolute.path,
    dartvm: dartvm == null ? null : File(dartvm).absolute.path,
    sdkVersion: sdkVersion,
  );
  final exitCode = _trainInScratch(
    dart: trainingVm,
    dartArgs: dartArgs,
    enableAsserts: enableAsserts,
    env: env,
    copies: [for (final c in copies) _Pair(c.key, File(c.value).absolute.path)],
    trees: [
      for (final t in trees) _Pair(t.key, Directory(t.value).absolute.path),
    ],
    out: out,
  );
  if (exitCode != 0) exit(exitCode);
  if (!out.existsSync()) {
    stderr.writeln(
      'app_jit_snapshot: the training run of ${dartArgs.first} wrote no '
      'snapshot to ${out.path}',
    );
    exit(1);
  }
}

Never _usage(String problem) {
  stderr.writeln(
    'app_jit_snapshot: $problem\n'
    'usage: dart app_jit_snapshot.dart --dart=<dart> --sdk-version=<v> '
    '--snapshot=<out> [--dartvm=<dartvm>] [--enable-asserts] [--env=K=V]... '
    '[--copy=D=S]... [--copy-tree=D=DIR]... -- <dart arguments>',
  );
  exit(64);
}

/// Returns the path of the training `dart`: a copy at a fixed path for
/// [sdkVersion], made from [dart] and [dartvm] when they are not there yet.
///
/// Under the Linux sandbox `/tmp` is private to each action, so the copy is
/// removed with the action. Elsewhere one copy per SDK version stays in `/tmp`,
/// and it is not deleted afterwards: another action may be using it. A version
/// is taken to name one binary; a copy with other bytes is replaced.
String _stableVm({
  required String dart,
  required String? dartvm,
  required String sdkVersion,
}) {
  final exeExt = dart.endsWith('.exe') ? '.exe' : '';
  final root = Platform.isWindows ? Directory.systemTemp.path : '/tmp';
  final bin = Directory('$root/rules_dart_vm-$sdkVersion/bin');
  bin.createSync(recursive: true);
  _installCopy(dart, '${bin.path}/dart$exeExt');
  final effectiveDartvm = dartvm ?? _adjacentDartvm(dart, exeExt);
  if (effectiveDartvm != null) {
    final vmExt = effectiveDartvm.endsWith('.exe') ? '.exe' : '';
    _installCopy(effectiveDartvm, '${bin.path}/dartvm$vmExt');
  }
  return '${bin.path}/dart$exeExt';
}

String? _adjacentDartvm(String dart, String exeExt) {
  final candidate = File('${File(dart).parent.path}/dartvm$exeExt');
  return candidate.existsSync() ? candidate.path : null;
}

/// Makes [target] an executable copy of [source], unless it is one already.
///
/// The copy is written under a name unique to this process, marked `0755`, then
/// renamed over [target]. A rename replaces the file in one step, so a reader
/// sees the old file or the new one, never a partial copy, and a process that
/// is running the old file keeps it.
void _installCopy(String source, String target) {
  final src = File(source);
  final dst = File(target);
  if (dst.existsSync() &&
      dst.lengthSync() == src.lengthSync() &&
      _sameBytes(src, dst)) {
    return;
  }
  final tmp = File('$target.$pid.${Random().nextInt(1 << 31)}.tmp');
  tmp.writeAsBytesSync(src.readAsBytesSync());
  chmodFile(tmp.path, 0x1ed);
  try {
    tmp.renameSync(target);
  } on FileSystemException {
    if (!dst.existsSync()) rethrow;
    try {
      tmp.deleteSync();
    } on FileSystemException {
      // Ignore cleanup errors.
    }
  }
}

bool _sameBytes(File a, File b) {
  final x = a.readAsBytesSync();
  final y = b.readAsBytesSync();
  if (x.length != y.length) return false;
  for (var i = 0; i < x.length; i++) {
    if (x[i] != y[i]) return false;
  }
  return true;
}

const _isolatedHomeEnvKeys = <String>{
  'HOME',
  'USERPROFILE',
  'LOCALAPPDATA',
  'APPDATA',
  'PUB_CACHE',
  'TEMP',
  'TMP',
  'TMPDIR',
  'XDG_CONFIG_HOME',
  'XDG_CACHE_HOME',
};

String? _lookupEnvCaseInsensitive(Map<String, String> env, String name) {
  final direct = env[name];
  if (direct != null && direct.isNotEmpty && !direct.contains('\x00')) {
    return direct;
  }
  final upper = name.toUpperCase();
  for (final entry in env.entries) {
    if (entry.key.toUpperCase() == upper &&
        entry.value.isNotEmpty &&
        !entry.value.contains('\x00')) {
      return entry.value;
    }
  }
  return null;
}

/// Builds a sanitized child-process environment isolated to [homeDir].
///
/// On Windows ([isWindows]), keeps the minimal system variables Windows needs
/// to start a process (`SystemRoot`, `WINDIR`, `SystemDrive`, `COMSPEC`,
/// `PATHEXT`, `PATH`, `NUMBER_OF_PROCESSORS`, `PROCESSOR_ARCHITECTURE`) from
/// [parentEnv] (falling back to `C:\Windows` for `SystemRoot` when absent),
/// and points the home, cache, and temporary directory variables
/// (`USERPROFILE`, `LOCALAPPDATA`, `APPDATA`, `HOME`, `PUB_CACHE`, `TEMP`,
/// `TMP`, `TMPDIR`) at [homeDir]. Any entry with an empty name or `=` in the
/// name is omitted.
Map<String, String> buildChildEnvironment({
  required String homeDir,
  Map<String, String>? parentEnv,
  Map<String, String> overrides = const {},
  bool? isWindows,
  bool includeParent = true,
}) {
  final source = parentEnv ?? Platform.environment;
  final win = isWindows ?? Platform.isWindows;
  final result = <String, String>{};

  bool isValidEntry(String key, String value) =>
      key.isNotEmpty &&
      !key.contains('=') &&
      !key.contains('\x00') &&
      !value.contains('\x00');

  void setEnv(String key, String value) {
    if (!isValidEntry(key, value)) return;
    if (win) {
      final upper = key.toUpperCase();
      result.removeWhere(
        (existingKey, _) => existingKey.toUpperCase() == upper,
      );
    }
    result[key] = value;
  }

  if (win) {
    final systemRoot =
        _lookupEnvCaseInsensitive(source, 'SystemRoot') ??
        _lookupEnvCaseInsensitive(source, 'WINDIR') ??
        r'C:\Windows';
    final systemDrive =
        _lookupEnvCaseInsensitive(source, 'SystemDrive') ??
        (systemRoot.length >= 2 && systemRoot[1] == ':'
            ? systemRoot.substring(0, 2)
            : 'C:');
    setEnv('SystemRoot', systemRoot);
    setEnv('WINDIR', _lookupEnvCaseInsensitive(source, 'WINDIR') ?? systemRoot);
    setEnv('SystemDrive', systemDrive);
    setEnv(
      'COMSPEC',
      _lookupEnvCaseInsensitive(source, 'COMSPEC') ??
          '$systemRoot\\System32\\cmd.exe',
    );
    setEnv(
      'PATHEXT',
      _lookupEnvCaseInsensitive(source, 'PATHEXT') ?? '.COM;.EXE;.BAT;.CMD',
    );
    final parentPath = _lookupEnvCaseInsensitive(source, 'PATH');
    setEnv(
      'PATH',
      (includeParent && parentPath != null)
          ? parentPath
          : '$systemRoot\\System32;$systemRoot',
    );
    for (final optionalKey in const [
      'NUMBER_OF_PROCESSORS',
      'PROCESSOR_ARCHITECTURE',
    ]) {
      final val = _lookupEnvCaseInsensitive(source, optionalKey);
      if (val != null) {
        setEnv(optionalKey, val);
      }
    }
    for (final homeKey in const [
      'USERPROFILE',
      'LOCALAPPDATA',
      'APPDATA',
      'HOME',
      'PUB_CACHE',
      'TEMP',
      'TMP',
      'TMPDIR',
    ]) {
      setEnv(homeKey, homeDir);
    }
    for (final entry in overrides.entries) {
      setEnv(entry.key, entry.value);
    }
    if ((_lookupEnvCaseInsensitive(result, 'SystemRoot') ?? '').isEmpty) {
      setEnv('SystemRoot', systemRoot);
    }
    return result;
  }

  if (includeParent) {
    for (final entry in source.entries) {
      if (_isolatedHomeEnvKeys.contains(entry.key.toUpperCase())) continue;
      setEnv(entry.key, entry.value);
    }
    for (final homeKey in const [
      'HOME',
      'USERPROFILE',
      'LOCALAPPDATA',
      'APPDATA',
      'PUB_CACHE',
    ]) {
      setEnv(homeKey, homeDir);
    }
  } else {
    setEnv('HOME', homeDir);
    setEnv('TMPDIR', homeDir);
  }
  for (final entry in overrides.entries) {
    setEnv(entry.key, entry.value);
  }
  return result;
}

/// A `KEY=VALUE` (or `DEST=SOURCE`) option value. Splits at the first `=`.
class _Pair {
  const _Pair(this.key, this.value);

  final String key;
  final String value;

  static _Pair parse(String text, String arg) {
    final eq = text.indexOf('=');
    if (eq < 0) _usage('expected KEY=VALUE in $arg');
    return _Pair(text.substring(0, eq), text.substring(eq + 1));
  }
}

/// Runs the training in a fresh scratch directory and copies the snapshot it
/// writes to [out]. Returns the training run's exit code.
///
/// The scratch directory is removed whatever the outcome. `exit` is not called
/// in here: it would skip the cleanup.
int _trainInScratch({
  required String dart,
  required List<String> dartArgs,
  required bool enableAsserts,
  required Map<String, String> env,
  required List<_Pair> copies,
  required List<_Pair> trees,
  required File out,
}) {
  // A private directory per run, so concurrent snapshot actions that share a
  // `/tmp` (no sandbox, or a shared one) cannot collide. The random suffix is
  // fixed-length, so the absolute path has the same length on every run.
  final scratchRoot = Platform.isWindows
      ? Directory.systemTemp
      : Directory('/tmp');
  final scratch = scratchRoot.createTempSync('rules_dart_snapshot.');
  try {
    // Every input is copied to its relative place, so the run needs only
    // relative paths.
    for (final c in copies) {
      _copyFile(c.value, '${scratch.path}/${c.key}');
    }
    for (final t in trees) {
      _copyTree(t.value, '${scratch.path}/${t.key}');
    }
    File('${scratch.path}/.dart_tool/package_config.json')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('{"configVersion": 2, "packages": []}\n');

    final childEnv = buildChildEnvironment(
      homeDir: Platform.isWindows ? scratch.path : '.',
      parentEnv: Platform.environment,
      overrides: env,
      isWindows: Platform.isWindows,
      includeParent: false,
    );

    // The training run keeps the VM flags that make the snapshot repeat, and
    // none that name a host path. The scratch directory is the working
    // directory, so every relative path resolves inside it.
    //
    // The runner keeps its default reporter and timeout, and no file reporter
    // is passed. With the file reporter, and with the explicit reporter and
    // timeout, the same inputs gave different snapshots from one run to the
    // next; with none of them, ten runs gave one snapshot. Nothing here reads a
    // report, and the test's exit code is all the training needs.
    final result = Process.runSync(
      dart,
      [
        '--deterministic',
        // Optimizing compilation stays on the training thread, so the functions
        // the snapshot holds optimized do not depend on when a background
        // compile happens to finish. (The stability measured for this tool was
        // with the flag in place; its own contribution was not measured
        // separately.)
        '--no-background-compilation',
        // Code for the VM's baseline CPU rather than the build machine's. The
        // intent is cross-CPU identity, so a cache can share the snapshot.
        '--target_unknown_cpu',
        if (enableAsserts) '--enable-asserts',
        '--packages=.dart_tool/package_config.json',
        '--snapshot-kind=app-jit',
        '--snapshot=snapshot.jit',
        ...dartArgs,
      ],
      workingDirectory: scratch.path,
      environment: childEnv,
      includeParentEnvironment: false,
    );

    // Bazel echoes any action output, so a clean run stays silent.
    if (result.exitCode != 0) {
      stdout.write(result.stdout as String);
      stderr.write(result.stderr as String);
      return result.exitCode;
    }
    final written = File('${scratch.path}/snapshot.jit');
    if (written.existsSync()) {
      out.parent.createSync(recursive: true);
      out.writeAsBytesSync(written.readAsBytesSync());
    }
    return 0;
  } finally {
    if (scratch.existsSync()) {
      try {
        scratch.deleteSync(recursive: true);
      } on FileSystemException {
        // Ignore cleanup errors.
      }
    }
  }
}

/// Copies every file under [from] to the same relative place under [to].
void _copyTree(String from, String to) {
  final source = Directory(from);
  final entities = source.listSync(recursive: true)
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final entity in entities) {
    if (entity is File) {
      final relative = entity.path.substring(source.path.length + 1);
      _copyFile(entity.path, '$to/$relative');
    }
  }
}

/// Copies [from] to [to] by content, creating the parent directories of [to].
///
/// Writes bytes rather than `File.copySync` so read-only input modes from a
/// sandbox or remote executor are not carried onto the scratch copy.
void _copyFile(String from, String to) {
  final dest = File(to);
  dest.parent.createSync(recursive: true);
  dest.writeAsBytesSync(File(from).readAsBytesSync());
}

/// Compiles a pre-built kernel `.dill` to an AOT snapshot (`--mode=aot-snapshot`)
/// or self-contained AOT executable (`--mode=exe`) without invoking `dartdev`.
///
/// `dart compile exe` runs through `dartdev`, which walks ancestor directories
/// up to `/` probing `pubspec.yaml` and `.dart_tool/package_config.json` (for
/// native-asset hook discovery) and spawns `/usr/bin/chmod` via `PATH`. Driving
/// `gen_snapshot --deterministic` directly and writing a fresh executable from
/// `dartaotruntime` plus the ELF snapshot (marking it `0755` via libc `chmod`)
/// keeps the compile strictly hermetic inside the action sandbox, even when
/// inputs are staged read-only and no shell or coreutils exist.
void _runAot(List<String> argv) {
  String? dart;
  String? mode;
  String? recordedUses;
  String? outputPath;
  String? dillPath;
  String? customGenSnapshot;
  String? customDartaotruntime;
  String? targetOs;
  String? targetArch;
  var enableAsserts = false;
  final extraGenSnapshotOptions = <String>[];

  for (var i = 0; i < argv.length; i++) {
    final arg = argv[i];
    if (arg == '--enable-asserts') {
      enableAsserts = true;
    } else if (arg == '--verbosity=error') {
      // Ignored: gen_snapshot is silent on success.
    } else if (arg.startsWith('--dart=')) {
      dart = arg.substring('--dart='.length);
    } else if (arg.startsWith('--mode=')) {
      mode = arg.substring('--mode='.length);
    } else if (arg.startsWith('--recorded-uses=')) {
      recordedUses = arg.substring('--recorded-uses='.length);
    } else if (arg.startsWith('--gen-snapshot=')) {
      customGenSnapshot = arg.substring('--gen-snapshot='.length);
    } else if (arg == '--gen-snapshot') {
      customGenSnapshot = argv[++i];
    } else if (arg.startsWith('--dartaotruntime=')) {
      customDartaotruntime = arg.substring('--dartaotruntime='.length);
    } else if (arg == '--dartaotruntime') {
      customDartaotruntime = argv[++i];
    } else if (arg.startsWith('--target-os=')) {
      targetOs = arg.substring('--target-os='.length);
    } else if (arg == '--target-os') {
      targetOs = argv[++i];
    } else if (arg.startsWith('--target-arch=')) {
      targetArch = arg.substring('--target-arch='.length);
    } else if (arg == '--target-arch') {
      targetArch = argv[++i];
    } else if (arg.startsWith('--extra-gen-snapshot-options=')) {
      final opts = arg.substring('--extra-gen-snapshot-options='.length);
      for (final opt in opts.split(',')) {
        if (opt.isNotEmpty) extraGenSnapshotOptions.add(opt);
      }
    } else if (arg == '-o') {
      outputPath = argv[++i];
    } else if (arg.startsWith('-o=')) {
      outputPath = arg.substring('-o='.length);
    } else if (!arg.startsWith('-')) {
      dillPath = arg;
    } else {
      stderr.writeln('app_jit_snapshot --aot: unknown argument $arg');
      exit(64);
    }
  }

  if (dart == null || mode == null || outputPath == null || dillPath == null) {
    stderr.writeln(
      'app_jit_snapshot --aot: --dart, --mode, -o, and input dill are required',
    );
    exit(64);
  }

  final isCross =
      (targetOs != null && targetOs.isNotEmpty) ||
      (targetArch != null && targetArch.isNotEmpty);
  if (isCross) {
    if (customGenSnapshot == null || customGenSnapshot.isEmpty) {
      stderr.writeln(
        'app_jit_snapshot --aot: cross-compilation to $targetOs-$targetArch '
        'requires --gen-snapshot',
      );
      exit(64);
    }
    if (mode == 'exe' &&
        (customDartaotruntime == null || customDartaotruntime.isEmpty)) {
      stderr.writeln(
        'app_jit_snapshot --aot: cross-compiling exe to $targetOs-$targetArch '
        'requires --dartaotruntime',
      );
      exit(64);
    }
  }

  final sdkBin = File(dart).parent.path;
  final hostExeExt = dart.endsWith('.exe') ? '.exe' : '';
  final hostDartaotruntime = '$sdkBin/dartaotruntime$hostExeExt';
  final targetDartaotruntime = customDartaotruntime ?? hostDartaotruntime;
  final genSnapshot =
      customGenSnapshot ?? '$sdkBin/utils/gen_snapshot$hostExeExt';

  // On non-ELF targets (e.g. native macOS Mach-O executables or Windows) or
  // jit-snapshot fallback on Windows, delegate to `dart compile` with a fresh
  // temporary HOME directory. Cross-compilation targets are always ELF and
  // never delegate to `dartdev`.
  if (!isCross &&
      (mode == 'jit-snapshot' ||
          dart.endsWith('.exe') ||
          (mode == 'exe' && !_isElfFile(File(targetDartaotruntime))))) {
    final compileArgs = <String>[
      'compile',
      mode,
      if (mode == 'exe' || mode == 'aot-snapshot') '--verbosity=error',
      if (enableAsserts) '--enable-asserts',
      if (recordedUses != null) '--recorded-uses=$recordedUses',
      for (final opt in extraGenSnapshotOptions)
        '--extra-gen-snapshot-options=$opt',
      '-o',
      outputPath,
      dillPath,
    ];
    final tempHome = Directory.systemTemp.createTempSync(
      'rules_dart_compile_home.',
    );
    final childEnv = buildChildEnvironment(
      homeDir: tempHome.path,
      parentEnv: Platform.environment,
      isWindows: Platform.isWindows,
    );
    final ProcessResult res;
    try {
      res = Process.runSync(
        dart,
        compileArgs,
        environment: childEnv,
        includeParentEnvironment: false,
      );
    } finally {
      if (tempHome.existsSync()) {
        try {
          tempHome.deleteSync(recursive: true);
        } on FileSystemException {
          // Ignore cleanup errors.
        }
      }
    }
    if (res.exitCode != 0) {
      stdout.write(res.stdout as String);
      stderr.write(res.stderr as String);
      exit(res.exitCode);
    }
    return;
  }

  final tmpDir = Directory.systemTemp.createTempSync('rules_dart_aot.');
  final homeDir = Directory('${tmpDir.path}/home')..createSync(recursive: true);
  final homeEnv = buildChildEnvironment(
    homeDir: homeDir.path,
    parentEnv: Platform.environment,
    isWindows: Platform.isWindows,
  );
  var failureExitCode = 0;
  try {
    var activeDill = dillPath;
    if (recordedUses != null) {
      final productPlatform =
          '$sdkBin/../lib/_internal/vm_platform_product.dill';
      final strongPlatform = '$sdkBin/../lib/_internal/vm_platform_strong.dill';
      final platformDill = File(productPlatform).existsSync()
          ? productPlatform
          : strongPlatform;
      final recordedDill = '${tmpDir.path}/recorded.dill';
      final gkRes = Process.runSync(
        hostDartaotruntime,
        [
          '$sdkBin/snapshots/gen_kernel_aot.dart.snapshot',
          '--platform=$platformDill',
          '--aot',
          '--tfa',
          '--no-embed-sources',
          '-Ddart.vm.product=true',
          '-Ddart.vm.asan=false',
          '-Ddart.vm.msan=false',
          '-Ddart.vm.tsan=false',
          if (targetOs != null && targetOs.isNotEmpty) '--target-os=$targetOs',
          if (enableAsserts) '--enable-asserts',
          '--from-dill=$dillPath',
          '--recorded-usages-file=$recordedUses',
          '-o',
          recordedDill,
          dillPath,
        ],
        environment: homeEnv,
        includeParentEnvironment: false,
      );
      if (gkRes.exitCode != 0) {
        stdout.write(gkRes.stdout as String);
        stderr.write(gkRes.stderr as String);
        failureExitCode = gkRes.exitCode;
        return;
      }
      activeDill = recordedDill;
    }

    final elfPath = mode == 'aot-snapshot'
        ? outputPath
        : '${tmpDir.path}/snapshot.elf';
    final gsRes = Process.runSync(
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
      failureExitCode = gsRes.exitCode;
      return;
    }

    if (mode == 'exe') {
      writeAppAotElfExe(
        dartaotruntime: File(targetDartaotruntime),
        snapshotElf: File(elfPath),
        output: File(outputPath),
      );
    }
  } finally {
    if (tmpDir.existsSync()) {
      try {
        tmpDir.deleteSync(recursive: true);
      } on FileSystemException {
        // Ignore cleanup errors.
      }
    }
  }
  if (failureExitCode != 0) {
    exit(failureExitCode);
  }
}

bool _isElfFile(File file) {
  if (!file.existsSync()) return false;
  final raf = file.openSync();
  try {
    final magic = raf.readSync(4);
    return magic.length == 4 &&
        magic[0] == 0x7f &&
        magic[1] == 0x45 &&
        magic[2] == 0x4c &&
        magic[3] == 0x46;
  } finally {
    raf.closeSync();
  }
}

/// Writes a self-contained AOT ELF executable to [output] by concatenating
/// [dartaotruntime], zero padding up to a 64 KiB page boundary, [snapshotElf],
/// and the 16-byte app-JIT/AOT trailer, then marks [output] executable (`0755`).
///
/// Does not use `File.copySync`: under remote execution and read-only sandboxes,
/// [dartaotruntime] has mode `0555` (or `0444`), and `copySync` copies that
/// read-only mode onto [output], causing a subsequent open for append to fail
/// with `EACCES`. Writing a fresh file and setting `0755` via `libc`'s `chmod`
/// avoids both copying read-only permissions and spawning `/bin/chmod`.
void writeAppAotElfExe({
  required File dartaotruntime,
  required File snapshotElf,
  required File output,
}) {
  const pageSize = 65536;
  output.parent.createSync(recursive: true);
  if (output.existsSync()) {
    output.deleteSync();
  }
  final runtimeBytes = dartaotruntime.readAsBytesSync();
  final runtimeLen = runtimeBytes.length;
  final padLen = (pageSize - (runtimeLen % pageSize)) % pageSize;
  final offset = runtimeLen + padLen;

  final raf = output.openSync(mode: FileMode.writeOnly);
  try {
    raf.writeFromSync(runtimeBytes);
    if (padLen > 0) {
      raf.writeFromSync(Uint8List(padLen));
    }
    raf.writeFromSync(snapshotElf.readAsBytesSync());
    final trailer = ByteData(16)
      ..setUint64(0, offset, Endian.little)
      ..setUint8(8, 0xdc)
      ..setUint8(9, 0xdc)
      ..setUint8(10, 0xf6)
      ..setUint8(11, 0xf6)
      ..setUint8(12, 0x00)
      ..setUint8(13, 0x00)
      ..setUint8(14, 0x00)
      ..setUint8(15, 0x00);
    raf.writeFromSync(trailer.buffer.asUint8List());
  } finally {
    raf.closeSync();
  }
  chmodFile(output.path, 0x1ed);
}

typedef _MallocNative = ffi.Pointer<ffi.Uint8> Function(ffi.Size);
typedef _MallocDart = ffi.Pointer<ffi.Uint8> Function(int);
typedef _FreeNative = ffi.Void Function(ffi.Pointer<ffi.Uint8>);
typedef _FreeDart = void Function(ffi.Pointer<ffi.Uint8>);
typedef _ChmodNative = ffi.Int Function(ffi.Pointer<ffi.Uint8>, ffi.Uint32);
typedef _ChmodDart = int Function(ffi.Pointer<ffi.Uint8>, int);

/// Sets POSIX permission bits [mode] on [path] via libc's `chmod(2)`.
void chmodFile(String path, int mode) {
  if (Platform.isWindows) return;
  final lib = ffi.DynamicLibrary.process();
  final malloc = lib.lookupFunction<_MallocNative, _MallocDart>('malloc');
  final free = lib.lookupFunction<_FreeNative, _FreeDart>('free');
  final chmod = lib.lookupFunction<_ChmodNative, _ChmodDart>('chmod');
  final bytes = utf8.encode(path);
  final ptr = malloc(bytes.length + 1);
  if (ptr == ffi.nullptr) {
    throw FileSystemException('malloc failed for chmod', path);
  }
  try {
    ptr.asTypedList(bytes.length + 1)
      ..setAll(0, bytes)
      ..[bytes.length] = 0;
    final rc = chmod(ptr, mode);
    if (rc != 0) {
      throw FileSystemException('chmod failed (rc=$rc)', path);
    }
  } finally {
    free(ptr);
  }
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

/// Returns the path to a cached copy of [snapshotPath] with
/// `Parser._setOption`'s comma-splitting disabled, or [snapshotPath] if the
/// file does not match a known AOT snapshot pattern.
String patchSnapshotSplitCommas(String snapshotPath) {
  final file = File(snapshotPath);
  if (!file.existsSync()) return snapshotPath;
  final baseName = snapshotPath
      .replaceAll(r'\', '/')
      .split('/')
      .last
      .replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  // Fast path: SDK snapshots are immutable in practice, so a patched copy (or
  // a record that patching does not apply) keyed by size and mtime lets every
  // action start reuse it with two stats instead of re-reading and re-scanning
  // tens of megabytes.
  FileStat snapshotStat;
  try {
    snapshotStat = file.statSync();
  } on FileSystemException {
    return snapshotPath;
  }
  final cacheFile = File(
    '${Directory.systemTemp.path}/'
    'rules_dart_nocomma_${baseName}_${snapshotStat.size}_'
    '${snapshotStat.modified.microsecondsSinceEpoch}.snapshot',
  );
  if (cacheFile.existsSync()) {
    return cacheFile.path;
  }
  final sentinelFile = File('${cacheFile.path}.nopatch');
  if (sentinelFile.existsSync()) {
    return snapshotPath;
  }
  final Uint8List bytes;
  try {
    bytes = file.readAsBytesSync();
  } on FileSystemException {
    return snapshotPath;
  }
  // The size-and-mtime cache name above already pins the content; a torn
  // cached copy is impossible because the write below is atomic.
  if (!patchSnapshotSplitCommasBytes(bytes)) {
    _writePatchSentinel(sentinelFile, snapshotPath);
    return snapshotPath;
  }
  final tmpFile = File(
    '${cacheFile.path}.tmp.$pid.${DateTime.now().microsecondsSinceEpoch}',
  );
  try {
    tmpFile.writeAsBytesSync(bytes, flush: true);
    if (Platform.isMacOS) {
      Process.runSync('/usr/bin/codesign', ['-f', '-s', '-', tmpFile.path]);
    }
    try {
      tmpFile.renameSync(cacheFile.path);
    } on FileSystemException {
      if (!cacheFile.existsSync()) {
        tmpFile.copySync(cacheFile.path);
      }
      if (tmpFile.existsSync()) {
        tmpFile.deleteSync();
      }
    }
    return cacheFile.path;
  } on FileSystemException {
    try {
      if (tmpFile.existsSync()) tmpFile.deleteSync();
    } on FileSystemException {
      // Ignore cleanup errors.
    }
    return snapshotPath;
  }
}

/// Records that [snapshotPath]'s snapshot needs no comma-splitting patch, so
/// future [patchSnapshotSplitCommas] calls skip re-reading and re-scanning it.
void _writePatchSentinel(File sentinelFile, String snapshotPath) {
  final tmpFile = File(
    '${sentinelFile.path}.tmp.$pid.${DateTime.now().microsecondsSinceEpoch}',
  );
  try {
    tmpFile.writeAsStringSync('$snapshotPath\n', flush: true);
    try {
      tmpFile.renameSync(sentinelFile.path);
    } on FileSystemException {
      if (!sentinelFile.existsSync()) {
        tmpFile.copySync(sentinelFile.path);
      }
      if (tmpFile.existsSync()) {
        tmpFile.deleteSync();
      }
    }
  } on FileSystemException {
    try {
      if (tmpFile.existsSync()) tmpFile.deleteSync();
    } on FileSystemException {
      // Ignore cleanup errors.
    }
  }
}

void _copyEntitySync(String srcPath, String dstPath) {
  final type = FileSystemEntity.typeSync(srcPath);
  if (type == FileSystemEntityType.file) {
    final dst = File(dstPath);
    if (dst.existsSync()) return;
    dst.parent.createSync(recursive: true);
    dst.writeAsBytesSync(File(srcPath).readAsBytesSync());
  } else if (type == FileSystemEntityType.directory) {
    for (final entity in Directory(srcPath).listSync(recursive: true)) {
      if (entity is File) {
        final rel = entity.path
            .substring(srcPath.length)
            .replaceAll(r'\', '/')
            .replaceFirst(RegExp(r'^/+'), '');
        final childDst = '$dstPath/$rel';
        if (FileSystemEntity.typeSync(childDst) !=
            FileSystemEntityType.notFound) {
          continue;
        }
        File(childDst).parent.createSync(recursive: true);
        File(childDst).writeAsBytesSync(File(entity.path).readAsBytesSync());
      }
    }
  }
}

String _stripFsRootPrefix(String path, List<String> fsRoots) {
  final slashPath = path.replaceAll(r'\', '/');
  var bestRootLen = -1;
  String? bestRel;
  for (final rawRoot in fsRoots) {
    final root = rawRoot.replaceAll(r'\', '/').replaceFirst(RegExp(r'/+$'), '');
    if (root.isEmpty || root == '.') continue;
    final prefix = '$root/';
    if (slashPath.startsWith(prefix) && root.length > bestRootLen) {
      bestRootLen = root.length;
      bestRel = slashPath.substring(prefix.length);
    }
  }
  return bestRel ?? slashPath.replaceFirst(RegExp(r'^(?:\./)+'), '');
}

/// Normalizes a filesystem path for comparison: `/` separators, no leading
/// `./` segments.
String _normFsPath(String path) =>
    path.replaceAll(r'\', '/').replaceFirst(RegExp(r'^(?:\./)+'), '');

/// A diagnostic for every `gen_kernel` input source with a directive URI that
/// names no file the action can read through its declared inputs: a `file:`
/// URI in any spelling, any other scheme but `dart:` and `package:`, a
/// `package:` URI climbing above its package, or a relative URI resolving to
/// no declared input source. The front end reads such a URI off the host,
/// outside every `--filesystem-root`, so the wrapper refuses before compiling.
/// Climbing `..` segments are followed past the declared inputs, never
/// clamped: enough segments name any host path. Every `if` alternative is
/// checked, since the wrapper has no configuration to select by. Empty when
/// clean. Each diagnostic names the file, the directive and the URI.
///
/// A relative URI is accepted when it resolves to a declared source beside the
/// importing file, or when it resolves to a declared source's multi-root key
/// ([_resolveKeyRelativeTarget] over [_stableSourceKey]): the front end finds
/// each key where it is, so a generated sibling in `bazel-out` staged beside a
/// source-tree importer reads a declared input, not the host.
List<String> _findDisallowedGenKernelDirectives(
  List<String> sources,
  List<String> fsRoots,
) {
  final contents = <String, String>{};
  for (final path in sources) {
    try {
      contents[path] = File(path).readAsStringSync();
    } on FileSystemException {
      // Missing or unreadable here; gen_kernel reports it.
    } on FormatException {
      // Not decodable text; gen_kernel reports it.
    }
  }
  final declared = <String>{
    for (final path in contents.keys) _normAbsStagedPath(path),
  };
  final declaredKeys = <String>{
    for (final path in contents.keys) _stableSourceKey(path, fsRoots),
  };
  final errors = <String>[];
  final paths = contents.keys.toList()..sort();
  for (final path in paths) {
    final content = contents[path];
    if (content == null) continue;
    final from = _normAbsStagedPath(path);
    final fromKey = _stableSourceKey(path, fsRoots);
    for (final ref in scanAllDirectiveUris(content)) {
      final uri = ref.uri;
      if (uri.startsWith(defaultMultiRootPrefix) || uri.startsWith('dart:')) {
        continue;
      }
      if (uri.startsWith('package:')) {
        if (isEscapingPackageUri(uri)) {
          errors.add(
            "app_jit_snapshot: $path ${ref.kind} '$uri' "
            'is not a declared input.',
          );
        }
        continue;
      }
      if (isFileSchemeDirectiveUri(uri) || isDisallowedDirectiveUri(uri)) {
        errors.add(
          "app_jit_snapshot: $path ${ref.kind} '$uri' is not a declared input.",
        );
        continue;
      }
      final target = resolveStagedRelativeTarget(uri, from);
      if (target == null || declared.contains(target)) continue;
      final keyTarget = _resolveKeyRelativeTarget(uri, fromKey);
      if (keyTarget != null && declaredKeys.contains(keyTarget)) continue;
      errors.add(
        "app_jit_snapshot: $path ${ref.kind} '$uri' is not a declared input.",
      );
    }
  }
  return errors;
}

/// The multi-root key naming the declared input source [path]: the
/// exec-root-relative path with its longest `--filesystem-root` prefix
/// stripped. The wrapper runs with the exec root as its working directory (the
/// `"."` root), so an absolute declared path under it becomes relative, and a
/// generated file's key drops the bin-root prefix — the same derivation the
/// entrypoint URI uses (see `stable_entry_path` and `stable_path` in
/// `common.bzl`). A relative directive URI resolved against one declared
/// source's key therefore names the same key the front end looks up whether
/// the target lives in the source tree or under `bazel-out`. Paths already
/// relative, or absolute but under no root and outside the working directory
/// (tests), keep the [_stripFsRootPrefix] spelling, which stays consistent
/// because every key in the comparison uses this same function.
String _stableSourceKey(String path, List<String> fsRoots) {
  var slash = path.replaceAll(r'\', '/');
  final cwd = Directory.current.path
      .replaceAll(r'\', '/')
      .replaceFirst(RegExp(r'/+$'), '');
  if (slash == cwd) {
    slash = '';
  } else if (slash.startsWith('$cwd/')) {
    slash = slash.substring(cwd.length + 1);
  }
  slash = slash.replaceFirst(RegExp(r'^(?:\./)+'), '');
  String? best;
  for (final rawRoot in fsRoots) {
    final root = rawRoot
        .replaceAll(r'\', '/')
        .replaceFirst(RegExp(r'/+$'), '')
        .replaceFirst(RegExp(r'^(?:\./)+'), '');
    if (root.isEmpty || root == '.') continue;
    if ((slash == root || slash.startsWith('$root/')) &&
        (best == null || root.length > best.length)) {
      best = root;
    }
  }
  if (best != null) {
    slash = slash == best ? '' : slash.substring(best.length + 1);
  }
  return slash;
}

/// The multi-root key a schemeless relative directive URI in the declared
/// source with key [fromKey] refers to: the front end resolves the URI against
/// the importing file's key and finds each key where it is, whether in the
/// source tree or under `bazel-out`, so a generated sibling staged beside its
/// importer names a declared input. `\` separates and escapes decode once, as
/// in [resolveStagedRelativeTarget]; a `..` climbing above the key root drops
/// away, the way the front end's own resolution stays inside the multi-root
/// space, and the caller accepts the result only when some declared source
/// holds that key.
///
/// Null when [uri] is not a relative URI (any scheme, a fragment, a
/// `//`-prefixed authority, or a `/`-absolute path, which names a host file
/// outside every root) or when a decoded `/` names no file. A `?...` query is
/// dropped and the path part resolved instead: an empty reference names the
/// importing file itself. Null never means "declared": the caller refuses it
/// unless the filesystem-path check above already accepted it.
String? _resolveKeyRelativeTarget(String uri, String fromKey) {
  final text = uri.contains(r'\') ? uri.replaceAll(r'\', '/') : uri;
  // A fragment names no file: the front end reports a URI with one instead of
  // reading through it. A query names no file either: the front end reads the
  // file the path part names, so the path part alone is resolved below.
  if (text.contains('#')) return null;
  final query = text.indexOf('?');
  final path = query < 0 ? text : text.substring(0, query);
  if (path.contains(':')) return null;
  if (path.startsWith('//') || path.startsWith('/')) return null;
  // An empty reference names the importing file itself (RFC 3986).
  if (path.isEmpty) return fromKey;
  final stack = <String>[];
  for (final part in fromKey.split('/')) {
    if (part.isNotEmpty) stack.add(part);
  }
  // Drop the file name: the URI resolves against its directory.
  if (stack.isNotEmpty) stack.removeLast();
  for (final raw in path.split('/')) {
    if (raw.isEmpty) continue;
    final seg = decodeUriSegment(raw);
    if (seg.isEmpty || seg == '.') continue;
    if (seg == '..') {
      if (stack.isNotEmpty) stack.removeLast();
      continue;
    }
    if (seg.contains('/')) return null;
    stack.add(seg);
  }
  return stack.join('/');
}

/// Links [dstPath] to [srcPath] (a file or directory), copying instead when
/// the platform refuses symlinks (Windows without developer mode).
///
/// [createLink] injects symlink creation (tests pass a throwing function to
/// exercise the copy fallback that Windows without developer mode takes).
void _stageEntitySync(
  String srcPath,
  String dstPath, {
  void Function(String linkPath, String target)? createLink,
}) {
  if (FileSystemEntity.typeSync(srcPath) == FileSystemEntityType.notFound) {
    return;
  }
  try {
    File(dstPath).parent.createSync(recursive: true);
    final slashSrc = srcPath.replaceAll(r'\', '/');
    final target = slashSrc.startsWith('/') || _isWindowsDrivePath(slashSrc)
        ? slashSrc
        : '${Directory.current.path.replaceAll(r'\', '/')}/$slashSrc';
    if (createLink != null) {
      createLink(dstPath, target);
    } else {
      Link(dstPath).createSync(target);
    }
    return;
  } on FileSystemException {
    // Fall through to a copy, which isolates just as well.
  }
  _copyEntitySync(srcPath, dstPath);
}

bool _isWindowsDrivePath(String s) =>
    s.length >= 2 &&
    ((s.codeUnitAt(0) >= 0x41 && s.codeUnitAt(0) <= 0x5a) ||
        (s.codeUnitAt(0) >= 0x61 && s.codeUnitAt(0) <= 0x7a)) &&
    s.codeUnitAt(1) == 0x3a &&
    (s.length == 2 || s.codeUnitAt(2) == 0x2f || s.codeUnitAt(2) == 0x5c);

/// Runs `gen_kernel` via `dartaotruntime` with comma-splitting disabled on
/// `-D` / `--define` options and an isolated `--filesystem-root` containing
/// only declared input sources.
void _runGenKernel(List<String> argv) {
  if (argv.length < 2) {
    stderr.writeln(
      'app_jit_snapshot --gen-kernel: expected <dartaotruntime> <gen_kernel_args...>',
    );
    exit(64);
  }
  final dartaotruntime = argv.first;
  final rawGenArgs = <String>[];
  final declaredInputSources = <String>[];
  final fsRoots = <String>[];
  String? outputPath;
  for (var i = 1; i < argv.length; i++) {
    final arg = argv[i];
    if (arg == '--input-source' && i + 1 < argv.length) {
      declaredInputSources.add(argv[++i]);
      continue;
    }
    if (arg.startsWith('--input-source=')) {
      declaredInputSources.add(arg.substring('--input-source='.length));
      continue;
    }
    if (arg == '--input-sources-file' && i + 1 < argv.length) {
      final file = File(argv[++i]);
      if (file.existsSync()) {
        for (final line in file.readAsLinesSync()) {
          if (line.isNotEmpty) declaredInputSources.add(line);
        }
      }
      continue;
    }
    if (arg.startsWith('--input-sources-file=')) {
      final file = File(arg.substring('--input-sources-file='.length));
      if (file.existsSync()) {
        for (final line in file.readAsLinesSync()) {
          if (line.isNotEmpty) declaredInputSources.add(line);
        }
      }
      continue;
    }
    if (arg == '--filesystem-root' && i + 1 < argv.length) {
      fsRoots.add(argv[i + 1]);
    } else if (arg.startsWith('--filesystem-root=')) {
      fsRoots.add(arg.substring('--filesystem-root='.length));
    } else if ((arg == '-o' || arg == '--output') && i + 1 < argv.length) {
      outputPath = argv[i + 1];
    } else if (arg.startsWith('-o=')) {
      outputPath = arg.substring('-o='.length);
    } else if (arg.startsWith('--output=')) {
      outputPath = arg.substring('--output='.length);
    }
    rawGenArgs.add(arg);
  }

  // Only patch the gen_kernel snapshot when a define actually contains a comma:
  // the patch disables Parser._setOption's comma splitting, which is only
  // needed for comma-containing defines.
  var hasCommaDefines = false;
  for (var i = 0; i < rawGenArgs.length; i++) {
    final arg = rawGenArgs[i];
    if (arg == '-D' || arg == '--define') {
      if (i + 1 < rawGenArgs.length && rawGenArgs[i + 1].contains(',')) {
        hasCommaDefines = true;
      }
    } else if (arg.startsWith('-D') && arg.length > 2) {
      if (arg.substring(2).contains(',')) hasCommaDefines = true;
    } else if (arg.startsWith('--define=')) {
      if (arg.substring('--define='.length).contains(',')) {
        hasCommaDefines = true;
      }
    }
  }
  if (rawGenArgs.isNotEmpty && hasCommaDefines) {
    rawGenArgs[0] = patchSnapshotSplitCommas(rawGenArgs[0]);
  }

  // No declared source may read the host (see
  // [_findDisallowedGenKernelDirectives]). This runs before the isolated-root
  // staging below: a disallowed URI fails however the roots resolve.
  final disallowedDirectives = _findDisallowedGenKernelDirectives(
    declaredInputSources,
    fsRoots,
  );
  if (disallowedDirectives.isNotEmpty) {
    for (final error in disallowedDirectives) {
      stderr.writeln(error);
    }
    exit(1);
  }

  // Only stage an isolated filesystem root when an undeclared file would
  // otherwise shadow a declared input. Each declared source is compared
  // against every root: the candidate naming the declared file itself is its
  // origin, and any other candidate that exists on disk is a shadow. In the
  // common case (no shadows) the declared roots are forwarded unchanged.
  var hasShadowRisk = false;
  if (declaredInputSources.isNotEmpty && fsRoots.isNotEmpty) {
    final normRoots = <String>[
      for (final root in fsRoots)
        _normFsPath(root).replaceFirst(RegExp(r'/+$'), ''),
    ];
    for (final srcPath in declaredInputSources) {
      final normSrc = _normFsPath(srcPath);
      final normKey = _normFsPath(_stripFsRootPrefix(srcPath, fsRoots));
      if (normKey.isEmpty) {
        hasShadowRisk = true;
        break;
      }
      for (final normRoot in normRoots) {
        final candidate = normRoot == '.' || normRoot.isEmpty
            ? normKey
            : '$normRoot/$normKey';
        // The candidate naming the declared file itself is its origin.
        if (candidate == normSrc) continue;
        if (File(candidate).existsSync()) {
          hasShadowRisk = true;
          break;
        }
      }
      if (hasShadowRisk) break;
    }
  }

  Directory? isolatedRootDir;
  final forwarded = <String>[];
  if (declaredInputSources.isNotEmpty && fsRoots.isNotEmpty && hasShadowRisk) {
    final baseDir = outputPath != null
        ? File(outputPath).parent
        : Directory.systemTemp;
    baseDir.createSync(recursive: true);
    isolatedRootDir = baseDir.createTempSync('.gen_kernel_root.');
    final seenKeys = <String>{};
    for (final srcPath in declaredInputSources) {
      final key = _stripFsRootPrefix(srcPath, fsRoots);
      if (key.isEmpty || !seenKeys.add(key)) continue;
      _stageEntitySync(srcPath, '${isolatedRootDir.path}/$key');
    }
    var insertedRoot = false;
    for (var i = 0; i < rawGenArgs.length; i++) {
      final arg = rawGenArgs[i];
      if (arg == '--filesystem-root' && i + 1 < rawGenArgs.length) {
        i++;
        if (!insertedRoot) {
          insertedRoot = true;
          forwarded
            ..add('--filesystem-root')
            ..add(isolatedRootDir.path);
        }
        continue;
      }
      if (arg.startsWith('--filesystem-root=')) {
        if (!insertedRoot) {
          insertedRoot = true;
          forwarded.add('--filesystem-root=${isolatedRootDir.path}');
        }
        continue;
      }
      forwarded.add(arg);
    }
  } else {
    forwarded.addAll(rawGenArgs);
  }

  final tempHome = Directory.systemTemp.createTempSync(
    'rules_dart_gen_kernel_home.',
  );
  final childEnv = buildChildEnvironment(
    homeDir: tempHome.path,
    parentEnv: Platform.environment,
    isWindows: Platform.isWindows,
  );
  final ProcessResult res;
  try {
    res = Process.runSync(
      dartaotruntime,
      forwarded,
      environment: childEnv,
      includeParentEnvironment: false,
    );
  } finally {
    if (isolatedRootDir != null && isolatedRootDir.existsSync()) {
      try {
        isolatedRootDir.deleteSync(recursive: true);
      } on FileSystemException {
        // Ignore cleanup errors.
      }
    }
    if (tempHome.existsSync()) {
      try {
        tempHome.deleteSync(recursive: true);
      } on FileSystemException {
        // Ignore cleanup errors.
      }
    }
  }
  if ((res.stdout as String).isNotEmpty) {
    stdout.write(res.stdout as String);
  }
  if ((res.stderr as String).isNotEmpty) {
    stderr.write(res.stderr as String);
  }
  if (res.exitCode != 0) {
    exit(res.exitCode);
  }
}
// Mirror of `directive_guard.dart` (the shared directive-URI check): the
// prologue scanner, the directive-URI resolution, the disallowed-scheme
// classification and the staged-relative resolution, copied verbatim (names
// included) so this tool classifies exactly what the modular kernel planner
// classifies.
//
// This file runs from source inside the whole-program `gen_kernel` action,
// where only this file is staged: it cannot import the guard library. Keep
// this mirror in sync with `directive_guard.dart`; the scanner diff must stay
// empty apart from this header.

const defaultMultiRootPrefix = 'org-dartlang-root:///';

/// The path after `multiRootPrefix`, or null for any other URI.
String? _stripPrefix(String uri, String multiRootPrefix) {
  if (uri.startsWith(multiRootPrefix)) {
    return uri.substring(multiRootPrefix.length);
  }
  return null;
}

/// The segments of the longest [packageDirs] directory holding `fromKey`, or
/// the empty list when no package holds it (an unpackaged file).
List<String> _packageDirOf(String fromKey, Map<String, String> packageDirs) {
  var best = const <String>[];
  for (final dir in packageDirs.values) {
    if (dir.isEmpty) continue;
    if (fromKey == dir || fromKey.startsWith('$dir/')) {
      final segs = dir.split('/');
      if (segs.length > best.length) best = segs;
    }
  }
  return best;
}

/// Applies the segments of a directive path onto [base]: empty and `.` segments
/// are dropped, each `..` pops while deeper than [floor], and a decoded `/`
/// (`%2F`) names no file, since no file can be read through it. Above [floor],
/// `..` either fails ([failAboveFloor], for `package:` URIs, where the front
/// end reports leaving the package) or is dropped (relative and absolute URIs,
/// which the front end clamps to the package directory or the multi-root).
String? _resolveDirectivePath(
  String path,
  List<String> base,
  int floor,
  bool failAboveFloor,
) {
  final stack = base.toList();
  for (final raw in path.split('/')) {
    if (raw.isEmpty) continue;
    final seg = decodeUriSegment(raw);
    if (seg.isEmpty || seg == '.') continue;
    if (seg == '..') {
      if (stack.length > floor) {
        stack.removeLast();
      } else if (failAboveFloor) {
        return null;
      }
      continue;
    }
    if (seg.contains('/')) return null;
    stack.add(seg);
  }
  return stack.join('/');
}

/// The key a directive URI (`import`, `export`, `part`, `part of`) in the file
/// named `fromKey` refers to: the key of the file the front end reads.
///
/// `packageDirs` maps each package name to its directory key (`pkg/lib`).
/// [multiRootPrefix] is the scheme the absolute URIs of multi-root files start
/// with (`org-dartlang-root:///`). Null when the URI names no workspace file:
/// an unknown package or scheme, an escape above a `package:` directory, a
/// fragment, an authority, or a decoded `/`. A `?...` query is dropped and the
/// path part resolved instead: an empty reference names the importing file
/// itself.
///
/// The resolution mirrors the front end exactly: `\` is a separator everywhere,
/// escapes decode once (either hex case), `/`-absolute URIs resolve against the
/// importer's package directory (unpackaged files against the multi-root), and
/// relative URIs against the importer's directory, clamped so `..` never leaves
/// the package directory.
String? resolveDirectiveUri(
  String uri,
  String fromKey,
  Map<String, String> packageDirs, {
  String multiRootPrefix = defaultMultiRootPrefix,
}) {
  final text = uri.contains(r'\') ? uri.replaceAll(r'\', '/') : uri;
  final absolute = _stripPrefix(text, multiRootPrefix);
  if (absolute != null) {
    return _resolveDirectivePath(absolute, const [], 0, false);
  }
  if (text.startsWith('package:')) {
    final rest = text.substring('package:'.length);
    if (rest.contains('?') || rest.contains('#')) return null;
    final slash = rest.indexOf('/');
    if (slash <= 0) return null;
    final dir = packageDirs[rest.substring(0, slash)];
    if (dir == null) return null;
    final base = dir.isEmpty ? const <String>[] : dir.split('/');
    return _resolveDirectivePath(
      rest.substring(slash + 1),
      base,
      base.length,
      true,
    );
  }
  // A fragment names no file: the front end reports a URI with one instead of
  // reading through it. A query names no file either: the front end reads the
  // file the path part names, so the path part alone is classified and
  // resolved below.
  if (text.contains('#')) return null;
  final query = text.indexOf('?');
  final path = query < 0 ? text : text.substring(0, query);
  if (path.contains(':')) return null;
  if (path.startsWith('//')) return null;
  // An empty reference names the importing file itself (RFC 3986).
  if (path.isEmpty) return fromKey;
  if (path.startsWith('/')) {
    final base = _packageDirOf(fromKey, packageDirs);
    return _resolveDirectivePath(path, base, base.length, false);
  }
  final slash = fromKey.lastIndexOf('/');
  final base = slash < 0
      ? const <String>[]
      : fromKey.substring(0, slash).split('/');
  final floor = _packageDirOf(fromKey, packageDirs).length;
  return _resolveDirectivePath(path, base, floor, false);
}

/// One URI-bearing directive of a source's prologue.
class ScanRef {
  const ScanRef(this.kind, this.uri);

  /// `import`, `export`, `part` or `part of`.
  final String kind;

  /// The URI. A configurable import gives the alternative it takes for the VM.
  final String uri;

  bool get isPart => kind == 'part';

  bool get isPartOf => kind == 'part of';
}

/// The directives of a source's prologue.
class ScanResult {
  const ScanResult(this.refs, {this.libraryName, this.partOfLibrary});

  final List<ScanRef> refs;

  /// The name from `library <name>;`, when declared.
  final String? libraryName;

  /// The library name from `part of <name>;`, when a part names its library by
  /// identifier rather than URI.
  final String? partOfLibrary;
}

/// The directives in the prologue of a Dart source, or null when the prologue has a
/// form this scanner does not read.
ScanResult? scanDirectives(String source, Set<String> vmLibraries) {
  try {
    return _Prologue(_Lexer(source), vmLibraries).parse();
  } on _Unparsable {
    return null;
  }
}

class _Unparsable implements Exception {
  const _Unparsable();
}

const _identKind = 0;
const _stringKind = 1;
const _punctKind = 2;
const _otherKind = 3;

class _Token {
  const _Token(this.kind, this.text, {this.raw = false});

  final int kind;
  final String text;
  final bool raw;
}

bool _isDigit(int c) => c >= 0x30 && c <= 0x39;

bool _isIdentStart(int c) =>
    (c >= 0x41 && c <= 0x5a) ||
    (c >= 0x61 && c <= 0x7a) ||
    c == 0x5f ||
    c == 0x24 ||
    c >= 0x80;

bool _isIdentChar(int c) => _isIdentStart(c) || _isDigit(c);

int _skipLine(String src, int start) {
  var at = start;
  while (at < src.length && src[at] != '\n' && src[at] != '\r') {
    at++;
  }
  return at;
}

/// The index just past the block comment that starts at `start`. Dart block
/// comments nest.
int _skipBlockComment(String src, int start) {
  var depth = 0;
  var at = start;
  while (at < src.length) {
    if (src.startsWith('/*', at)) {
      depth++;
      at += 2;
    } else if (src.startsWith('*/', at)) {
      depth--;
      at += 2;
      if (depth == 0) return at;
    } else {
      at++;
    }
  }
  throw const _Unparsable();
}

String _unescape(String s) {
  if (!s.contains('\\')) return s;
  final out = StringBuffer();
  var i = 0;
  while (i < s.length) {
    final ch = s[i++];
    if (ch != '\\') {
      out.write(ch);
      continue;
    }
    if (i >= s.length) throw const _Unparsable();
    final esc = s[i++];
    switch (esc) {
      case 'n':
        out.write('\n');
      case 'r':
        out.write('\r');
      case 'f':
        out.write('\f');
      case 'b':
        out.write('\b');
      case 't':
        out.write('\t');
      case 'v':
        out.write('\v');
      case 'x':
        if (i + 2 > s.length) throw const _Unparsable();
        final code = int.tryParse(s.substring(i, i + 2), radix: 16);
        if (code == null) throw const _Unparsable();
        out.writeCharCode(code);
        i += 2;
      case 'u':
        if (i < s.length && s[i] == '{') {
          final close = s.indexOf('}', i + 1);
          if (close < 0) throw const _Unparsable();
          final code = int.tryParse(s.substring(i + 1, close), radix: 16);
          if (code == null || code < 0 || code > 0x10FFFF) {
            throw const _Unparsable();
          }
          out.writeCharCode(code);
          i = close + 1;
        } else {
          if (i + 4 > s.length) throw const _Unparsable();
          final code = int.tryParse(s.substring(i, i + 4), radix: 16);
          if (code == null) throw const _Unparsable();
          out.writeCharCode(code);
          i += 4;
        }
      default:
        out.write(esc);
    }
  }
  return out.toString();
}

/// Reads the tokens of a Dart source one at a time, so a scan that stops at the end
/// of the directives never reads the rest of the file.
class _Lexer {
  _Lexer(this._src);

  final String _src;
  var _at = 0;
  _Token? _ahead;

  _Token? peek() => _ahead ??= _scan();

  _Token? take() {
    final token = peek();
    _ahead = null;
    return token;
  }

  _Token? _scan() {
    final src = _src;
    final n = src.length;
    if (_at == 0) {
      if (src.startsWith('\uFEFF')) _at++;
      if (src.startsWith('#!', _at)) {
        _at = _skipLine(src, _at + 2);
      }
    }
    while (_at < n) {
      final ch = src[_at];
      if (ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r') {
        _at++;
        continue;
      }
      if (ch == '/' && _at + 1 < n && src[_at + 1] == '/') {
        _at = _skipLine(src, _at + 2);
        continue;
      }
      if (ch == '/' && _at + 1 < n && src[_at + 1] == '*') {
        _at = _skipBlockComment(src, _at);
        continue;
      }
      final code = ch.codeUnitAt(0);
      if (_isIdentStart(code)) {
        final start = _at;
        while (_at < n && _isIdentChar(src.codeUnitAt(_at))) {
          _at++;
        }
        final word = src.substring(start, _at);
        if (word == 'r' && _at < n && (src[_at] == "'" || src[_at] == '"')) {
          return _string(raw: true);
        }
        return _Token(_identKind, word);
      }
      if (_isDigit(code)) {
        final start = _at;
        while (_at < n && _isIdentChar(src.codeUnitAt(_at))) {
          _at++;
        }
        return _Token(_otherKind, src.substring(start, _at));
      }
      if (ch == "'" || ch == '"') return _string(raw: false);
      _at++;
      return _Token(_punctKind, ch);
    }
    return null;
  }

  /// The string literal at `_at`, with its quotes removed and its escapes kept.
  _Token _string({required bool raw}) {
    final src = _src;
    final quote = src[_at];
    final triple = src.startsWith(quote * 3, _at);
    final delim = triple ? quote * 3 : quote;
    var contentStart = _at + delim.length;
    final endQuote = _skipString(_at, raw: raw);
    final contentEnd = endQuote - delim.length;
    if (triple && contentStart < contentEnd) {
      if (src.startsWith('\r\n', contentStart)) {
        contentStart += 2;
      } else if (src[contentStart] == '\n' || src[contentStart] == '\r') {
        contentStart += 1;
      }
    }
    _at = endQuote;
    return _Token(
      _stringKind,
      src.substring(contentStart, contentEnd),
      raw: raw,
    );
  }

  /// The index just past the string literal that starts at `quoteAt`.
  int _skipString(int quoteAt, {required bool raw}) {
    final src = _src;
    final n = src.length;
    final quote = src[quoteAt];
    final triple = src.startsWith(quote * 3, quoteAt);
    final delim = triple ? quote * 3 : quote;
    var at = quoteAt + delim.length;
    while (true) {
      if (at >= n) throw const _Unparsable();
      if (!raw && src[at] == '\\') {
        if (at + 1 >= n) throw const _Unparsable();
        at += 2;
        continue;
      }
      if (!raw && src.startsWith(r'${', at)) {
        at = _skipInterpolation(at + 2);
        continue;
      }
      if (src.startsWith(delim, at)) {
        return at + delim.length;
      }
      if (!triple && (src[at] == '\n' || src[at] == '\r')) {
        throw const _Unparsable();
      }
      at++;
    }
  }

  /// The index just past the `}` that closes a `${...}` string interpolation
  /// whose body starts at `start`.
  int _skipInterpolation(int start) {
    final src = _src;
    final n = src.length;
    var at = start;
    var depth = 1;
    while (at < n) {
      final ch = src[at];
      if (ch == '/' && at + 1 < n && src[at + 1] == '/') {
        at = _skipLine(src, at + 2);
        continue;
      }
      if (ch == '/' && at + 1 < n && src[at + 1] == '*') {
        at = _skipBlockComment(src, at);
        continue;
      }
      final code = ch.codeUnitAt(0);
      if (_isIdentStart(code) || _isDigit(code)) {
        final wordStart = at;
        while (at < n && _isIdentChar(src.codeUnitAt(at))) {
          at++;
        }
        if (at - wordStart == 1 &&
            src[wordStart] == 'r' &&
            at < n &&
            (src[at] == "'" || src[at] == '"')) {
          at = _skipString(at, raw: true);
        }
        continue;
      }
      if (ch == "'" || ch == '"') {
        at = _skipString(at, raw: false);
        continue;
      }
      if (ch == '{') {
        depth++;
      } else if (ch == '}') {
        depth--;
        if (depth == 0) return at + 1;
      }
      at++;
    }
    throw const _Unparsable();
  }
}

/// Reads the directive prologue: `library`, `import`, `export`, `part` and `part
/// of`, with the annotations before them. The first other token ends it.
class _Prologue {
  _Prologue(this._lexer, this._vm, {this.collectAll = false});

  final _Lexer _lexer;
  final Set<String> _vm;

  /// When true, every URI of an `import` or `export` directive is collected:
  /// the declared URI and each `if` alternative, without evaluating which one
  /// the configuration selects. Validators without the VM library set use this
  /// so no spelling of a disallowed scheme hides in an unselected branch.
  final bool collectAll;

  _Token? _peek() => _lexer.peek();

  _Token _take() {
    final token = _lexer.take();
    if (token == null) throw const _Unparsable();
    return token;
  }

  bool _is(String text, int kind) {
    final token = _peek();
    return token != null && token.kind == kind && token.text == text;
  }

  bool _ident(String text) => _is(text, _identKind);

  bool _punct(String text) => _is(text, _punctKind);

  void _expect(String text) {
    if (!_punct(text)) throw const _Unparsable();
    _lexer.take();
  }

  /// Consumes up to and including `text`.
  void _skipPast(String text) {
    while (!_punct(text)) {
      _take();
    }
    _lexer.take();
  }

  void _identToken() {
    if (_take().kind != _identKind) throw const _Unparsable();
  }

  /// A dotted identifier such as `foo` or `foo.bar.baz`.
  String _dottedIdent() {
    final first = _take();
    if (first.kind != _identKind) throw const _Unparsable();
    final out = StringBuffer(first.text);
    while (_punct('.')) {
      _lexer.take();
      final next = _take();
      if (next.kind != _identKind) throw const _Unparsable();
      out
        ..write('.')
        ..write(next.text);
    }
    return out.toString();
  }

  /// Adjacent string literals are one URI.
  String _string() {
    final token = _take();
    if (token.kind != _stringKind) throw const _Unparsable();
    final out = StringBuffer(token.raw ? token.text : _unescape(token.text));
    while (_peek()?.kind == _stringKind) {
      final next = _take();
      out.write(next.raw ? next.text : _unescape(next.text));
    }
    return out.toString();
  }

  /// `@name`, `@name.name`, `@name<...>(...)`, or `@name<...>.name(...)`.
  void _annotation() {
    _expect('@');
    _identToken();
    while (_punct('.')) {
      _lexer.take();
      _identToken();
    }
    if (_punct('<')) {
      var depth = 0;
      do {
        final token = _take();
        if (token.kind == _punctKind && token.text == '<') depth++;
        if (token.kind == _punctKind && token.text == '>') depth--;
      } while (depth > 0);
      while (_punct('.')) {
        _lexer.take();
        _identToken();
      }
    }
    if (_punct('(')) {
      var depth = 0;
      do {
        final token = _take();
        if (token.kind == _punctKind && token.text == '(') depth++;
        if (token.kind == _punctKind && token.text == ')') depth--;
      } while (depth > 0);
    }
  }

  /// The `if (...)` test of a configurable import, after its `(`, through its `)`.
  /// True when it holds for the VM. In CFE's configurable-import environment,
  /// available SDK libraries are mapped to `'true'` and all other names are
  /// unspecified (matching only `== ''`).
  bool _condition() {
    final text = _dottedIdent();
    String? value;
    if (_punct('=')) {
      _lexer.take();
      _expect('=');
      value = _string();
    }
    _expect(')');
    const prefix = 'dart.library.';
    if (text.startsWith(prefix)) {
      final present = _vm.contains(text.substring(prefix.length));
      if (!present) return false;
      return value == null || value == 'true';
    }
    return value == '';
  }

  /// `import` or `export` after its keyword: the URI, then any `if`
  /// alternatives, then the rest of the directive, which names nothing to read.
  ScanRef _uriDirective(String kind, List<ScanRef> refs) {
    final declared = _string();
    if (collectAll) refs.add(ScanRef(kind, declared));
    var chosen = declared;
    var picked = false;
    while (_ident('if')) {
      _lexer.take();
      _expect('(');
      final holds = _condition();
      final alternative = _string();
      if (collectAll) refs.add(ScanRef(kind, alternative));
      if (holds && !picked) {
        chosen = alternative;
        picked = true;
      }
    }
    _skipPast(';');
    return ScanRef(kind, chosen);
  }

  ScanResult parse() {
    final refs = <ScanRef>[];
    String? libraryName;
    String? partOfLibrary;
    while (true) {
      final token = _peek();
      if (token == null) break;
      if (token.kind == _punctKind && token.text == '@') {
        _annotation();
        continue;
      }
      if (token.kind != _identKind) break;
      if (token.text == 'library') {
        _lexer.take();
        if (_punct(';')) {
          _lexer.take();
        } else if (_peek()?.kind == _identKind) {
          libraryName ??= _dottedIdent();
          _expect(';');
        } else {
          break;
        }
      } else if (token.text == 'import' || token.text == 'export') {
        _lexer.take();
        if (_peek()?.kind != _stringKind) break;
        final ref = _uriDirective(token.text, refs);
        if (!collectAll) refs.add(ref);
      } else if (token.text == 'part') {
        _lexer.take();
        if (_ident('of')) {
          _lexer.take();
          if (_peek()?.kind == _stringKind) {
            refs.add(ScanRef('part of', _string()));
          } else {
            partOfLibrary ??= _dottedIdent();
          }
          _expect(';');
        } else if (_peek()?.kind == _stringKind) {
          refs.add(ScanRef('part', _string()));
          _expect(';');
        } else {
          break;
        }
      } else {
        break;
      }
    }
    return ScanResult(
      refs,
      libraryName: libraryName,
      partOfLibrary: partOfLibrary,
    );
  }
}

/// Every URI-bearing directive of a source's prologue: each `import` and
/// `export` contributes its declared URI and every `if` alternative, each
/// `part` and `part of` its URI. Conditions are not evaluated, so no VM
/// library set is needed. An empty list when the prologue does not scan (the
/// compiler then reports the genuine syntax error).
List<ScanRef> scanAllDirectiveUris(String source) {
  try {
    return _Prologue(_Lexer(source), const {}, collectAll: true).parse().refs;
  } on _Unparsable {
    return const [];
  }
}

/// The diagnostics for every disallowed-scheme directive URI in `fileContents`
/// (display path to source text), in path order. Empty when clean. Each names
/// the file, the directive and the URI.
List<String> findDisallowedDirectives(
  Map<String, String> fileContents, {
  String tool = 'dart',
  String multiRootPrefix = defaultMultiRootPrefix,
}) {
  final errors = <String>[];
  final paths = fileContents.keys.toList()..sort();
  for (final path in paths) {
    final content = fileContents[path];
    if (content == null) continue;
    for (final ref in scanAllDirectiveUris(content)) {
      final disallowed = ref.isPart || ref.isPartOf
          ? isFileSchemeDirectiveUri(ref.uri)
          : isDisallowedDirectiveUri(ref.uri, multiRootPrefix: multiRootPrefix);
      if (disallowed) {
        errors.add(
          "$tool: $path ${ref.kind} '${ref.uri}' is not a declared input.",
        );
      }
    }
  }
  return errors;
}

// BEGIN staged-resolver-mirror: byte-identical in directive_guard.dart,
// app_jit_snapshot.dart and builder_shim.dart (pinned by
// directive_guard_test.dart). Edit only by syncing all three copies.

/// Decodes one raw URI path segment the way the front end does (RFC 3986): each
/// valid `%XX` escape becomes its byte (bytes together decode as UTF-8, either
/// hex case), while anything else — including a lone `%` — stays literal.
/// Decoding happens once: a `%` produced by decoding is never decoded again.
String decodeUriSegment(String segment) {
  if (!segment.contains('%')) return segment;
  final out = StringBuffer();
  final bytes = <int>[];
  void flush() {
    if (bytes.isEmpty) return;
    out.write(utf8.decode(bytes, allowMalformed: true));
    bytes.clear();
  }

  for (var i = 0; i < segment.length; i++) {
    final c = segment.codeUnitAt(i);
    if (c == 0x25 && i + 2 < segment.length) {
      final hex = int.tryParse(segment.substring(i + 1, i + 3), radix: 16);
      if (hex != null && hex >= 0 && hex <= 0xff) {
        bytes.add(hex);
        i += 2;
        continue;
      }
    }
    flush();
    out.writeCharCode(c);
  }
  flush();
  return out.toString();
}

/// Whether [uri] is a `package:` URI whose path climbs above its package
/// directory (`package:pkg/sub/../../x.dart`). The front end reports leaving
/// the package, but a tool that resolves against the real filesystem reads a
/// host file instead, so the staged-source check refuses it before they run.
/// False for any other URI, including a `package:` URI that stays inside its
/// package (an unknown package name fails closed downstream, where the
/// analyzer cannot resolve it, so it is not refused here).
bool isEscapingPackageUri(String uri) {
  if (!uri.startsWith('package:')) return false;
  final rest = uri.substring('package:'.length);
  if (rest.contains('?') || rest.contains('#')) return false;
  final slash = rest.indexOf('/');
  if (slash <= 0) return false;
  final text = rest.substring(slash + 1).replaceAll(r'\', '/');
  var depth = 0;
  for (final raw in text.split('/')) {
    if (raw.isEmpty) continue;
    final seg = decodeUriSegment(raw);
    if (seg.isEmpty || seg == '.') continue;
    if (seg == '..') {
      depth--;
      if (depth < 0) return true;
    } else if (!seg.contains('/')) {
      depth++;
    }
  }
  return false;
}

/// Whether [path] is absolute: POSIX `/`, a Windows drive (`C:/`, `C:\`), or
/// a UNC share (`\\`).
bool _isAbsoluteStagedPath(String path) =>
    path.startsWith('/') ||
    path.startsWith(r'\') ||
    (path.length >= 3 &&
        ((path.codeUnitAt(0) >= 0x41 && path.codeUnitAt(0) <= 0x5a) ||
            (path.codeUnitAt(0) >= 0x61 && path.codeUnitAt(0) <= 0x7a)) &&
        path.codeUnitAt(1) == 0x3a &&
        (path.codeUnitAt(2) == 0x2f || path.codeUnitAt(2) == 0x5c));

bool _isWindowsDriveSegment(String s) =>
    s.length == 2 &&
    ((s.codeUnitAt(0) >= 0x41 && s.codeUnitAt(0) <= 0x5a) ||
        (s.codeUnitAt(0) >= 0x61 && s.codeUnitAt(0) <= 0x7a)) &&
    s.codeUnitAt(1) == 0x3a;

/// [path] as an absolute `/`-separated path: backslashes become separators,
/// a relative path resolves against the current directory, and empty and `.`
/// segments drop out. `..` segments stay (the caller applies them against its
/// own base), except the resolution below, which clamps them at the
/// filesystem root the way the analyzer does.
String _normAbsStagedPath(String path) {
  final slashed = path.replaceAll(r'\', '/');
  final absolute = _isAbsoluteStagedPath(slashed)
      ? slashed
      : '${Directory.current.path.replaceAll(r'\', '/')}/$slashed';
  final unc = absolute.startsWith('//');
  final parts = <String>[];
  for (final part in absolute.split('/')) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..') {
      // `..` clamps at the filesystem root the way the analyzer clamps it:
      // past `/`, past a drive (`C:`), or past a UNC share's host.
      final floor = unc
          ? (parts.length <= 2 ? parts.length : 2)
          : (parts.isNotEmpty && _isWindowsDriveSegment(parts.first) ? 1 : 0);
      if (parts.length > floor) {
        parts.removeLast();
      }
      continue;
    }
    parts.add(part);
  }
  final joined = parts.join('/');
  if (unc) return '//$joined';
  if (absolute.startsWith('/')) return '/$joined';
  return joined;
}

/// The absolute `/`-separated path a schemeless relative or `/`-absolute
/// directive URI in the staged file [fromPath] refers to, resolved the way the
/// analyzer resolves it on the real filesystem: `\` separates, escapes decode
/// once, a `?...` query is dropped (the front end reads the file the path part
/// names, query or not), and `..` climbs past the staged tree (clamped at the
/// filesystem root, where overshooting names any host path) instead of staying
/// inside the declared inputs.
///
/// An empty reference — `''`, or `'?query'` with no path — names the importing
/// file itself (RFC 3986): a self-import, always declared.
///
/// Null when [uri] is not such a URI: any scheme (`dart:`, `package:`,
/// `file:`, the multi-root scheme, or anything else with a `:`), a fragment
/// (the front end reports a URI with one instead of reading through it), or a
/// `//`-prefixed authority. A decoded `/` also yields null: it names no file,
/// so the compiler reports it and the guard has nothing to confine. Null means
/// "no host file beyond what the scheme check already refuses", never "inside
/// the declared inputs".
String? resolveStagedRelativeTarget(String uri, String fromPath) {
  final text = uri.contains(r'\') ? uri.replaceAll(r'\', '/') : uri;
  // A fragment names no file: the front end reports a URI with one instead of
  // reading through it, whatever path precedes it.
  if (text.contains('#')) return null;
  // A query names no file either: the front end reads the file the path part
  // names, so the path part alone is classified and resolved below. Cutting
  // here also keeps a `:` inside the query from looking like a scheme.
  final query = text.indexOf('?');
  final path = query < 0 ? text : text.substring(0, query);
  if (path.contains(':')) return null;
  if (path.startsWith('//')) return null;
  final from = _normAbsStagedPath(fromPath);
  // An empty reference names the importing file itself (RFC 3986).
  if (path.isEmpty) return from;
  final rooted = from.startsWith('/');
  final drive =
      !rooted &&
      from.contains('/') &&
      _isWindowsDriveSegment(from.split('/').first);
  final stack = from.split('/');
  // Drop the file name: the URI resolves against its directory.
  if (stack.isNotEmpty) stack.removeLast();
  final floor = rooted || drive ? 1 : 0;
  final absolute = path.startsWith('/');
  final base = absolute ? stack.sublist(0, floor) : stack;
  final queue = absolute ? path.substring(1) : path;
  for (final raw in queue.split('/')) {
    if (raw.isEmpty) continue;
    final seg = decodeUriSegment(raw);
    if (seg.isEmpty || seg == '.') continue;
    if (seg == '..') {
      if (base.length > floor) base.removeLast();
      continue;
    }
    if (seg.contains('/')) return null;
    base.add(seg);
  }
  final joined = base.join('/');
  // A rooted `from` splits with a leading empty segment, so the join already
  // starts with `/` (or `//` for a UNC share); only fill in a bare `/` when
  // the base ran empty.
  if (rooted) return joined.startsWith('/') ? joined : '/$joined';
  return joined;
}

/// Whether `uri` is a `file:` URI in any spelling: any letter case, any
/// authority (`file://localhost/`), a bare path (`file:x.dart`), backslash
/// separators, or a query or fragment suffix. The front end reads all of these
/// off the host filesystem, outside every multi-root.
bool isFileSchemeDirectiveUri(String uri) {
  final colon = uri.indexOf(':');
  if (colon != 4) return false;
  const scheme = 'file';
  for (var i = 0; i < 4; i++) {
    var c = uri.codeUnitAt(i);
    if (c >= 0x41 && c <= 0x5A) c += 0x20;
    if (c != scheme.codeUnitAt(i)) return false;
  }
  return true;
}

bool _isSchemeStart(int c) =>
    (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7a);

bool _isSchemeChar(int c) =>
    _isSchemeStart(c) ||
    (c >= 0x30 && c <= 0x39) ||
    c == 0x2B ||
    c == 0x2D ||
    c == 0x2E;

/// Whether an `import` or `export` directive URI must fail the build: it names
/// no file the action can read through its declared inputs. That is a `file:`
/// URI in any spelling, or any other URI scheme but `dart:`, `package:` and
/// the multi-root scheme. `dart:` libraries are checked against the VM set and
/// `package:` URIs against the package config by the caller. Schemeless
/// relative URIs are not classified here: the staged-source check resolves
/// those against the importing file's declared location itself, since no
/// caller confines them.
bool isDisallowedDirectiveUri(
  String uri, {
  String multiRootPrefix = defaultMultiRootPrefix,
}) {
  if (uri.startsWith(multiRootPrefix)) return false;
  if (uri.startsWith('package:') || uri.startsWith('dart:')) return false;
  if (isFileSchemeDirectiveUri(uri)) return true;
  final colon = uri.indexOf(':');
  if (colon <= 0) return false;
  if (!_isSchemeStart(uri.codeUnitAt(0))) return false;
  for (var i = 1; i < colon; i++) {
    if (!_isSchemeChar(uri.codeUnitAt(i))) return false;
  }
  return true;
}

// END staged-resolver-mirror
