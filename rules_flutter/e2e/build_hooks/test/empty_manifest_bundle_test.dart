/// Reads `//:empty_manifest_app`'s `flutter_assets/` tree, built with
/// `-c opt`, where native_link's link hook ran.
library;

import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test("an empty manifest bundles a hook's data asset", () {
    final String bundle = Runfiles.create().rlocation(
      '_main/empty_manifest_app_flutter_assets',
    );
    expect(
      File('$bundle/packages/native_link/factors.json').readAsStringSync(),
      '[6]',
    );
  });
}
