import 'dart:io';

import 'package:sdk_coupling_e2e/user.dart';
import 'package:sdk_coupling_staged/message.dart';
import 'package:test/test.dart';

void main() {
  test('target test runs on target SDK while build tools ran on exec SDK', () {
    expect(Platform.version, startsWith('3.13.4'));
  });

  test('copy_tree and script codegen produce expected library', () {
    expect(stagedGreeting(), equals('staged: generated part works'));
  });

  test('kernel-mode json_serializable and combining shims round-trip', () {
    const user = CoupledUser(id: 7, name: 'Ada');
    final decoded = CoupledUser.fromJson(user.toJson());
    expect(decoded.id, equals(7));
    expect(decoded.name, equals('Ada'));
  });
}
