// Scope shared by the wave-1 project lint rules (`rules_dart_project_lints`).
//
// Every rule checks only production Dart compilation units: test files,
// fixtures, generated staging areas, and documentation never carry project
// rule diagnostics, so the rules stay silent where the patterns they forbid
// are legitimate scaffolding.
import 'package:analyzer/analysis_rule/rule_context.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';

/// Workspace-relative path segments that mark a compilation unit as
/// non-production, wherever they appear in its path.
const Set<String> _nonProductionSegments = {
  '.claude',
  '.dart_tool',
  '.git',
  '.github',
  'docs',
  'e2e',
  'examples',
  'fixtures',
  'references',
  'test',
  'testdata',
  'tests',
  'third_party',
};

/// Staged-project marker separating a `<name>.proj` staging root from
/// workspace-relative paths under `src/`.
///
/// `dart_analyze` stages targets under `<target>.dart_analyze.proj/src/` or
/// `<target>.dart_analyze.summary.proj/src/` (and `analyze_runner` strips
/// options under `<target>.dart_analyze.proj.stripped/src/`); the
/// workspace-relative path of a staged unit starts after this marker.
final RegExp _stagedSrcMarker = RegExp(r'\.proj(?:\.stripped)?/src/');

/// Matches a normalized Windows drive-letter root prefix such as `D:/`.
final RegExp _windowsDrive = RegExp('^[A-Za-z]:/');

/// Whether the Dart compilation unit at [unitPath] is production code that
/// the project lint rules check.
///
/// The workspace-relative path is derived from [unitPath] after the staged
/// `<name>.proj/src/` marker when staged by `dart_analyze`, otherwise
/// relative to [packageRoot] (stripping a leading `src/` when present) so
/// standalone and fixture tests still analyze `lib/...` paths normally while
/// skipping `*_test.dart` and `test/...` paths. Units outside production
/// paths — `*_test.dart` files, `dev/testdata/**`, `dart/tests/**`,
/// `flutter/tests/**`, and any path through a non-production segment or a
/// `bazel-` or `__gate_canary_` directory — are never checked.
bool isProductionProjectLintPath(String unitPath, {String? packageRoot}) {
  final String relative = _workspaceRelativePath(unitPath, packageRoot);
  final List<String> segments = relative.split('/');
  if (segments.isNotEmpty && segments.last.endsWith('_test.dart')) {
    return false;
  }
  for (final segment in segments) {
    if (_nonProductionSegments.contains(segment)) {
      return false;
    }
    if (segment.startsWith('bazel-') || segment.startsWith('__gate_canary_')) {
      return false;
    }
  }
  return true;
}

/// The workspace-relative path of [unitPath], derived after the staged-project
/// marker when present, otherwise relative to [packageRoot].
String _workspaceRelativePath(String unitPath, String? packageRoot) {
  final String normalized = unitPath.replaceAll(r'\', '/');
  final RegExpMatch? stagedMatch = _stagedSrcMarker
      .allMatches(normalized)
      .lastOrNull;
  if (stagedMatch != null) {
    return normalized.substring(stagedMatch.end);
  }
  if (packageRoot != null && packageRoot.isNotEmpty) {
    final String? stripped = _stripRootPrefix(normalized, packageRoot);
    if (stripped != null) {
      return stripped;
    }
  }
  return normalized;
}

/// Returns [normalizedPath] relative to [rawRoot] (stripping a leading `src/`
/// when present), or `null` when [normalizedPath] does not sit under [rawRoot].
String? _stripRootPrefix(String normalizedPath, String rawRoot) {
  String root = rawRoot.replaceAll(r'\', '/');
  while (root.length > 1 && root.endsWith('/')) {
    root = root.substring(0, root.length - 1);
  }
  final prefix = root == '/' ? '/' : '$root/';
  final bool matches =
      normalizedPath.startsWith(prefix) ||
      (_windowsDrive.hasMatch(prefix) &&
          normalizedPath.length >= prefix.length &&
          normalizedPath.substring(0, prefix.length).toLowerCase() ==
              prefix.toLowerCase());
  if (!matches) {
    return null;
  }
  final String relative = normalizedPath.substring(prefix.length);
  return relative.startsWith('src/')
      ? relative.substring('src/'.length)
      : relative;
}

/// Whether [unit] at [unitPath] is a persistent-worker unit whose `print` and
/// `stdout` writes the `no_stdout_in_worker` rule reports.
///
/// A unit is a worker unit when it is not `worker_protocol.dart` itself and
/// either imports `worker_protocol.dart`, is named `*_worker.dart` or
/// `worker_entry.dart`, or declares a `main` or `*Main` function or method
/// whose source mentions `--persistent_worker`.
bool isPersistentWorkerUnit(CompilationUnit unit, String unitPath) {
  final String basename = _basename(unitPath);
  if (basename == 'worker_protocol.dart') {
    return false;
  }
  if (basename == 'worker_entry.dart' || basename.endsWith('_worker.dart')) {
    return true;
  }
  if (_importsWorkerProtocol(unit)) {
    return true;
  }
  return _declaresPersistentMain(unit);
}

/// The last `/`-separated segment of [path].
String _basename(String path) {
  final String normalized = path.replaceAll(r'\', '/');
  final int slash = normalized.lastIndexOf('/');
  return slash < 0 ? normalized : normalized.substring(slash + 1);
}

/// Whether [unit] imports `worker_protocol.dart` under any URI spelling.
bool _importsWorkerProtocol(CompilationUnit unit) {
  for (final Directive directive in unit.directives) {
    if (directive is ImportDirective) {
      if (directive.uri.stringValue?.endsWith('worker_protocol.dart') ??
          false) {
        return true;
      }
      for (final Configuration config in directive.configurations) {
        if (config.uri.stringValue?.endsWith('worker_protocol.dart') ?? false) {
          return true;
        }
      }
    }
  }
  return false;
}

/// Whether [unit] declares a `main` or `*Main` function or method whose source
/// mentions `--persistent_worker`.
bool _declaresPersistentMain(CompilationUnit unit) {
  final scanner = _PersistentMainScanner();
  unit.accept(scanner);
  return scanner.found;
}

/// Scans every function and method declaration for a persistent entrypoint.
class _PersistentMainScanner extends GeneralizingAstVisitor<void> {
  /// Whether a `main` or `*Main` declaration mentioning `--persistent_worker`
  /// has been seen.
  bool found = false;

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    _checkDeclaration(node.name.lexeme, node.toSource());
    super.visitFunctionDeclaration(node);
  }

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    _checkDeclaration(node.name.lexeme, node.toSource());
    super.visitMethodDeclaration(node);
  }

  /// Records [source] when [name] declares a persistent entrypoint.
  void _checkDeclaration(String name, String source) {
    if (!found && (name == 'main' || name.endsWith('Main'))) {
      found = source.contains('--persistent_worker');
    }
  }
}

/// Whether [unit] imports [libraryUri] under [prefix] (directly or via a
/// conditional import configuration).
bool prefixImportsLibrary(
  CompilationUnit unit,
  String prefix,
  String libraryUri,
) {
  for (final Directive directive in unit.directives) {
    if (directive is ImportDirective && directive.prefix?.name == prefix) {
      if (directive.uri.stringValue == libraryUri) {
        return true;
      }
      for (final Configuration config in directive.configurations) {
        if (config.uri.stringValue == libraryUri) {
          return true;
        }
      }
    }
  }
  return false;
}

/// [expression] without any surrounding parentheses.
Expression unparenthesized(Expression expression) {
  var current = expression;
  while (current is ParenthesizedExpression) {
    current = current.expression;
  }
  return current;
}

/// Per-unit check state shared by the project lint rule visitors.
///
/// The analysis driver registers each rule's visitor once per library and
/// reuses it across every compilation unit of that library, so a visitor
/// cannot decide the scope once: the gate recomputes it when the visited unit
/// changes and remembers the verdict otherwise.
final class ProjectLintUnitGate {
  /// Creates a gate; [workerOnly] limits the verdict to persistent-worker
  /// units (see [isPersistentWorkerUnit]).
  new({required this.workerOnly});

  /// Whether only persistent-worker units pass the gate.
  final bool workerOnly;

  CompilationUnit? _unit;
  bool _inScope = false;
  bool _isWorker = false;

  /// Whether the unit [context] currently visits is checked by the rule.
  bool shouldCheck(RuleContext context) {
    final RuleContextUnit? current = context.currentUnit;
    if (current == null) {
      return false;
    }
    final CompilationUnit unit = current.unit;
    if (!identical(unit, _unit)) {
      _unit = unit;
      final String path = current.file.path;
      final String? rootPath =
          context.package?.root.path ??
          context
              .definingUnit
              .unit
              .declaredFragment
              ?.element
              .session
              .analysisContext
              .contextRoot
              .root
              .path;
      _inScope = isProductionProjectLintPath(path, packageRoot: rootPath);
      _isWorker = _inScope && workerOnly && isPersistentWorkerUnit(unit, path);
    }
    return _inScope && (!workerOnly || _isWorker);
  }
}
