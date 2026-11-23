/// Finds the stock `flutter` tool and checks that it is the version the rules compile with.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_dev/src/options.dart';

/// The name of the file in an IDE SDK shim's `bin/` that names the real SDK (see `ide.dart`).
const String shimConfigName = 'flutter_dev_shim.json';

/// A stock Flutter SDK.
class StockTool {
  /// The SDK at [root].
  new(this.root);

  /// Finds the SDK: [flag] (the `flutter` executable or the SDK root), then the SDK an IDE shim
  /// next to [self] names, then `FLUTTER_ROOT`, then `flutter` on `PATH`.
  factory find({
    required String self,
    required Map<String, String> environment,
    String? flag,
  }) {
    String? root;
    if (flag != null) {
      root = FileSystemEntity.isDirectorySync(flag)
          ? flag
          : File(flag).absolute.parent.parent.path;
    } else if (shimRoot(self) case final String shimmed) {
      root = shimmed;
    } else if (environment['FLUTTER_ROOT'] case final String env
        when env.isNotEmpty && !_isShim(env)) {
      root = env;
    } else {
      for (final String dir in (environment['PATH'] ?? '').split(':')) {
        if (dir.isEmpty) continue;
        final candidate = File('$dir/flutter');
        if (!candidate.existsSync()) continue;
        final String real = candidate.resolveSymbolicLinksSync();
        if (_isShim(File(real).parent.parent.path) ||
            real == File(self).absolute.path) {
          continue;
        }
        root = File(real).parent.parent.path;
        break;
      }
    }
    if (root == null || !File('$root/bin/flutter').existsSync()) {
      throw UsageException(
        'cannot find the stock `flutter` tool${root == null ? '' : ' (no bin/flutter in $root)'}. '
        'Install the Flutter SDK the rules use, then put it on PATH, set FLUTTER_ROOT, '
        'or pass --bazel-flutter=<path>.',
      );
    }
    return StockTool(Directory(root).absolute.path);
  }

  /// The root of the SDK.
  final String root;

  /// The `flutter` executable.
  String get executable =>
      Platform.isWindows ? '$root\\bin\\flutter.bat' : '$root/bin/flutter';

  /// The SDK's version, from the file the tool writes on its first run, or null when it has not
  /// run yet.
  String? get version {
    final cached = File('$root/bin/cache/flutter.version.json');
    if (cached.existsSync()) {
      try {
        final json =
            jsonDecode(cached.readAsStringSync()) as Map<String, Object?>;
        return (json['flutterVersion'] ?? json['frameworkVersion']) as String?;
      } on FormatException {
        return null;
      }
    }
    final plain = File('$root/version');
    return plain.existsSync() ? plain.readAsStringSync().trim() : null;
  }

  /// Fails unless the SDK is [wanted], the version of the rules' toolchain: the stock tool
  /// recompiles the app with its own frontend server and `dart:ui`, and those must match the
  /// engine Bazel put in the app.
  void checkVersion(String? wanted, {required bool allowMismatch}) {
    final String? have = version;
    if (wanted == null || have == wanted) return;
    final message =
        'the stock flutter in $root is ${have ?? 'of unknown version'}, '
        'and the rules build with Flutter $wanted.';
    if (allowMismatch) {
      stderr.writeln('flutter_dev: warning: $message');
      return;
    }
    throw UsageException(
      '$message Install Flutter $wanted and pass --bazel-flutter=<its bin/flutter>, '
      'or run anyway with --bazel-allow-version-mismatch.',
    );
  }
}

/// The real SDK an IDE shim names, when [self] is a shim's `bin/flutter`.
String? shimRoot(String self) {
  final config = File('${File(self).parent.path}/$shimConfigName');
  if (!config.existsSync()) return null;
  return (jsonDecode(config.readAsStringSync())
          as Map<String, Object?>)['flutterRoot']
      as String?;
}

bool _isShim(String root) => File('$root/bin/$shimConfigName').existsSync();
