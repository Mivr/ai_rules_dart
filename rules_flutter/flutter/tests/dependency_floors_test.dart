/// Dependency-floor guard: every regular `bazel_dep` in the root
/// `MODULE.bazel` declares the minimum this repository supports, not the
/// release the repository happens to compile.
///
/// Bzlmod resolves a module to the highest version anywhere in the graph, so a
/// declaration is a floor inherited by every consumer. The checked-in table
/// (`dependency_floors.json`) records that floor and the symbol, package or
/// attribute that sets it; this test fails when a declaration is above its
/// floor (a consumer would be force-upgraded), when a dependency is missing
/// from the table, or when the root-only override that keeps this repository
/// on a current release is absent. `e2e/min_versions` proves the other half:
/// the floors build and the transitive lifts resolve at their lifted values.
///
/// The test reads `//:MODULE.bazel` and the table from `data`, so the inputs
/// are the tracked files rather than whatever a developer's working copy
/// happens to contain.
library;

import 'dart:io';

import 'package:dependency_floors/dependency_floors_lib.dart';
import 'package:test/test.dart';

/// Read a file named by [variable] from the test environment, failing when the
/// data dependency or its runfiles path is missing.
String _readData(String variable) {
  final String? path = Platform.environment[variable];
  final String? runfiles = Platform.environment['TEST_SRCDIR'];
  if (path == null || path.isEmpty || runfiles == null) {
    throw StateError(
      '$variable or TEST_SRCDIR is unset; the test target needs that data file',
    );
  }
  return File('$runfiles/$path').readAsStringSync();
}

void main() {
  late final Map<String, Floor> floors;
  late final List<Dependency> deps;
  late final Map<String, String> pinned;

  setUpAll(() {
    floors = parseFloors(_readData('FLOOR_TABLE'));
    deps = dependencies(_readData('MODULE_BZL'));
    pinned = overrides(_readData('MODULE_BZL'));
  });

  test('every regular dependency has a checked-in floor', () {
    final Set<String> declared = {
      for (final dep in deps)
        if (!dep.dev) dep.name,
    };
    expect(
      declared.difference(floors.keys.toSet()),
      isEmpty,
      reason: 'regular bazel_dep names missing from dependency_floors.json',
    );
    expect(
      floors.keys.toSet().difference(declared),
      isEmpty,
      reason: 'stale dependency_floors.json entries with no bazel_dep',
    );
  });

  test('every declared version is its floor, not a current release', () {
    for (final dep in deps) {
      if (dep.dev) continue;
      final String floor = floors[dep.name]!.floor;
      expect(
        dep.version,
        equals(floor),
        reason:
            '${dep.name} declares ${dep.version} but the supported floor is '
            '$floor; a consumer would be force-upgraded by MVS',
      );
    }
  });

  test('every current release above a floor has a root-only override', () {
    for (final dep in deps) {
      if (dep.dev) continue;
      final Floor entry = floors[dep.name]!;
      expect(
        pinned[dep.name],
        entry.current == entry.floor ? isNull : equals(entry.current),
        reason: entry.current == entry.floor
            ? '${dep.name} is already current at its floor; a root override '
                  'would hide the declared floor'
            : 'this checkout must keep building ${dep.name} ${entry.current} '
                  'through a root-only single_version_override',
      );
    }
  });

  test('the table resolves each floor or names the module that lifts it', () {
    for (final MapEntry<String, Floor> entry in floors.entries) {
      if (entry.value.liftedBy.isEmpty) {
        expect(
          entry.value.resolved,
          equals(entry.value.floor),
          reason: '${entry.key} has no lift, so it must resolve at its floor',
        );
      } else {
        for (final String module in entry.value.liftedBy) {
          expect(
            floors.containsKey(module),
            isTrue,
            reason: '${entry.key} names unknown lifting module $module',
          );
        }
      }
    }
  });
}
