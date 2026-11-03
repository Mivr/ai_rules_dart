// Reports wall-clock reads in action code.
//
// `DateTime.now()`, unseeded `Random()`, and `Directory.systemTemp` vary from
// run to run, so actions using them are not reproducible or cacheable. Seeded
// `Random(seed)` and `DateTime.utc(...)` stay allowed.
import 'package:analyzer/analysis_rule/analysis_rule.dart';
import 'package:analyzer/analysis_rule/rule_context.dart';
import 'package:analyzer/analysis_rule/rule_visitor_registry.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/error/error.dart';

import 'package:rules_dart_project_lints/project_lint_scope.dart';

/// Reports wall-clock reads in action code.
///
/// Only production compilation units are checked. Reported are
/// `DateTime.now()`, `DateTime.timestamp()`, unseeded `Random()`,
/// `Random.secure()`, and `Directory.systemTemp` — as instance creations or
/// invocations, unqualified or `dart:core`/`dart:math`/`dart:io`-prefixed.
/// Seeded `Random(seed)` and `DateTime.utc(...)` stay allowed.
class NoWallClockInActions extends AnalysisRule {
  /// Creates the `no_wall_clock_in_actions` project lint rule.
  new() : super(name: 'no_wall_clock_in_actions', description: _description);

  /// The user-facing description of the `no_wall_clock_in_actions` rule.
  static const String _description =
      'Avoid wall-clock reads in action code; '
      'seed `Random` and use `DateTime.utc`.';

  /// The diagnostic reported for wall-clock reads.
  static const LintCode _code = LintCode(
    'no_wall_clock_in_actions',
    'Avoid wall-clock reads in action code; '
        'seed `Random` and use `DateTime.utc`.',
  );

  @override
  DiagnosticCode get diagnosticCode => _code;

  @override
  void registerNodeProcessors(
    RuleVisitorRegistry registry,
    RuleContext context,
  ) {
    registry.addInstanceCreationExpression(this, _Visitor(this, context));
    registry.addMethodInvocation(this, _Visitor(this, context));
    registry.addPrefixedIdentifier(this, _Visitor(this, context));
    registry.addPropertyAccess(this, _Visitor(this, context));
  }
}

/// Visits creations, invocations, and property reads in one library,
/// reporting wall-clock reads.
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
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    if (!_gate.shouldCheck(context)) {
      return;
    }
    final ConstructorName constructor = node.constructorName;
    final List<String> parts = constructor.type.toSource().split('.');
    if (parts.length > 2) {
      return;
    }
    _checkTypeMember((
      prefix: parts.length == 2 ? parts.first : null,
      typeName: parts.length == 2 ? parts.last : parts.first,
      member: constructor.name?.name,
      arguments: node.argumentList,
      target: constructor.name ?? constructor.type,
    ), node);
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (!_gate.shouldCheck(context)) {
      return;
    }
    final Expression? receiver = node.target;
    if (receiver == null) {
      return;
    }
    final Expression unparenthesizedReceiver = unparenthesized(receiver);
    if (unparenthesizedReceiver is SimpleIdentifier) {
      _checkTypeMember((
        prefix: null,
        typeName: unparenthesizedReceiver.name,
        member: node.methodName.name,
        arguments: node.argumentList,
        target: node.methodName,
      ), node);
    } else if (unparenthesizedReceiver is PrefixedIdentifier) {
      _checkTypeMember((
        prefix: unparenthesizedReceiver.prefix.name,
        typeName: unparenthesizedReceiver.identifier.name,
        member: node.methodName.name,
        arguments: node.argumentList,
        target: node.methodName,
      ), node);
    }
  }

  @override
  void visitPrefixedIdentifier(PrefixedIdentifier node) {
    if (!_gate.shouldCheck(context)) {
      return;
    }
    // A bare `Directory.systemTemp` read. `Directory.systemTemp()` with
    // parentheses parses as an instance creation, which has no
    // `PrefixedIdentifier` node, so this never double-reports.
    if (node.prefix.name == 'Directory' &&
        node.identifier.name == 'systemTemp') {
      rule.reportAtNode(node.identifier);
    }
  }

  @override
  void visitPropertyAccess(PropertyAccess node) {
    if (!_gate.shouldCheck(context)) {
      return;
    }
    // `io.Directory.systemTemp` through a `dart:io` import prefix.
    final Expression? target = node.target;
    if (node.propertyName.name == 'systemTemp' &&
        target is PrefixedIdentifier &&
        target.identifier.name == 'Directory') {
      if (importUriForPrefix(
            node.root as CompilationUnit,
            target.prefix.name,
          ) ==
          'dart:io') {
        rule.reportAtNode(node.propertyName);
      }
    }
  }

  /// Reports [node] when the type member [member] is a wall-clock read.
  void _checkTypeMember(_TypeMember member, AstNode node) {
    final unit = node.root as CompilationUnit;
    final String typeName = member.typeName;
    if (typeName == 'DateTime' &&
        _isDartLibrary(unit, member.prefix, 'dart:core')) {
      if (member.member == 'now' || member.member == 'timestamp') {
        rule.reportAtNode(member.target);
      }
      return;
    }
    if (typeName == 'Random' &&
        _isDartLibrary(unit, member.prefix, 'dart:math')) {
      _checkRandom(member);
      return;
    }
    if (typeName == 'Directory' &&
        member.member == 'systemTemp' &&
        _isDartLibrary(unit, member.prefix, 'dart:io')) {
      rule.reportAtNode(member.target);
    }
  }

  /// Reports unseeded `Random()` and `Random.secure()` constructions.
  void _checkRandom(_TypeMember member) {
    if (member.member == null) {
      if (member.arguments.arguments.isEmpty) {
        rule.reportAtNode(member.target);
      }
    } else if (member.member == 'secure') {
      rule.reportAtNode(member.target);
    }
  }

  /// Whether an optional [prefix] accepts the `dart:` library [uri]:
  /// unqualified references always do, prefixed ones only when [unit] imports
  /// [uri] under [prefix].
  bool _isDartLibrary(CompilationUnit unit, String? prefix, String uri) {
    return prefix == null || importUriForPrefix(unit, prefix) == uri;
  }
}

/// A type member reference: `prefix.Type.member`, `Type.member`, or `Type()`.
typedef _TypeMember = ({
  String? prefix,
  String typeName,
  String? member,
  ArgumentList arguments,
  AstNode target,
});
