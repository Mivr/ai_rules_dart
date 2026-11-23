/// Fixture-tree tests for the doc extract exemption checks.
library;

import 'dart:io';

import 'package:test/test.dart';

import 'doc_extract_exemptions.dart';

const DocExemption _android = DocExemption(
  stem: 'droid',
  reason: 'android modules',
  needsAndroidClosure: true,
);

Directory _fixture(Map<String, String> files) {
  final Directory root = Directory.systemTemp.createTempSync('doc_exempt_');
  addTearDown(() => root.deleteSync(recursive: true));
  files.forEach((path, text) {
    File('${root.path}/$path')
      ..createSync(recursive: true)
      ..writeAsStringSync(text);
  });
  return root;
}

DocExtractVerdict _check(
  Directory root,
  List<DocExemption> exemptions,
  Set<String> extracts,
) => checkDocExtracts(
  DocExtractInputs(
    repoRoot: root.path,
    exemptions: exemptions,
    extractStems: extracts,
  ),
);

void main() {
  test('a public stem with no extract and no exemption fails', () {
    final Directory root = _fixture({'flutter/a.bzl': '', 'flutter/b.bzl': ''});
    final DocExtractVerdict v = _check(root, const [], {'a'});
    expect(v.problems, hasLength(1));
    expect(v.problems.single, contains('flutter/b.bzl'));
  });

  test('an exemption naming a missing file fails', () {
    final Directory root = _fixture({'flutter/a.bzl': ''});
    final DocExtractVerdict v = _check(
      root,
      const [DocExemption(stem: 'gone', reason: 'r')],
      {'a'},
    );
    expect(v.problems.single, contains('"gone"'));
  });

  test('an extract naming a missing file fails', () {
    final Directory root = _fixture({'flutter/a.bzl': ''});
    final DocExtractVerdict v = _check(root, const [], {'a', 'ghost'});
    expect(v.problems.single, contains('ghost.doc_extract'));
  });

  test('an exempt stem that regains an extract is reported, not failed', () {
    final Directory root = _fixture({'flutter/a.bzl': ''});
    final DocExtractVerdict v = _check(
      root,
      const [DocExemption(stem: 'a', reason: 'old reason')],
      {'a'},
    );
    expect(v.problems, isEmpty);
    expect(v.notes.single, contains('Stale exemption'));
  });

  test(
    'an Android exemption passes when the closure reaches rules_android',
    () {
      final Directory root = _fixture({
        'flutter/droid.bzl': 'load("//flutter/private:x.bzl", "x")\n',
        'flutter/private/x.bzl':
            'load("@rules_android//android:rules.bzl", "android_binary")\n',
      });
      expect(_check(root, const [_android], {}).problems, isEmpty);
    },
  );

  test('an Android exemption passes via a rules_kotlin load', () {
    final Directory root = _fixture({
      'flutter/droid.bzl':
          "load('@rules_flutter//flutter/private:x.bzl', 'x')\n",
      'flutter/private/x.bzl': 'load(":y.bzl", "y")\n',
      'flutter/private/y.bzl':
          'load("@rules_kotlin//kotlin:android.bzl", "kt")\n',
    });
    expect(_check(root, const [_android], {}).problems, isEmpty);
  });

  test('an Android exemption fails when the closure reaches neither', () {
    final Directory root = _fixture({
      'flutter/droid.bzl': 'load("//flutter/private:x.bzl", "x")\n',
      'flutter/private/x.bzl': 'load("@bazel_skylib//lib:paths.bzl", "p")\n',
    });
    final DocExtractVerdict v = _check(root, const [_android], {});
    expect(v.problems.single, contains('stale'));
  });
}
