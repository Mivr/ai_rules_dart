/// `action-toolchain`: an action registered without naming its toolchain, and
/// the SDK attributes the Dart toolchain must read through `DefaultInfo`.
library;

import 'package:inventory/finding.dart';
import 'package:inventory/source_tree.dart';
import 'package:inventory/starlark.dart';

/// Where one module's actions are checked.
typedef ToolchainScope = ({String module, String bzlDir, bool allowSpread});

/// The rule's name in debt files and allow comments.
const String actionToolchainRule = 'action-toolchain';

/// The rule's name for the legacy `.files` read.
const String sdkFilesRule = 'sdk-files-legacy';

final RegExp _actionCallee = RegExp(
  r'\bctx\s*\.\s*actions\s*\.\s*(?:run|run_shell)\b',
);
final RegExp _toolchainArgument = RegExp(r'(?:^|[\s,])toolchain\s*=(?!=)');

/// The `dart_toolchain` attributes whose targets' files the toolchain reads.
const List<String> _sdkAttributes = [
  'sdk_root',
  'compile_files',
  'runtime_files',
  'analyze_files',
];

/// Every `ctx.actions.run` and `run_shell` in the scope's `.bzl` files whose
/// own argument list has no `toolchain =`. With `--incompatible_auto_exec_groups`
/// an action that names none cannot be matched to the toolchain that supplies
/// its executable. A call that spreads `**` is skipped when the scope allows it.
List<Finding> checkActionToolchains(
  SourceTree tree,
  List<ToolchainScope> scopes,
) {
  final findings = <Finding>[];
  for (final scope in scopes) {
    final List<String> bzl = [
      for (final String p in tree.paths)
        if (p.startsWith('${scope.module}/${scope.bzlDir}/') &&
            p.endsWith('.bzl'))
          p,
    ];
    if (bzl.isEmpty) {
      throw SetupException(
        'no .bzl files found under ${scope.module}/${scope.bzlDir}',
      );
    }
    for (final path in bzl) {
      findings.addAll(_actionCalls(path, tree.read(path), scope.allowSpread));
    }
  }
  return findings;
}

List<Finding> _actionCalls(String path, String text, bool allowSpread) {
  final lines = Lines(text);
  final String code = blank(text);
  final findings = <Finding>[];
  for (final RegExpMatch callee in _actionCallee.allMatches(code)) {
    final String? problem = _problem(code, callee.end, allowSpread);
    if (problem == null) continue;
    final Finding? finding = findingAt(
      rule: actionToolchainRule,
      file: path,
      lines: lines,
      offset: callee.start,
      message: '${callee.group(0)!.replaceAll(RegExp(r'\s+'), '')} $problem',
    );
    if (finding != null) findings.add(finding);
  }
  return findings;
}

String? _problem(String code, int calleeEnd, bool allowSpread) {
  final int open = code.indexOf(RegExp(r'\S'), calleeEnd);
  if (open < 0 || code[open] != '(') {
    return 'is used without a call, so its arguments cannot be checked';
  }
  final int close = closingParen(code, open);
  if (close < 0) return 'has parentheses that never close';
  final String arguments = topLevel(code.substring(open + 1, close));
  if (allowSpread && arguments.contains('**')) return null;
  return _toolchainArgument.hasMatch(arguments)
      ? null
      : 'passes no `toolchain =`';
}

/// A read of `sdk_root.files` and friends in the toolchain rule, or an SDK
/// attribute it no longer reads as `ctx.attr.<name>[DefaultInfo].files`.
List<Finding> checkSdkFiles(SourceTree tree, {required String path}) {
  if (!tree.paths.contains(path)) {
    throw SetupException('$path not found');
  }
  final String text = tree.read(path);
  final lines = Lines(text);
  final String code = blank(text);
  final findings = <Finding>[];
  final legacy = RegExp(
    '\\b(?:${_sdkAttributes.join('|')})\\s*\\.\\s*files\\b',
  );
  for (final RegExpMatch m in legacy.allMatches(code)) {
    final Finding? finding = findingAt(
      rule: sdkFilesRule,
      file: path,
      lines: lines,
      offset: m.start,
      message:
          'reads ${m.group(0)} through the legacy `.files`; use '
          '`[DefaultInfo].files`',
    );
    if (finding != null) findings.add(finding);
  }
  for (final String attr in _sdkAttributes) {
    final modern = RegExp(
      '\\bctx\\s*\\.\\s*attr\\s*\\.\\s*$attr\\s*\\[\\s*DefaultInfo\\s*\\]'
      r'\s*\.\s*files\b',
    );
    if (!modern.hasMatch(code)) {
      findings.add(
        Finding(
          rule: sdkFilesRule,
          file: path,
          line: 1,
          message: 'expected ctx.attr.$attr[DefaultInfo].files',
          key: 'missing $attr',
        ),
      );
    }
  }
  return findings;
}
