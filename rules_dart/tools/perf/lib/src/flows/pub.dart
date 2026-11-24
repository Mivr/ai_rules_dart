/// Pub planning: a 300-package lock planned through a local mirror of the
/// hosted API (never pub.dev), cold, warm, and with one package added.
library;

import 'dart:convert';
import 'dart:io';

import 'package:yaml/yaml.dart';

import '../bazel.dart';
import '../flow.dart';
import '../workspace.dart';
import 'common.dart';

/// The hub's name in the generated workspace.
const pubHub = 'pub300';

/// The package the add flow removes from the lock and adds back. Nothing in
/// the 300-package lock depends on it.
const pubAddedPackage = 'after_layout';

/// The hosted entries of a `pubspec.lock`: name, version, sha256.
List<({String name, String version, String sha256})> hostedEntries(
  String lock,
) {
  final doc = loadYaml(lock) as YamlMap;
  return [
    for (final e in (doc['packages'] as YamlMap).entries)
      if ((e.value as YamlMap)['source'] == 'hosted')
        (
          name: e.key as String,
          version: (e.value as YamlMap)['version'] as String,
          sha256:
              ((e.value as YamlMap)['description'] as YamlMap)['sha256']
                  as String,
        ),
  ];
}

/// [lock] without the entry of [package], cut at the spans the YAML parser
/// reports: from the line of its key to the line of the next key.
String lockWithout(String lock, String package) {
  final packages = (loadYaml(lock) as YamlMap).nodes['packages']! as YamlMap;
  final keys = [for (final k in packages.nodes.keys) k as YamlNode]
    ..sort((a, b) => a.span.start.offset.compareTo(b.span.start.offset));
  final at = keys.indexWhere((k) => k.value == package);
  if (at < 0) throw ArgumentError('$package is not in the lock');
  int lineStart(int offset) => lock.lastIndexOf('\n', offset - 1) + 1;
  final start = lineStart(keys[at].span.start.offset);
  int end;
  if (at + 1 < keys.length) {
    end = lineStart(keys[at + 1].span.start.offset);
  } else {
    end = packages.nodes[keys[at]]!.span.end.offset;
    end = lock.substring(lineStart(end), end).trim().isEmpty
        ? lineStart(end)
        : lock.indexOf('\n', end) + 1;
  }
  return lock.replaceRange(start, end, '');
}

/// Removes the pub extension's recorded result and the facts of [entries]
/// from the lockfile at [path], so the next evaluation plans those packages
/// again.
void dropPubFacts(
  String path,
  List<({String name, String version, String sha256})> entries,
) {
  final f = File(path);
  if (!f.existsSync()) return;
  final doc = jsonDecode(f.readAsStringSync()) as Map<String, Object?>;
  final exts = doc['moduleExtensions'] as Map<String, Object?>? ?? {};
  exts.removeWhere((k, _) => k.endsWith('%pub'));
  final wanted = {
    for (final e in entries) '/hosted/${e.name}/${e.version}/${e.sha256}',
  };
  final facts = doc['facts'] as Map<String, Object?>? ?? {};
  for (final MapEntry(:key, :value) in facts.entries) {
    if (!key.endsWith('%pub')) continue;
    // Keys look like `pub.plan.v1/hosted/<name>/<version>/<sha256>/<url>`.
    (value as Map<String, Object?>).removeWhere(
      (k, _) => wanted.any((w) => k.endsWith(w) || k.contains('$w/')),
    );
  }
  f.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(doc));
}

/// Pub planning of the 300-package lock in `--option=pub_lock=`.
final class PubFlow extends Flow {
  /// The flow in [state]: `cold`, `warm` or `add`.
  PubFlow(this.state);

  @override
  final String state;

  @override
  String get id => 'pub.$state.rules';

  @override
  String get tool => 'rules_dart';

  @override
  String get corpus => 'pub300-mirror';

  @override
  String get flow => 'pub_plan';

  @override
  Set<String> get tags => const {'mirror'};

  late String _ws;
  late String _lock;
  late List<({String name, String version, String sha256})> _entries;
  Bazel? _b;

  @override
  Bazel? get server => _b;

  @override
  String describe(Ctx c) =>
      switch (state) {
        'cold' =>
          'bazel query @$pubHub//:all with the hub\'s facts and the extension entry dropped from both lockfiles '
              'and the archives dropped from the workspace\'s repository cache; time: the profile\'s '
              '"evaluate module extension ...%pub" (query wall in extra)',
        'warm' =>
          'bazel query @$pubHub//:all after a comment is appended to the lock (re-evaluation, all facts known); '
              'time: the profile\'s extension evaluation',
        _ =>
          'bazel build --nobuild of the hub targets of every package whose archive is in the shared repository '
              'cache, plus $pubAddedPackage, after the lock gains $pubAddedPackage (the lock without it planned and '
              'those repositories fetched first, untimed); time: Bazel elapsed; repositories fetched (marker files '
              'changed) in extra',
      } +
      '; lock ${c.options['pub_lock']} through the mirror in .bazelrc.user';

  @override
  Future<void> setUp(Ctx c) async {
    final src = c.options['pub_lock'];
    if (src == null)
      throw const NotAvailable(
        'no --option=pub_lock=<300-package lock on the mirror>',
      );
    _lock = File(src).readAsStringSync();
    _entries = hostedEntries(_lock);
    _ws = '${c.scratch}/gen/pub300';
    Directory(_ws).createSync(recursive: true);
    File('$_ws/MODULE.bazel').writeAsStringSync(
      'module(name = "bench_pub300")\n\n'
      'bazel_dep(name = "ai_rules_dart", version = "0.0.0", repo_name = "rules_dart")\n'
      'local_path_override(module_name = "ai_rules_dart", path = "${c.repo}/rules_dart")\n\n'
      'dart = use_extension("@rules_dart//dart:extensions.bzl", "dart")\n'
      'use_repo(dart, "dart_toolchains")\n'
      'register_toolchains("@dart_toolchains//:all")\n\n'
      'pub = use_extension("@rules_dart//dart/pub:extensions.bzl", "pub")\n'
      'pub.from_lock(name = "$pubHub", lock = "//:pubspec.lock")\n'
      'use_repo(pub, "$pubHub")\n',
    );
    File('$_ws/BUILD.bazel').writeAsStringSync('');
    File('$_ws/.bazelversion').writeAsStringSync('9.3.0\n');
    File('$_ws/.bazelrc')
        .writeAsStringSync('try-import %workspace%/.bazelrc.user\n');
    // Cold and warm plan only, from a repository cache of their own (the
    // cold flow empties it). The add flow fetches repositories, so it uses
    // Bazel's shared repository cache and fetches only the packages whose
    // archives are already there: nothing is downloaded but the added one,
    // from the mirror.
    File('$_ws/.bazelrc.user').writeAsStringSync(
      [
        ...c.bazelrcLines,
        if (state != 'add')
          'common --repository_cache=${c.scratch}/pub-repocache',
        '',
      ].join('\n'),
    );
    File('$_ws/pubspec.lock').writeAsStringSync(
      state == 'add' ? lockWithout(_lock, pubAddedPackage) : _lock,
    );
    _b = c.bazelIn(_ws, id);
    if (state == 'add') {
      final cache = (await _b!.must(['info', 'repository_cache'])).stdout
          .trim();
      _targets = [
        for (final e in _entries)
          if (e.name != pubAddedPackage &&
              Directory('$cache/content_addressable/sha256/${e.sha256}')
                  .existsSync())
            '@$pubHub//:${e.name}',
      ];
      await _b!.must(['build', '--nobuild', ..._targets]);
    } else {
      await _b!.must(['query', '@$pubHub//:all']);
    }
  }

  /// The hub targets the add flow fetches.
  List<String> _targets = const [];

  void _salt(Ctx c, String base) =>
      File('$_ws/pubspec.lock')
          .writeAsStringSync('$base# bench salt ${c.fresh()}\n');

  @override
  Future<void> prepare(Ctx c, int run) async {
    switch (state) {
      case 'cold':
        final ob = await _b!.outputBase();
        dropPubFacts('$_ws/MODULE.bazel.lock', _entries);
        dropPubFacts('$ob/MODULE.bazel.lock', _entries);
        for (final e in _entries) {
          rmrf(
            '${c.scratch}/pub-repocache/content_addressable/sha256/${e.sha256}',
          );
        }
        _salt(c, _lock);
      case 'warm':
        _salt(c, _lock);
      default:
        _salt(c, lockWithout(_lock, pubAddedPackage));
        await _b!.must(['build', '--nobuild', ..._targets]);
        _salt(c, _lock);
    }
  }

  @override
  Future<Measured> measure(Ctx c, int run) async {
    if (state == 'add') {
      final ob = await _b!.outputBase();
      final before = _markers(ob);
      final d = await _b!.run([
        'build',
        '--nobuild',
        ..._targets,
        '@$pubHub//:$pubAddedPackage',
      ]);
      if (!d.ok) throw StateError('run ${run + 1} failed: ${d.tail()}');
      final after = _markers(ob);
      final fetched = after.entries
          .where((e) => before[e.key] != e.value)
          .length;
      return Measured(
        elapsedSeconds(d.stderr) ?? d.seconds,
        extra: {
          'repositories_fetched': fetched,
          'repositories_watched': _targets.length + 1,
        },
      );
    }
    final profile = '${c.scratch}/logs/$id.profile.json.gz';
    final d = await _b!.run(['query', '--profile=$profile', '@$pubHub//:all']);
    if (!d.ok) throw StateError('run ${run + 1} failed: ${d.tail()}');
    return Measured(
      extensionSeconds(profileEvents(profile), 'extensions.bzl%pub'),
      extra: {'query_wall_s': double.parse(d.seconds.toStringAsFixed(3))},
    );
  }

  /// Repository marker files of the output base and their contents' hash.
  Map<String, int> _markers(String ob) {
    final dir = Directory('$ob/external');
    if (!dir.existsSync()) return const {};
    return {
      for (final e in dir.listSync(followLinks: false))
        if (e is File && e.path.endsWith('.marker'))
          e.path: e.readAsStringSync().hashCode,
    };
  }

  @override
  Future<void> tearDown(Ctx c) async {
    if (state != 'cold') File('$_ws/pubspec.lock').writeAsStringSync(_lock);
  }
}
