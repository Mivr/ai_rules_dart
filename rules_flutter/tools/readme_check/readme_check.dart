/// Whether README.md's install block names a resolvable module pair.
///
/// The `### MODULE.bazel` block must pin `ai_rules_flutter` with
/// `ai_rules_dart` (each carrying its `repo_name`) and give one
/// `archive_override` per module whose URL tag, `strip_prefix` and
/// `integrity` agree with the `bazel_dep` version, so the block resolves
/// as written in a fresh root module. M-7.
library;

/// Modules the install block must pin, with the `repo_name` each keeps.
const _expectedRepos = {
  'ai_rules_flutter': 'rules_flutter',
  'ai_rules_dart': 'rules_dart',
};

/// Integrity values are sha256 SRI strings: base64 of 32 bytes.
final _sri = RegExp(r'^sha256-[A-Za-z0-9+/]{43}=$');

/// The install block: the first starlark fence under `### MODULE.bazel`.
String installBlock(String readme) {
  const fence = '```starlark';
  final int heading = readme.indexOf('### MODULE.bazel');
  if (heading < 0) {
    throw StateError('README has no ### MODULE.bazel heading');
  }
  final int open = readme.indexOf(fence, heading);
  if (open < 0) {
    throw StateError('install block: no starlark fence');
  }
  final int close = readme.indexOf('```', open + fence.length);
  if (close < 0) {
    throw StateError('install block: unterminated fence');
  }
  return readme.substring(open + fence.length, close);
}

/// The value of `key = "..."` in a Bazel call, or null when absent.
String? _attr(String call, String key) {
  final RegExpMatch? found = RegExp('$key = "([^"]*)"').firstMatch(call);
  return found?.group(1);
}

/// Every `callName(...)` invocation in [block], parens balanced.
Iterable<String> _calls(String block, String callName) sync* {
  var rest = block;
  while (true) {
    final int open = rest.indexOf('$callName(');
    if (open < 0) return;
    var depth = 0;
    int i = open + callName.length;
    for (; i < rest.length; i++) {
      if (rest[i] == '(') depth++;
      if (rest[i] == ')') {
        depth--;
        if (depth == 0) break;
      }
    }
    if (depth != 0) {
      throw StateError('install block: unterminated $callName(');
    }
    yield rest.substring(open, i + 1);
    rest = rest.substring(i + 1);
  }
}

/// Issue strings for the install block; empty when it resolves as written.
List<String> checkInstallBlock(String readme) {
  final issues = <String>[];
  final String block = installBlock(readme);
  final List<String> deps = _calls(block, 'bazel_dep').toList();
  final List<String> overrides = _calls(block, 'archive_override').toList();
  for (final dep in deps) {
    final String? name = _attr(dep, 'name');
    if (name == null || !_expectedRepos.containsKey(name)) {
      issues.add('install block: unexpected bazel_dep ${name ?? dep}');
    }
  }
  for (final MapEntry<String, String> entry in _expectedRepos.entries) {
    issues.addAll(_checkModule(deps, overrides, entry.key, entry.value));
  }
  return issues;
}

/// Issues for one expected module's dep plus override pair.
List<String> _checkModule(
  List<String> deps,
  List<String> overrides,
  String name,
  String repoName,
) {
  final issues = <String>[];
  final Iterable<String> dep = deps.where((d) => _attr(d, 'name') == name);
  if (dep.isEmpty) return ['install block: no bazel_dep for $name'];
  final String version = _attr(dep.first, 'version') ?? '';
  if (_attr(dep.first, 'repo_name') != repoName) {
    issues.add('install block: $name needs repo_name = "$repoName"');
  }
  final Iterable<String> override = overrides.where(
    (o) => _attr(o, 'module_name') == name,
  );
  if (override.isEmpty) {
    return [...issues, 'install block: no archive_override for $name'];
  }
  final Iterable<String> urls = RegExp(r'"(https://[^"]*)"')
      .allMatches(override.first)
      .map((m) => m.group(1)!);
  if (urls.isEmpty || !urls.every((u) => u.contains('/v$version/'))) {
    issues.add('install block: $name URL tag disagrees with $version');
  }
  if (!(_attr(override.first, 'strip_prefix') ?? '').endsWith('-$version')) {
    issues.add('install block: $name strip_prefix disagrees with $version');
  }
  if (!_sri.hasMatch(_attr(override.first, 'integrity') ?? '')) {
    issues.add('install block: $name integrity is not a sha256 SRI string');
  }
  return issues;
}
