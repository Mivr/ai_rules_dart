// The generated iOS native registrant must leave the Android-only plugin out:
// no import, no registration call. This runs on Linux, so a filtering
// regression fails before the macOS simulator leg.
import 'dart:io';

import 'package:runfiles/runfiles.dart';

const String _androidOnlyModule = 'android_only_plugin';
const String _androidOnlyClass = 'AndroidOnlyPlugin';

void main(List<String> args) {
  if (args.length != 1) {
    throw StateError('expected one registrant path, got $args');
  }
  final runfiles = Runfiles.create();
  final path = runfiles.rlocation(args.single);
  final source = File(path).readAsStringSync();

  if (!source.contains('@objc class GeneratedPluginRegistrant')) {
    throw StateError(
      '$path is not the iOS GeneratedPluginRegistrant:\n$source',
    );
  }
  if (!source.contains('import ios_greeting_plugin') ||
      !source.contains('IosGreetingPlugin.register(with:')) {
    throw StateError(
      '$path does not register the iOS plugin, so the absence of the '
      'Android-only plugin would prove nothing:\n$source',
    );
  }
  if (source.contains(_androidOnlyModule)) {
    throw StateError(
      '$path imports the Android-only plugin $_androidOnlyModule:\n$source',
    );
  }
  if (source.contains(_androidOnlyClass)) {
    throw StateError(
      '$path registers the Android-only plugin $_androidOnlyClass:\n$source',
    );
  }
}
