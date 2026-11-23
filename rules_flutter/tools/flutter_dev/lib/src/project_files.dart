/// The files the stock tool and the IDE read from the project: `.dart_tool/package_config.json`,
/// `.dart_tool/package_graph.json`, and the generated sources at their source paths.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_dev/src/bazel.dart';
import 'package:flutter_dev/src/options.dart';

const String _appScheme = 'org-dartlang-app:///';

/// Rewrites the package config Bazel compiled the app with into one the stock tool, the analyzer
/// and the debugger can read: every root a `file:` URI, and `sky_engine` added.
///
/// Bazel's roots are `org-dartlang-app:///<path>` with `<path>` relative to the execution root:
/// `external/<repo>/...` for an external repository (under [outputBase]) and a workspace path
/// otherwise. Workspace packages therefore point at the source tree itself, so an edit is what
/// the stock tool compiles.
Map<String, Object?> idePackageConfig(
  Map<String, Object?> bazelConfig, {
  required String workspace,
  required String outputBase,
  required String flutterRoot,
}) {
  final config = Map<String, Object?>.of(bazelConfig);
  final packages = <Map<String, Object?>>[
    for (final p in (config['packages']! as List<Object?>))
      Map<String, Object?>.of(p! as Map<String, Object?>),
  ];
  for (final p in packages) {
    final root = p['rootUri']! as String;
    if (!root.startsWith(_appScheme)) continue;
    final String rel = root.substring(_appScheme.length);
    p['rootUri'] = Uri.directory(
      rel.startsWith('external/') ? '$outputBase/$rel' : _join(workspace, rel),
    ).toString();
  }
  // The analyzer finds `dart:ui` through `sky_engine`, which pub lists and the compile does not need.
  if (!packages.any((Map<String, Object?> p) => p['name'] == 'sky_engine')) {
    packages.add(<String, Object?>{
      'name': 'sky_engine',
      'rootUri': Uri.directory('$flutterRoot/bin/cache/pkg/sky_engine')
          .toString(),
      'packageUri': 'lib/',
    });
  }
  config['packages'] = packages;
  config['generator'] = 'flutter_dev';
  config['flutterRoot'] = Uri.file(flutterRoot).toString();
  return config;
}

/// The dependency graph pub writes, which the stock tool's plugin discovery walks. A flat graph,
/// the root depending on every package, finds the same plugins: the app's whole closure is what
/// Bazel compiled.
Map<String, Object?> packageGraph(
  Map<String, Object?> packageConfig,
  String rootPackage,
) {
  final names = <String>[
    for (final p in (packageConfig['packages']! as List<Object?>))
      if ((p! as Map<String, Object?>)['name'] case final String n
          when n != rootPackage && n != 'sky_engine')
        n,
  ]..sort();
  return <String, Object?>{
    'roots': <String>[rootPackage],
    'packages': <Object?>[
      <String, Object?>{
        'name': rootPackage,
        'version': '0.0.0',
        'dependencies': names,
        'devDependencies': <String>[],
      },
      for (final n in names)
        <String, Object?>{
          'name': n,
          'version': '0.0.0',
          'dependencies': <String>[],
        },
    ],
    'configVersion': 1,
  };
}

/// Writes [content] to [path] unless it already holds exactly that, so watchers stay quiet.
bool writeIfChanged(String path, String content) {
  final f = File(path);
  if (f.existsSync() && f.readAsStringSync() == content) return false;
  f.parent.createSync(recursive: true);
  f.writeAsStringSync(content);
  return true;
}

/// What the tool remembers between runs, in `.dart_tool/flutter_dev/state.json`.
class State {
  /// A state kept in [file].
  new(this.file, this.generators, this.links);

  /// Reads the state of the project in [projectDir], or an empty one.
  factory load(String projectDir) {
    final file = File('$projectDir/.dart_tool/flutter_dev/state.json');
    var generators = <String, List<String>>{};
    var links = <String>[];
    if (file.existsSync()) {
      try {
        final json =
            jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
        generators = <String, List<String>>{
          for (final e
              in ((json['generators'] as Map<String, Object?>?) ??
                      const <String, Object?>{})
                  .entries)
            e.key: (e.value! as List<Object?>).cast<String>(),
        };
        links = ((json['links'] as List<Object?>?) ?? const <Object?>[])
            .cast<String>();
      } on FormatException {
        // A damaged state only costs one more build.
      }
    }
    return State(file, generators, links);
  }

  /// Where it is kept.
  final File file;

  /// Per `--bazel-target`, the generator labels found last time: the next run builds them in the
  /// same invocation as the app.
  final Map<String, List<String>> generators;

  /// The links the tool made, as workspace paths, so it can remove those no longer generated.
  List<String> links;

  /// Writes it back.
  void save() => writeIfChanged(
    file.path,
    const JsonEncoder.withIndent('  ')
        .convert(<String, Object?>{'generators': generators, 'links': links}),
  );
}

/// Links each generated source at its workspace path, pointing at [targetOf] its path. Sources
/// whose generator the stock tool runs itself ([skip]) are not linked, and a link of ours there is
/// removed so the stock tool can write the file. Links made last time that are no longer wanted
/// are removed. A regular file in the way is replaced only when its bytes equal the output;
/// otherwise the user has to decide.
void linkGeneratedSources({
  required String workspace,
  required List<GeneratedSource> sources,
  required String Function(GeneratedSource) targetOf,
  required Set<String> skip,
  required State state,
}) {
  final wanted = <String>[];
  for (final s in sources) {
    final link = Link(_join(workspace, s.path));
    if (skip.contains(s.generator)) {
      if (state.links.contains(s.path) && link.existsSync()) link.deleteSync();
      continue;
    }
    final String target = targetOf(s);
    wanted.add(s.path);
    if (link.existsSync()) {
      if (link.targetSync() == target) continue;
      link.deleteSync();
    } else if (File(link.path).existsSync()) {
      final f = File(link.path);
      if (!_sameBytes(f, File(target))) {
        throw UsageException(
          '${s.path} is a file in the source tree, and Bazel generates it (${s.generator}). '
          'Remove it, or exclude it from the BUILD file and stop generating it.',
        );
      }
      f.deleteSync();
    }
    link.createSync(target, recursive: true);
  }
  for (final String old in state.links) {
    if (wanted.contains(old)) continue;
    final link = Link(_join(workspace, old));
    if (link.existsSync()) link.deleteSync();
  }
  state.links = wanted;
}

bool _sameBytes(File a, File b) {
  if (!b.existsSync() || a.lengthSync() != b.lengthSync()) return false;
  final Uint8List x = a.readAsBytesSync();
  final Uint8List y = b.readAsBytesSync();
  for (var i = 0; i < x.length; i++) {
    if (x[i] != y[i]) return false;
  }
  return true;
}

String _join(String dir, String rel) => rel.isEmpty ? dir : '$dir/$rel';
