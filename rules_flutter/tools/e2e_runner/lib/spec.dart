/// Parser and validator for `mivr-e2e-spec/1` workspace specs (`e2e.yaml`).
library;

import 'dart:io';

import 'package:yaml/yaml.dart';

/// Supported schema identifier for `e2e.yaml` files.
const String e2eSpecSchema = 'mivr-e2e-spec/1';

const Set<String> _allowedRootKeys = {'schema', 'commands'};

const Set<String> _allowedCommandKeys = {
  'name',
  'run',
  'args',
  'write_files',
  'replace_in_files',
  'min_tests_executed',
  'expect',
};

const Set<String> _allowedExpectKeys = {
  'exit_code',
  'non_zero',
  'stderr_contains',
  'stdout_contains',
  'output_contains',
  'output_regex',
  'stderr_not_contains',
  'output_not_contains',
  'test_log_contains',
  'test_xml_contains',
};

const Set<String> _allowedWriteFileKeys = {'path', 'content'};

const Set<String> _allowedReplaceFileKeys = {'path', 'from', 'to'};

/// Failure raised during spec validation, staging mutation, or command checks.
///
/// Always carries both [specPath] and [commandName] so diagnostics identify
/// the exact spec file and command step that failed.
class E2eRunnerException implements Exception {
  /// Creates an [E2eRunnerException] for [specPath] and [commandName].
  const new({
    required this.specPath,
    required this.commandName,
    required this.message,
  });

  /// Path to the `e2e.yaml` file being parsed or executed.
  final String specPath;

  /// Name of the command (or `<spec>` / `commands[i]` when unnamed).
  final String commandName;

  /// Human-readable failure reason.
  final String message;

  @override
  String toString() => '$specPath [$commandName]: $message';
}

/// One file write declared by a command's `write_files` entry.
class WriteFileSpec {
  /// Creates a [WriteFileSpec] writing [content] to workspace-relative [path].
  const new({
    required this.path,
    required this.content,
  });

  /// Workspace-relative destination path.
  final String path;

  /// Full UTF-8 text content to write.
  final String content;
}

/// One in-place text replacement declared by a command's `replace_in_files`.
class ReplaceInFileSpec {
  /// Creates a [ReplaceInFileSpec] replacing [from] with [to] in [path].
  const new({
    required this.path,
    required this.from,
    required this.to,
  });

  /// Workspace-relative file path to edit.
  final String path;

  /// Substring to replace.
  final String from;

  /// Replacement text (`${WORKSPACE}` expands to the staged workspace path).
  final String to;
}

/// Expected exit-status policy for a command in `e2e.yaml`.
typedef ExitExpectation = ({int? exitCode, bool nonZero});

/// Positive output/log matchers for a command in `e2e.yaml`.
typedef PositiveMatchSpec = ({
  List<String> stderrContains,
  List<String> stdoutContains,
  List<String> outputContains,
  List<RegExp> outputRegex,
  List<String> testLogContains,
  List<String> testXmlContains,
});

/// Negative output matchers for a command in `e2e.yaml`.
typedef NegativeMatchSpec = ({
  List<String> stderrNotContains,
  List<String> outputNotContains,
});

const ExitExpectation _defaultExitExpectation = (
  exitCode: null,
  nonZero: false,
);

const PositiveMatchSpec _defaultPositiveMatch = (
  stderrContains: <String>[],
  stdoutContains: <String>[],
  outputContains: <String>[],
  outputRegex: <RegExp>[],
  testLogContains: <String>[],
  testXmlContains: <String>[],
);

const NegativeMatchSpec _defaultNegativeMatch = (
  stderrNotContains: <String>[],
  outputNotContains: <String>[],
);

/// Expected outcome assertions for one command in `e2e.yaml`.
class ExpectSpec {
  /// Creates an [ExpectSpec].
  const new({
    this.exit = _defaultExitExpectation,
    this.positive = _defaultPositiveMatch,
    this.negative = _defaultNegativeMatch,
  });

  /// Exit-code expectation.
  final ExitExpectation exit;

  /// Required output/log substrings and regex patterns.
  final PositiveMatchSpec positive;

  /// Forbidden output substrings.
  final NegativeMatchSpec negative;

  /// Exact non-4 exit code expected, or `null` when [nonZero] or default `0`.
  int? get exitCode => exit.exitCode;

  /// Whether any non-zero (and non-4) exit code is expected.
  bool get nonZero => exit.nonZero;

  /// Substrings that must appear in `stderr`.
  List<String> get stderrContains => positive.stderrContains;

  /// Substrings that must appear in `stdout`.
  List<String> get stdoutContains => positive.stdoutContains;

  /// Substrings that must appear in combined `stdout` + `stderr`.
  List<String> get outputContains => positive.outputContains;

  /// Regular expressions that must match combined `stdout` + `stderr`.
  List<RegExp> get outputRegex => positive.outputRegex;

  /// Substrings that must not appear in `stderr`.
  List<String> get stderrNotContains => negative.stderrNotContains;

  /// Substrings that must not appear in combined `stdout` + `stderr`.
  List<String> get outputNotContains => negative.outputNotContains;

  /// Substrings that must appear in collected `test.log` outputs.
  List<String> get testLogContains => positive.testLogContains;

  /// Substrings that must appear in collected JUnit `test.xml` outputs.
  List<String> get testXmlContains => positive.testXmlContains;

  /// Whether this expectation expects the command to exit with code `0`.
  bool get expectsZeroExit => !nonZero && (exitCode == null || exitCode == 0);
}

/// One ordered command entry in an [E2eSpec].
class CommandSpec {
  /// Creates a [CommandSpec].
  const new({
    required this.name,
    required this.tokens,
    this.writeFiles = const [],
    this.replaceInFiles = const [],
    this.minTestsExecuted,
    this.expect = const ExpectSpec(),
  });

  /// Display name of this command step.
  final String name;

  /// Tokenized argv (before Bazel client / `--output_base` expansion).
  final List<String> tokens;

  /// Files to write in the staged workspace before running this command.
  final List<WriteFileSpec> writeFiles;

  /// Replacements to apply in the staged workspace before running this command.
  final List<ReplaceInFileSpec> replaceInFiles;

  /// Explicit minimum non-skipped test count for `bazel test`, if configured.
  final int? minTestsExecuted;

  /// Outcome assertions for this command.
  final ExpectSpec expect;
}

/// Parsed and validated `mivr-e2e-spec/1` specification.
class E2eSpec {
  /// Creates an [E2eSpec].
  const new({
    required this.specPath,
    required this.commands,
  });

  /// Path to the `e2e.yaml` file.
  final String specPath;

  /// Non-empty ordered list of commands to execute.
  final List<CommandSpec> commands;
}

/// Spec path and command name context attached to [E2eRunnerException]s.
typedef SpecErrorContext = ({String specPath, String commandName});

/// Reads, parses, and validates the `e2e.yaml` file at [specPath].
E2eSpec loadE2eSpec(String specPath) {
  final String content;
  try {
    content = File(specPath).readAsStringSync();
  } on FileSystemException catch (error) {
    throw E2eRunnerException(
      specPath: specPath,
      commandName: '<spec>',
      message: 'cannot read spec file: ${error.message}',
    );
  }
  return parseE2eSpec(content, specPath: specPath);
}

/// Parses and validates [yamlSource] as a `mivr-e2e-spec/1` document.
E2eSpec parseE2eSpec(String yamlSource, {required String specPath}) {
  const rootCtx = '<spec>';
  final Object? doc;
  try {
    doc = loadYaml(yamlSource);
  } on YamlException catch (error) {
    throw E2eRunnerException(
      specPath: specPath,
      commandName: rootCtx,
      message: 'invalid YAML: ${error.message}',
    );
  }
  if (doc is! YamlMap) {
    throw E2eRunnerException(
      specPath: specPath,
      commandName: rootCtx,
      message: 'top-level YAML value must be a map',
    );
  }
  _checkAllowedKeys(
    doc,
    _allowedRootKeys,
    (specPath: specPath, commandName: rootCtx),
    'spec root',
  );
  final Object? schema = doc['schema'];
  if (schema != e2eSpecSchema) {
    throw E2eRunnerException(
      specPath: specPath,
      commandName: rootCtx,
      message: 'expected schema "$e2eSpecSchema", got "$schema"',
    );
  }
  final Object? rawCommands = doc['commands'];
  if (rawCommands is! YamlList || rawCommands.isEmpty) {
    throw E2eRunnerException(
      specPath: specPath,
      commandName: 'commands',
      message: 'commands must be a non-empty list',
    );
  }
  final commands = <CommandSpec>[];
  for (var i = 0; i < rawCommands.length; i++) {
    commands.add(_parseCommand(rawCommands[i], index: i, specPath: specPath));
  }
  return E2eSpec(specPath: specPath, commands: commands);
}

CommandSpec _parseCommand(
  Object? raw, {
  required int index,
  required String specPath,
}) {
  final fallbackName = 'commands[$index]';
  if (raw is String) {
    final String trimmed = raw.trim();
    final name = trimmed.isEmpty ? fallbackName : trimmed;
    final SpecErrorContext ctx = (specPath: specPath, commandName: name);
    final List<String> tokens = tokenizeCommandLine(raw, ctx);
    _validateCommandTokens(tokens, ctx);
    return CommandSpec(name: name, tokens: tokens);
  }
  if (raw is! YamlMap) {
    throw E2eRunnerException(
      specPath: specPath,
      commandName: fallbackName,
      message: 'command entry must be a string or a map',
    );
  }
  final String name = _resolveCommandName(raw, fallbackName, specPath);
  final SpecErrorContext ctx = (specPath: specPath, commandName: name);
  _checkAllowedKeys(raw, _allowedCommandKeys, ctx, 'command');
  final List<String> tokens = _parseRunOrArgs(raw, ctx);
  _validateCommandTokens(tokens, ctx);
  final List<WriteFileSpec> writeFiles = _parseWriteFiles(
    raw['write_files'],
    ctx,
  );
  final List<ReplaceInFileSpec> replaceInFiles = _parseReplaceInFiles(
    raw['replace_in_files'],
    ctx,
  );
  final int? minTests = _parseMinTests(raw['min_tests_executed'], ctx);
  final ExpectSpec expect = _parseExpect(raw['expect'], ctx);
  return CommandSpec(
    name: name,
    tokens: tokens,
    writeFiles: writeFiles,
    replaceInFiles: replaceInFiles,
    minTestsExecuted: minTests,
    expect: expect,
  );
}

String _resolveCommandName(YamlMap map, String fallback, String specPath) {
  if (!map.containsKey('name')) return fallback;
  final Object? rawName = map['name'];
  if (rawName is! String || rawName.trim().isEmpty) {
    throw E2eRunnerException(
      specPath: specPath,
      commandName: fallback,
      message: '"name" must be a non-empty string',
    );
  }
  return rawName.trim();
}

List<String> _parseRunOrArgs(YamlMap map, SpecErrorContext ctx) {
  final bool hasRun = map.containsKey('run');
  final bool hasArgs = map.containsKey('args');
  if (!hasRun && !hasArgs) {
    _fail(ctx, 'command must specify either "run" or "args"');
  }
  if (hasRun && hasArgs) {
    _fail(ctx, 'command cannot specify both "run" and "args"');
  }
  if (hasRun) {
    final Object? runVal = map['run'];
    if (runVal is! String || runVal.trim().isEmpty) {
      _fail(ctx, '"run" must be a non-empty string');
    }
    return tokenizeCommandLine(runVal, ctx);
  }
  final Object? argsVal = map['args'];
  if (argsVal is! YamlList || argsVal.isEmpty) {
    _fail(ctx, '"args" must be a non-empty list of strings');
  }
  final tokens = <String>[];
  for (final Object? item in argsVal) {
    if (item is! String || item.isEmpty) {
      _fail(ctx, 'every element of "args" must be a non-empty string');
    }
    tokens.add(item);
  }
  return tokens;
}

/// Splits [commandLine] into argv tokens while rejecting shell operators.
List<String> tokenizeCommandLine(String commandLine, SpecErrorContext ctx) {
  final tokens = <String>[];
  final current = StringBuffer();
  var inToken = false;
  String? quote;
  for (var i = 0; i < commandLine.length; i++) {
    final String ch = commandLine[i];
    if (quote != null) {
      final ({int nextIndex, String? quote}) step = _consumeQuotedChar(
        commandLine,
        index: i,
        quote: quote,
        buffer: current,
      );
      i = step.nextIndex;
      quote = step.quote;
      continue;
    }
    if (ch == "'" || ch == '"') {
      quote = ch;
      inToken = true;
      continue;
    }
    _rejectInlineShellSyntax(commandLine, index: i, ctx: ctx);
    if (ch.trim().isEmpty) {
      if (inToken) {
        tokens.add(current.toString());
        current.clear();
        inToken = false;
      }
      continue;
    }
    inToken = true;
    current.write(ch);
  }
  if (quote != null) {
    _fail(ctx, 'unterminated quote in command string');
  }
  if (inToken) {
    tokens.add(current.toString());
  }
  if (tokens.isEmpty) {
    _fail(ctx, 'command must not be empty');
  }
  return tokens;
}

({int nextIndex, String? quote}) _consumeQuotedChar(
  String commandLine, {
  required int index,
  required String quote,
  required StringBuffer buffer,
}) {
  final String ch = commandLine[index];
  if (ch == r'\' && quote == '"' && index + 1 < commandLine.length) {
    buffer.write(commandLine[index + 1]);
    return (nextIndex: index + 1, quote: quote);
  }
  if (ch == quote) {
    return (nextIndex: index, quote: null);
  }
  buffer.write(ch);
  return (nextIndex: index, quote: quote);
}

void _rejectInlineShellSyntax(
  String commandLine, {
  required int index,
  required SpecErrorContext ctx,
}) {
  final String ch = commandLine[index];
  if (ch == ';' || ch == '|') {
    _fail(ctx, 'shell syntax ("$ch") is not allowed in spec commands');
  }
  if (ch == '&' &&
      index + 1 < commandLine.length &&
      commandLine[index + 1] == '&') {
    _fail(ctx, 'shell syntax ("&&") is not allowed in spec commands');
  }
}

void _validateCommandTokens(List<String> tokens, SpecErrorContext ctx) {
  const shellOps = {'||', '&&', '|', ';'};
  for (var i = 0; i < tokens.length; i++) {
    final String token = tokens[i];
    if (shellOps.contains(token)) {
      _fail(ctx, 'shell operator "$token" is not allowed in spec commands');
    }
    final String? attemptsValue = _extractFlakyAttempts(tokens, i);
    if (attemptsValue != null) {
      final int? parsed = int.tryParse(attemptsValue);
      if (parsed == null || parsed != 1) {
        _fail(
          ctx,
          '--flaky_test_attempts must not exceed 1 (got "$attemptsValue")',
        );
      }
    }
  }
}

String? _extractFlakyAttempts(List<String> tokens, int index) {
  final String token = tokens[index];
  if (token.startsWith('--flaky_test_attempts=')) {
    return token.substring('--flaky_test_attempts='.length);
  }
  if (token == '--flaky_test_attempts' && index + 1 < tokens.length) {
    return tokens[index + 1];
  }
  return null;
}

List<WriteFileSpec> _parseWriteFiles(Object? raw, SpecErrorContext ctx) {
  if (raw == null) return const [];
  if (raw is YamlMap) return _parseWriteFilesMap(raw, ctx);
  if (raw is YamlList) return _parseWriteFilesList(raw, ctx);
  _fail(ctx, '"write_files" must be a map or a list of {path, content} maps');
}

List<WriteFileSpec> _parseWriteFilesMap(YamlMap raw, SpecErrorContext ctx) {
  final result = <WriteFileSpec>[];
  for (final MapEntry<Object?, Object?> entry in raw.entries) {
    final Object? key = entry.key;
    final Object? val = entry.value;
    if (key is! String || key.trim().isEmpty || val is! String) {
      _fail(ctx, 'write_files map entries must map non-empty path -> string');
    }
    result.add(WriteFileSpec(path: key, content: val));
  }
  return result;
}

List<WriteFileSpec> _parseWriteFilesList(YamlList raw, SpecErrorContext ctx) {
  final result = <WriteFileSpec>[];
  for (final Object? item in raw) {
    if (item is! YamlMap) {
      _fail(ctx, 'write_files list items must be maps');
    }
    _checkAllowedKeys(item, _allowedWriteFileKeys, ctx, 'write_files item');
    final Object? path = item['path'];
    final Object? content = item['content'];
    if (path is! String || path.trim().isEmpty || content is! String) {
      _fail(ctx, 'write_files item requires string "path" and "content"');
    }
    result.add(WriteFileSpec(path: path, content: content));
  }
  return result;
}

List<ReplaceInFileSpec> _parseReplaceInFiles(
  Object? raw,
  SpecErrorContext ctx,
) {
  if (raw == null) return const [];
  if (raw is! YamlList) {
    _fail(ctx, '"replace_in_files" must be a list of {path, from, to} maps');
  }
  final result = <ReplaceInFileSpec>[];
  for (final Object? item in raw) {
    if (item is! YamlMap) {
      _fail(ctx, 'replace_in_files items must be maps');
    }
    _checkAllowedKeys(item, _allowedReplaceFileKeys, ctx, 'replace_in_files');
    final Object? path = item['path'];
    final Object? from = item['from'];
    final Object? to = item['to'];
    if (path is! String ||
        path.trim().isEmpty ||
        from is! String ||
        from.isEmpty ||
        to is! String) {
      _fail(
        ctx,
        'replace_in_files requires non-empty "path", non-empty "from", '
        'and string "to"',
      );
    }
    result.add(ReplaceInFileSpec(path: path, from: from, to: to));
  }
  return result;
}

int? _parseMinTests(Object? raw, SpecErrorContext ctx) {
  if (raw == null) return null;
  if (raw is! int || raw < 1) {
    _fail(ctx, '"min_tests_executed" must be an integer >= 1 (got "$raw")');
  }
  return raw;
}

ExpectSpec _parseExpect(Object? raw, SpecErrorContext ctx) {
  if (raw == null) return const ExpectSpec();
  if (raw is! YamlMap) {
    _fail(ctx, '"expect" must be a map');
  }
  _checkAllowedKeys(raw, _allowedExpectKeys, ctx, 'expect');
  final int? exitCode = _parseExitCode(raw['exit_code'], ctx);
  final bool nonZero = _parseNonZero(
    raw['non_zero'],
    hasNonZero: raw.containsKey('non_zero'),
    exitCode: exitCode,
    ctx: ctx,
  );
  return ExpectSpec(
    exit: (exitCode: exitCode, nonZero: nonZero),
    positive: (
      stderrContains: _parseStringOrList(
        raw['stderr_contains'],
        'stderr_contains',
        ctx,
      ),
      stdoutContains: _parseStringOrList(
        raw['stdout_contains'],
        'stdout_contains',
        ctx,
      ),
      outputContains: _parseStringOrList(
        raw['output_contains'],
        'output_contains',
        ctx,
      ),
      outputRegex: _parseRegexList(raw['output_regex'], ctx),
      testLogContains: _parseStringOrList(
        raw['test_log_contains'],
        'test_log_contains',
        ctx,
      ),
      testXmlContains: _parseStringOrList(
        raw['test_xml_contains'],
        'test_xml_contains',
        ctx,
      ),
    ),
    negative: (
      stderrNotContains: _parseStringOrList(
        raw['stderr_not_contains'],
        'stderr_not_contains',
        ctx,
      ),
      outputNotContains: _parseStringOrList(
        raw['output_not_contains'],
        'output_not_contains',
        ctx,
      ),
    ),
  );
}

int? _parseExitCode(Object? raw, SpecErrorContext ctx) {
  if (raw == null) return null;
  if (raw is! int) {
    _fail(ctx, '"exit_code" must be an integer (got "$raw")');
  }
  if (raw == 4) {
    _fail(ctx, '"exit_code: 4" (Bazel NO_TESTS_FOUND) is forbidden');
  }
  return raw;
}

bool _parseNonZero(
  Object? raw, {
  required bool hasNonZero,
  required int? exitCode,
  required SpecErrorContext ctx,
}) {
  if (!hasNonZero || raw == null) return false;
  if (raw is! bool) {
    _fail(ctx, '"non_zero" must be a boolean (got "$raw")');
  }
  if (raw && exitCode == 0) {
    _fail(ctx, '"non_zero: true" conflicts with "exit_code: 0"');
  }
  if (!raw && exitCode != null && exitCode != 0) {
    _fail(ctx, '"non_zero: false" conflicts with non-zero "exit_code"');
  }
  return raw;
}

List<String> _parseStringOrList(
  Object? raw,
  String field,
  SpecErrorContext ctx,
) {
  if (raw == null) return const [];
  if (raw is String) return [raw];
  if (raw is YamlList) {
    final items = <String>[];
    for (final Object? entry in raw) {
      if (entry is! String) {
        _fail(ctx, 'every element of "$field" must be a string');
      }
      items.add(entry);
    }
    return items;
  }
  _fail(ctx, '"$field" must be a string or a list of strings');
}

List<RegExp> _parseRegexList(Object? raw, SpecErrorContext ctx) {
  final List<String> patterns = _parseStringOrList(raw, 'output_regex', ctx);
  final compiled = <RegExp>[];
  for (final pattern in patterns) {
    try {
      compiled.add(RegExp(pattern));
    } on FormatException catch (error) {
      _fail(ctx, 'invalid "output_regex" pattern "$pattern": ${error.message}');
    }
  }
  return compiled;
}

void _checkAllowedKeys(
  YamlMap map,
  Set<String> allowed,
  SpecErrorContext ctx,
  String scope,
) {
  for (final Object? key in map.keys) {
    if (key is! String || !allowed.contains(key)) {
      _fail(ctx, 'unknown key "$key" in $scope');
    }
  }
}

Never _fail(SpecErrorContext ctx, String message) {
  throw E2eRunnerException(
    specPath: ctx.specPath,
    commandName: ctx.commandName,
    message: message,
  );
}
