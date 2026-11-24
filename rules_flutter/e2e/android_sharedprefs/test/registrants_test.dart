/// The Dart plugin registrant of the app names `shared_preferences_android`.
///
/// A missing registration is invisible at build time and surfaces on the
/// device as a `MissingPluginException` from `SharedPreferences.getInstance()`.
/// This test reads the generated file the build produces and fails, naming
/// the plugin and the file, unless it registers the plugin by its
/// `dartPluginClass` (`SharedPreferencesAndroid`, from its `pubspec.yaml`).
///
/// The Android side (`GeneratedPluginRegistrant` and the plugin's
/// `pluginClass`) is checked in the APK by `//:app_apk_test`: the Java
/// registrant is the one the Flutter tool wrote, carried by the pin.
///
/// The Dart registrant is `app_dart_registrant.dart`, symlinked from the
/// `app_flutter_plugin_registrant.dart` file `generate_dart_plugin_registrant`
/// writes for the Android-configured `flutter_application` and passes to
/// `FlutterKernelCompile` under `-Dflutter.dart_plugin_registrant=`.
library;

import 'dart:io';

const _plugin = 'shared_preferences_android';
const _dartPluginClass = 'SharedPreferencesAndroid';
const _dartRegistrant = 'app_dart_registrant.dart';

String _read(String relativePath) {
  final srcDir = Platform.environment['TEST_SRCDIR'];
  final workspace = Platform.environment['TEST_WORKSPACE'];
  if (srcDir == null || workspace == null) {
    stderr.writeln('Missing TEST_SRCDIR or TEST_WORKSPACE env vars');
    exit(1);
  }
  final file = File('$srcDir/$workspace/$relativePath');
  if (!file.existsSync()) {
    stderr.writeln('$relativePath was not generated (looked at ${file.path})');
    exit(1);
  }
  return file.readAsStringSync();
}

/// Reports a failure naming the missing plugin and the registrant file.
bool _check({
  required String file,
  required String content,
  required Pattern registration,
  required String what,
}) {
  if (content.contains(registration)) {
    stdout.writeln('ok: $file registers $_plugin ($what)');
    return true;
  }
  stderr
    ..writeln('FAIL: $file does not register $_plugin: no $what.')
    ..writeln('--- $file ---')
    ..writeln(content);
  return false;
}

void main() {
  final dart = _read(_dartRegistrant);
  final results = [
    _check(
      file: _dartRegistrant,
      content: dart,
      registration: RegExp('\\b$_dartPluginClass\\.registerWith\\(\\)'),
      what: '$_dartPluginClass.registerWith() call',
    ),
    _check(
      file: _dartRegistrant,
      content: dart,
      registration: "import 'package:$_plugin/$_plugin.dart'",
      what: 'import of package:$_plugin',
    ),
  ];
  if (results.contains(false)) {
    exit(1);
  }
}
