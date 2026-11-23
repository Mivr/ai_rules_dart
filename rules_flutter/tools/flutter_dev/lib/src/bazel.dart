/// Runs `bazel build` with the rules' `flutter_dev_files` aspect and reads what it produced.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_dev/src/build_events.dart';
import 'package:flutter_dev/src/options.dart';
import 'package:flutter_dev/src/repo_name.dart';

/// The rules' repository on the `bazel build` command line: by the canonical name of the
/// repository this tool was built in, so it resolves whatever name the user's workspace gives the
/// rules. Built inside the rules' own workspace that name is empty, and the apparent name is used.
String get _rules =>
    rulesFlutterRepo.isEmpty ? '@rules_flutter' : '@@$rulesFlutterRepo';

/// The aspect that brings the application's files onto disk.
String get devFilesAspect => '$_rules//flutter:dev_files.bzl%flutter_dev_files';

/// The aspect that names the packages below the app's dev dependencies.
String get devPackagesAspect =>
    '$_rules//flutter:dev_files.bzl%flutter_dev_packages';

/// The profile-mode flag of the rules.
String get profileFlag => '--$_rules//flutter:profile';

/// The output group with each application's package config and description.
const String stockDevGroup = 'flutter_stock_dev';

/// The output group with the generated Dart sources and their generators.
const String generatedGroup = 'flutter_stock_dev_generated';

/// The output group of [devPackagesAspect]: one JSON file per package.
const String devPackagesGroup = 'flutter_stock_dev_packages';

/// A `bazel build` the tool runs.
class Bazel {
  /// A build in [workspace] with [executable].
  new({
    required this.executable,
    required this.workspace,
    required this.mode,
    required this.extraArgs,
    required this.terminal,
    required this.environment,
    required this.scratch,
  });

  /// The Bazel client.
  final String executable;

  /// The environment Bazel runs in: this tool's own.
  final Map<String, String> environment;

  /// A directory of the tool's own, for the build event file.
  final String scratch;

  /// The workspace directory Bazel runs in.
  final String workspace;

  /// Debug, profile or release.
  final Mode mode;

  /// `--bazel-arg` values.
  final List<String> extraArgs;

  /// True when the user watches a terminal: Bazel then writes its progress there directly. In
  /// `--machine` mode stdout belongs to the protocol, so Bazel's output goes to stderr.
  final bool terminal;

  List<String> get _modeArgs => switch (mode) {
    Mode.debug => const <String>['-c', 'dbg'],
    Mode.profile => <String>['-c', 'opt', profileFlag],
    Mode.release => const <String>['-c', 'opt'],
  };

  /// Builds [targets] with [aspect] (the `flutter_dev_files` aspect by default), asking for
  /// [groups] (with a `+`, on top of the default outputs, when [withDefault]; no aspect when
  /// [groups] is empty), and returns what the build event file says it produced. Throws a
  /// [BuildFailure] when the build fails.
  Future<BuildOutputs> build(
    List<String> targets, {
    required List<String> groups,
    required bool withDefault,
    String? aspect,
  }) async {
    Directory(scratch).createSync(recursive: true);
    final events = File('$scratch/build_events.json');
    try {
      final args = <String>[
        'build',
        ..._modeArgs,
        if (groups.isNotEmpty) ...<String>[
          '--aspects=${aspect ?? devFilesAspect}',
          '--output_groups=${groups.map((String g) => withDefault ? '+$g' : g).join(',')}',
        ],
        '--build_event_json_file=${events.path}',
        ...extraArgs,
        '--',
        ...targets,
      ];
      stderr.writeln('flutter_dev: $executable ${args.join(' ')}');
      final int code;
      try {
        if (terminal) {
          final Process p = await Process.start(
            executable,
            args,
            workingDirectory: workspace,
            mode: ProcessStartMode.inheritStdio,
            environment: environment,
            includeParentEnvironment: false,
          );
          code = await p.exitCode;
        } else {
          final Process p = await Process.start(
            executable,
            args,
            workingDirectory: workspace,
            environment: environment,
            includeParentEnvironment: false,
          );
          await Future.wait(<Future<void>>[
            p.stdout.forEach(stderr.add),
            p.stderr.forEach(stderr.add),
          ]);
          code = await p.exitCode;
        }
      } on ProcessException catch (e) {
        throw UsageException(
          'cannot start Bazel (`$executable`): ${e.message}. Pass --bazel=<path> or set BAZEL.',
        );
      }
      if (code != 0) throw BuildFailure(code, targets);
      return BuildOutputs.read(events);
    } finally {
      if (events.existsSync()) events.deleteSync();
    }
  }
}

/// A failed `bazel build`.
class BuildFailure implements Exception {
  /// A build of [targets] that exited with [exitCode].
  new(this.exitCode, this.targets);

  /// Bazel's exit code.
  final int exitCode;

  /// What was built.
  final List<String> targets;

  @override
  String toString() =>
      'the build of ${targets.join(' ')} failed (bazel exit code $exitCode); see above';
}

/// What the aspect says about the application below a target.
class AppInfo {
  /// An application description.
  new({
    required this.label,
    required this.package,
    required this.flutterVersion,
    required this.packageConfig,
  });

  /// Reads the one application description among [outputs] of [target].
  factory from(BuildOutputs outputs, String target) {
    final infos = <AppInfo>[
      for (final f in outputs.files(target, stockDevGroup))
        if (f.endsWith('.flutter_stock_dev.json')) AppInfo._read(outputs, f),
    ];
    final labels = <String>{for (final i in infos) i.label};
    if (labels.isEmpty) {
      throw UsageException(
        '$target has no flutter_application below it, so there is no app to run.',
      );
    }
    if (labels.length > 1) {
      throw UsageException(
        '$target has more than one flutter_application below it (${labels.join(', ')}); '
        'name a target with one.',
      );
    }
    return infos.first;
  }

  factory _read(BuildOutputs outputs, String path) {
    final json = jsonDecode(
      File(outputs.absolute(path)).readAsStringSync(),
    ) as Map<String, Object?>;
    return AppInfo(
      label: normalizeLabel(json['label']! as String),
      package: json['package'] as String?,
      flutterVersion: json['flutterVersion'] as String?,
      packageConfig: outputs.absolute(json['packageConfig']! as String),
    );
  }

  /// The `flutter_application` label.
  final String label;

  /// Its Dart package name.
  final String? package;

  /// The Flutter version of the toolchain that built it.
  final String? flutterVersion;

  /// The absolute path of its package config.
  final String packageConfig;
}

/// A generated Dart source the app compiles.
class GeneratedSource {
  /// A generated source at [path], generated by [generator].
  new({
    required this.path,
    required this.generator,
    required this.output,
  });

  /// Its path in the workspace, where the stock tool and the IDE look for it.
  final String path;

  /// The label of the target that generates it.
  final String generator;

  /// The output path (relative to the execution root) the aspect reached it at.
  final String output;
}

/// The generated sources below [target], and the generator labels the stock tool regenerates itself.
({List<GeneratedSource> sources, Set<String> stockGenerators}) generatedSources(
  BuildOutputs outputs,
  String target,
) {
  final List<String> files = outputs.files(target, generatedGroup);
  final owners = <String, String>{};
  final stock = <String>{};
  for (final String f in files.where(
    (String f) => f.endsWith('.flutter_stock_dev_generated.json'),
  )) {
    final json = jsonDecode(
      File(outputs.absolute(f)).readAsStringSync(),
    ) as Map<String, Object?>;
    final sources = json['sources'] as Map<String, Object?>?;
    if (sources != null) {
      sources.forEach(
        (String path, Object? owner) =>
            owners[path] = normalizeLabel(owner! as String),
      );
    }
    if (json['stockGenerator'] != null) {
      stock.add(normalizeLabel(json['label']! as String));
    }
  }
  final result = <GeneratedSource>[];
  for (final String f in files.where((String f) => f.endsWith('.dart'))) {
    final String path = workspacePath(f);
    final String? owner = owners[path];
    if (owner == null || result.any((GeneratedSource s) => s.path == path)) {
      continue;
    }
    result.add(GeneratedSource(path: path, generator: owner, output: f));
  }
  return (sources: result, stockGenerators: stock);
}

/// The workspace path of an output path: `bazel-out/<configuration>/bin/<path>`.
String workspacePath(String output) {
  final List<String> parts = output.split('/');
  if (parts.length > 3 && parts[0] == 'bazel-out' && parts[2] == 'bin') {
    return parts.sublist(3).join('/');
  }
  return output;
}
