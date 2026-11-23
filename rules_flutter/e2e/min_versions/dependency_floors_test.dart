/// Floor proof for a consumer workspace.
///
/// This module declares every dependency at the minimum rules_flutter
/// supports. The repository rule `@resolved_module_versions` reads each
/// selected module's own `MODULE.bazel`, so this program asserts the graph
/// Bazel actually built, not a hand-written model of it. A dependency whose
/// own requirement is above our floor is expected at that lifted version and
/// is attributed to the module that lifted it; presenting a lift as our floor
/// would hide a real consumer requirement.
///
/// It deliberately does not depend on `package:test`: `e2e/min_versions` has a
/// Flutter-only pub graph, so `dart_test` runs this `main` directly and a
/// thrown [StateError] is the failing test result.
library;

import 'dart:convert';
import 'dart:io';

import 'package:dependency_floors/dependency_floors_lib.dart';

/// Read a file named by [variable] from the test environment, failing when the
/// data dependency or its runfiles path is missing.
String _readData(String variable) {
  final path = Platform.environment[variable];
  final runfiles = Platform.environment['TEST_SRCDIR'];
  if (path == null || path.isEmpty || runfiles == null) {
    throw StateError(
      '$variable or TEST_SRCDIR is unset; the test target needs that data file',
    );
  }
  return File('$runfiles/$path').readAsStringSync();
}

/// Fail with [reason] unless [condition] holds.
void _check(bool condition, String reason) {
  if (!condition) throw StateError(reason);
}

/// Compare two dotted numeric versions, returning a negative number, zero or a
/// positive number as [left] is older than, equal to or newer than [right].
int _compareVersions(String left, String right) {
  final a = left.split('.').map(int.parse).toList();
  final b = right.split('.').map(int.parse).toList();
  final length = a.length > b.length ? a.length : b.length;
  for (var i = 0; i < length; i++) {
    final value = i < a.length ? a[i] : 0;
    final other = i < b.length ? b[i] : 0;
    if (value != other) return value - other;
  }
  return 0;
}

/// Assert the declared pins and the resolved graph against the floor table.
void main() {
  final floors = parseFloors(_readData('FLOOR_TABLE'));
  final deps = dependencies(_readData('MODULE_BZL'));
  final resolved = _resolvedVersions(_readData('RESOLVED_VERSIONS'));
  final declared = {for (final dep in deps) dep.name: dep.version};

  for (final entry in floors.entries) {
    _check(
      declared[entry.key] == entry.value.floor,
      '${entry.key} must be declared at its floor ${entry.value.floor}, '
      'not ${declared[entry.key]}',
    );
  }

  // Workspace-only fixtures, not rules_flutter floors: the module under test,
  // the archive-pinned NDK extension and rules_android's SDK-template shell
  // dependency that `//:android_repositories.bzl` maps for its generated
  // repository.
  const fixtures = {'ai_rules_flutter', 'rules_android_ndk', 'rules_shell'};
  for (final dep in deps) {
    if (fixtures.contains(dep.name)) continue;
    _check(
      floors.containsKey(dep.name),
      '${dep.name} has no entry in the dependency floor table',
    );
  }

  for (final entry in floors.entries) {
    final actual = resolved[entry.key];
    _check(actual != null, '${entry.key} is missing from the resolved graph');
    _check(
      _compareVersions(actual!, entry.value.floor) >= 0,
      '${entry.key} resolved to $actual, below the floor '
      '${entry.value.floor}',
    );
    if (entry.value.liftedBy.isEmpty) {
      _check(
        actual == entry.value.floor,
        '${entry.key} has no lift, so it must resolve at the floor '
        '${entry.value.floor}, not $actual',
      );
      continue;
    }
    _check(
      actual == entry.value.resolved,
      '${entry.key} must resolve at the lifted ${entry.value.resolved} '
      '(${entry.value.liftedBy.join(", ")}), not $actual',
    );
    _check(
      _compareVersions(actual, entry.value.floor) > 0,
      '${entry.key} names a lift but does not resolve above its floor',
    );
  }

  _check(
    resolved.keys.toSet().difference(floors.keys.toSet()).isEmpty,
    'versions.json contains modules without a floor entry',
  );
  _check(
    floors.keys.toSet().difference(resolved.keys.toSet()).isEmpty,
    'versions.json is missing a module from the floor table',
  );
  stdout.writeln('dependency floors: ${floors.length} modules checked');
}

/// Parse the repository rule's `versions.json` into module-to-version entries.
Map<String, String> _resolvedVersions(String source) {
  final decoded = jsonDecode(source);
  if (decoded is! Map<String, dynamic>) {
    throw StateError('versions.json is not a JSON object');
  }
  final versions = <String, String>{};
  decoded.forEach((module, version) {
    if (version is! String) {
      throw StateError('versions.json entry for $module is not a string');
    }
    versions[module] = version;
  });
  return versions;
}
