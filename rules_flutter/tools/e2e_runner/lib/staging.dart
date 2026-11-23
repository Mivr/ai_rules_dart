/// Workspace staging, escaping `local_path_override` rewriting, and file edits.
library;

import 'dart:io';

import 'package:e2e_runner/spec.dart';
import 'package:path/path.dart' as p;

enum _TokKind { ident, string, punct, other }

typedef _StarlarkToken = ({_TokKind kind, String text, int start, int end});

typedef _SpanEdit = ({int start, int end, String replacement});

/// Copies [sourceWorkspace] into [stagedWorkspace] and rewrites escaping
/// relative `local_path_override` paths in staged module files.
///
/// Entries named `bazel-*` are skipped. Intra-workspace relative symlinks are
/// preserved as relative symlinks inside [stagedWorkspace]; symlinks whose
/// targets point outside [sourceWorkspace] (such as Bazel runfiles links) are
/// dereferenced into regular writable files so no staged symlink escapes
/// [stagedWorkspace].
void stageWorkspace({
  required String sourceWorkspace,
  required String stagedWorkspace,
  SpecErrorContext? context,
}) {
  final String srcRoot = p.normalize(p.absolute(sourceWorkspace));
  final String dstRoot = p.normalize(p.absolute(stagedWorkspace));
  final srcDir = Directory(srcRoot);
  if (!srcDir.existsSync()) {
    final SpecErrorContext errCtx =
        context ??
        (specPath: p.join(srcRoot, 'e2e.yaml'), commandName: '<spec>');
    throw E2eRunnerException(
      specPath: errCtx.specPath,
      commandName: errCtx.commandName,
      message: 'workspace directory does not exist: $srcRoot',
    );
  }
  Directory(dstRoot).createSync(recursive: true);
  _copyTree(srcRoot, dstRoot, sourceRoot: srcRoot);
  _rewriteStagedModuleFiles(dstRoot, sourceRoot: srcRoot);
}

void _copyTree(String srcDir, String dstDir, {required String sourceRoot}) {
  final List<FileSystemEntity> entries = Directory(
    srcDir,
  ).listSync(followLinks: false);
  for (final entry in entries) {
    final String name = p.basename(entry.path);
    if (name.startsWith('bazel-')) continue;
    final String dstPath = p.join(dstDir, name);
    if (FileSystemEntity.isLinkSync(entry.path)) {
      _copyLinkEntry(entry.path, dstPath, sourceRoot: sourceRoot);
    } else if (entry is Directory) {
      Directory(dstPath).createSync(recursive: true);
      _copyTree(entry.path, dstPath, sourceRoot: sourceRoot);
    } else if (entry is File) {
      _copyWritableFile(entry.path, dstPath);
    }
  }
}

void _copyLinkEntry(
  String linkPath,
  String dstPath, {
  required String sourceRoot,
}) {
  final String rawTarget = Link(linkPath).targetSync();
  if (p.isRelative(rawTarget)) {
    final String resolved = p.normalize(
      p.join(p.dirname(linkPath), rawTarget),
    );
    if (!_escapesWorkspace(resolved, sourceRoot)) {
      Link(dstPath).createSync(rawTarget);
      return;
    }
  }
  final FileSystemEntityType targetType = FileSystemEntity.typeSync(linkPath);
  if (targetType == FileSystemEntityType.directory) {
    Directory(dstPath).createSync(recursive: true);
    _copyDereferencedDir(linkPath, dstPath);
  } else if (targetType == FileSystemEntityType.file) {
    _copyWritableFile(linkPath, dstPath);
  }
}

void _copyDereferencedDir(String srcDir, String dstDir) {
  final List<FileSystemEntity> entries = Directory(srcDir).listSync();
  for (final entry in entries) {
    final String name = p.basename(entry.path);
    if (name.startsWith('bazel-')) continue;
    final String dstPath = p.join(dstDir, name);
    if (entry is Directory) {
      Directory(dstPath).createSync(recursive: true);
      _copyDereferencedDir(entry.path, dstPath);
    } else if (entry is File) {
      _copyWritableFile(entry.path, dstPath);
    }
  }
}

void _copyWritableFile(String srcFile, String dstFile) {
  File(srcFile).copySync(dstFile);
  if (!Platform.isWindows) {
    final int mode = FileStat.statSync(dstFile).mode;
    if ((mode & 0x80) == 0) {
      Process.runSync('chmod', ['u+w', dstFile]);
    }
  }
}

void _rewriteStagedModuleFiles(
  String stagedRoot, {
  required String sourceRoot,
}) {
  final List<FileSystemEntity> entries = Directory(
    stagedRoot,
  ).listSync(recursive: true, followLinks: false);
  for (final entry in entries) {
    final String name = p.basename(entry.path);
    if (name != 'MODULE.bazel' && !name.endsWith('.MODULE.bazel')) continue;
    final FileSystemEntityType resolvedType = FileSystemEntity.typeSync(
      entry.path,
    );
    if (resolvedType != FileSystemEntityType.file) continue;
    final String relDir = p.relative(p.dirname(entry.path), from: stagedRoot);
    final String originalModuleDir = relDir == '.'
        ? sourceRoot
        : p.normalize(p.join(sourceRoot, relDir));
    final file = File(entry.path);
    final String original = file.readAsStringSync();
    final String updated = rewriteEscapingPathOverrides(
      original,
      originalModuleDir: originalModuleDir,
      sourceWorkspaceDir: sourceRoot,
    );
    if (updated != original) {
      file.writeAsStringSync(updated);
    }
  }
}

/// Rewrites relative `local_path_override(..., path = "...")` arguments in
/// [moduleContent] that escape [sourceWorkspaceDir] so they point to their
/// resolved target paths relative to [originalModuleDir].
///
/// Intra-workspace relative overrides and absolute paths are left unchanged.
String rewriteEscapingPathOverrides(
  String moduleContent, {
  required String originalModuleDir,
  required String sourceWorkspaceDir,
}) {
  final String normModuleDir = p.normalize(p.absolute(originalModuleDir));
  final String normWorkspaceDir = p.normalize(p.absolute(sourceWorkspaceDir));
  final List<_StarlarkToken> tokens = _lexStarlark(moduleContent);
  final edits = <_SpanEdit>[];
  for (var i = 0; i + 1 < tokens.length; i++) {
    final _StarlarkToken tok = tokens[i];
    if (tok.kind != _TokKind.ident || tok.text != 'local_path_override') {
      continue;
    }
    if (i > 0 && tokens[i - 1].text == '.') continue;
    if (tokens[i + 1].text != '(') continue;
    final ({int closeIndex, _StarlarkToken? pathLiteral}) call =
        _findPathArgInCall(tokens, openParenIndex: i + 1);
    final _StarlarkToken? pathTok = call.pathLiteral;
    if (pathTok != null) {
      final String? rawPath = _unquoteStarlarkString(pathTok.text);
      if (rawPath != null && _isRelativeOverridePath(rawPath)) {
        final String resolved = p.normalize(p.join(normModuleDir, rawPath));
        if (_escapesWorkspace(resolved, normWorkspaceDir)) {
          final String posixPath = resolved.replaceAll(r'\', '/');
          edits.add((
            start: pathTok.start,
            end: pathTok.end,
            replacement: '"${_escapeStarlarkDoubleQuoted(posixPath)}"',
          ));
        }
      }
    }
    i = call.closeIndex;
  }
  if (edits.isEmpty) return moduleContent;
  final out = StringBuffer();
  var cursor = 0;
  for (final edit in edits) {
    out
      ..write(moduleContent.substring(cursor, edit.start))
      ..write(edit.replacement);
    cursor = edit.end;
  }
  out.write(moduleContent.substring(cursor));
  return out.toString();
}

({int closeIndex, _StarlarkToken? pathLiteral}) _findPathArgInCall(
  List<_StarlarkToken> tokens, {
  required int openParenIndex,
}) {
  var depth = 1;
  _StarlarkToken? pathLiteral;
  for (int k = openParenIndex + 1; k < tokens.length; k++) {
    final String text = tokens[k].text;
    if (tokens[k].kind == _TokKind.punct) {
      if (text == '(' || text == '[' || text == '{') {
        depth++;
        continue;
      }
      if (text == ')' || text == ']' || text == '}') {
        depth--;
        if (depth == 0) {
          return (closeIndex: k, pathLiteral: pathLiteral);
        }
        continue;
      }
    }
    if (depth == 1 &&
        tokens[k].kind == _TokKind.ident &&
        text == 'path' &&
        k + 2 < tokens.length &&
        tokens[k + 1].text == '=' &&
        tokens[k + 2].kind == _TokKind.string) {
      pathLiteral = tokens[k + 2];
    }
  }
  return (closeIndex: tokens.length - 1, pathLiteral: pathLiteral);
}

List<_StarlarkToken> _lexStarlark(String source) {
  final tokens = <_StarlarkToken>[];
  var i = 0;
  while (i < source.length) {
    final String ch = source[i];
    if (ch.trim().isEmpty) {
      i++;
      continue;
    }
    if (ch == '#') {
      while (i < source.length && source[i] != '\n') {
        i++;
      }
      continue;
    }
    if (ch == '"' || ch == "'" || _isRawStringStart(source, i)) {
      final _StarlarkToken strTok = _scanStringToken(source, i);
      tokens.add(strTok);
      i = strTok.end;
      continue;
    }
    if (_isIdentStart(ch)) {
      final start = i;
      i++;
      while (i < source.length && _isIdentPart(source[i])) {
        i++;
      }
      tokens.add((
        kind: _TokKind.ident,
        text: source.substring(start, i),
        start: start,
        end: i,
      ));
      continue;
    }
    final _StarlarkToken punctTok = _scanPunctOrOther(source, i);
    tokens.add(punctTok);
    i = punctTok.end;
  }
  return tokens;
}

bool _isRawStringStart(String source, int index) {
  if (source[index] != 'r' && source[index] != 'R') return false;
  if (index + 1 >= source.length) return false;
  final String next = source[index + 1];
  return next == '"' || next == "'";
}

_StarlarkToken _scanStringToken(String source, int start) {
  var i = start;
  var isRaw = false;
  if (source[i] == 'r' || source[i] == 'R') {
    isRaw = true;
    i++;
  }
  final String quoteChar = source[i];
  final bool triple =
      i + 2 < source.length &&
      source[i + 1] == quoteChar &&
      source[i + 2] == quoteChar;
  final delim = triple ? '$quoteChar$quoteChar$quoteChar' : quoteChar;
  i += delim.length;
  while (i < source.length) {
    if (!isRaw && source[i] == r'\') {
      i += 2;
      continue;
    }
    if (source.startsWith(delim, i)) {
      i += delim.length;
      break;
    }
    i++;
  }
  if (i > source.length) i = source.length;
  return (
    kind: _TokKind.string,
    text: source.substring(start, i),
    start: start,
    end: i,
  );
}

_StarlarkToken _scanPunctOrOther(String source, int index) {
  const twoCharOps = {'==', '!=', '<=', '>='};
  if (index + 1 < source.length) {
    final String pair = source.substring(index, index + 2);
    if (twoCharOps.contains(pair)) {
      return (
        kind: _TokKind.punct,
        text: pair,
        start: index,
        end: index + 2,
      );
    }
  }
  const singlePunct = {'(', ')', '[', ']', '{', '}', ',', '=', '.'};
  final String ch = source[index];
  return (
    kind: singlePunct.contains(ch) ? _TokKind.punct : _TokKind.other,
    text: ch,
    start: index,
    end: index + 1,
  );
}

bool _isIdentStart(String ch) {
  final int code = ch.codeUnitAt(0);
  return (code >= 65 && code <= 90) ||
      (code >= 97 && code <= 122) ||
      code == 95;
}

bool _isIdentPart(String ch) {
  final int code = ch.codeUnitAt(0);
  return _isIdentStart(ch) || (code >= 48 && code <= 57);
}

String? _unquoteStarlarkString(String tokenText) {
  var body = tokenText;
  var isRaw = false;
  if (body.startsWith('r') || body.startsWith('R')) {
    isRaw = true;
    body = body.substring(1);
  }
  String delim;
  if (body.startsWith('"""') && body.length >= 6 && body.endsWith('"""')) {
    delim = '"""';
  } else if (body.startsWith("'''") &&
      body.length >= 6 &&
      body.endsWith("'''")) {
    delim = "'''";
  } else if (body.length >= 2 &&
      (body.startsWith('"') || body.startsWith("'")) &&
      body.endsWith(body[0])) {
    delim = body[0];
  } else {
    return null;
  }
  final String inner = body.substring(delim.length, body.length - delim.length);
  if (isRaw) return inner;
  final buf = StringBuffer();
  for (var i = 0; i < inner.length; i++) {
    if (inner[i] == r'\' && i + 1 < inner.length) {
      i++;
      final String next = inner[i];
      switch (next) {
        case 'n':
          buf.write('\n');
        case 'r':
          buf.write('\r');
        case 't':
          buf.write('\t');
        default:
          buf.write(next);
      }
    } else {
      buf.write(inner[i]);
    }
  }
  return buf.toString();
}

String _escapeStarlarkDoubleQuoted(String value) =>
    value.replaceAll(r'\', r'\\').replaceAll('"', r'\"');

bool _isRelativeOverridePath(String rawPath) {
  if (rawPath.isEmpty) return false;
  if (rawPath.startsWith('/') || rawPath.startsWith(r'\')) return false;
  if (RegExp(r'^[A-Za-z]:[\\/]').hasMatch(rawPath)) return false;
  return true;
}

bool _escapesWorkspace(String resolvedPath, String workspaceRoot) =>
    !p.equals(resolvedPath, workspaceRoot) &&
    !p.isWithin(workspaceRoot, resolvedPath);

/// Writes [specs] into [stagedWorkspace] before a command runs.
void applyWriteFiles(
  List<WriteFileSpec> specs, {
  required String stagedWorkspace,
  required SpecErrorContext context,
}) {
  final String wsRoot = p.normalize(p.absolute(stagedWorkspace));
  for (final spec in specs) {
    final String target = _resolveStagedPath(
      spec.path,
      wsRoot: wsRoot,
      context: context,
    );
    try {
      File(target).parent.createSync(recursive: true);
      File(target).writeAsStringSync(spec.content);
    } on FileSystemException catch (error) {
      throw E2eRunnerException(
        specPath: context.specPath,
        commandName: context.commandName,
        message: 'cannot write file "${spec.path}": ${error.message}',
      );
    }
  }
}

/// Applies [specs] replacements inside [stagedWorkspace] before a command runs.
void applyReplaceInFiles(
  List<ReplaceInFileSpec> specs, {
  required String stagedWorkspace,
  required SpecErrorContext context,
}) {
  final String wsRoot = p.normalize(p.absolute(stagedWorkspace));
  final String posixWorkspace = wsRoot.replaceAll(r'\', '/');
  for (final spec in specs) {
    final String target = _resolveStagedPath(
      spec.path,
      wsRoot: wsRoot,
      context: context,
    );
    final String original;
    try {
      original = File(target).readAsStringSync();
    } on FileSystemException catch (error) {
      throw E2eRunnerException(
        specPath: context.specPath,
        commandName: context.commandName,
        message: 'cannot read file "${spec.path}": ${error.message}',
      );
    }
    if (!original.contains(spec.from)) {
      throw E2eRunnerException(
        specPath: context.specPath,
        commandName: context.commandName,
        message: 'pattern "${spec.from}" not found in "${spec.path}"',
      );
    }
    final String expandedTo = spec.to.replaceAll(
      r'${WORKSPACE}',
      posixWorkspace,
    );
    try {
      File(target)
          .writeAsStringSync(original.replaceAll(spec.from, expandedTo));
    } on FileSystemException catch (error) {
      throw E2eRunnerException(
        specPath: context.specPath,
        commandName: context.commandName,
        message: 'cannot write file "${spec.path}": ${error.message}',
      );
    }
  }
}

String _resolveStagedPath(
  String relPath, {
  required String wsRoot,
  required SpecErrorContext context,
}) {
  if (!_isRelativeOverridePath(relPath)) {
    throw E2eRunnerException(
      specPath: context.specPath,
      commandName: context.commandName,
      message: 'workspace file path must be relative: "$relPath"',
    );
  }
  final String resolved = p.normalize(p.join(wsRoot, relPath));
  if (_escapesWorkspace(resolved, wsRoot) || p.equals(resolved, wsRoot)) {
    throw E2eRunnerException(
      specPath: context.specPath,
      commandName: context.commandName,
      message: 'workspace file path escapes staged workspace: "$relPath"',
    );
  }
  return resolved;
}
