import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

/// The exact bytes `dart_test` writes as `<name>.coverage_map.json` under
/// `bazel coverage` for `//dart/tests/coverage_map_fixture/golden:subject`.
void main() {
  test('the map is the expected JSON, byte for byte', () {
    final String workspace = Platform.environment['TEST_WORKSPACE'] ?? '_main';
    const pkg = 'dart/tests/coverage_map_fixture/golden';
    final String path = Runfiles.create().rlocation(
      '$workspace/$pkg/subject.coverage_map.json',
    );
    // Keys in sorted order, as `json.encode` writes them.
    final expected = [
      '"org-dartlang-root:///$pkg/leaf/lib/leaf.dart":"$pkg/leaf/lib/leaf.dart"',
      '"org-dartlang-root:///$pkg/subject.dart":"$pkg/subject.dart"',
      '"org-dartlang-root:///$pkg/top/lib/top.dart":"$pkg/top/lib/top.dart"',
      '"package:coverage_map_golden_leaf/leaf.dart":"$pkg/leaf/lib/leaf.dart"',
      '"package:coverage_map_golden_top/top.dart":"$pkg/top/lib/top.dart"',
    ];
    expect(File(path).readAsStringSync(), '{${expected.join(',')}}');
  });
}
