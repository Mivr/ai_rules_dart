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

/// Makes files and directories in `bazel-out` writable.
void makeBazelOutWritable(String execroot) {
  final outDir = Directory('$execroot/bazel-out');
  if (!outDir.existsSync()) return;

  try {
    if (Platform.isLinux || Platform.isMacOS) {
      Process.runSync('chmod', ['-R', 'u+w', outDir.path]);
    }
  } on ProcessException catch (e) {
    stderr.writeln('chmod on bazel-out failed: $e');
  } on Exception catch (e) {
    stderr.writeln('Error making bazel-out writable: $e');
  }
}

/// Compares two files byte-by-byte for equality.
bool areFilesByteIdentical(File a, File b) {
  if (!a.existsSync() || !b.existsSync()) return false;
  final lengthA = a.lengthSync();
  final lengthB = b.lengthSync();
  if (lengthA != lengthB) return false;

  final bytesA = a.readAsBytesSync();
  final bytesB = b.readAsBytesSync();
  if (bytesA.length != bytesB.length) return false;

  for (var i = 0; i < bytesA.length; i++) {
    if (bytesA[i] != bytesB[i]) return false;
  }
  return true;
}

List<String> _moveOutputsAside(
  String execroot,
  Directory backupDir,
  Set<String> declaredOutputs,
) {
  final movedAside = <String>[];
  for (final relPath in declaredOutputs) {
    final srcFile = File('$execroot/$relPath');
    if (srcFile.existsSync()) {
      final backupFile = File('${backupDir.path}/$relPath');
      backupFile.parent.createSync(recursive: true);
      srcFile.copySync(backupFile.path);
      srcFile.deleteSync();
      movedAside.add(relPath);
    }
  }
  return movedAside;
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

    final env = Map<String, String>.of(Platform.environment);
    env.addAll(spawn.environmentVariables);

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

String? _verifyOutputs(
  String execroot,
  Directory backupDir,
  Set<String> verifyPaths,
) {
  for (final relPath in verifyPaths) {
    final replayedFile = File('$execroot/$relPath');
    final originalBackup = File('${backupDir.path}/$relPath');

    if (!replayedFile.existsSync()) {
      return 'Replayed output missing: $relPath';
    }
    if (!originalBackup.existsSync()) {
      return 'Original output missing in backup: $relPath';
    }

    if (!areFilesByteIdentical(replayedFile, originalBackup)) {
      return 'Byte mismatch in verified output: $relPath';
    }
  }
  return null;
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
  final backupDir = Directory(
    '$execroot/_perf_replay_backup_${DateTime.now().microsecondsSinceEpoch}',
  );
  if (!backupDir.existsSync()) backupDir.createSync(recursive: true);

  final declaredOutputs = <String>{};
  for (final spawn in orderedSpawns) {
    declaredOutputs.addAll(spawn.declaredOutputs);
  }

  final List<String> movedAside;
  try {
    movedAside = _moveOutputsAside(execroot, backupDir, declaredOutputs);
  } on FileSystemException catch (e) {
    stderr.writeln('Failed moving outputs aside: $e');
    return ReplayResult(
      identical: false,
      solCpuSeconds: null,
      reason: 'Failed moving outputs aside: $e',
      replayedCount: 0,
    );
  } on Exception catch (e) {
    stderr.writeln('Error during output backup: $e');
    return ReplayResult(
      identical: false,
      solCpuSeconds: null,
      reason: 'Failed moving outputs aside: $e',
      replayedCount: 0,
    );
  }

  try {
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
  } finally {
    _restoreOutputs(execroot, backupDir, movedAside);
  }
}

void _restoreOutputs(
  String execroot,
  Directory backupDir,
  List<String> movedAside,
) {
  try {
    for (final relPath in movedAside) {
      final backupFile = File('${backupDir.path}/$relPath');
      if (backupFile.existsSync()) {
        final targetFile = File('$execroot/$relPath');
        targetFile.parent.createSync(recursive: true);
        backupFile.copySync(targetFile.path);
      }
    }
    if (backupDir.existsSync()) {
      backupDir.deleteSync(recursive: true);
    }
  } on FileSystemException catch (e) {
    stderr.writeln('Error restoring backup files: $e');
  } on Exception catch (e) {
    stderr.writeln('Error during backup restoration: $e');
  }
}
