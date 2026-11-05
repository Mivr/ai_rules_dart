/// The `mivr-e2e-spec/1` model and parser.
///
/// A spec is a per-workspace `e2e.yaml` that lists the commands CI runs for
/// that workspace, in order, with the expectations (exit code, output
/// markers, executed-test floor) the runner must hold them to. Nothing here
/// touches a process or the filesystem beyond the YAML text it is handed, so
/// the parser is pure and unit-testable offline.
library;

import 'package:yaml/yaml.dart';

/// The only schema version this runner accepts.
const String specSchema = 'mivr-e2e-spec/1';

/// A spec or command that cannot be loaded.
final class SpecError implements Exception {
  /// Creates a spec error.
  SpecError(this.message);

  /// Human-readable description; already names the spec path and command.
  final String message;

  @override
  String toString() => message;
}

/// Substrings checked against process stdout, stderr, and combined output.
final class OutputPatterns {
  /// Creates a set of stream substring patterns.
  const OutputPatterns({
    this.stdout = const [],
    this.stderr = const [],
    this.output = const [],
  });

  /// Substrings checked against stdout.
  final List<String> stdout;

  /// Substrings checked against stderr.
  final List<String> stderr;

  /// Substrings checked against combined stdout + stderr.
  final List<String> output;
}

/// One `expect:` block of a command.
final class Expect {
  /// Creates an expectation.
  const Expect({
    this.exitCode,
    this.nonZero = false,
    this.required = const OutputPatterns(),
    this.forbidden = const OutputPatterns(),
    this.outputRegex = const [],
    this.testLogContains = const [],
    this.testXmlContains = const [],
  });

  /// Exact expected process exit code, when set.
  final int? exitCode;

  /// When true, the process must exit non-zero.
  final bool nonZero;

  /// Substrings that must appear on stdout, stderr, or combined output.
  final OutputPatterns required;

  /// Substrings that must NOT appear on stderr or combined output.
  final OutputPatterns forbidden;

  /// Regex patterns that combined stdout + stderr must match.
  final List<String> outputRegex;

  /// Substrings that concatenated `test.log` files must contain.
  final List<String> testLogContains;

  /// Substrings that concatenated JUnit `test.xml` files must contain.
  final List<String> testXmlContains;

  /// Substrings the process stderr must contain.
  List<String> get stderrContains => required.stderr;

  /// Substrings the process stdout must contain.
  List<String> get stdoutContains => required.stdout;

  /// Substrings the combined stdout + stderr must contain.
  List<String> get outputContains => required.output;

  /// Substrings the process stderr must NOT contain.
  List<String> get stderrNotContains => forbidden.stderr;

  /// Substrings the combined stdout + stderr must NOT contain.
  List<String> get outputNotContains => forbidden.output;
}

/// A find/replace pair applied by `replace_in_files`.
final class Replacement {
  /// Creates a replacement.
  const Replacement({required this.find, required this.replace});

  /// Literal text to find.
  final String find;

  /// Literal text to replace [find] with.
  final String replace;
}

/// One command of a spec: a process to run plus files and expectations.
final class Command {
  /// Creates a command.
  const Command({
    required this.name,
    required this.argv,
    this.writeFiles = const {},
    this.replaceInFiles = const {},
    this.minTestsExecuted,
    this.expect,
  });

  /// Display name, used in error messages; defaults to the command text.
  final String name;

  /// The argument vector to execute. A leading `bazel` is the placeholder the
  /// runner swaps for the resolved client.
  final List<String> argv;

  /// Relative staged-workspace path to file content, written before running.
  final Map<String, String> writeFiles;

  /// Relative staged-workspace path to ordered replacements.
  final Map<String, List<Replacement>> replaceInFiles;

  /// Floor of non-skipped executed tests for a `bazel test` command.
  final int? minTestsExecuted;

  /// Expected exit code / output markers, when set.
  final Expect? expect;
}

/// A parsed, validated spec.
final class Spec {
  /// Creates a spec.
  const Spec({required this.commands});

  /// Ordered commands, never empty.
  final List<Command> commands;
}

const Set<String> _topLevelKeys = {'schema', 'commands'};
const Set<String> _commandKeys = {
  'name',
  'run',
  'args',
  'write_files',
  'replace_in_files',
  'min_tests_executed',
  'expect',
};
const Set<String> _expectKeys = {
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

String _errPrefix(String? specPath, String? name) =>
    specPath == null ? '' : 'spec $specPath: command "${name ?? '<empty>'}": ';

void _checkForbiddenRunSyntax(String text, int index, String prefix) {
  final ch = text[index];
  if (ch == '|' || ch == ';') {
    throw SpecError('${prefix}shell syntax "$ch" is forbidden in run');
  }
  if (ch == '&' && index + 1 < text.length && text[index + 1] == '&') {
    throw SpecError('${prefix}shell syntax "&&" is forbidden in run');
  }
}

/// Splits a `run:` shorthand string into an argument vector.
///
/// Supports single and double quotes for grouping arguments and rejects shell
/// chaining or pipe syntax (`|`, `||`, `&&`, `;`).
List<String> splitRun(String run, {String? specPath, String? name}) {
  final trimmed = run.trim();
  final prefix = _errPrefix(specPath, name);
  if (trimmed.isEmpty) {
    throw SpecError('${prefix}command run string is empty');
  }
  final argv = <String>[];
  final current = StringBuffer();
  var inToken = false;
  String? quote;
  for (var i = 0; i < trimmed.length; i++) {
    final ch = trimmed[i];
    if (quote != null) {
      if (ch == quote) {
        quote = null;
      } else {
        current.write(ch);
      }
      continue;
    }
    _checkForbiddenRunSyntax(trimmed, i, prefix);
    if (ch == "'" || ch == '"') {
      quote = ch;
      inToken = true;
    } else if (RegExp(r'\s').hasMatch(ch)) {
      if (inToken) {
        argv.add(current.toString());
        current.clear();
        inToken = false;
      }
    } else {
      current.write(ch);
      inToken = true;
    }
  }
  if (quote != null) {
    throw SpecError('${prefix}unclosed quote in run');
  }
  if (inToken) argv.add(current.toString());
  return argv;
}

void _rejectFlakyAttempts(List<String> argv, String specPath, String name) {
  for (var i = 0; i < argv.length; i++) {
    final arg = argv[i];
    String? val;
    if (arg.startsWith('--flaky_test_attempts=')) {
      val = arg.substring('--flaky_test_attempts='.length);
    } else if (arg == '--flaky_test_attempts' && i + 1 < argv.length) {
      val = argv[i + 1];
    }
    if (val != null) {
      final parsed = int.tryParse(val);
      if (parsed == null || parsed > 1) {
        throw SpecError(
          'spec $specPath: command "$name": '
          '--flaky_test_attempts above 1 is forbidden (got "$val")',
        );
      }
    }
  }
}

String _asString(Object? value, String specPath, String name, String key) {
  if (value is String) return value;
  throw SpecError('spec $specPath: command "$name": $key must be a string');
}

int _asInt(Object? value, String specPath, String name, String key) {
  if (value is int) return value;
  throw SpecError('spec $specPath: command "$name": $key must be an int');
}

bool _asBool(Object? value, String specPath, String name, String key) {
  if (value is bool) return value;
  throw SpecError('spec $specPath: command "$name": $key must be a bool');
}

Map<Object?, Object?> _asMap(
  Object? value,
  String specPath,
  String name,
  String key,
) {
  if (value is Map) return value;
  throw SpecError('spec $specPath: command "$name": $key must be a map');
}

List<Object?> _asList(Object? value, String specPath, String name, String key) {
  if (value is List) return value;
  throw SpecError('spec $specPath: command "$name": $key must be a list');
}

void _rejectUnknownKeys(
  Map<Object?, Object?> map,
  Set<String> allowed,
  String specPath,
  String name,
  String scope,
) {
  for (final key in map.keys) {
    if (key is! String || !allowed.contains(key)) {
      throw SpecError(
        'spec $specPath: command "$name": unknown $scope key "$key"',
      );
    }
  }
}

List<String> _optStrings(
  Map<Object?, Object?> map,
  String key,
  String specPath,
  String name,
) {
  final val = map[key];
  if (val == null) return const [];
  if (val is String) return [val];
  if (val is List) {
    return val.map((e) => _asString(e, specPath, name, '$key entry')).toList();
  }
  throw SpecError(
    'spec $specPath: command "$name": $key must be a string or list of strings',
  );
}

Expect? _parseExpect(Object? raw, String specPath, String name) {
  if (raw == null) return null;
  final map = _asMap(raw, specPath, name, 'expect');
  _rejectUnknownKeys(map, _expectKeys, specPath, name, 'expect');
  final exitCode = map.containsKey('exit_code')
      ? _asInt(map['exit_code'], specPath, name, 'exit_code')
      : null;
  if (exitCode == 4) {
    throw SpecError(
      'spec $specPath: command "$name": '
      'exit_code 4 is rejected unconditionally',
    );
  }
  return Expect(
    exitCode: exitCode,
    nonZero: map.containsKey('non_zero')
        ? _asBool(map['non_zero'], specPath, name, 'non_zero')
        : false,
    required: OutputPatterns(
      stdout: _optStrings(map, 'stdout_contains', specPath, name),
      stderr: _optStrings(map, 'stderr_contains', specPath, name),
      output: _optStrings(map, 'output_contains', specPath, name),
    ),
    forbidden: OutputPatterns(
      stderr: _optStrings(map, 'stderr_not_contains', specPath, name),
      output: _optStrings(map, 'output_not_contains', specPath, name),
    ),
    outputRegex: _optStrings(map, 'output_regex', specPath, name),
    testLogContains: _optStrings(map, 'test_log_contains', specPath, name),
    testXmlContains: _optStrings(map, 'test_xml_contains', specPath, name),
  );
}

Map<String, String> _parseWriteFiles(
  Object? raw,
  String specPath,
  String name,
) {
  if (raw == null) return const {};
  final map = _asMap(raw, specPath, name, 'write_files');
  final result = <String, String>{};
  for (final entry in map.entries) {
    final path = _asString(entry.key, specPath, name, 'write_files path');
    result[path] = _asString(
      entry.value,
      specPath,
      name,
      'write_files content',
    );
  }
  return result;
}

Map<String, List<Replacement>> _parseReplaceInFiles(
  Object? raw,
  String specPath,
  String name,
) {
  if (raw == null) return const {};
  final map = _asMap(raw, specPath, name, 'replace_in_files');
  final result = <String, List<Replacement>>{};
  for (final entry in map.entries) {
    final path = _asString(entry.key, specPath, name, 'replace_in_files path');
    final list = _asList(entry.value, specPath, name, 'replace_in_files value');
    final replacements = <Replacement>[];
    for (final item in list) {
      final itemMap = _asMap(item, specPath, name, 'replace_in_files entry');
      _rejectUnknownKeys(
        itemMap,
        const {'find', 'replace'},
        specPath,
        name,
        'replace_in_files',
      );
      replacements.add(
        Replacement(
          find: _asString(itemMap['find'], specPath, name, 'find'),
          replace: _asString(itemMap['replace'], specPath, name, 'replace'),
        ),
      );
    }
    result[path] = replacements;
  }
  return result;
}

List<String> _parseArgv(
  Map<Object?, Object?> map,
  String specPath,
  String name,
) {
  final hasRun = map.containsKey('run');
  final hasArgs = map.containsKey('args');
  if (!hasRun && !hasArgs) {
    throw SpecError(
      'spec $specPath: command "$name" has neither "run" nor "args"',
    );
  }
  if (hasRun && hasArgs) {
    throw SpecError(
      'spec $specPath: command "$name" has both "run" and "args"',
    );
  }
  if (hasRun) {
    return splitRun(
      _asString(map['run'], specPath, name, 'run'),
      specPath: specPath,
      name: name,
    );
  }
  final list = _asList(map['args'], specPath, name, 'args');
  final argv = list
      .map((e) => _asString(e, specPath, name, 'args entry'))
      .toList();
  if (argv.isEmpty) {
    throw SpecError('spec $specPath: command "$name" has an empty "args"');
  }
  return argv;
}

Command _parseCommand(Object? raw, String specPath, int index) {
  if (raw is String) {
    final argv = splitRun(raw, specPath: specPath, name: '#$index');
    _rejectFlakyAttempts(argv, specPath, raw);
    return Command(name: raw, argv: argv);
  }
  final map = _asMap(raw, specPath, '#$index', 'command');
  final name = map.containsKey('name')
      ? _asString(map['name'], specPath, '#$index', 'name')
      : '#$index';
  _rejectUnknownKeys(map, _commandKeys, specPath, name, 'command');
  final argv = _parseArgv(map, specPath, name);
  final resolvedName = map.containsKey('name') ? name : argv.join(' ');
  _rejectFlakyAttempts(argv, specPath, resolvedName);
  final minTests = map.containsKey('min_tests_executed')
      ? _asInt(map['min_tests_executed'], specPath, name, 'min_tests_executed')
      : null;
  if (minTests != null && minTests < 1) {
    throw SpecError(
      'spec $specPath: command "$resolvedName": '
      'min_tests_executed must be >= 1',
    );
  }
  return Command(
    name: resolvedName,
    argv: argv,
    writeFiles: _parseWriteFiles(map['write_files'], specPath, resolvedName),
    replaceInFiles: _parseReplaceInFiles(
      map['replace_in_files'],
      specPath,
      resolvedName,
    ),
    minTestsExecuted: minTests,
    expect: _parseExpect(map['expect'], specPath, resolvedName),
  );
}

/// Parses a `mivr-e2e-spec/1` YAML document into a [Spec].
///
/// Throws [SpecError] naming [specPath] (and the command name) for any
/// invalid shape.
Spec parseSpec(String yamlText, {required String specPath}) {
  final Object? loaded;
  try {
    loaded = loadYaml(yamlText);
  } on YamlException catch (e) {
    throw SpecError('spec $specPath: invalid YAML: ${e.message}');
  }
  final map = _asMap(loaded, specPath, '<top>', 'spec');
  _rejectUnknownKeys(map, _topLevelKeys, specPath, '<top>', 'top-level');
  final schema = _asString(map['schema'], specPath, '<top>', 'schema');
  if (schema != specSchema) {
    throw SpecError(
      'spec $specPath: unsupported schema "$schema" (expected $specSchema)',
    );
  }
  final commandsRaw = _asList(map['commands'], specPath, '<top>', 'commands');
  if (commandsRaw.isEmpty) {
    throw SpecError('spec $specPath: "commands" must not be empty');
  }
  final commands = <Command>[
    for (var i = 0; i < commandsRaw.length; i++)
      _parseCommand(commandsRaw[i], specPath, i + 1),
  ];
  return Spec(commands: commands);
}

/// Narrows [spec] to the commands named in [names], keeping spec order.
///
/// Fails closed: an empty [names] list, a blank name, or a name that matches
/// no command throws a [SpecError] naming [specPath], so a typo can never
/// shrink a run to nothing or silently skip a command.
Spec selectCommands(Spec spec, List<String> names, {required String specPath}) {
  if (names.isEmpty || names.any((n) => n.trim().isEmpty)) {
    throw SpecError('spec $specPath: --command filter is empty');
  }
  final known = spec.commands.map((c) => c.name).toSet();
  for (final name in names) {
    if (!known.contains(name)) {
      throw SpecError(
        'spec $specPath: --command "$name" matches no command '
        '(known: ${known.join(', ')})',
      );
    }
  }
  return Spec(
    commands: [
      for (final c in spec.commands)
        if (names.contains(c.name)) c,
    ],
  );
}
