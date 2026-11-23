/// Derives which public `flutter/*.bzl` entries need a `//docs` doc extract
/// and checks the exemption list that excuses the rest.
library;

import 'dart:io';

/// A public entry stem excused from having a `starlark_doc_extract`.
class DocExemption {
  const new({
    required this.stem,
    required this.reason,
    this.needsAndroidClosure = false,
  });

  final String stem;

  /// Why the stem has no extract, as stated in `docs/BUILD.bazel`.
  final String reason;

  /// Whether [reason] is that the load closure reaches `@rules_android//` or
  /// `@rules_kotlin//`, which the guard then checks against the tree.
  final bool needsAndroidClosure;
}

/// Outcome of [checkDocExtracts]: [problems] fail the guard, [notes] do not.
class DocExtractVerdict {
  final List<String> problems = <String>[];
  final List<String> notes = <String>[];
}

/// Inputs for [checkDocExtracts].
class DocExtractInputs {
  const new({
    required this.repoRoot,
    required this.exemptions,
    required this.extractStems,
  });

  final String repoRoot;
  final List<DocExemption> exemptions;

  /// Stems of the `<stem>.doc_extract` targets declared in `//docs`.
  final Set<String> extractStems;
}

final RegExp _loadPattern = RegExp(r'''\bload\(\s*(?:"([^"]+)"|'([^']+)')''');
const List<String> _androidPrefixes = ['@rules_android//', '@rules_kotlin//'];

/// Stems of the `.bzl` files directly under `<repoRoot>/flutter`, sorted.
List<String> publicEntryStems(String repoRoot) {
  final stems = <String>[
    for (final FileSystemEntity entry in Directory(
      '$repoRoot/flutter',
    ).listSync())
      if (entry is File && entry.path.endsWith('.bzl'))
        entry.uri.pathSegments.last.replaceAll(RegExp(r'\.bzl$'), ''),
  ]..sort();
  return stems;
}

/// The repo-relative path a load label names, or null when it is external.
String? _inRepoPath(String label, String fromFile) {
  var rest = label;
  if (rest.startsWith('@rules_flutter//')) {
    rest = rest.substring('@rules_flutter'.length);
  }
  if (rest.startsWith(':')) {
    final int slash = fromFile.lastIndexOf('/');
    final String pkg = slash < 0 ? '' : fromFile.substring(0, slash + 1);
    return '$pkg${rest.substring(1)}';
  }
  if (!rest.startsWith('//')) return null;
  return rest.substring(2).replaceFirst(':', '/');
}

/// Every load label in the in-repo load closure of `flutter/<stem>.bzl`.
///
/// Follows `//` and `@rules_flutter//` loads through the tree with a static
/// `load("...")` scan; labels that leave the repo are collected, not followed.
Set<String> loadClosureLabels(String repoRoot, String stem) {
  final labels = <String>{};
  final seen = <String>{};
  final pending = <String>['flutter/$stem.bzl'];
  while (pending.isNotEmpty) {
    final String path = pending.removeLast();
    final file = File('$repoRoot/$path');
    if (!seen.add(path) || !file.existsSync()) continue;
    for (final RegExpMatch m in _loadPattern.allMatches(
      file.readAsStringSync(),
    )) {
      final String label = (m.group(1) ?? m.group(2))!;
      labels.add(label);
      final String? next = _inRepoPath(label, path);
      if (next != null) pending.add(next);
    }
  }
  return labels;
}

void _checkExemption(
  DocExemption exemption,
  DocExtractInputs inputs,
  DocExtractVerdict out,
) {
  final String stem = exemption.stem;
  if (!File('${inputs.repoRoot}/flutter/$stem.bzl').existsSync()) {
    out.problems.add('Exempt stem "$stem" names no flutter/$stem.bzl file');
    return;
  }
  if (inputs.extractStems.contains(stem)) {
    out.notes.add(
      'Stale exemption: "$stem" has a doc extract again; drop it from the '
      'exemption list (${exemption.reason})',
    );
  }
  if (!exemption.needsAndroidClosure) return;
  final Set<String> labels = loadClosureLabels(inputs.repoRoot, stem);
  if (!labels.any((l) => _androidPrefixes.any(l.startsWith))) {
    out.problems.add(
      'Android exemption for "$stem" is stale: its load closure no longer '
      'reaches @rules_android// or @rules_kotlin//',
    );
  }
}

/// Checks the declared extracts against the public entries and exemptions.
DocExtractVerdict checkDocExtracts(DocExtractInputs inputs) {
  final out = DocExtractVerdict();
  final Set<String> public = publicEntryStems(inputs.repoRoot).toSet();
  final Set<String> exempt = {for (final e in inputs.exemptions) e.stem};
  for (final DocExemption e in inputs.exemptions) {
    _checkExemption(e, inputs, out);
  }
  for (final String stem in inputs.extractStems) {
    if (!public.contains(stem)) {
      out.problems.add(
        '//docs:$stem.doc_extract names no flutter/$stem.bzl file',
      );
    }
  }
  for (final stem in public) {
    if (!exempt.contains(stem) && !inputs.extractStems.contains(stem)) {
      out.problems.add(
        'Public entry flutter/$stem.bzl has neither a //docs:$stem.doc_extract '
        'nor an exemption',
      );
    }
  }
  return out;
}
