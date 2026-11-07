// Reports `print` calls and `stdout` text writes in persistent worker units.
//
// Workers communicate over the Bazel persistent-worker protocol, whose framing
// rides on `stdout`: a stray `print` or text write corrupts the frame stream.
// Binary frame writes (`stdout.add`), `stderr`, and `ZoneSpecification` print
// interception stay allowed.
import 'package:analyzer/analysis_rule/analysis_rule.dart';
import 'package:analyzer/analysis_rule/rule_context.dart';
import 'package:analyzer/analysis_rule/rule_visitor_registry.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/error/error.dart';

import 'package:rules_dart_project_lints/project_lint_scope.dart';

/// Text methods of `dart:io` `stdout` reported in persistent worker units.
const Set<String> _textWriteMethods = {
  'addStream',
  'write',
  'writeAll',
  'writeCharCode',
  'writeln',
};

/// Reports `print` calls and `stdout` text writes in persistent worker units.
///
/// Only production compilation units that are worker units (see
/// [isPersistentWorkerUnit]) are checked. Reported are `print(...)` calls
/// that are unqualified and non-cascaded or `dart:core`-prefixed, and the text
/// methods [write, writeAll, writeCharCode, writeln, addStream] on `dart:io`
/// `stdout`. Binary frame writes (`stdout.add(...)`), `stderr.*`, and
/// `ZoneSpecification(print: ...)` interception stay allowed.
class NoStdoutInWorker extends AnalysisRule {
  /// Creates the `no_stdout_in_worker` project lint rule.
  new() : super(name: 'no_stdout_in_worker', description: _description);

  /// The user-facing description of the `no_stdout_in_worker` rule.
  static const String _description =
      'Avoid `print` and `stdout` text writes in persistent worker units.';

  /// The diagnostic reported for worker `print` and `stdout` text writes.
  static const LintCode _code = LintCode(
    'no_stdout_in_worker',
    'Avoid `print` and `stdout` text writes in persistent worker units.',
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

/// Visits invocations in one library, reporting worker `print`/`stdout` text
/// writes.
class _Visitor extends SimpleAstVisitor<void> {
  /// Creates a visitor reporting through [rule] under [context].
  new(this.rule, this.context);

  /// The rule violations are reported through.
  final AnalysisRule rule;

  /// The analysis context the visited unit is read from.
  final RuleContext context;

  /// The per-unit production and worker-unit gate.
  final ProjectLintUnitGate _gate = ProjectLintUnitGate(workerOnly: true);

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (!_gate.shouldCheck(context)) {
      return;
    }
    if (node.methodName.name == 'print') {
      _checkPrint(node);
    } else if (_textWriteMethods.contains(node.methodName.name)) {
      _checkStdoutWrite(node);
    }
  }

  /// Reports `print(...)` unless it is cascaded, qualified, or intercepted.
  void _checkPrint(MethodInvocation node) {
    if (node.isCascaded) {
      return;
    }
    final Expression? target = node.target;
    if (target == null) {
      final Element? element = node.methodName.element;
      if (element == null || (element.library?.isDartCore ?? false)) {
        rule.reportAtNode(node.methodName);
      }
      return;
    }
    if (target is SimpleIdentifier &&
        prefixImportsLibrary(
          node.root as CompilationUnit,
          target.name,
          'dart:core',
        )) {
      rule.reportAtNode(node.methodName);
    }
  }

  /// Reports text writes on `dart:io` `stdout`.
  void _checkStdoutWrite(MethodInvocation node) {
    if (_isStdoutTarget(node.realTarget, node.root as CompilationUnit)) {
      rule.reportAtNode(node.methodName);
    }
  }

  /// Whether [target] reads the `dart:io` `stdout` top-level variable, either
  /// unqualified or through a `dart:io` import prefix.
  bool _isStdoutTarget(Expression? target, CompilationUnit unit) {
    if (target == null) {
      return false;
    }
    final Expression receiver = unparenthesized(target);
    if (receiver is SimpleIdentifier) {
      if (receiver.isQualified || receiver.name != 'stdout') {
        return false;
      }
      final Element? element = receiver.element;
      return element == null || element.library?.uri.toString() == 'dart:io';
    }
    if (receiver is PrefixedIdentifier) {
      return receiver.identifier.name == 'stdout' &&
          prefixImportsLibrary(unit, receiver.prefix.name, 'dart:io');
    }
    if (receiver is PropertyAccess) {
      final Expression? inner = receiver.target;
      return receiver.propertyName.name == 'stdout' &&
          inner is SimpleIdentifier &&
          prefixImportsLibrary(unit, inner.name, 'dart:io');
    }
    return false;
  }
}
