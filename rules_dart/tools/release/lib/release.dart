/// The decisions of a release, as functions of tags, commits and releases.
///
/// Nothing here runs git; `bin/release.dart` collects the facts.
library;

import 'package:release/modules.dart';

final _feature = RegExp(r'^feat(\([^)]+\))?!?: ');
final _breaking = RegExp(r'^[a-z]+(\([^)]+\))?!: ');

/// One commit: its subject line and its `Changelog:` trailer values.
typedef Commit = ({String subject, List<String> entries});

/// The newest version of [module]: its baseline, or a tag of its own that is
/// newer. A refused release leaves its tag in git, so its number stays used.
Version latestVersion(ReleaseModule module, Iterable<String> tags) {
  var latest = module.baseline;
  for (final tag in tags) {
    final Version? v = module.versionOfTag(tag);
    if (v != null && compareVersions(v, latest) > 0) latest = v;
  }
  return latest;
}

/// Why [version] cannot be the next release of [module], or null when it can.
String? tagProblem(
  ReleaseModule module,
  String version,
  Iterable<String> tags,
) {
  final Version? v = parseVersion(version);
  if (v == null) {
    return 'Version must look like v1.2.3, got "$version"';
  }
  final String tag = module.tagOf(v);
  if (tags.any((t) => t.trim() == tag)) return 'Tag $tag exists';
  final Version latest = latestVersion(module, tags);
  if (compareVersions(v, latest) <= 0) {
    return '$version is not newer than ${showVersion(latest)}, the latest '
        'release of ${module.name}';
  }
  return null;
}

/// The version to release after [latest] for [commits], or null when none of
/// them carries a `Changelog:` entry other than `skip`.
///
/// A `feat` or breaking (`!`) commit bumps the minor while the major is 0 (a
/// breaking one bumps the major from 1.0 on), anything else the patch.
Version? nextVersion(Version latest, List<Commit> commits) {
  final bool notable = commits.any(
    (c) => c.entries.any((e) => e.isNotEmpty && e != 'skip'),
  );
  if (!notable) return null;
  final bool breaking = commits.any((c) => _breaking.hasMatch(c.subject));
  final bool feature = commits.any((c) => _feature.hasMatch(c.subject));
  if (breaking && latest.major > 0) {
    return (major: latest.major + 1, minor: 0, patch: 0);
  }
  if (breaking || feature) {
    return (major: latest.major, minor: latest.minor + 1, patch: 0);
  }
  return (major: latest.major, minor: latest.minor, patch: latest.patch + 1);
}

/// Where release notes start: the git ref of the newest published release of
/// [module], older than [before] when that is given.
///
/// [published] are the tags that have a published (not draft) release; a tag
/// the release gate refused is in git and not here, so its commits stay in the
/// notes. Without a release of its own the notes start at the module's
/// baseline commit. Returns a tag or a commit.
String notesBase(
  ReleaseModule module,
  Iterable<String> published, {
  Version? before,
}) {
  String ref = module.baselineCommit;
  var best = module.baseline;
  for (final tag in published) {
    final Version? v = module.versionOfTag(tag);
    if (v == null) continue;
    final bool older = before == null || compareVersions(v, before) < 0;
    if (older && compareVersions(v, best) > 0) {
      best = v;
      ref = tag.trim();
    }
  }
  return ref;
}
