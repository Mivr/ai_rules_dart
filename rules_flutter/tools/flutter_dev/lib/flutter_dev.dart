/// `flutter_dev`: Bazel builds the app, the stock `flutter` tool does everything after that.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_dev/src/bazel.dart';
import 'package:flutter_dev/src/build_events.dart';
import 'package:flutter_dev/src/ide.dart';
import 'package:flutter_dev/src/options.dart';
import 'package:flutter_dev/src/project_files.dart';
import 'package:flutter_dev/src/session.dart';
import 'package:flutter_dev/src/stock_tool.dart';

export 'src/options.dart' show Options, UsageException, usage;

/// Runs the tool; returns the exit code.
///
/// [self] is this tool's executable, [environment] its environment, [input] and [output] the
/// `--machine` client's streams; all default to this process's.
Future<int> flutterDev(
  List<String> argv, {
  String? self,
  Map<String, String>? environment,
  Stream<List<int>>? input,
  IOSink? output,
}) async {
  self ??= Platform.resolvedExecutable;
  environment ??= Platform.environment;
  try {
    final options = Options.parse(<String>[...shimFlags(self), ...argv]);
    final String? command = options.command;
    if (command == 'run' || command == 'attach' || command == 'ide') {
      return await _session(options, self, environment, input, output);
    }
    // As an IDE's SDK shim, every other command is the stock tool's.
    if (shimRoot(self) != null) {
      final tool = StockTool.find(self: self, environment: environment);
      final Process p = await Process.start(
        tool.executable,
        argv,
        mode: ProcessStartMode.inheritStdio,
        environment: environment,
        includeParentEnvironment: false,
      );
      return await p.exitCode;
    }
    if (command == null ||
        command == 'help' ||
        argv.contains('--help') ||
        argv.contains('-h')) {
      stdout.write(usage);
      return command == null && argv.isEmpty ? 64 : 0;
    }
    throw UsageException(
      'unknown command `$command`; flutter_dev runs `run`, `attach` and `ide`.\n\n$usage',
    );
  } on UsageException catch (e) {
    stderr.writeln('flutter_dev: $e');
    return 64;
  } on BuildFailure catch (e) {
    stderr.writeln('flutter_dev: $e');
    return e.exitCode;
  }
}

Future<int> _session(
  Options options,
  String self,
  Map<String, String> environment,
  Stream<List<int>>? input,
  IOSink? output,
) async {
  final String projectDir =
      environment['BUILD_WORKING_DIRECTORY'] ?? Directory.current.path;
  if (!File('$projectDir/pubspec.yaml').existsSync()) {
    throw UsageException(
      '$projectDir has no pubspec.yaml: run flutter_dev in the Flutter project directory.',
    );
  }
  final String workspace =
      environment['BUILD_WORKSPACE_DIRECTORY'] ?? _findWorkspace(projectDir);
  final String? target = options.target;
  if (target == null) {
    throw UsageException(
      'name the app to build with --bazel-target=<label>, for example --bazel-target=//:app',
    );
  }
  // Found before the build, so a missing tool fails at once; its version is checked after the
  // build, which says what the rules use.
  final tool = StockTool.find(
    flag: options.flutter,
    self: self,
    environment: environment,
  );
  final bazel = Bazel(
    executable: options.bazel ?? environment['BAZEL'] ?? 'bazel',
    workspace: workspace,
    mode: options.mode,
    extraArgs: options.bazelArgs,
    terminal: !options.machine && stderr.hasTerminal,
    environment: environment,
    scratch: '$projectDir/$toolDir',
  );

  // 1. Build: the app (not on the web, where the stock tool compiles), the aspect's files, and the
  // generators of the generated sources in the top-level configuration, where a later
  // `bazel build <generator>` writes them.
  final state = State.load(projectDir);
  final List<String> known = state.generators[target] ?? const <String>[];
  const groups = <String>[stockDevGroup, generatedGroup];
  final BuildOutputs out = options.web
      ? await bazel.build(<String>[target], groups: groups, withDefault: false)
      : await bazel.build(
          <String>[target, ...known],
          groups: groups,
          withDefault: true,
        );
  final app = AppInfo.from(out, target);
  final ({List<GeneratedSource> sources, Set<String> stockGenerators})
  generated = generatedSources(out, target);
  final bool ownL10n = File('$projectDir/l10n.yaml').existsSync();
  final Set<String> skip = ownL10n
      ? generated.stockGenerators
      : const <String>{};
  final List<String> generators = <String>{
    for (final s in generated.sources)
      if (!skip.contains(s.generator)) s.generator,
  }.toList()..sort();
  var top = out;
  if (generators.isNotEmpty &&
      (options.web || !generators.every(known.contains))) {
    top = await bazel.build(
      generators,
      groups: const <String>[],
      withDefault: true,
    );
  }
  state.generators[target] = generators;
  tool.checkVersion(
    app.flutterVersion,
    allowMismatch: options.allowVersionMismatch,
  );

  // 2. The files the stock tool and the IDE read.
  final bazelConfig = jsonDecode(
    File(app.packageConfig).readAsStringSync(),
  ) as Map<String, Object?>;
  final Map<String, Object?> config = idePackageConfig(
    bazelConfig,
    workspace: workspace,
    outputBase: out.outputBase,
    flutterRoot: tool.root,
  );
  final String? package = app.package;
  if (package == null) {
    throw UsageException('${app.label} has no package_name.');
  }
  writeIfChanged(
    '$projectDir/.dart_tool/package_config.json',
    const JsonEncoder.withIndent('  ').convert(config),
  );
  writeIfChanged(
    '$projectDir/.dart_tool/package_graph.json',
    const JsonEncoder.withIndent('  ').convert(packageGraph(config, package)),
  );
  linkGeneratedSources(
    workspace: workspace,
    sources: generated.sources,
    targetOf: (GeneratedSource s) => top.absolute(
      top
          .files(s.generator, 'default')
          .firstWhere(
            (String f) => workspacePath(f) == s.path,
            orElse: () => s.output,
          ),
    ),
    skip: skip,
    state: state,
  );
  state.save();
  if (generators.isNotEmpty) {
    stderr.writeln(
      'flutter_dev: generated sources are linked from Bazel. After editing an input of '
      '${generators.join(' ')}, run `${bazel.executable} build ${bazel.mode == Mode.debug ? '-c dbg ' : ''}'
      '${generators.join(' ')}`, then hot reload.',
    );
  }
  if (ownL10n && generated.stockGenerators.isNotEmpty) {
    stderr.writeln(
      'flutter_dev: this project has l10n.yaml, so the stock tool runs gen-l10n itself, '
      'at start and before each reload, into the source tree.',
    );
  }

  if (options.command == 'ide') {
    return _ide(options, self, projectDir, target, tool);
  }

  // 3. Hand over.
  final bool restart =
      options.autoRestart &&
      options.mode == Mode.debug &&
      !options.noHot &&
      !options.web;
  final args = <String>[...options.globalArgs, options.command!];
  if (options.command == 'run') {
    if (!options.hasOption('--pub') && !options.hasOption('--no-pub')) {
      args.add('--no-pub');
    }
    if (!options.web) {
      args.addAll(<String>[
        '--use-application-binary',
        _appBinary(out, target),
      ]);
    }
  }
  String? pidFile;
  if (!options.machine && restart && !Platform.isWindows) {
    pidFile = _option(options.commandArgs, '--pid-file');
    if (pidFile == null) {
      pidFile = '$projectDir/$toolDir/flutter.pid';
      args.addAll(<String>['--pid-file', pidFile]);
    }
    final f = File(pidFile);
    if (f.existsSync()) f.deleteSync();
  }
  args.addAll(options.commandArgs);
  return await (options.machine
      ? runMachine(
          tool.executable,
          args,
          workingDirectory: projectDir,
          restart: restart,
          environment: environment,
          input: input,
          output: output,
        )
      : runTerminal(
          tool.executable,
          args,
          workingDirectory: projectDir,
          pidFile: pidFile,
          restart: restart,
          environment: environment,
        ));
}

int _ide(
  Options options,
  String self,
  String projectDir,
  String target,
  StockTool tool,
) {
  final String installed = installTool(projectDir, self);
  final List<String> flags = options.ownFlags;
  final String launch = const JsonEncoder.withIndent('  ')
      .convert(vscodeLaunch(target: target, flags: flags));
  if (writeNew('$projectDir/.vscode/launch.json', '$launch\n')) {
    stderr.writeln('flutter_dev: wrote .vscode/launch.json');
  } else {
    stderr.writeln(
      'flutter_dev: .vscode/launch.json exists; add these configurations to it:',
    );
    stdout.writeln(launch);
  }
  final String name = target.replaceAll(RegExp('[^A-Za-z0-9_.-]+'), '_');
  final runConfig = '.run/flutter_dev$name.run.xml';
  if (writeNew(
    '$projectDir/$runConfig',
    intellijRunConfiguration(target: target, flags: flags),
  )) {
    stderr.writeln('flutter_dev: wrote $runConfig');
  }
  final String shim = writeSdkShim(
    projectDir: projectDir,
    tool: installed,
    flutterRoot: tool.root,
    flags: flags,
  );
  stderr.writeln(
    'flutter_dev: IntelliJ and Android Studio: set the Flutter SDK path of this project to $shim; '
    'its bin/flutter is flutter_dev, everything else is ${tool.root}.',
  );
  return 0;
}

/// The application binary the stock tool takes with `--use-application-binary`.
String _appBinary(BuildOutputs out, String target) {
  final List<String> files = out.files(target, 'default');
  final String name = target.substring(target.lastIndexOf(RegExp('[:/]')) + 1);
  for (final suffix in <String>['.apk', '.ipa']) {
    for (final f in files) {
      if (f.endsWith(suffix)) return out.absolute(f);
    }
  }
  for (final f in files) {
    final int app = f.indexOf('.app/');
    if (f.endsWith('.app')) return out.absolute(f);
    if (app >= 0) return out.absolute(f.substring(0, app + 4));
  }
  for (final f in files) {
    if (f.endsWith('.zip')) {
      return out.absolute(f); // a macOS bundle, as rules_apple archives it
    }
  }
  for (final f in files) {
    final String base = f.substring(f.lastIndexOf('/') + 1);
    if (base == name || base == '$name.exe') return out.absolute(f);
  }
  throw UsageException(
    '$target built no app the stock tool can run (an .apk, .ipa, .app, .zip or an executable named $name); '
    'it built: ${files.take(5).join(', ')}${files.length > 5 ? ', ...' : ''}',
  );
}

String? _option(List<String> args, String name) {
  for (var i = 0; i < args.length; i++) {
    if (args[i] == name && i + 1 < args.length) return args[i + 1];
    if (args[i].startsWith('$name=')) return args[i].substring(name.length + 1);
  }
  return null;
}

String _findWorkspace(String from) {
  Directory dir = Directory(from).absolute;
  while (true) {
    for (final marker in <String>[
      'MODULE.bazel',
      'REPO.bazel',
      'WORKSPACE.bazel',
      'WORKSPACE',
    ]) {
      if (File('${dir.path}/$marker').existsSync()) return dir.path;
    }
    if (dir.parent.path == dir.path) {
      throw UsageException(
        '$from is not inside a Bazel workspace (no MODULE.bazel above it).',
      );
    }
    dir = dir.parent;
  }
}
