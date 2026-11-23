/// Source pins for `flutter_android_aab` (the App Bundle rule).
///
/// The bundle is built by rules_android 0.8.0's public `android_application`
/// macro, so the rule must load exactly that entry point, nothing under
/// rules_android's private `//rules/...` packages, and no host tool. Signing is
/// `jarsigner` from the JDK toolchain, never a shell or a debug key. The
/// bundletool it runs is the sha256-pinned Maven artifact in the e2e
/// workspace's lock file. The behaviour (one `BuildBundle` action,
/// `validate` exiting 0) is checked in `e2e/android_example`, which has the
/// Android SDK.
library;

import 'dart:io';

import 'package:test/test.dart';

const _emitter = 'flutter/private/flutter_android_aab.bzl';
const _macro = 'flutter/android.bzl';
const _lock = 'e2e/android_example/rules_android_maven_install.json';

/// Workspace root: `BUILD_WORKSPACE_DIRECTORY`, else the first ancestor of the
/// runfiles anchor that holds `flutter/` and `MODULE.bazel`.
String _root() {
  bool isRoot(String d) =>
      Directory('$d/flutter').existsSync() &&
      File('$d/MODULE.bazel').existsSync();
  final Map<String, String> env = Platform.environment;
  final String? ws = env['BUILD_WORKSPACE_DIRECTORY'];
  if (ws != null && isRoot(ws)) return ws;
  String dir = File(
    '${env['TEST_SRCDIR']}/${env['GUARD_ROOT_ANCHOR']}',
  ).resolveSymbolicLinksSync();
  for (var i = 0; i < 9; i++) {
    dir = File(dir).parent.path;
    if (isRoot(dir)) return dir;
  }
  throw StateError('workspace root not found');
}

String _read(String relative) =>
    File('${_root()}/$relative').readAsStringSync();

/// The AAB section of the shared emitter file: from its marker comment on.
String _aabSection() {
  final String source = _read(_emitter);
  final int start = source.indexOf('# Android App Bundle');
  expect(start, isNonNegative, reason: 'AAB section marker not found');
  return source.substring(start);
}

/// The text of `def <name>(` up to the next top-level statement.
String _function(String source, String name) {
  final int start = source.indexOf('def $name(');
  expect(start, isNonNegative, reason: 'def $name not found');
  final int end = source.indexOf(RegExp(r'\n[a-zA-Z_#]'), start + 1);
  return source.substring(start, end < 0 ? source.length : end);
}

void main() {
  test('builds on the public android_application entry point only', () {
    final String emitter = _read(_emitter);
    expect(
      emitter,
      contains(
        'load("@rules_android//android:rules.bzl", "android_application")',
      ),
    );
    expect(emitter, contains('bundle_config_file ='));
    expect(_aabSection(), contains('"versionCode": "1"'));
    final Iterable<RegExpMatch> loads = RegExp(r'load\("([^"]+)"')
        .allMatches(emitter);
    for (final m in loads) {
      expect(
        m.group(1),
        isNot(startsWith('@rules_android//rules')),
        reason: 'only the public entry point may be loaded from rules_android',
      );
    }
    expect(
      _aabSection(),
      isNot(matches(RegExp(r'bundletool\.bzl|busybox\.bzl|run_shell'))),
    );
  });

  test('signs with the JDK toolchain jarsigner and runs no host tool', () {
    final String emitter = _aabSection();
    expect(emitter, contains('@bazel_tools//tools/jdk:toolchain_type'));
    expect(emitter, contains('-storepass:file'));
    expect(emitter, contains('-keypass:file'));
    expect(emitter, isNot(contains('use_default_shell_env')));
    expect(emitter, isNot(contains('debug')));
  });

  test('documents signing, the unsigned path and the rules_android floor', () {
    final String macroFn = _function(_read(_macro), 'flutter_android_aab');
    expect(macroFn, contains('unsigned'));
    expect(macroFn, contains('keystore = "release.jks"'));
    expect(
      macroFn,
      contains('keystore_password_file = keystore_password_file'),
    );
    expect(macroFn, contains('key_password_file = key_password_file'));
    expect(macroFn, contains('rules_android 0.8.0'));
    expect(macroFn, contains('flutter_android_aab(\n            name = '));
  });

  test('bundletool is pinned by version and sha256 in the lock file', () {
    final String lock = _read(_lock);
    final RegExpMatch? pin = RegExp(
      r'"com\.android\.tools\.build:bundletool": \{\s*"shasums": \{\s*"jar": "([0-9a-f]{64})"\s*\},\s*"version": "1\.18\.2"',
    ).firstMatch(lock);
    expect(pin, isNotNull, reason: 'bundletool 1.18.2 must carry a jar sha256');
  });
}
