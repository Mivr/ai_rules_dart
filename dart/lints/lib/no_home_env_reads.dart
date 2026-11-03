// Reports reads of well-known home directory environment variables.
//
// Action code must not read `APPDATA`, `HOME`, and friends: the values vary
// from machine to machine, so actions reading them are not reproducible or
// cacheable. Assignment writes such as `env['HOME'] = scratchDir` stay
// allowed: they set up a hermetic environment rather than reading the host.
import 'package:analyzer/analysis_rule/analysis_rule.dart';
import 'package:analyzer/analysis_rule/rule_context.dart';
import 'package:analyzer/analysis_rule/rule_visitor_registry.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/error/error.dart';

import 'package:rules_dart_project_lints/project_lint_scope.dart';

/// Home directory environment variable names reported on read.
const Set<String> _homeVariableNames = {
  'APPDATA',
  'HOME',
  'HOMEDRIVE',
  'HOMEPATH',
  'LOCALAPPDATA',
  'USERPROFILE',
  'XDG_CACHE_HOME',
  'XDG_CONFIG_HOME',
  'XDG_DATA_HOME',
  'XDG_STATE_HOME',
};

/// Reports reads of well-known home directory environment variables.
///
/// Only production compilation units are checked. Reported are index reads
/// (`...['HOME']`), `.containsKey(...)`, `String.fromEnvironment(...)`, and
/// `bool.hasEnvironment(...)` — unqualified or `dart:core`-prefixed —
/// folding parenthesized, adjacent, and `+` compile-time string literals.
/// Assignment left-hand-side writes such as `env['HOME'] = scratchDir` stay
/// allowed.
class NoHomeEnvReads extends AnalysisRule {
  /// Creates the `no_home_env_reads` project lint rule.
  new() : super(name: 'no_home_env_reads', description: _description);

  /// The user-facing description of the `no_home_env_reads` rule.
  static const String _description =
      'Avoid reading home directory environment variables in action code.';

  /// The diagnostic reported for home environment variable reads.
  static const LintCode _code = LintCode(
    'no_home_env_reads',
    'Avoid reading home directory environment variables in action code.',
  );

  @override
  DiagnosticCode get diagnosticCode => _code;

  @override
  void registerNodeProcessors(
    RuleVisitorRegistry registry,
    RuleContext context,
  ) {
    registry.addIndexExpression(this, _Visitor(this, context));
    registry.addInstanceCreationExpression(this, _Visitor(this, context));
    registry.addMethodInvocation(this, _Visitor(this, context));
  }
}

/// Visits index reads and environment lookups in one library, reporting home
/// directory variable reads.
class _Visitor extends SimpleAstVisitor<void> {
  /// Creates a visitor reporting through [rule] under [context].
  new(this.rule, this.context);

  /// The rule violations are reported through.
  final AnalysisRule rule;

  /// The analysis context the visited unit is read from.
  final RuleContext context;

  /// The per-unit production gate.
  final ProjectLintUnitGate _gate = ProjectLintUnitGate(workerOnly: false);

  @override
  void visitIndexExpression(IndexExpression node) {
    if (!_gate.shouldCheck(context)) {
      return;
    }
    if (_isWriteTarget(node)) {
      return;
    }
    _checkName(foldStringConstant(node.index), node);
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    if (!_gate.shouldCheck(context)) {
      return;
    }
    final ConstructorName constructor = node.constructorName;
    final String? member = constructor.name?.name;
    if (member != 'fromEnvironment' && member != 'hasEnvironment') {
      return;
    }
    final List<String> parts = constructor.type.toSource().split('.');
    if (parts.length > 2) {
      return;
    }
    final String? prefix = parts.length == 2 ? parts.first : null;
    final String typeName = parts.length == 2 ? parts.last : parts.first;
    if (member == 'fromEnvironment' && typeName == 'String' ||
        member == 'hasEnvironment' && typeName == 'bool') {
      if (_isDartCore(constructor, prefix)) {
        _checkPositionalString(
          node.argumentList,
          constructor.name ?? constructor.type,
        );
      }
    }
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (!_gate.shouldCheck(context)) {
      return;
    }
    if (node.methodName.name == 'containsKey') {
      _checkPositionalString(node.argumentList, node.methodName);
      return;
    }
    final _TypeReference? typeName = _receiverTypeName(node.target);
    if (typeName == null) {
      return;
    }
    if ((node.methodName.name == 'fromEnvironment' &&
            typeName.name == 'String') ||
        (node.methodName.name == 'hasEnvironment' && typeName.name == 'bool')) {
      if (_isDartCore(node, typeName.prefix)) {
        _checkPositionalString(node.argumentList, node.methodName);
      }
    }
  }

  /// Whether [node] is written rather than read: the left-hand side of an
  /// assignment.
  bool _isWriteTarget(IndexExpression node) {
    final AstNode? parent = node.parent;
    return parent is AssignmentExpression && parent.leftHandSide == node;
  }

  /// The `Type.member` receiver of a `fromEnvironment`/`hasEnvironment`
  /// invocation, or `null` when [target] is not a type reference.
  _TypeReference? _receiverTypeName(Expression? target) {
    if (target == null) {
      return null;
    }
    final Expression receiver = unparenthesized(target);
    if (receiver is SimpleIdentifier) {
      return (prefix: null, name: receiver.name);
    }
    if (receiver is PrefixedIdentifier) {
      return (prefix: receiver.prefix.name, name: receiver.identifier.name);
    }
    return null;
  }

  /// Whether an optional [prefix] accepts `dart:core`: unqualified references
  /// always do, prefixed ones only when [anchor]'s unit imports `dart:core`
  /// under [prefix].
  bool _isDartCore(AstNode anchor, String? prefix) {
    return prefix == null ||
        importUriForPrefix(anchor.root as CompilationUnit, prefix) ==
            'dart:core';
  }

  /// Reports [target] when the first positional argument of [arguments] folds
  /// to a home variable name.
  void _checkPositionalString(ArgumentList arguments, AstNode target) {
    for (final Argument argument in arguments.arguments) {
      if (argument is NamedArgument) {
        continue;
      }
      _checkName(foldStringConstant(argument as Expression), target);
      return;
    }
  }

  /// Reports [target] when [name] is a home variable name.
  void _checkName(String? name, AstNode target) {
    if (name != null && _homeVariableNames.contains(name)) {
      rule.reportAtNode(target);
    }
  }
}

/// A `Type.member` receiver reference with its optional import prefix.
typedef _TypeReference = ({String? prefix, String name});

/// Folds parenthesized, adjacent, and `+` compile-time string literals to
/// their value, or returns `null` when [node] is not a constant string.
String? foldStringConstant(Expression node) {
  if (node is SimpleStringLiteral) {
    return node.value;
  }
  if (node is AdjacentStrings) {
    final buffer = StringBuffer();
    for (final StringLiteral part in node.strings) {
      final String? value = foldStringConstant(part);
      if (value == null) {
        return null;
      }
      buffer.write(value);
    }
    return buffer.toString();
  }
  if (node is BinaryExpression) {
    if (node.operator.lexeme != '+') {
      return null;
    }
    final String? left = foldStringConstant(node.leftOperand);
    final String? right = foldStringConstant(node.rightOperand);
    if (left == null || right == null) {
      return null;
    }
    return '$left$right';
  }
  if (node is ParenthesizedExpression) {
    return foldStringConstant(node.expression);
  }
  return null;
}
