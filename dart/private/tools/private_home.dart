// A private home directory for subprocesses that start the Dart CLI.
//
// The Dart CLI records telemetry state under the user's home
// (`.dart-tool/CLIENT_ID`, `dart-flutter-telemetry.*`). A runner that lets it
// inherit the caller's home writes outside Bazel's declared outputs, so every
// runner that starts the Dart CLI points the home variables at a fresh
// directory that is removed afterwards, on success and on failure.
import 'dart:io';

/// The home variables pointed at [home] for a Dart CLI run.
Map<String, String> privateHomeEnv(String home) => {
  'HOME': home,
  'USERPROFILE': home,
  'LOCALAPPDATA': home,
  'APPDATA': home,
  'XDG_CONFIG_HOME': home,
};

/// Runs [action] with a fresh private home, removed afterwards.
///
/// [action] gets the environment entries pointing at the fresh directory. The
/// directory is removed when [action] returns and when it throws.
T withPrivateHome<T>(
  String prefix,
  T Function(Map<String, String> env) action,
) {
  final home = Directory.systemTemp.createTempSync(prefix);
  try {
    return action(privateHomeEnv(home.path));
  } finally {
    if (home.existsSync()) {
      try {
        home.deleteSync(recursive: true);
      } on FileSystemException {
        // Ignore cleanup errors.
      }
    }
  }
}
