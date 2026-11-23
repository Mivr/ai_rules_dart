/// The directive guard's per-source verdict cache, split out of the incremental
/// `FlutterKernelCompile` worker.
library;

import 'directive_guard.dart';

/// Scans [subset] against the full [declared] set under the roots, returning
/// each readable source's diagnostics.
typedef GuardScan = Map<String, List<String>> Function(
  List<String> subset,
  List<String> declared,
  List<String> roots,
);

/// The directive guard with a per-source verdict cache.
///
/// A source's verdict depends on its own content, the declared set (sources
/// that exist) and the roots. While the declared set and roots are those of the
/// previous check, only sources whose content digest changed are rescanned;
/// any other change of the declared set or roots rescans every source. The
/// first check scans everything and so seeds the per-source verdicts.
class GuardCache {
  new({GuardScan? scan}) : _scan = scan ?? _defaultScan;

  final GuardScan _scan;
  Set<String>? _declared;
  List<String>? _roots;
  final Map<String, String?> _digests = {};
  final Map<String, List<String>> _verdicts = {};

  static Map<String, List<String>> _defaultScan(
    List<String> subset,
    List<String> declared,
    List<String> roots,
  ) => scanFlutterDirectivesAgainst(subset, declared, roots);

  /// The guard errors for [dartSources] under [roots] given the current
  /// content [hashes] (null marks a missing file), in a full scan's order.
  List<String> check(
    List<String> dartSources,
    List<String> roots,
    Map<String, String?> hashes,
  ) {
    final Set<String> declared = {
      for (final s in dartSources)
        if (hashes[s] != null) s,
    };
    final List<String> stale = _staleSources(declared, roots, hashes);
    if (stale.isNotEmpty) {
      _verdicts.addAll(_scan(stale, declared.toList(), roots));
      for (final s in stale) {
        _digests[s] = hashes[s];
      }
    }
    return [
      for (final s in declared.toList()..sort()) ...?_verdicts[s],
    ];
  }

  /// The sources to rescan; resets the cache first when the declared set or
  /// roots differ from the previous check's.
  List<String> _staleSources(
    Set<String> declared,
    List<String> roots,
    Map<String, String?> hashes,
  ) {
    final Set<String>? prior = _declared;
    final bool same =
        prior != null &&
        prior.length == declared.length &&
        prior.containsAll(declared) &&
        _roots!.join('\x00') == roots.join('\x00');
    if (!same) {
      _digests.clear();
      _verdicts.clear();
      _declared = declared;
      _roots = List.of(roots);
    }
    return [
      for (final s in declared)
        if (!_digests.containsKey(s) || _digests[s] != hashes[s]) s,
    ];
  }
}
