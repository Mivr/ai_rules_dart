/// Text check: the README documents `flutter_drive_test` (clause D).
///
/// The README must show a `load` of `flutter_drive_test` from
/// `@rules_flutter//flutter:android.bzl`, name its attributes and the
/// environment the driver receives on each device, and state the supported
/// device kinds: the Android emulator and the iOS simulator.
library;

import 'dart:io';

import 'package:test/test.dart';

String _readme() {
  final String srcdir = Platform.environment['TEST_SRCDIR']!;
  final String key = Platform.environment['README_PATH']!;
  return File('$srcdir/$key').readAsStringSync();
}

void main() {
  late String readme;
  setUpAll(() => readme = _readme());

  test('has a flutter_drive_test section', () {
    expect(readme, contains('### flutter_drive_test'));
  });

  test('loads flutter_drive_test from flutter/android.bzl', () {
    final load = RegExp(
      r'load\("@rules_flutter//flutter:android\.bzl"[^)]*"flutter_drive_test"',
    );
    expect(load.hasMatch(readme), isTrue);
  });

  test('documents the attributes and the driver environment', () {
    for (final word in [
      '`app`',
      '`driver`',
      '`package_name`',
      'VM_SERVICE_URL',
    ]) {
      expect(readme, contains(word));
    }
  });

  test('loads flutter_drive_test from flutter/ios.bzl', () {
    final load = RegExp(
      r'load\("@rules_flutter//flutter:ios\.bzl"[^)]*"flutter_drive_test"',
    );
    expect(load.hasMatch(readme), isTrue);
  });

  test('states the supported device kinds and the iOS environment', () {
    final int start = readme.indexOf('### flutter_drive_test');
    final int end = readme.indexOf('### flutter_plugin', start);
    final String section = readme.substring(start, end);
    expect(
      section,
      contains('Supported device kinds are the Android emulator'),
    );
    expect(section, contains('iOS simulator'));
    expect(section, contains('FLUTTER_DRIVE_IOS_UDID'));
    expect(section, contains('FLUTTER_DRIVE_VM_SERVICE_URI'));
    expect(section, contains('FLUTTER_DRIVE_PACKAGE'));
    expect(section, isNot(contains('| `platform` |')));
    expect(readme, isNot(contains('Android only')));
    expect(readme, isNot(contains('iOS simulator support is a later item')));
  });
}
