/// Verifies `track_widget_creation` reaches the kernel of a debug APK.
///
/// Flutter's widget-creation transformer adds a named constructor parameter
/// to every widget constructor, and the name of that parameter is the only
/// thing in the kernel that exists because of the flag. The test reads
/// `assets/flutter_assets/kernel_blob.bin` out of two debug APKs built from
/// the same sources and deps, one with `track_widget_creation = True` and one
/// with `False`, and expects the parameter name in the first only. It reads
/// the final kernel only, so it holds whether the app compiled whole-program
/// or linked per-package modules.
///
/// The bare word `creationLocation` is not the marker: the framework's own
/// inspector declares it, so both kernels carry it. The test requires it in
/// both kernels, which shows the reader holds a real framework kernel.
library;

// This script's diagnostics are its product: it reports what it found in the
// built artifact to the bazel test log, so `print` is its output channel
// rather than a stray debugging statement.
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'apk_reader.dart';

const _kernelEntry = 'assets/flutter_assets/kernel_blob.bin';

/// The constructor parameter the widget-creation transformer adds, as written
/// in `_creationLocationParameterName` of the Dart SDK's
/// `pkg/kernel/lib/transformations/track_widget_constructor_locations.dart`
/// (the Dart revision Flutter 3.47.7's engine pins).
const _marker = r'$creationLocationd_0dea112b090073317d4';

/// The word the framework's inspector declares, present with or without the
/// transformer.
const _frameworkWord = 'creationLocation';

final _failures = <String>[];

/// Records a failure naming [expected] and [found] when [ok] is false.
void _check(String expected, {required bool ok, required String found}) {
  if (ok) {
    print('OK: $expected');
  } else {
    stderr.writeln('FAIL: expected $expected; found $found');
    _failures.add(expected);
  }
}

/// How many times [needle] occurs in [haystack].
int _count(Uint8List haystack, String needle) {
  final text = latin1.decode(haystack);
  var count = 0;
  for (var at = text.indexOf(needle); at >= 0;) {
    count++;
    at = text.indexOf(needle, at + needle.length);
  }
  return count;
}

void main() {
  final tracked = zipEntry(runfile('TRACKED_APK'), _kernelEntry);
  final untracked = zipEntry(runfile('UNTRACKED_APK'), _kernelEntry);
  print(
    'kernel_blob.bin: ${tracked.length} bytes tracked, '
    '${untracked.length} bytes untracked',
  );

  final kernels = {'tracked': tracked, 'untracked': untracked};
  for (final MapEntry(key: role, value: kernel) in kernels.entries) {
    final words = _count(kernel, _frameworkWord);
    _check(
      'the $role kernel to carry the framework word $_frameworkWord',
      ok: words > 0,
      found: '$words occurrences',
    );
  }
  final trackedMarkers = _count(tracked, _marker);
  _check(
    'the track_widget_creation = True kernel to carry $_marker',
    ok: trackedMarkers > 0,
    found: '$trackedMarkers occurrences',
  );
  final untrackedMarkers = _count(untracked, _marker);
  _check(
    'the track_widget_creation = False kernel to carry no $_marker',
    ok: untrackedMarkers == 0,
    found: '$untrackedMarkers occurrences',
  );

  if (_failures.isNotEmpty) {
    stderr.writeln('\n${_failures.length} check(s) failed.');
    exit(1);
  }
  print('\nAll Android widget-tracking checks passed.');
}
