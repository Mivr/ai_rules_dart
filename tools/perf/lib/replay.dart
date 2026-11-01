/// Chain replay and byte-identical reproduction proof.
library;

import 'dart:io';

import 'cli_args.dart';
import 'cpu.dart';
import 'spawn_log.dart';

/// Replay execution result.
final class ReplayResult {
  /// Creates a replay result.
  const ReplayResult({
    required this.identical,
    required this.solCpuSeconds,
    required this.reason,
    required this.replayedCount,
  });

  /// Whether the replayed outputs matched byte-for-byte.
  final bool identical;

  /// Speed-of-light CPU seconds (null on failure).
  final double? solCpuSeconds;

  /// Status reason ("ok" or failure description).
  final String reason;

  /// Number of replayed chain spawns.
  final int replayedCount;
}

final class _ExecrootSnapshot {
  const _ExecrootSnapshot({required this.files, required this.dirs});

  final Set<String> files;
  final Set<String> dirs;
}

String _relPath(String root, String fullPath) {
  final normRoot = root.replaceAll(r'\', '/');
  final normFull = fullPath.replaceAll(r'\', '/');
  if (normFull.startsWith('$normRoot/')) {
    return normFull.substring(normRoot.length + 1);
  }
  return normFull;
}

_ExecrootSnapshot _snapshotExecroot(String execroot) {
  final files = <String>{};
  final dirs = <String>{};
  final rootDir = Directory(execroot);
  if (!rootDir.existsSync()) {
    return _ExecrootSnapshot(files: files, dirs: dirs);
  }

  void walk(Directory current, {required bool isRoot}) {
    for (final entity in current.listSync(followLinks: false)) {
      final rel = _relPath(execroot, entity.path);
      if (isRoot && rel == 'external') continue;
      if (entity is Directory) {
        dirs.add(rel);
        walk(entity, isRoot: false);
      } else {
        files.add(rel);
      }
    }
  }

  walk(rootDir, isRoot: true);
  return _ExecrootSnapshot(files: files, dirs: dirs);
}

/// Makes files and directories in `bazel-out` writable.
void makeBazelOutWritable(String execroot) {
  final outDir = Directory('$execroot/bazel-out');
  if (!outDir.existsSync()) return;

  try {
    if (Platform.isLinux || Platform.isMacOS) {
      Process.runSync(
        'chmod',
        ['-R', 'u+w', outDir.path],
        environment: cleanProcessEnvironment(),
        includeParentEnvironment: false,
      );
    } else if (Platform.isWindows) {
      final winOutPath = outDir.path.replaceAll('/', r'\');
      Process.runSync(
        'attrib',
        ['-r', '$winOutPath\\*', '/s', '/d'],
        environment: cleanProcessEnvironment(),
        includeParentEnvironment: false,
      );
    }
  } on ProcessException catch (e) {
    stderr.writeln('chmod/attrib on bazel-out failed: $e');
  }
}

/// Compares two files byte-by-byte for equality.
bool areFilesByteIdentical(File a, File b) {
  if (!a.existsSync() || !b.existsSync()) return false;
  if (a.lengthSync() != b.lengthSync()) return false;

  final bytesA = a.readAsBytesSync();
  final bytesB = b.readAsBytesSync();
  if (bytesA.length != bytesB.length) return false;

  for (var i = 0; i < bytesA.length; i++) {
    if (bytesA[i] != bytesB[i]) return false;
  }
  return true;
}

void _deleteEntityAtPath(String fullPath) {
  final type = FileSystemEntity.typeSync(fullPath, followLinks: false);
  if (type == FileSystemEntityType.notFound) return;
  if (type == FileSystemEntityType.directory) {
    Directory(fullPath).deleteSync(recursive: true);
  } else if (type == FileSystemEntityType.link) {
    Link(fullPath).deleteSync();
  } else {
    File(fullPath).deleteSync();
  }
}

void _copyLeafEntity(FileSystemEntity src, String dstPath) {
  _deleteEntityAtPath(dstPath);
  File(dstPath).parent.createSync(recursive: true);
  if (src is Link) {
    Link(dstPath).createSync(src.targetSync());
  } else if (src is File) {
    src.copySync(dstPath);
  }
}

void _copyEntityToBackup(String execroot, Directory backupDir, String relPath) {
  final fullPath = '$execroot/$relPath';
  final type = FileSystemEntity.typeSync(fullPath, followLinks: false);
  if (type == FileSystemEntityType.notFound) return;

  if (type == FileSystemEntityType.directory) {
    final srcDir = Directory(fullPath);
    final dstDir = Directory('${backupDir.path}/$relPath')
      ..createSync(recursive: true);
    for (final child in srcDir.listSync(recursive: true, followLinks: false)) {
      final subRel = _relPath(srcDir.path, child.path);
      if (child is Directory) {
        Directory('${dstDir.path}/$subRel').createSync(recursive: true);
      } else {
        _copyLeafEntity(child, '${dstDir.path}/$subRel');
      }
    }
  } else if (type == FileSystemEntityType.link) {
    _copyLeafEntity(Link(fullPath), '${backupDir.path}/$relPath');
  } else if (type == FileSystemEntityType.file) {
    _copyLeafEntity(File(fullPath), '${backupDir.path}/$relPath');
  }
}

void _backupAndMoveOutputsAside({
  required String execroot,
  required Directory backupDir,
  required Set<String> declaredOutputs,
  required Set<String> verifyPaths,
}) {
  final allToBackup = <String>{...verifyPaths, ...declaredOutputs}.toList()
    ..sort((a, b) => a.length.compareTo(b.length));
  for (final relPath in allToBackup) {
    _copyEntityToBackup(execroot, backupDir, relPath);
  }

  final sortedDeclared = declaredOutputs.toList()
    ..sort((a, b) => b.length.compareTo(a.length));
  for (final relPath in sortedDeclared) {
    _deleteEntityAtPath('$execroot/$relPath');
  }
}

void _ensureOutputParentDirs(
  String execroot,
  Directory backupDir,
  SpawnRecord spawn,
) {
  final outputs = spawn.listedOutputs.isNotEmpty
      ? spawn.listedOutputs
      : spawn.actualOutputs;
  for (final out in outputs) {
    File('$execroot/$out').parent.createSync(recursive: true);
    final bakType = FileSystemEntity.typeSync(
      '${backupDir.path}/$out',
      followLinks: false,
    );
    if (bakType == FileSystemEntityType.directory) {
      Directory('$execroot/$out').createSync(recursive: true);
    }
  }
}

String _resolveReplayExecutable(String execroot, String cmd) {
  if (!Platform.isWindows || isAbsoluteCliPath(cmd)) return cmd;
  if (cmd.contains('/') || cmd.contains(r'\')) {
    final candidate = File('$execroot/$cmd');
    if (candidate.existsSync()) return candidate.path;
  }
  return cmd;
}

(double, String?) _executeSpawns({
  required List<SpawnRecord> orderedSpawns,
  required String execroot,
  required Directory backupDir,
  required ChildCpuClock clock,
  required bool isTestFlow,
}) {
  var totalCpu = 0.0;
  for (final spawn in orderedSpawns) {
    if (spawn.commandArgs.isEmpty) continue;

    _ensureOutputParentDirs(execroot, backupDir, spawn);
    final env = cleanProcessEnvironment(overlay: spawn.environmentVariables);
    final cmd = spawn.commandArgs.first;
    final executable = _resolveReplayExecutable(execroot, cmd);
    final args = spawn.commandArgs.sublist(1);

    final ProcessResult result;
    final beforeCpu = clock.getChildCpuSeconds();
    try {
      result = Process.runSync(
        executable,
        args,
        workingDirectory: execroot,
        environment: env,
        includeParentEnvironment: false,
      );
    } on ProcessException catch (e) {
      final afterCpu = clock.getChildCpuSeconds();
      final stepCpu = afterCpu - beforeCpu;
      if (stepCpu > 0) totalCpu += stepCpu;
      return (totalCpu, 'Spawn $cmd failed to start: $e');
    }
    final afterCpu = clock.getChildCpuSeconds();
    final stepCpu = afterCpu - beforeCpu;
    if (stepCpu > 0) totalCpu += stepCpu;

    if (result.exitCode != 0) {
      if (isTestFlow && spawn.isTestRunner) {
        return (
          totalCpu,
          'TestRunner failed with exit code ${result.exitCode}',
        );
      }
      return (
        totalCpu,
        'Spawn $cmd failed with exit code ${result.exitCode}: ${result.stderr}',
      );
    }
  }
  return (totalCpu, null);
}

String? _verifyLeafEntityIdentical(
  String repPath,
  String bakPath,
  String displayPath,
) {
  final bakType = FileSystemEntity.typeSync(bakPath, followLinks: false);
  final repType = FileSystemEntity.typeSync(repPath, followLinks: false);
  if (repType == FileSystemEntityType.notFound) {
    return 'Replayed output missing: $displayPath';
  }
  if (repType != bakType) {
    return 'Output type mismatch in verified output: $displayPath';
  }
  if (bakType == FileSystemEntityType.link) {
    if (Link(repPath).targetSync() != Link(bakPath).targetSync()) {
      return 'Symlink target mismatch in verified output: $displayPath';
    }
    return null;
  }
  if (!areFilesByteIdentical(File(repPath), File(bakPath))) {
    return 'Byte mismatch in verified output: $displayPath';
  }
  return null;
}

Map<String, String> _collectNonDirEntries(Directory dir) {
  final entries = <String, String>{};
  for (final e in dir.listSync(recursive: true, followLinks: false)) {
    if (e is! Directory) {
      entries[_relPath(dir.path, e.path)] = e.path;
    }
  }
  return entries;
}

String? _verifyDirectoryIdentical(
  Directory replayed,
  Directory backup,
  String relPath,
) {
  if (!replayed.existsSync()) return 'Replayed directory missing: $relPath';
  final repEntries = _collectNonDirEntries(replayed);
  final bakEntries = _collectNonDirEntries(backup);
  if (repEntries.length != bakEntries.length) {
    return 'Directory entry count mismatch in $relPath';
  }
  for (final entry in bakEntries.entries) {
    final repPath = repEntries[entry.key];
    if (repPath == null) return 'Missing file in $relPath: ${entry.key}';
    final err = _verifyLeafEntityIdentical(
      repPath,
      entry.value,
      '$relPath/${entry.key}',
    );
    if (err != null) return err;
  }
  return null;
}

String? _verifyOutputs(
  String execroot,
  Directory backupDir,
  Set<String> verifyPaths,
) {
  for (final relPath in verifyPaths) {
    final bakPath = '${backupDir.path}/$relPath';
    final bakType = FileSystemEntity.typeSync(bakPath, followLinks: false);
    if (bakType == FileSystemEntityType.notFound) {
      return 'Original output missing in backup: $relPath';
    }
    if (bakType == FileSystemEntityType.directory) {
      final err = _verifyDirectoryIdentical(
        Directory('$execroot/$relPath'),
        Directory(bakPath),
        relPath,
      );
      if (err != null) return err;
      continue;
    }
    final err = _verifyLeafEntityIdentical(
      '$execroot/$relPath',
      bakPath,
      relPath,
    );
    if (err != null) return err;
  }
  return null;
}

void _sweepUndeclaredSideEffects(String execroot, _ExecrootSnapshot before) {
  final after = _snapshotExecroot(execroot);
  for (final relFile in after.files) {
    if (!before.files.contains(relFile)) {
      _deleteEntityAtPath('$execroot/$relFile');
    }
  }
  final extraDirs = after.dirs.where((d) => !before.dirs.contains(d)).toList()
    ..sort((a, b) => b.length.compareTo(a.length));
  for (final relDir in extraDirs) {
    final dir = Directory('$execroot/$relDir');
    if (dir.existsSync() && dir.listSync(followLinks: false).isEmpty) {
      dir.deleteSync();
    }
  }
}

void _restoreBackupEntities(Directory backupDir, String execroot) {
  if (!backupDir.existsSync()) return;
  for (final entity in backupDir.listSync(
    recursive: true,
    followLinks: false,
  )) {
    final rel = _relPath(backupDir.path, entity.path);
    if (entity is Directory) {
      Directory('$execroot/$rel').createSync(recursive: true);
    } else {
      _copyLeafEntity(entity, '$execroot/$rel');
    }
  }
  if (Platform.isLinux || Platform.isMacOS) {
    Process.runSync(
      'chmod',
      ['-R', 'u+w', backupDir.path],
      environment: cleanProcessEnvironment(),
      includeParentEnvironment: false,
    );
  }
  backupDir.deleteSync(recursive: true);
}

void _sweepAndRestore({
  required String execroot,
  required Directory backupDir,
  required Set<String> declaredOutputs,
  required _ExecrootSnapshot snapshotBefore,
}) {
  try {
    makeBazelOutWritable(execroot);
    final sortedDeclared = declaredOutputs.toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    for (final relPath in sortedDeclared) {
      _deleteEntityAtPath('$execroot/$relPath');
    }
    _sweepUndeclaredSideEffects(execroot, snapshotBefore);
    _restoreBackupEntities(backupDir, execroot);
  } on ProcessException catch (e) {
    stderr.writeln('Error chmodding backup outputs: $e');
  } on FileSystemException catch (e) {
    stderr.writeln('Error sweeping/restoring replay outputs: $e');
  }
}

ReplayResult _runReplayAndVerify({
  required List<SpawnRecord> orderedSpawns,
  required String execroot,
  required Directory backupDir,
  required Set<String> verifyPaths,
  required ChildCpuClock clock,
  required bool isTestFlow,
}) {
  try {
    final (cpu, failure) = _executeSpawns(
      orderedSpawns: orderedSpawns,
      execroot: execroot,
      backupDir: backupDir,
      clock: clock,
      isTestFlow: isTestFlow,
    );
    if (failure != null) {
      return ReplayResult(
        identical: false,
        solCpuSeconds: null,
        reason: failure,
        replayedCount: orderedSpawns.length,
      );
    }

    final verifyErr = _verifyOutputs(execroot, backupDir, verifyPaths);
    if (verifyErr != null) {
      return ReplayResult(
        identical: false,
        solCpuSeconds: null,
        reason: verifyErr,
        replayedCount: orderedSpawns.length,
      );
    }

    return ReplayResult(
      identical: true,
      solCpuSeconds: cpu,
      reason: 'ok',
      replayedCount: orderedSpawns.length,
    );
  } on FileSystemException catch (e) {
    stderr.writeln('Replay filesystem error: $e');
    return ReplayResult(
      identical: false,
      solCpuSeconds: null,
      reason: 'Replay filesystem error: $e',
      replayedCount: orderedSpawns.length,
    );
  }
}

/// Replays ordered spawns in `execroot` and verifies byte-identical outputs.
ReplayResult replayChainAndVerify({
  required List<SpawnRecord> orderedSpawns,
  required String execroot,
  required Set<String> verifyPaths,
  required ChildCpuClock clock,
  bool isTestFlow = false,
}) {
  if (orderedSpawns.isEmpty) {
    return const ReplayResult(
      identical: false,
      solCpuSeconds: null,
      reason: 'No chain spawns to replay',
      replayedCount: 0,
    );
  }

  makeBazelOutWritable(execroot);
  final snapshotBefore = _snapshotExecroot(execroot);
  final backupDir = Directory.systemTemp.createTempSync('rd_perf_backup_');

  final declaredOutputs = <String>{};
  for (final spawn in orderedSpawns) {
    declaredOutputs.addAll(spawn.declaredOutputs);
  }

  try {
    _backupAndMoveOutputsAside(
      execroot: execroot,
      backupDir: backupDir,
      declaredOutputs: declaredOutputs,
      verifyPaths: verifyPaths,
    );
  } on FileSystemException catch (e) {
    stderr.writeln('Failed moving outputs aside: $e');
    _sweepAndRestore(
      execroot: execroot,
      backupDir: backupDir,
      declaredOutputs: declaredOutputs,
      snapshotBefore: snapshotBefore,
    );
    return ReplayResult(
      identical: false,
      solCpuSeconds: null,
      reason: 'Failed moving outputs aside: $e',
      replayedCount: 0,
    );
  }

  try {
    return _runReplayAndVerify(
      orderedSpawns: orderedSpawns,
      execroot: execroot,
      backupDir: backupDir,
      verifyPaths: verifyPaths,
      clock: clock,
      isTestFlow: isTestFlow,
    );
  } finally {
    _sweepAndRestore(
      execroot: execroot,
      backupDir: backupDir,
      declaredOutputs: declaredOutputs,
      snapshotBefore: snapshotBefore,
    );
  }
}
