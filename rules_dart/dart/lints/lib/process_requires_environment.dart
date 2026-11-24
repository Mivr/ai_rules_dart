// Reports `Process` spawns that do not pin their environment.
//
// A spawned process inherits the parent environment unless `environment:` and
// `includeParentEnvironment: false` are both passed, so an unpinned spawn
// leaks `HOME`, proxy settings, and other host state into the action.
import 'package:analyzer/analysis_rule/analysis_rule.dart';
import 'package:analyzer/analysis_rule/rule_context.dart';
import 'package:analyzer/analysis_rule/rule_visitor_registry.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/error/error.dart';

import 'package:rules_dart_project_lints/project_lint_scope.dart';

/// `Process` spawning methods checked for a pinned environment.
const Set<String> _spawnMethods = {'run', 'runSync', 'start'};

/// Reports `Process` spawns that do not pin their environment.
///
/// Only production compilation units are checked. Reported are `Process.run`,
/// `Process.runSync`, and `Process.start` calls — unqualified or
/// `dart:io`-prefixed — unless the argument list passes both a non-`null`
/// `environment:` named argument and `includeParentEnvironment: false`.
class ProcessRequiresEnvironment extends AnalysisRule {
  /// Creates the `process_requires_environment` project lint rule.
  new()
    : super(name: 'process_requires_environment', description: _description);

  /// The user-facing description of the `process_requires_environment` rule.
  static const String _description =
      'Pass `environment:` and `includeParentEnvironment: false` '
      'to `Process` spawns.';

  /// The diagnostic reported for unpinned `Process` spawns.
  static const LintCode _code = LintCode(
    'process_requires_environment',
    'Pass `environment:` and `includeParentEnvironment: false` '
        'to `Process` spawns.',
  );

  @override
  DiagnosticCode get diagnosticCode => _code;

  @override
  void registerNodeProcessors(
    RuleVisitorRegistry registry,
    RuleContext context,
  ) {
    registry.addMethodInvocation(this, _Visitor(this, context));
  }
}

/// Visits invocations in one library, reporting unpinned `Process` spawns.
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
  void visitMethodInvocation(MethodInvocation node) {
    if (!_gate.shouldCheck(context)) {
      return;
    }
    if (!_spawnMethods.contains(node.methodName.name)) {
      return;
    }
    if (!_isProcessTarget(node.target, node.root as CompilationUnit)) {
      return;
    }
    if (!_pinsEnvironment(node.argumentList)) {
      rule.reportAtNode(node.methodName);
    }
  }

  /// Whether [target] names the `dart:io` `Process` class, either
  /// unqualified or through a `dart:io` import prefix.
  bool _isProcessTarget(Expression? target, CompilationUnit unit) {
    if (target == null) {
      return false;
    }
    final Expression receiver = unparenthesized(target);
    if (receiver is SimpleIdentifier) {
      return !receiver.isQualified && receiver.name == 'Process';
    }
    if (receiver is PrefixedIdentifier) {
      return receiver.identifier.name == 'Process' &&
          prefixImportsLibrary(unit, receiver.prefix.name, 'dart:io');
    }
    return false;
  }

  /// Whether [arguments] passes both a non-`null` `environment:` argument and
  /// `includeParentEnvironment: false`.
  bool _pinsEnvironment(ArgumentList arguments) {
    var hasEnvironment = false;
    var dropsParent = false;
    for (final Argument argument in arguments.arguments) {
      if (argument is NamedArgument) {
        if (argument.name.lexeme == 'environment') {
          hasEnvironment =
              unparenthesized(argument.argumentExpression) is! NullLiteral;
        } else if (argument.name.lexeme == 'includeParentEnvironment') {
          final Expression pinned = unparenthesized(
            argument.argumentExpression,
          );
          dropsParent = pinned is BooleanLiteral && !pinned.value;
        }
      }
    }
    return hasEnvironment && dropsParent;
  }
}
