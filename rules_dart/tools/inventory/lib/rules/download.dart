/// `download-unpinned`: a fetch that bypasses the pinned helpers, or an
/// `http_*` repository rule without a literal checksum.
library;

import 'package:inventory/finding.dart';
import 'package:inventory/source_tree.dart';
import 'package:inventory/starlark.dart';

/// Where one module's downloads are checked.
typedef DownloadScope = ({String module, String bzlDir, String helper});

/// The rule's name in debt files and allow comments.
const String downloadRule = 'download-unpinned';

const Map<String, String> _httpRules = {
  'http_archive': 'archive',
  'http_file': 'file',
  'http_jar': 'jar',
};

final RegExp _rawDownload = RegExp(
  r'\.download(_and_extract)?(?![A-Za-z0-9_])',
);
final RegExp _getattrDownload = RegExp(
  r'''getattr\s*\([^()]*['"]download(_and_extract)?['"]''',
);
final RegExp _literalChecksum = RegExp(
  r'''(?:sha256|integrity)\s*=\s*(?:"([^"]*)"|'([^']*)')''',
);
final RegExp _checksumAttribute = RegExp(r'(?:sha256|integrity)\s*=');
final RegExp _loadItem = RegExp(
  r'''(?:([A-Za-z_][A-Za-z0-9_]*)\s*=\s*)?("[^"]*"|'[^']*')''',
);
final RegExp _rebinding = RegExp(
  r'^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*([A-Za-z_][A-Za-z0-9_]*)\s*$',
  multiLine: true,
);

/// Every context download outside the module's helper, and every `http_*`
/// instantiation in its `.bzl` files and in every `MODULE.bazel` below the
/// module without a non-empty literal `sha256` or `integrity`.
///
/// A call counts whether it uses the rule's own name, a `load` alias, a plain
/// re-binding, or a `use_repo_rule` proxy.
List<Finding> checkDownloads(SourceTree tree, List<DownloadScope> scopes) {
  final findings = <Finding>[];
  for (final scope in scopes) {
    final List<String> bzl = [
      for (final String p in tree.paths)
        if (p.startsWith('${scope.module}/${scope.bzlDir}/') &&
            p.endsWith('.bzl'))
          p,
    ];
    final List<String> modules = [
      for (final String p in tree.paths)
        if (p.startsWith('${scope.module}/') && (p.endsWith('/MODULE.bazel')))
          p,
    ];
    if (bzl.isEmpty || modules.isEmpty) {
      throw SetupException(
        'no .bzl or MODULE.bazel files found for ${scope.module}',
      );
    }
    final helper = '${scope.module}/${scope.helper}';
    for (final path in [...bzl, ...modules]) {
      final String text = tree.read(path);
      if (path != helper && path.endsWith('.bzl')) {
        findings.addAll(_rawDownloads(path, text));
      }
      findings.addAll(_httpChecksums(path, text));
    }
    final String helperText = tree.read(helper);
    for (final def in [
      'def pinned_download(',
      'def pinned_download_and_extract(',
    ]) {
      if (!helperText.contains(def)) {
        findings.add(
          Finding(
            rule: downloadRule,
            file: helper,
            line: 1,
            message: 'the shared download helper must define $def',
            key: 'missing $def',
          ),
        );
      }
    }
  }
  return findings;
}

List<Finding> _rawDownloads(String path, String text) {
  final lines = Lines(text);
  final String code = blank(text);
  final String withStrings = blank(text, blankStrings: false);
  return [
    for (final RegExpMatch m in _rawDownload.allMatches(code))
      ?findingAt(
        rule: downloadRule,
        file: path,
        lines: lines,
        offset: m.start,
        message:
            'context ${m.group(0)!.substring(1)} outside the download helper; '
            'fetch through pinned_download or pinned_download_and_extract',
      ),
    for (final RegExpMatch m in _getattrDownload.allMatches(withStrings))
      ?findingAt(
        rule: downloadRule,
        file: path,
        lines: lines,
        offset: m.start,
        message:
            'getattr lookup of a context download method; fetch through '
            'pinned_download or pinned_download_and_extract',
      ),
  ];
}

List<Finding> _httpChecksums(String path, String text) {
  final lines = Lines(text);
  final String code = blank(text);
  final Map<String, String> names = {
    for (final String rule in _httpRules.keys) rule: rule,
    ..._loadAliases(code, text),
    ..._proxies(code, text),
  };
  final findings = <Finding>[];
  for (final MapEntry<String, String> name in names.entries) {
    final call = RegExp('\\b${RegExp.escape(name.key)}\\s*\\(');
    for (final RegExpMatch m in call.allMatches(code)) {
      final int close = closingParen(code, m.end - 1);
      final String what = name.key == name.value
          ? name.value
          : '${name.value} through ${name.key}';
      final String? problem = close < 0
          ? 'never closes'
          : _checksumProblem(text.substring(m.start, close + 1));
      if (problem == null) continue;
      final Finding? finding = findingAt(
        rule: downloadRule,
        file: path,
        lines: lines,
        offset: m.start,
        message: '$what $problem',
      );
      if (finding != null) findings.add(finding);
    }
  }
  return findings;
}

String? _checksumProblem(String call) {
  for (final RegExpMatch m in _literalChecksum.allMatches(call)) {
    if ((m.group(1) ?? m.group(2) ?? '').isNotEmpty) return null;
  }
  return _checksumAttribute.hasMatch(call)
      ? 'has no non-empty literal sha256 or integrity; a variable, a '
            'conditional or an empty string pins nothing'
      : 'has no sha256 or integrity';
}

/// Names bound to an `http_*` rule by `load` aliases and by plain
/// re-bindings of those names or of the rule names.
Map<String, String> _loadAliases(String code, String text) {
  final found = <String, String>{};
  for (final RegExpMatch load in RegExp(r'\bload\s*\(').allMatches(code)) {
    final int close = closingParen(code, load.end - 1);
    if (close < 0) continue;
    final Iterable<RegExpMatch> items = _loadItem
        .allMatches(text.substring(load.start, close + 1))
        .skip(1);
    for (final item in items) {
      final String symbol = item
          .group(2)!
          .substring(1, item.group(2)!.length - 1);
      if (_httpRules.containsKey(symbol)) {
        found[item.group(1) ?? symbol] = symbol;
      }
    }
  }
  var changed = true;
  while (changed) {
    changed = false;
    for (final RegExpMatch m in _rebinding.allMatches(code)) {
      final String? rule =
          found[m.group(2)] ??
          (_httpRules.containsKey(m.group(2)) ? m.group(2) : null);
      if (rule != null && !found.containsKey(m.group(1))) {
        found[m.group(1)!] = rule;
        changed = true;
      }
    }
  }
  return found;
}

/// Names bound by `name = use_repo_rule(label, "http_*")`.
Map<String, String> _proxies(String code, String text) {
  final proxies = <String, String>{};
  final binding = RegExp(r'([A-Za-z_][A-Za-z0-9_]*)\s*=\s*use_repo_rule\s*\(');
  for (final RegExpMatch m in binding.allMatches(code)) {
    final int close = closingParen(code, m.end - 1);
    if (close < 0) continue;
    final List<String> literals = [
      for (final RegExpMatch s in RegExp(
        '"[^"]*"|\'[^\']*\'',
      ).allMatches(text.substring(m.start, close + 1)))
        s.group(0)!.substring(1, s.group(0)!.length - 1),
    ];
    if (literals.length >= 2 && _httpRules.containsKey(literals[1])) {
      proxies[m.group(1)!] = literals[1];
    }
  }
  return proxies;
}
