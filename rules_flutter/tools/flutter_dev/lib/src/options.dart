/// The command line of `flutter_dev`: its own `--bazel*` flags, and everything else, which goes to
/// the stock `flutter` tool unchanged.
library;

/// Thrown for a command line or a set-up that cannot work. The message is for the user.
class UsageException implements Exception {
  /// An error with [message].
  new(this.message);

  /// What went wrong, and what to do.
  final String message;

  @override
  String toString() => message;
}

/// The build mode `flutter run` was asked for.
enum Mode {
  /// `-c dbg`, hot reload.
  debug,

  /// `-c opt` with the rules' profile flag.
  profile,

  /// `-c opt`.
  release,
}

/// A parsed command line.
class Options {
  new _({
    required this.command,
    required this.globalArgs,
    required this.commandArgs,
    required this.target,
    required this.bazel,
    required this.bazelArgs,
    required this.flutter,
    required this.autoRestart,
    required this.allowVersionMismatch,
  });

  /// Splits [argv]. Every argument that starts with `--bazel` belongs to `flutter_dev`, wherever it
  /// stands, so an IDE can put them among its own arguments; the rest is the stock command line.
  factory parse(List<String> argv) {
    String? target;
    String? bazel;
    String? flutter;
    var autoRestart = true;
    var allowVersionMismatch = false;
    final bazelArgs = <String>[];
    final stock = <String>[];
    for (final arg in argv) {
      if (!arg.startsWith('--bazel')) {
        stock.add(arg);
        continue;
      }
      final int eq = arg.indexOf('=');
      final String name = eq < 0 ? arg : arg.substring(0, eq);
      final String? value = eq < 0 ? null : arg.substring(eq + 1);
      String required() {
        if (value == null || value.isEmpty) {
          throw UsageException('$name needs a value: $name=<value>');
        }
        return value;
      }

      switch (name) {
        case '--bazel':
          bazel = required();
        case '--bazel-target':
          target = required();
        case '--bazel-arg':
          bazelArgs.add(required());
        case '--bazel-flutter':
          flutter = required();
        case '--bazel-no-restart':
          autoRestart = false;
        case '--bazel-allow-version-mismatch':
          allowVersionMismatch = true;
        default:
          throw UsageException('unknown option $name\n\n$usage');
      }
    }
    // Global flags (`-v`, `--suppress-analytics`) may come before the command.
    final int commandIndex = stock.indexWhere((String a) => !a.startsWith('-'));
    return Options._(
      command: commandIndex < 0 ? null : stock[commandIndex],
      globalArgs: commandIndex < 0 ? stock : stock.sublist(0, commandIndex),
      commandArgs: commandIndex < 0
          ? const <String>[]
          : stock.sublist(commandIndex + 1),
      target: target,
      bazel: bazel,
      bazelArgs: bazelArgs,
      flutter: flutter,
      autoRestart: autoRestart,
      allowVersionMismatch: allowVersionMismatch,
    );
  }

  /// `run`, `attach`, `ide`, or a stock command passed through; null when there is none.
  final String? command;

  /// Stock flags before the command.
  final List<String> globalArgs;

  /// Stock arguments after the command.
  final List<String> commandArgs;

  /// `--bazel-target`: the label that builds the app (an APK, a desktop bundle, an `.app`), or for
  /// the web any target with the `flutter_application` below it.
  final String? target;

  /// `--bazel`: the Bazel executable.
  final String? bazel;

  /// `--bazel-arg`, repeated: extra arguments for `bazel build`.
  final List<String> bazelArgs;

  /// `--bazel-flutter`: the stock `flutter` executable or the root of its SDK.
  final String? flutter;

  /// False with `--bazel-no-restart`.
  final bool autoRestart;

  /// True with `--bazel-allow-version-mismatch`.
  final bool allowVersionMismatch;

  /// Every `--bazel*` flag again, for launch configurations that call this tool back.
  List<String> get ownFlags => <String>[
    if (bazel != null) '--bazel=$bazel',
    if (target != null) '--bazel-target=$target',
    for (final String a in bazelArgs) '--bazel-arg=$a',
    if (flutter != null) '--bazel-flutter=$flutter',
    if (!autoRestart) '--bazel-no-restart',
    if (allowVersionMismatch) '--bazel-allow-version-mismatch',
  ];

  /// Whether the stock tool speaks its JSON protocol on stdout.
  bool get machine => commandArgs.contains('--machine');

  /// The build mode the stock arguments ask for.
  Mode get mode => commandArgs.contains('--release')
      ? Mode.release
      : commandArgs.contains('--profile')
      ? Mode.profile
      : Mode.debug;

  /// Whether hot mode is off (`--no-hot`).
  bool get noHot => commandArgs.contains('--no-hot');

  /// The device id given with `-d` or `--device-id`, if any.
  String? get deviceId {
    for (var i = 0; i < commandArgs.length; i++) {
      final String a = commandArgs[i];
      if ((a == '-d' || a == '--device-id') && i + 1 < commandArgs.length) {
        return commandArgs[i + 1];
      }
      if (a.startsWith('--device-id=')) {
        return a.substring('--device-id='.length);
      }
      if (a.startsWith('-d') && a.length > 2 && !a.startsWith('--')) {
        return a.substring(a[2] == '=' ? 3 : 2);
      }
    }
    return null;
  }

  /// Whether the device is a browser: the stock tool then compiles and serves the app itself.
  bool get web =>
      const <String>{'chrome', 'edge', 'web-server'}.contains(deviceId);

  /// Whether the stock arguments name an option (`--pid-file`, `--pid-file=x`).
  bool hasOption(String name) =>
      commandArgs.any((String a) => a == name || a.startsWith('$name='));
}

/// The help text.
const String usage = r'''
flutter_dev: build a Flutter app with Bazel, then hand it to the stock `flutter` tool.

  flutter_dev run --bazel-target=//:app [flutter run arguments]
  flutter_dev attach --bazel-target=//:app [flutter attach arguments]
  flutter_dev ide --bazel-target=//:app [--bazel* flags]

`run` and `attach` build the target (`-c dbg`, or `-c opt` with --profile or --release), write
.dart_tool/package_config.json and .dart_tool/package_graph.json, link the generated Dart sources
into the source tree, and run stock `flutter run --use-application-binary <the build>` or
`flutter attach`. The stock tool then installs, launches, hot reloads, hot restarts, serves
DevTools and debugs. One hot restart follows the launch, so breakpoints bind from the start.
`-d chrome` hands the sources to stock `flutter run -d chrome`, which compiles them itself.
`ide` does the same set-up and writes launch configurations for VS Code and IntelliJ.
Any other command goes to the stock tool unchanged.

Options of flutter_dev (all others go to the stock tool):
  --bazel-target=<label>          The app to build (required for run, attach and ide).
  --bazel=<path>                  The Bazel executable (default: $BAZEL, then `bazel`).
  --bazel-arg=<arg>               An extra `bazel build` argument; repeat for more.
  --bazel-flutter=<path>          The stock `flutter`, or its SDK root (default: $FLUTTER_ROOT,
                                  then `flutter` on PATH). It must be the version the rules use.
  --bazel-allow-version-mismatch  Run a stock tool of another version anyway.
  --bazel-no-restart              No hot restart after the launch.
''';
