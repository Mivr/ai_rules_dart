/// Chain replay and byte-identical reproduction proof.
library;

import 'dart:io';

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
      Process.runSync('chmod', ['-R', 'u+w', outDir.path]);
    } else if (Platform.isWindows) {
      Process.runSync('attrib', ['-r', '${outDir.path}\\*', '/s', '/d']);
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
      } else if (child is File) {
        final dstFile = File('${dstDir.path}/$subRel');
        dstFile.parent.createSync(recursive: true);
        child.copySync(dstFile.path);
      }
    }
  } else if (type == FileSystemEntityType.file) {
    final dstFile = File('${backupDir.path}/$relPath');
    dstFile.parent.createSync(recursive: true);
    File(fullPath).copySync(dstFile.path);
  }
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

void _backupAndMoveOutputsAside({
  required String execroot,
  required Directory backupDir,
  required Set<String> declaredOutputs,
  required Set<String> verifyPaths,
}) {
  for (final relPath in verifyPaths) {
    _copyEntityToBackup(execroot, backupDir, relPath);
  }
  final sortedDeclared = declaredOutputs.toList()
    ..sort((a, b) => b.length.compareTo(a.length));
  for (final relPath in sortedDeclared) {
    _copyEntityToBackup(execroot, backupDir, relPath);
    _deleteEntityAtPath('$execroot/$relPath');
  }
}

(double, String?) _executeSpawns({
  required List<SpawnRecord> orderedSpawns,
  required String execroot,
  required ChildCpuClock clock,
  required bool isTestFlow,
}) {
  var totalCpu = 0.0;
  for (final spawn in orderedSpawns) {
    if (spawn.commandArgs.isEmpty) continue;

    final env = Map<String, String>.of(Platform.environment)
      ..addAll(spawn.environmentVariables);
    final cmd = spawn.commandArgs.first;
    final args = spawn.commandArgs.sublist(1);

    final beforeCpu = clock.getChildCpuSeconds();
    final result = Process.runSync(
      cmd,
      args,
      workingDirectory: execroot,
      environment: env,
    );
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

String? _verifyDirectoryIdentical(
  Directory replayed,
  Directory backup,
  String relPath,
) {
  if (!replayed.existsSync()) return 'Replayed directory missing: $relPath';
  final repFiles = <String, File>{};
  for (final e in replayed.listSync(recursive: true, followLinks: false)) {
    if (e is File) repFiles[_relPath(replayed.path, e.path)] = e;
  }
  final bakFiles = <String, File>{};
  for (final e in backup.listSync(recursive: true, followLinks: false)) {
    if (e is File) bakFiles[_relPath(backup.path, e.path)] = e;
  }
  if (repFiles.length != bakFiles.length) {
    return 'Directory entry count mismatch in $relPath';
  }
  for (final entry in bakFiles.entries) {
    final repFile = repFiles[entry.key];
    if (repFile == null) return 'Missing file in $relPath: ${entry.key}';
    if (!areFilesByteIdentical(repFile, entry.value)) {
      return 'Byte mismatch in verified output: $relPath/${entry.key}';
    }
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
    final replayedFile = File('$execroot/$relPath');
    if (!replayedFile.existsSync()) {
      return 'Replayed output missing: $relPath';
    }
    if (!areFilesByteIdentical(replayedFile, File(bakPath))) {
      return 'Byte mismatch in verified output: $relPath';
    }
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

    if (backupDir.existsSync()) {
      for (final entity in backupDir.listSync(
        recursive: true,
        followLinks: false,
      )) {
        final rel = _relPath(backupDir.path, entity.path);
        if (entity is Directory) {
          Directory('$execroot/$rel').createSync(recursive: true);
        } else if (entity is File) {
          final target = File('$execroot/$rel');
          target.parent.createSync(recursive: true);
          entity.copySync(target.path);
        }
      }
      if (Platform.isLinux || Platform.isMacOS) {
        Process.runSync('chmod', ['-R', 'u+w', backupDir.path]);
      }
      backupDir.deleteSync(recursive: true);
    }
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
  final (cpu, failure) = _executeSpawns(
    orderedSpawns: orderedSpawns,
    execroot: execroot,
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
