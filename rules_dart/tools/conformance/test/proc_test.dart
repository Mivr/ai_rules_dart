import 'dart:io';

import 'package:conformance/proc.dart';
import 'package:test/test.dart';

void main() {
  group('failureLineOf', () {
    test('takes Bazel\'s specific error over a fetch header', () {
      expect(
        failureLineOf('''
INFO: Invocation ID: x
ERROR: /ob/external/a/b.bzl:1:2: An error occurred during the fetch of repository 'r':
ERROR: no such package '@r//': bad manifest
'''),
        "ERROR: no such package '@r//': bad manifest",
      );
    });

    test('adds the compiler\'s own error to a failed action', () {
      expect(
        failureLineOf('''
ERROR: /w/BUILD.bazel:43:18: Compiling a.cc failed: (Exit 1): clang++ failed: error executing CppCompile command (from x) clang++ ...
[12 / 30] Compiling ...
external/s/gdkx.h:30:10: fatal error: 'X11/Xlib.h' file not found
'''),
        "ERROR: /w/BUILD.bazel:43:18: Compiling a.cc failed: "
        "external/s/gdkx.h:30:10: fatal error: 'X11/Xlib.h' file not found",
      );
    });

    test('joins a tool\'s error with the lines after it', () {
      expect(
        failureLineOf('''
Building Linux application...
CMake Error at FindPkgConfig.cmake:1093 (message):
  The following required packages were not found:
   - gtk+-3.0
Call Stack (most recent call first):
'''),
        'CMake Error at FindPkgConfig.cmake:1093 (message): '
        'The following required packages were not found: - gtk+-3.0 '
        'Call Stack (most recent call first):',
      );
    });

    test('falls back to the last line', () {
      expect(failureLineOf('a\nb\n\n'), 'b');
    });
  });

  test('copyTree skips named top-level entries and keeps executable bits', () {
    final tmp = Directory.systemTemp.createTempSync('proc_test');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final from = Directory('${tmp.path}/from')..createSync();
    File('${from.path}/keep/a.txt')
      ..createSync(recursive: true)
      ..writeAsStringSync('a');
    File('${from.path}/build/out.txt')
      ..createSync(recursive: true)
      ..writeAsStringSync('o');
    final tool = File('${from.path}/tool')..writeAsStringSync('#!/bin/sh\n');
    // A Windows file has no executable bit to set or to keep.
    if (!Platform.isWindows) Process.runSync('chmod', ['755', tool.path]);
    final to = Directory('${tmp.path}/to');
    File('${from.path}/keep/ephemeral/gen.txt')
      ..createSync(recursive: true)
      ..writeAsStringSync('g');
    copyTree(from, to, skip: {'build'}, skipAnywhere: {'ephemeral'});
    expect(File('${to.path}/keep/a.txt').readAsStringSync(), 'a');
    expect(Directory('${to.path}/keep/ephemeral').existsSync(), isFalse);
    expect(Directory('${to.path}/build').existsSync(), isFalse);
    expect(File('${to.path}/tool').existsSync(), isTrue);
    if (!Platform.isWindows) {
      expect(File('${to.path}/tool').statSync().mode & 0x40, isNot(0));
    }
  });
}
