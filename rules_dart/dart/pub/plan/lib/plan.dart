/// Plans of pub locks, written ahead of time and checked against their locks.
///
/// A plan holds what the `pub` extension records as a fact for every hosted
/// package of a lock: its dependency names, its SDK constraint and its archive
/// URL, under the same key (`pub.plan.v1/hosted/<name>/<version>/<sha256>/<url>`).
/// A module that ships a lock ships its plan with it (`pub.from_lock(plan =
/// ...)`), so the extension plans that lock with no request in every module
/// that depends on it.
library;

import 'dart:convert';

import 'package:yaml/yaml.dart';

/// The schema every key and the file carry; it is the extension's
/// `PLAN_FACTS_SCHEMA`.
const planSchema = 'pub.plan.v1';

/// One hosted entry of a `pubspec.lock`: the package name, the locked
/// version, the archive sha256 the lock pins and the server (the entry's
/// `description.url`, pub.dev when absent).
typedef HostedEntry = ({
  String name,
  String version,
  String sha256,
  String url,
});

/// What the extension derives from a hosted entry.
extension HostedEntryPlan on HostedEntry {
  /// The fact key the extension looks this entry up under.
  String get key => '$planSchema/hosted/$name/$version/$sha256/$url';

  /// The server's listing of every version of the package.
  Uri listingUri([String? server]) =>
      Uri.parse('${_trimSlash(server ?? url)}/api/packages/$name');

  /// The archive URL the extension uses when the listing names none.
  String get fallbackArchiveUrl =>
      '${_trimSlash(url)}/packages/$name/versions/$version.tar.gz';
}

String _trimSlash(String s) =>
    s.endsWith('/') ? _trimSlash(s.substring(0, s.length - 1)) : s;

/// The hosted entries of a `pubspec.lock`, by name. Entries of other sources
/// are left out: a plan covers hosted packages only.
Map<String, HostedEntry> hostedEntries(String lockText) {
  final Object? lock = loadYaml(lockText);
  final Object? packages = lock is YamlMap ? lock['packages'] : null;
  final entries = <String, HostedEntry>{};
  if (packages is! YamlMap) return entries;
  for (final MapEntry(:key, :value) in packages.entries) {
    if (value is! YamlMap || value['source'] != 'hosted') continue;
    final Object? description = value['description'];
    final YamlMap desc = description is YamlMap ? description : YamlMap();
    entries['$key'] = (
      name: '$key',
      version: '${value['version']}',
      sha256: '${desc['sha256'] ?? ''}'.trim(),
      url: '${desc['url'] ?? 'https://pub.dev'}',
    );
  }
  return entries;
}

/// Plans one entry from its server's listing, as the extension does.
///
/// Throws a [FormatException] when the listing does not list the locked
/// version, or lists another archive sha256 than the lock.
Map<String, Object> planFromListing(
  Map<String, Object?> listing,
  HostedEntry entry,
) {
  final Object? versions = listing['versions'];
  if (versions is! List) {
    throw FormatException('${entry.name}: the listing has no versions');
  }
  final Iterable<Map<String, Object?>> match = versions
      .whereType<Map<String, Object?>>()
      .where((v) => v['version'] == entry.version);
  if (match.isEmpty) {
    throw FormatException(
      '${entry.name}: the listing does not list ${entry.version}',
    );
  }
  final Map<String, Object?> version = match.first;
  final Object? pubspec = version['pubspec'];
  if (pubspec is! Map<String, Object?>) {
    throw FormatException(
      '${entry.name} ${entry.version}: the listing entry has no pubspec',
    );
  }
  final Object? listedSha = version['archive_sha256'];
  if (listedSha != null && '$listedSha'.toLowerCase() != entry.sha256) {
    throw FormatException(
      '${entry.name} ${entry.version}: the lock pins sha256 ${entry.sha256}, the listing says $listedSha',
    );
  }
  final Object? deps = pubspec['dependencies'];
  final Object? environment = pubspec['environment'];
  final Object? sdk = environment is Map ? environment['sdk'] : null;
  final Object? archiveUrl = version['archive_url'];
  return {
    'deps': [if (deps is Map) ...deps.keys.map((k) => '$k')]..sort(),
    'sdk': sdk == null ? '' : '$sdk',
    'archive_url': archiveUrl is String && archiveUrl.isNotEmpty
        ? archiveUrl
        : entry.fallbackArchiveUrl,
  };
}

/// Renders a plan file from plans by fact key, sorted so it diffs well.
String renderPlan(Map<String, Map<String, Object>> plans) {
  final Map<String, Map<String, Object>> sorted = {
    for (final key in plans.keys.toList()..sort()) key: plans[key]!,
  };
  return '${const JsonEncoder.withIndent('  ').convert({'schema': planSchema, 'plans': sorted})}\n';
}

/// Why a plan file does not plan exactly the hosted entries of its lock; empty
/// when it does.
List<String> planProblems(String lockText, String planText) {
  final Map<String, HostedEntry> entries = hostedEntries(lockText);
  final problems = <String>[];
  final Object? decoded;
  try {
    decoded = jsonDecode(planText);
  } on FormatException catch (e) {
    return ['the plan is not JSON: ${e.message}'];
  }
  if (decoded is! Map<String, Object?> ||
      decoded['schema'] != planSchema ||
      decoded['plans'] is! Map) {
    return ['the plan is not {"schema": "$planSchema", "plans": {...}}'];
  }
  final Object? listed = decoded['plans'];
  final Map<String, Object?> plans = listed is Map<String, Object?>
      ? listed
      : const {};
  final Map<String, HostedEntry> wanted = {
    for (final e in entries.values) e.key: e,
  };
  for (final String key in wanted.keys) {
    final Object? plan = plans[key];
    if (plan == null) {
      problems.add(
        'no plan for ${wanted[key]!.name} ${wanted[key]!.version} ($key)',
      );
    } else if (plan is! Map ||
        plan['deps'] is! List ||
        (plan['deps'] as List).any((d) => d is! String) ||
        plan['sdk'] is! String ||
        plan['archive_url'] is! String ||
        (plan['archive_url'] as String).isEmpty) {
      problems.add('the plan of $key is malformed');
    }
  }
  for (final String key in plans.keys) {
    if (!wanted.containsKey(key)) {
      problems.add('the plan has $key, which the lock does not pin');
    }
  }
  return problems;
}
