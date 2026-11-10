/// Finds the rules_dart checkout that holds the workflow files under test.
library;

import 'dart:io';

import 'package:runfiles/runfiles.dart';

bool _isRulesDartRepoRoot(Directory dir) {
  final moduleFile = File('${dir.path}/MODULE.bazel');
  if (!moduleFile.existsSync()) return false;
  final dartType = FileSystemEntity.typeSync(
    '${dir.path}/dart',
    followLinks: false,
  );
  return dartType == FileSystemEntityType.directory;
}

String? _walkUpForRepoRoot(String startPath) {
  var current = Directory(startPath);
  while (true) {
    final moduleFile = File('${current.path}/MODULE.bazel');
    if (moduleFile.existsSync()) {
      final realModuleDir = File(moduleFile.resolveSymbolicLinksSync()).parent;
      if (_isRulesDartRepoRoot(realModuleDir)) return realModuleDir.path;
      if (_isRulesDartRepoRoot(realModuleDir.parent)) {
        return realModuleDir.parent.path;
      }
    }
    final parent = current.parent;
    if (parent.path == current.path) return null;
    current = parent;
  }
}

String? _resolveFromRunfilesAnchor(String rlocationArg) {
  try {
    final mapped = Runfiles.create().rlocation(rlocationArg);
    final anchor = File(mapped);
    if (!anchor.existsSync()) return null;
    final resolvedAnchor = File(anchor.resolveSymbolicLinksSync());
    return _walkUpForRepoRoot(resolvedAnchor.parent.path);
  } on StateError catch (e) {
    stderr.writeln('Runfiles anchor lookup unavailable: $e');
    return null;
  } on FileSystemException catch (e) {
    stderr.writeln('Runfiles anchor symlink resolution skipped: $e');
    return null;
  } on ArgumentError catch (e) {
    stderr.writeln('Invalid runfiles anchor path: $e');
    return null;
  }
}

/// Locates the repository root from a runfiles anchor, `BUILD_WORKSPACE_DIRECTORY`
/// or the current directory.
String locateRepoRoot(List<String> args) {
  if (args.isNotEmpty) {
    final fromAnchor = _resolveFromRunfilesAnchor(args.first);
    if (fromAnchor != null) return fromAnchor;
  }
  final bwd = Platform.environment['BUILD_WORKSPACE_DIRECTORY'];
  if (bwd != null) {
    final fromBwd = _walkUpForRepoRoot(bwd);
    if (fromBwd != null) return fromBwd;
  }
  final fromCwd = _walkUpForRepoRoot(Directory.current.path);
  if (fromCwd != null) return fromCwd;
  throw StateError('Unable to locate rules_dart repository root');
}
