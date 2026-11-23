/// Every flow of the plan's target table, for the rules and for the stock
/// tools, by id.
library;

import 'dart:io';

import 'package:yaml/yaml.dart';

import '../bazel.dart';
import '../flow.dart';
import '../generate.dart';
import '../proc.dart';
import '../workspace.dart';
import 'analysis.dart';
import 'codegen.dart';
import 'common.dart';
import 'devloop.dart';
import 'device.dart';
import 'pub.dart';

/// Graph sizes and shapes of the analysis flows.
const analysisSizes = [2000, 5000];

/// The small graph the regression check analyses.
const checkGraph = GraphSpec(libraries: 500);

/// The 500,000-line Dart graph: 2,000 libraries of about 250 lines.
final dart500k = GraphSpec(
  libraries: 2000,
  methods: GraphSpec.methodsFor(500000, 2000),
  packageTest: true,
);

/// The 500,000-line Flutter graph.
final flutter500k = GraphSpec(
  libraries: 2000,
  methods: GraphSpec.methodsFor(500000, 2000),
  flutter: true,
);

const _dartTest = 'rules_dart/e2e/dart_test';
const _linux = 'rules_flutter/e2e/linux_example';
const _ffi = 'rules_flutter/e2e/ffi_example';
const _plugins = 'rules_flutter/e2e/android_plugins';

const _mathBody = EditSpec(
  'mathlib/lib/mathlib.dart',
  EditKind.body,
  anchor: 'int factorial(int n) {',
);
const _mathApi = EditSpec('mathlib/lib/mathlib.dart', EditKind.api);
const _leafBody = EditSpec(
  '$leafDir/lib/x.dart',
  EditKind.body,
  anchor: bodyAnchor,
);
const _leafApi = EditSpec('$leafDir/lib/x.dart', EditKind.api);
const _petitEdit = EditSpec(
  'lib/src/matcher/accept.dart',
  EditKind.replace,
  anchor: 'fastParseOn(input, start) >= 0;',
  to: 'fastParseOn(input, start) + 0 * {n} >= 0;',
);
const _flavorsEdit = EditSpec(
  'lib/config.dart',
  EditKind.replace,
  anchor: r"retries=$retries'",
  to: r"retries=$retries r{n}'",
);
const _mainBody = EditSpec(
  'lib/main.dart',
  EditKind.body,
  anchor: 'void main() {',
);
const _definesBody = EditSpec(
  'lib/main_defines.dart',
  EditKind.body,
  anchor: 'void main() {',
);
const _ffiBody = EditSpec(
  'lib/main.dart',
  EditKind.body,
  anchor: 'Future<void> main() async {',
);
const _kotlinApp = EditSpec(
  'android/app/src/main/kotlin/dev/rdf/counter/MainActivity.kt',
  EditKind.kotlin,
);

/// The Kotlin file of the plugin the plugin-edit flows change, below the
/// plugin's root.
const _pluginKotlin =
    'android/src/main/kotlin/io/flutter/plugins/urllauncher/UrlLauncher.kt';

/// The plugin the plugin-edit flows change.
const _plugin = 'url_launcher_android';

/// A copy of an e2e workspace; Android ones import the Android rc file.
WorkspaceFn _e2e(String rel, {bool android = false, String? as}) =>
    (c) async => e2eCopy(
      c.repo,
      c.scratch,
      rel,
      as: as,
      rcLines: [
        ...c.bazelrcLines,
        if (android && c.androidBazelrc != null) 'import ${c.androidBazelrc}',
      ],
    );

/// A stock copy of an e2e workspace (or a corpus project), made once.
WorkspaceFn _stockCopy(String from, {String? name}) => (c) async {
  final src = from.startsWith('/') ? from : '${c.repo}/$from';
  final dir = '${c.scratch}/stock/${name ?? from.split('/').last}';
  if (!File('$dir/.bench-copied').existsSync()) {
    copyTree(src, dir);
    File('$dir/.bench-copied').writeAsStringSync(from);
  }
  return dir;
};

/// A corpus project with its conformance overlay, for the rules.
WorkspaceFn _corpusRules(String project, {bool android = false}) => (c) async {
  final corpus = c.options['corpus'] ?? '/work/rdf/corpus/apps';
  final dir = '${c.scratch}/ws/corpus_$project';
  if (!File('$dir/.bench-copied').existsSync()) {
    copyTree('$corpus/$project', dir);
    _overlay(
      Directory('${c.repo}/rules_dart/tools/conformance/overlays/$project'),
      dir,
    );
    if (project == 'dart_pkg') {
      File('$dir/pubspec.lock.pinned').copySync('$dir/pubspec.lock');
    }
    File('$dir/.bench-copied').writeAsStringSync(project);
  }
  writeBazelrcUser(dir, c.repo, [
    ...c.bazelrcLines,
    if (android && c.androidBazelrc != null) 'import ${c.androidBazelrc}',
  ], flutter: project != 'dart_pkg');
  final rc = File('$dir/.bazelrc');
  if (!rc.existsSync() || !rc.readAsStringSync().contains('.bazelrc.user')) {
    rc.writeAsStringSync(
      'try-import %workspace%/.bazelrc.user\n',
      mode: FileMode.append,
    );
  }
  return dir;
};

void _overlay(Directory from, String to) {
  for (final e in from.listSync(recursive: true, followLinks: false)) {
    if (e is! File) continue;
    final rel = e.path.substring(from.path.length + 1);
    final dst = File('$to/$rel');
    dst.parent.createSync(recursive: true);
    e.copySync(dst.path);
  }
}

/// A corpus project for the stock tools.
WorkspaceFn _corpusStock(String project) => (c) async {
  final corpus = c.options['corpus'] ?? '/work/rdf/corpus/apps';
  final dir = await _stockCopy('$corpus/$project', name: 'corpus_$project')(c);
  if (project == 'dart_pkg')
    File('$dir/pubspec.lock.pinned').copySync('$dir/pubspec.lock');
  return dir;
};

/// The android_plugins copy whose plugin [_plugin] comes from a copy of its
/// repository, so an edit to it is seen (Bazel does not watch fetched
/// repositories). The override goes on the timed command, not in the rc.
Future<String> _pluginOverride(Ctx c) async {
  final ws = await _e2e(
    _plugins,
    android: true,
    as: 'android_plugins_plugin_edit',
  )(c);
  final b = c.bazelIn(ws, 'android.kotlin_plugin');
  await b.must(['build', '--nobuild', '-c', 'dbg', '//:app']);
  final ob = await b.outputBase();
  const repo = 'ai_rules_flutter++android_model+android_model';
  final copy = '${c.scratch}/plugin-repo';
  if (!File('$copy/.bench-copied').existsSync()) {
    await must(Cmd(['cp', '-rL', '$ob/external/$repo', copy], cwd: c.scratch));
    File('$copy/.bench-copied').writeAsStringSync('');
  }
  writeBazelrcUser(ws, c.repo, [
    ...c.bazelrcLines,
    if (c.androidBazelrc != null) 'import ${c.androidBazelrc}',
    'common --override_repository=$repo=$copy',
  ], flutter: true);
  return ws;
}

/// The stock android_plugins copy with [_plugin] overridden to a copy of
/// the pub cache's, so an edit to it is seen.
Future<String> _stockPluginOverride(Ctx c) async {
  final ws = await _stockCopy(_plugins, name: 'android_plugins_plugin_edit')(c);
  final pubspec = File('$ws/pubspec.yaml');
  if (!pubspec.readAsStringSync().contains('dependency_overrides:')) {
    final lock =
        loadYaml(File('$ws/pubspec.lock').readAsStringSync()) as YamlMap;
    final version =
        ((lock['packages'] as YamlMap)[_plugin] as YamlMap)['version'];
    final cache = c.stockVar('PUB_CACHE');
    final copy = '${c.scratch}/stock/$_plugin';
    copyTree('$cache/hosted/pub.dev/$_plugin-$version', copy);
    pubspec.writeAsStringSync(
      'dependency_overrides:\n  $_plugin:\n    path: $copy\n',
      mode: FileMode.append,
    );
  }
  return ws;
}

/// Every flow, in the order a full run measures them.
List<Flow> catalogue() {
  final flows = <Flow>[];

  // Analysis phase, and the actions registered per source file.
  for (final shape in Shape.values) {
    for (final n in analysisSizes) {
      final s = GraphSpec(libraries: n, shape: shape);
      flows
        ..add(AnalysisFlow(s, aspects: false))
        ..add(AnalysisFlow(s, aspects: true))
        ..add(stockAnalyze(s));
    }
  }
  flows
    ..add(AnalysisFlow(checkGraph, aspects: false, tags: const {'cheap'}))
    ..add(AnalysisFlow(checkGraph, aspects: true, tags: const {'cheap'}))
    ..add(PerSourceFlow(test: false))
    ..add(PerSourceFlow(test: true));

  // Dart edit loops.
  BazelFlow dartEdit(
    String id,
    String corpus,
    String state,
    WorkspaceFn ws,
    List<String> targets,
    EditSpec edit,
    Set<String> tags, {
    String command = 'build',
  }) => BazelFlow(
    id: id,
    tool: 'rules_dart',
    corpus: corpus,
    flow: command == 'test' ? 'test_after_edit' : 'kernel_edit',
    state: state,
    tags: tags,
    warm: true,
    workspace: ws,
    command: [command],
    targets: targets,
    edits: [edit],
  );
  flows
    ..add(
      dartEdit(
        'dart.body.small.rules',
        'e2e/dart_test',
        'edit_body',
        _e2e(_dartTest),
        ['//:mathlib_test'],
        _mathBody,
        const {'cheap'},
      ),
    )
    ..add(
      dartEdit(
        'dart.api.small.rules',
        'e2e/dart_test',
        'edit_api',
        _e2e(_dartTest),
        ['//:mathlib_test'],
        _mathApi,
        const {'cheap'},
      ),
    )
    ..add(
      dartEdit(
        'dart.body.500k.rules',
        'gen-${dart500k.name}',
        'edit_body',
        (c) => graphWorkspace(c, dart500k),
        ['//tests:t0_test'],
        _leafBody,
        const {'heavy', '500k'},
      ),
    )
    ..add(
      dartEdit(
        'dart.api.500k.rules',
        'gen-${dart500k.name}',
        'edit_api',
        (c) => graphWorkspace(c, dart500k),
        ['//tests:t0_test'],
        _leafApi,
        const {'heavy', '500k'},
      ),
    )
    ..add(
      dartEdit(
        'dart.test.small.rules',
        'dart_pkg',
        'edit_body',
        _corpusRules('dart_pkg'),
        ['//...'],
        _petitEdit,
        const {},
        command: 'test',
      ),
    )
    ..add(
      StockFlow(
        id: 'dart.test.small.stock',
        corpus: 'dart_pkg',
        flow: 'test_after_edit',
        state: 'edit_body',
        tags: const {'stock'},
        workspace: _corpusStock('dart_pkg'),
        setUpSteps: const [
          ['dart', 'pub', 'get', '--offline'],
        ],
        argv: const ['dart', 'test'],
        edits: const [_petitEdit],
      ),
    )
    ..add(
      dartEdit(
        'dart.test.500k.rules',
        'gen-${dart500k.name}',
        'edit_body',
        (c) => graphWorkspace(c, dart500k),
        ['//tests:all'],
        _leafBody,
        const {'heavy', '500k'},
        command: 'test',
      ),
    )
    ..add(
      StockFlow(
        id: 'dart.test.500k.stock',
        corpus: 'gen-${dart500k.name}-twin',
        flow: 'test_after_edit',
        state: 'edit_body',
        tags: const {'heavy', '500k', 'stock'},
        workspace: (c) => twinWorkspace(c, dart500k),
        cwd: 'tests',
        argv: const ['dart', 'test'],
        edits: const [_leafBody],
      ),
    );

  // Flutter debug app edits.
  BazelFlow flutterEdit(
    String id,
    String corpus,
    WorkspaceFn ws,
    String target,
    EditSpec edit,
    Set<String> tags,
  ) => BazelFlow(
    id: id,
    tool: 'rules_flutter',
    corpus: corpus,
    flow: 'debug_app_edit',
    state: 'edit_body',
    tags: tags,
    warm: true,
    workspace: ws,
    command: const ['build', '-c', 'dbg'],
    targets: [target],
    edits: [edit],
  );
  StockFlow bundle(
    String id,
    String corpus,
    WorkspaceFn ws,
    EditSpec edit, {
    List<String> extra = const [],
    String cwd = '',
    Set<String> tags = const {'stock'},
  }) => StockFlow(
    id: id,
    corpus: corpus,
    flow: 'debug_app_edit',
    state: 'edit_body',
    tags: tags,
    workspace: ws,
    cwd: cwd,
    setUpSteps: [
      if (cwd.isEmpty) ['flutter', 'pub', 'get', '--offline'],
    ],
    argv: ['flutter', 'build', 'bundle', '--debug', ...extra],
    edits: [edit],
  );
  flows
    ..add(
      flutterEdit(
        'flutter.plain.rules',
        'e2e/linux_example',
        _e2e(_linux),
        '//:app_flutter',
        _mainBody,
        const {'cheap'},
      ),
    )
    ..add(
      bundle(
        'flutter.plain.stock',
        'e2e/linux_example',
        _stockCopy(_linux),
        _mainBody,
      ),
    )
    // The rules' app with defines (one with a comma), a defines file and a
    // flavor; stock has no project with those (the e2e one imports a
    // Bazel-only package), so its column is the corpus app with defines.
    ..add(
      flutterEdit(
        'flutter.defines.rules',
        'e2e/linux_example',
        _e2e(_linux),
        '//:app_defines_files',
        _definesBody,
        const {'cheap'},
      ),
    )
    ..add(
      bundle(
        'flutter.defines.stock',
        'flavors_defines',
        _corpusStock('flavors_defines'),
        _flavorsEdit,
        // `flutter build bundle` has no --flavor.
        extra: _flavorDefines,
      ),
    )
    ..add(
      flutterEdit(
        'flutter.defines_corpus.rules',
        'flavors_defines',
        _corpusRules('flavors_defines', android: true),
        '//:app',
        _flavorsEdit,
        const {'android', 'corpus'},
      ),
    )
    ..add(
      flutterEdit(
        'flutter.plugins.rules',
        'e2e/android_plugins',
        _e2e(_plugins, android: true),
        '//:counter',
        _mainBody,
        const {'android'},
      ),
    )
    ..add(
      bundle(
        'flutter.plugins.stock',
        'e2e/android_plugins',
        _stockCopy(_plugins),
        _mainBody,
      ),
    )
    ..add(
      flutterEdit(
        'flutter.native_assets.rules',
        'e2e/ffi_example',
        _e2e(_ffi),
        '//:ffi_linux',
        _ffiBody,
        const {},
      ),
    )
    ..add(
      flutterEdit(
        'flutter.500k.rules',
        'gen-${flutter500k.name}',
        (c) => graphWorkspace(c, flutter500k),
        '//app:app',
        _leafBody,
        const {'heavy', '500k'},
      ),
    )
    ..add(
      bundle(
        'flutter.500k.stock',
        'gen-${flutter500k.name}-twin',
        (c) => twinWorkspace(c, flutter500k),
        _leafBody,
        cwd: 'app',
        tags: const {'heavy', '500k', 'stock'},
      ),
    );

  // Android, against Gradle (`flutter build apk --debug`).
  BazelFlow android(
    String id,
    String state, {
    List<EditSpec> edits = const [],
    WorkspaceFn? ws,
    bool clean = false,
    List<String> cleanArgs = const ['--disk_cache='],
    Set<String> tags = const {'android'},
  }) => BazelFlow(
    id: id,
    tool: 'rules_flutter',
    corpus: 'e2e/android_plugins',
    flow: 'android_debug',
    state: state,
    tags: tags,
    warm: !clean,
    workspace: ws ?? _e2e(_plugins, android: true),
    command: const ['build', '-c', 'dbg'],
    targets: const ['//:app'],
    edits: edits,
    clean: clean,
    cleanArgs: cleanArgs,
    warmUp: !clean,
  );
  StockFlow gradle(
    String id,
    String state, {
    List<EditSpec> edits = const [],
    WorkspaceFn? ws,
    List<List<String>> prepare = const [],
    Set<String> tags = const {'android', 'stock'},
  }) => StockFlow(
    id: id,
    corpus: 'e2e/android_plugins',
    flow: 'android_debug',
    state: state,
    tags: tags,
    workspace: ws ?? _stockCopy(_plugins),
    setUpSteps: const [
      ['flutter', 'pub', 'get', '--offline'],
    ],
    prepareSteps: prepare,
    argv: const ['flutter', 'build', 'apk', '--debug'],
    edits: edits,
  );
  const pluginEdit = EditSpec(
    '../../plugin-repo/pub/hosted/pub.dev/$_plugin-*/$_pluginKotlin',
    EditKind.kotlin,
  );
  const stockPluginEdit = EditSpec(
    '../$_plugin/$_pluginKotlin',
    EditKind.kotlin,
  );
  flows
    ..add(
      android(
        'android.kotlin_app.rules',
        'edit_kotlin_app',
        edits: const [_kotlinApp],
      ),
    )
    ..add(
      gradle(
        'android.kotlin_app.stock',
        'edit_kotlin_app',
        edits: const [_kotlinApp],
      ),
    )
    ..add(
      android(
        'android.kotlin_plugin.rules',
        'edit_kotlin_plugin',
        edits: const [pluginEdit],
        ws: _pluginOverride,
      ),
    )
    ..add(
      gradle(
        'android.kotlin_plugin.stock',
        'edit_kotlin_plugin',
        edits: const [stockPluginEdit],
        ws: _stockPluginOverride,
      ),
    )
    ..add(android('android.dart.rules', 'edit_dart', edits: const [_mainBody]))
    ..add(gradle('android.dart.stock', 'edit_dart', edits: const [_mainBody]))
    ..add(android('android.nochange.rules', 'warm'))
    ..add(gradle('android.nochange.stock', 'warm'))
    ..add(AddPluginFlow(stock: false))
    ..add(AddPluginFlow(stock: true))
    ..add(
      android(
        'android.clean.rules',
        'clean',
        clean: true,
        tags: const {'android', 'heavy'},
      ),
    )
    ..add(
      android(
        'android.clean_all_jobs.rules',
        'clean_all_jobs',
        clean: true,
        cleanArgs: const ['--disk_cache=', '--jobs=HOST_CPUS'],
        tags: const {'android', 'heavy', 'on_request'},
      ),
    )
    ..add(
      gradle(
        'android.clean.stock',
        'clean',
        prepare: const [
          ['flutter', 'clean'],
          ['flutter', 'pub', 'get', '--offline'],
        ],
        tags: const {'android', 'heavy', 'stock'},
      ),
    )
    ..add(
      gradle(
        'android.clean_new_daemon.stock',
        'clean_new_daemon',
        prepare: const [
          ['flutter', 'clean'],
          ['flutter', 'pub', 'get', '--offline'],
          // Stops the daemons of the stock environment's Gradle home, which
          // must be the harness's own (GRADLE_USER_HOME), never a shared one.
          [
            'sh',
            '-c',
            'test -n "\$GRADLE_USER_HOME" && cd android && ./gradlew --stop',
          ],
        ],
        tags: const {'android', 'heavy', 'stock'},
      ),
    )
    ..add(
      BazelFlow(
        id: 'android.warm_cache.rules',
        tool: 'rules_flutter',
        corpus: 'e2e/android_plugins',
        flow: 'android_debug',
        state: 'clean_warm_cache',
        tags: const {'android'},
        workspace: _e2e(_plugins, android: true),
        command: const ['build', '-c', 'dbg'],
        targets: const ['//:app'],
        clean: true,
      ),
    )
    ..add(InstallFlow(stock: false))
    ..add(InstallFlow(stock: true));

  // Code generation, 200 files, against build_runner.
  for (final state in ['cold', 'warm', 'edit']) {
    flows
      ..add(CodegenFlow(state, stock: false))
      ..add(CodegenFlow(state, stock: true));
  }

  // Pub planning through the mirror.
  for (final state in ['cold', 'warm', 'add']) {
    flows.add(PubFlow(state));
  }

  // The dev loop.
  for (final step in ['start', 'reload', 'restart']) {
    flows
      ..add(DevLoopFlow(step, stock: false))
      ..add(DevLoopFlow(step, stock: true));
  }

  // Clean builds of the corpus.
  for (final (project, kind, target, stockArgv, android) in [
    ('counter', 'apk', '//:apk', ['flutter', 'build', 'apk', '--debug'], true),
    ('counter', 'web', '//:web', ['flutter', 'build', 'web'], false),
    (
      'flavors_defines',
      'apk',
      '//:apk',
      [
        'flutter',
        'build',
        'apk',
        '--debug',
        '--flavor',
        'dev',
        ..._flavorDefines,
      ],
      true,
    ),
    (
      'flavors_defines',
      'web',
      '//:web',
      ['flutter', 'build', 'web', ..._flavorDefines],
      false,
    ),
    ('large', 'web', '//:web', ['flutter', 'build', 'web'], false),
    (
      'dart_pkg',
      'exe',
      '//:calc',
      ['dart', 'compile', 'exe', 'example/calc.dart', '-o', 'calc.exe'],
      false,
    ),
  ]) {
    final dart = project == 'dart_pkg';
    flows
      ..add(
        BazelFlow(
          id: 'clean.$project.$kind.rules',
          tool: dart ? 'rules_dart' : 'rules_flutter',
          corpus: project,
          flow: 'clean_build_$kind',
          state: 'cold',
          tags: {'heavy', 'corpus', if (android) 'android'},
          workspace: _corpusRules(project, android: android),
          command: [
            'build',
            if (kind == 'apk') ...['-c', 'dbg'],
          ],
          targets: [target],
          clean: true,
          cleanArgs: const ['--disk_cache='],
          warmUp: false,
        ),
      )
      ..add(
        StockFlow(
          id: 'clean.$project.$kind.stock',
          corpus: project,
          flow: 'clean_build_$kind',
          state: 'cold',
          tags: {'heavy', 'corpus', 'stock', if (android) 'android'},
          workspace: _corpusStock(project),
          prepareSteps: [
            ['rm', '-rf', 'build', '.dart_tool'],
            [dart ? 'dart' : 'flutter', 'pub', 'get', '--offline'],
          ],
          warmUp: false,
          argv: stockArgv,
        ),
      );
  }

  // What this host cannot run.
  for (final (id, tool, flow, reason) in [
    (
      'ios.sim_edit.rules',
      'rules_flutter',
      'ios_debug',
      'no Mac: the iOS simulator flows need Xcode',
    ),
    (
      'ios.sim_edit.stock',
      'stock',
      'ios_debug',
      'no Mac: `flutter build ios` does not exist on Linux',
    ),
    ('ios.swift_edit.rules', 'rules_flutter', 'ios_debug', 'no Mac'),
    ('ios.swift_edit.stock', 'stock', 'ios_debug', 'no Mac'),
    (
      'linux.desktop_edit.stock',
      'stock',
      'linux_debug',
      '`flutter build linux` needs the gtk+-3.0 development files, which this host lacks (system packages are off limits)',
    ),
  ]) {
    flows.add(
      UnavailableFlow(
        id: id,
        tool: tool,
        corpus: '-',
        flow: flow,
        state: '-',
        reason: reason,
      ),
    );
  }
  return flows;
}

const _flavorDefines = [
  '--dart-define=FLAVOR=prod',
  '--dart-define=API_URL=https://api.example.invalid',
  '--dart-define=RETRIES=5',
];

/// Adding one plugin (`device_info_plus`) to the nine-plugin app: the
/// rules pin the Android model again (timed apart, in extra) and build;
/// stock builds after `flutter pub add`.
final class AddPluginFlow extends Flow {
  /// The flow for the rules or for stock.
  AddPluginFlow({required this.stock});

  /// Which side.
  final bool stock;

  @override
  String get id => 'android.add_plugin.${stock ? 'stock' : 'rules'}';
  @override
  String get tool => stock ? 'stock' : 'rules_flutter';
  @override
  String get corpus => 'e2e/android_plugins';
  @override
  String get flow => 'android_debug';
  @override
  String get state => 'add_plugin';
  @override
  bool get warm => !stock;
  @override
  Set<String> get tags => {'android', if (stock) 'stock'};

  static const _files = [
    'pubspec.yaml',
    'pubspec.lock',
    'BUILD.bazel',
    'android_model.json',
  ];
  late String _ws;
  final _saved = <String, String>{};
  Bazel? _b;

  @override
  Bazel? get server => _b;

  @override
  String describe(Ctx c) => stock
      ? 'flutter build apk --debug after `flutter pub add --offline device_info_plus` (untimed), the app built '
            'before without it and the plugin\'s directories under build/ deleted'
      : 'bazel build -c dbg --disk_cache= //:app after `flutter pub add --offline device_info_plus`, `bazel run '
            '//:android_pin` (timed apart: extra.pin_s) and the label added to the app\'s deps, all untimed; the app '
            'built before without it and the plugin\'s outputs under bazel-out deleted';

  Cmd _stockCmd(Ctx c, List<String> a) => c.stock(a, _ws);

  @override
  Future<void> setUp(Ctx c) async {
    _ws = stock
        ? await _stockCopy(_plugins)(c)
        : await _e2e(_plugins, android: true)(c);
    // The originals come from the repository, not from the copy, which a
    // run killed between its edit and its tear-down leaves edited.
    for (final f in _files) {
      final file = File('${c.repo}/$_plugins/$f');
      if (file.existsSync()) _saved[f] = file.readAsStringSync();
    }
    _restore();
    if (!stock) _b = c.bazelIn(_ws, id);
    await must(
      _stockCmd(c, ['flutter', 'pub', 'get', '--offline']),
      log: c.log(id),
    );
  }

  void _restore() {
    for (final MapEntry(:key, :value) in _saved.entries) {
      File('$_ws/$key').writeAsStringSync(value);
    }
  }

  double? _pin;

  /// Deletes what an earlier run built for the added plugin, so every run
  /// builds it as new: its directories under the app's `build/` (Gradle) or
  /// its repositories' under `bazel-out/*/bin/external/` (the timed Bazel
  /// build also leaves the disk cache out).
  void _dropPluginOutputs() {
    final roots = stock
        ? [Directory('$_ws/build')]
        : [
            for (final cfg
                in Directory('$_ws/bazel-out').existsSync()
                    ? Directory('$_ws/bazel-out').listSync()
                    : const <FileSystemEntity>[])
              Directory('${cfg.path}/bin/external'),
          ];
    for (final root in roots) {
      if (!root.existsSync()) continue;
      for (final e in root.listSync(followLinks: false)) {
        final name = e.uri.pathSegments.lastWhere((p) => p.isNotEmpty);
        if (name.startsWith('device_info_plus') ||
            name.contains('deps__device_info_plus')) {
          rmrf(e.path);
        }
      }
    }
  }

  @override
  Future<void> prepare(Ctx c, int run) async {
    _restore();
    final log = c.log(id);
    await must(_stockCmd(c, ['flutter', 'pub', 'get', '--offline']), log: log);
    if (stock) {
      await must(
        _stockCmd(c, ['flutter', 'build', 'apk', '--debug']),
        log: log,
      );
    } else {
      await _b!.must(['build', '-c', 'dbg', '//:app']);
    }
    _dropPluginOutputs();
    await must(
      _stockCmd(c, ['flutter', 'pub', 'add', '--offline', 'device_info_plus']),
      log: log,
    );
    if (!stock) {
      // The pin runs Gradle, which needs the stock environment (Java, the
      // SDK, the Gradle home); Bazel's own client environment stays as it
      // is for every build, so the script is written and run apart.
      final script = '${c.scratch}/android_pin.sh';
      final built = await _b!.must([
        'run',
        '--script_path=$script',
        '//:android_pin',
      ]);
      final pin = await runCmd(_stockCmd(c, [script]), log: log);
      if (!pin.ok) throw StateError('android_pin failed: ${pin.tail()}');
      _pin = (elapsedSeconds(built.stderr) ?? built.seconds) + pin.seconds;
      final build = File('$_ws/BUILD.bazel');
      build.writeAsStringSync(
        build.readAsStringSync().replaceFirst(
          '        "@deps//:camera",\n',
          '        "@deps//:camera",\n        "@deps//:device_info_plus",\n',
        ),
      );
    }
  }

  @override
  Future<Measured> measure(Ctx c, int run) async {
    if (stock) {
      final d = await runCmd(
        _stockCmd(c, ['flutter', 'build', 'apk', '--debug']),
        log: c.log(id),
      );
      if (!d.ok) throw StateError('run ${run + 1} failed: ${d.tail()}');
      return Measured(d.seconds);
    }
    final execLog = '${c.scratch}/logs/$id.exec.json';
    final d = await _b!.run([
      'build',
      '-c',
      'dbg',
      '--disk_cache=',
      '--execution_log_json_file=$execLog',
      '//:app',
    ]);
    if (!d.ok) throw StateError('run ${run + 1} failed: ${d.tail()}');
    return Measured(
      elapsedSeconds(d.stderr) ?? d.seconds,
      mnemonics: mnemonicsOfFile(execLog),
      extra: {'pin_s': _pin},
    );
  }

  @override
  Future<void> tearDown(Ctx c) async {
    _restore();
    await runCmd(
      _stockCmd(c, ['flutter', 'pub', 'get', '--offline']),
      log: c.log(id),
    );
  }
}

/// Installing the app on the emulator after a Dart-only edit: the rules'
/// split install (`//:app_install`) against `adb install -r` of the stock
/// debug APK.
final class InstallFlow extends Flow {
  /// The flow for the rules or for stock.
  InstallFlow({required this.stock});

  /// Which side.
  final bool stock;

  @override
  String get id => 'android.install.${stock ? 'stock' : 'rules'}';
  @override
  String get tool => stock ? 'stock' : 'rules_flutter';
  @override
  String get corpus => 'e2e/android_plugins';
  @override
  String get flow => 'android_install';
  @override
  String get state => 'edit_dart';
  @override
  bool get warm => !stock;
  @override
  Set<String> get tags => {'android', 'emulator', if (stock) 'stock'};

  late String _ws;
  late Emulator _emu;
  Bazel? _b;
  final _edits = Edits();

  @override
  Bazel? get server => _b;

  @override
  String describe(Ctx c) => stock
      ? 'adb install -r build/app/outputs/flutter-apk/app-debug.apk; before each run: ${_mainBody.describe} and flutter build apk --debug (untimed)'
      : 'bazel run -c dbg //:app_install (the splits that changed); before each run: ${_mainBody.describe} and bazel build -c dbg //:app (untimed); time: wall clock of the command (a wait for a build slot of a wrapper counts)';

  @override
  Future<void> setUp(Ctx c) async {
    _emu = await emulator(c);
    _ws = stock
        ? await _stockCopy(_plugins)(c)
        : await _e2e(_plugins, android: true)(c);
    await uninstallApp(c, _emu, c.log(id));
    if (stock) {
      await must(
        c.stock(['flutter', 'pub', 'get', '--offline'], _ws),
        log: c.log(id),
      );
      await must(
        c.stock(['flutter', 'build', 'apk', '--debug'], _ws),
        log: c.log(id),
      );
      await must(
        Cmd(
          [
            'adb',
            'install',
            '-r',
            'build/app/outputs/flutter-apk/app-debug.apk',
          ],
          cwd: _ws,
          env: _emu.env,
        ),
        log: c.log(id),
      );
    } else {
      _b = c.bazelIn(_ws, id);
      await _install(c);
    }
  }

  Future<Done> _install(Ctx c) => runCmd(
    Cmd(
      [...c.bazel, 'run', '-c', 'dbg', '//:app_install'],
      cwd: _ws,
      env: _emu.env,
    ),
    log: c.log(id),
  );

  @override
  Future<void> prepare(Ctx c, int run) async {
    _edits.apply(_ws, _mainBody, c.fresh());
    if (stock) {
      await must(
        c.stock(['flutter', 'build', 'apk', '--debug'], _ws),
        log: c.log(id),
      );
    } else {
      await _b!.must(['build', '-c', 'dbg', '//:app']);
    }
  }

  @override
  Future<Measured> measure(Ctx c, int run) async {
    final d = stock
        ? await runCmd(
            Cmd(
              [
                'adb',
                'install',
                '-r',
                'build/app/outputs/flutter-apk/app-debug.apk',
              ],
              cwd: _ws,
              env: _emu.env,
            ),
            log: c.log(id),
          )
        : await _install(c);
    if (!d.ok) throw StateError('run ${run + 1} failed: ${d.tail()}');
    return Measured(d.seconds);
  }

  @override
  Future<void> tearDown(Ctx c) async => _edits.restore();
}
