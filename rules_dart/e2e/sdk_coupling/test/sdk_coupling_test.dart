import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:sdk_coupling_staged/message.dart';
import 'package:test/test.dart';

void main(List<String> args) {
  // The first argument is the `dart` of the `target_dart` registration.
  final runfiles = Runfiles.create();
  final dart = runfiles.rlocation(args.first);
  final targetSdk = File('${File(dart).parent.parent.path}/version')
      .readAsStringSync()
      .trim();

  test('target test runs on target SDK while build tools ran on exec SDK', () {
    expect(Platform.version, startsWith(targetSdk));
  });

  test('copy_tree and script codegen produce expected library', () {
    expect(stagedGreeting(), equals('staged: generated part works'));
  });
}
