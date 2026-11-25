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
/// The first build of one counter target in debug: no cache but the download
/// cache, the output base expunged.
BazelFlow _firstCounter(String kind, String target, {bool android = false}) {
  final id = 'first.counter.$kind.rules';
  return BazelFlow(
    id: id,
    tool: 'rules_flutter',
    corpus: 'counter',
    flow: 'first_build_$kind',
    state: 'no_cache',
    tags: {'heavy', 'corpus', if (android) 'android'},
    workspace: _corpusRules('counter', android: android),
    command: const ['build', '-c', 'dbg'],
    targets: [target],
    clean: true,
    cleanArgs: const ['--disk_cache=', '--repo_contents_cache='],
    extraPrepare: (c, ws, run) =>
        c.bazelIn(ws, id).must(['clean', '--expunge']),
  );
}

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
    // A clean flow builds once untimed too, so every timed run starts with
    // the external repositories fetched and the outputs cleaned.
    warmUp: true,
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
    ..add(AddDependencyFlow.plugin(stock: false))
    ..add(AddDependencyFlow.plugin(stock: true))
    ..add(AddDependencyFlow.dartPackage())
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
          // One untimed build first: the timed runs start with the
          // repositories fetched and the outputs cleaned.
          warmUp: true,
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
          // The same for the stock tools: the Gradle daemon is up and the
          // pub cache filled before the first timed run.
          warmUp: true,
          argv: stockArgv,
        ),
      );
  }

  // The first build on a machine with no cache but the download cache: the
  // output base expunged and the repository contents cache left out, so
  // every repository is extracted again and every action runs.
  flows
    ..add(
      BazelFlow(
        id: 'first.dart_pkg.exe.rules',
        tool: 'rules_dart',
        corpus: 'dart_pkg',
        flow: 'first_build_exe',
        state: 'no_cache',
        tags: const {'heavy', 'corpus'},
        workspace: _corpusRules('dart_pkg'),
        command: const ['build'],
        targets: const ['//:calc'],
        clean: true,
        cleanArgs: const ['--disk_cache=', '--repo_contents_cache='],
        extraPrepare: (c, ws, run) => c
            .bazelIn(ws, 'first.dart_pkg.exe.rules')
            .must(['clean', '--expunge']),
      ),
    )
    // The same first build of the corpus counter app's debug APK and debug
    // Linux app: the Flutter rows of the first-build decision record (S15).
    ..add(_firstCounter('apk', '//:apk', android: true))
    ..add(_firstCounter('linux', '//:linux'))
    // A web edit of the corpus counter app: the dart2js bundle again after a
    // body edit, against stock `flutter build web` after the same edit.
    ..add(
      BazelFlow(
        id: 'web.counter.edit.rules',
        tool: 'rules_flutter',
        corpus: 'counter',
        flow: 'web_edit',
        state: 'edit_body',
        tags: const {'corpus', 'web'},
        workspace: _corpusRules('counter'),
        command: const ['build'],
        targets: const ['//:web'],
        edits: const [_mainBody],
        warm: true,
      ),
    )
    ..add(
      StockFlow(
        id: 'web.counter.edit.stock',
        corpus: 'counter',
        flow: 'web_edit',
        state: 'edit_body',
        tags: const {'corpus', 'web', 'stock'},
        workspace: _corpusStock('counter'),
        setUpSteps: const [
          ['flutter', 'pub', 'get', '--offline'],
        ],
        argv: const ['flutter', 'build', 'web'],
        edits: const [_mainBody],
      ),
    );

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

/// Adding one dependency to an app with `flutter pub add`, then a debug
/// build: `device_info_plus` to the nine-plugin Android app (the rules pin
/// the Android model again, timed apart in extra) against Gradle, and the
/// pure-Dart `equatable` to `e2e/linux_example`.
///
/// Every Bazel command of a rules flow runs with `--disk_cache=`: Bazel does
/// not reuse its local action cache across a change of the disk cache
/// setting (every action it checks misses), so building the state before
/// with the disk cache and timing the state after without it reran every
/// action of the app. Every output of the packages the lock adds is deleted
/// before the timed build, so each run builds them as new. A rules run fails
/// when an action of anything else than the added packages and the app's own
/// targets ran: adding a dependency must not rebuild an untouched package.
final class AddDependencyFlow extends Flow {
  /// Adding [package] to the workspace [corpus] and building [target];
  /// [android] pins the Android model again before the build.
  AddDependencyFlow({
    required this.id,
    required this.stock,
    required this.corpus,
    required this.package,
    required this.target,
    required this.depsAnchor,
    required this.android,
  });

  /// `device_info_plus` into the nine-plugin Android app.
  factory AddDependencyFlow.plugin({required bool stock}) => AddDependencyFlow(
    id: 'android.add_plugin.${stock ? 'stock' : 'rules'}',
    stock: stock,
    corpus: _plugins,
    package: 'device_info_plus',
    target: '//:app',
    depsAnchor: '        "@deps//:camera",\n',
    android: true,
  );

  /// The pure-Dart `equatable` into `e2e/linux_example`'s debug app.
  factory AddDependencyFlow.dartPackage() => AddDependencyFlow(
    id: 'flutter.add_package.rules',
    stock: false,
    corpus: _linux,
    package: 'equatable',
    target: '//:app_flutter',
    depsAnchor: '        "@deps//:flutter",\n',
    android: false,
  );

  @override
  final String id;

  /// Which side.
  final bool stock;

  @override
  final String corpus;

  /// The package `flutter pub add` adds.
  final String package;

  /// The target the timed build builds.
  final String target;

  /// The first line of the app's `deps` the package's label goes after.
  final String depsAnchor;

  /// Whether the app is an Android app with a pinned model.
  final bool android;

  @override
  String get tool => stock ? 'stock' : 'rules_flutter';
  @override
  String get flow => android ? 'android_debug' : 'flutter_debug';
  @override
  String get state => android ? 'add_plugin' : 'add_package';
  @override
  bool get warm => !stock;
  @override
  Set<String> get tags => {
    if (android) 'android' else 'flutter',
    if (stock) 'stock',
  };

  static const _files = [
    'pubspec.yaml',
    'pubspec.lock',
    'BUILD.bazel',
    'android_model.json',
    'analysis_options.yaml',
  ];
  late String _ws;
  final _saved = <String, String>{};
  Bazel? _b;
  Set<String> _added = const {};

  @override
  Bazel? get server => _b;

  @override
  String describe(Ctx c) => stock
      ? 'flutter build apk --debug after `flutter pub add --offline $package` (untimed), the app built '
            'before without it and the added packages\' directories under build/ deleted'
      : 'bazel build -c dbg --disk_cache= $target after `flutter pub add --offline $package`'
            '${android ? ', `bazel run //:android_pin` (timed apart: extra.pin_s)' : ''} and the label added to '
            'the app\'s deps, all untimed and all with --disk_cache=; the app built before without it and the '
            'outputs of every package the lock adds deleted; fails when an action of another package runs';

  Cmd _stockCmd(Ctx c, List<String> a) => c.stock(a, _ws);

  @override
  Future<void> setUp(Ctx c) async {
    _ws = stock
        ? await _stockCopy(corpus)(c)
        : await _e2e(corpus, android: android)(c);
    // The originals come from the repository, not from the copy, which a
    // run killed between its edit and its tear-down leaves edited.
    for (final f in _files) {
      final file = File('${c.repo}/$corpus/$f');
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

  /// Deletes what an earlier run built for the packages the lock adds, so
  /// every run builds them as new: their directories under the app's
  /// `build/` (Gradle), or (Bazel) their repositories' outputs, their
  /// Android libraries' and the app's split of each.
  void _dropAddedOutputs() {
    final roots = stock
        ? [Directory('$_ws/build')]
        : [
            for (final cfg
                in Directory('$_ws/bazel-out').existsSync()
                    ? Directory('$_ws/bazel-out').listSync()
                    : const <FileSystemEntity>[])
              Directory('${cfg.path}/bin'),
          ];
    void drop(Directory dir, bool Function(String) matches, int depth) {
      if (!dir.existsSync()) return;
      for (final e in dir.listSync(followLinks: false)) {
        final name = e.uri.pathSegments.lastWhere((p) => p.isNotEmpty);
        if (matches(name)) {
          rmrf(e.path);
        } else if (depth > 0 && e is Directory) {
          drop(e, matches, depth - 1);
        }
      }
    }

    for (final root in roots) {
      drop(
        root,
        (name) =>
            _added.contains(name) ||
            _added.any(
              (p) => name.endsWith('__$p') || name.contains('p_${p}__'),
            ),
        // bin/, bin/external/, bin/external/<android model repository>/.
        2,
      );
    }
  }

  @override
  Future<void> prepare(Ctx c, int run) async {
    _restore();
    final log = c.log(id);
    await must(_stockCmd(c, ['flutter', 'pub', 'get', '--offline']), log: log);
    final before = File('$_ws/pubspec.lock').readAsStringSync();
    if (stock) {
      await must(
        _stockCmd(c, ['flutter', 'build', 'apk', '--debug']),
        log: log,
      );
    } else {
      await _b!.must(['build', '-c', 'dbg', '--disk_cache=', target]);
    }
    await must(
      _stockCmd(c, ['flutter', 'pub', 'add', '--offline', package]),
      log: log,
    );
    _added = addedPackages(
      before,
      File('$_ws/pubspec.lock').readAsStringSync(),
    );
    if (!_added.contains(package)) {
      throw StateError('`flutter pub add $package` did not add it to the lock');
    }
    _dropAddedOutputs();
    // `flutter pub add` may rewrite these; the build reads them.
    for (final f in ['analysis_options.yaml']) {
      final saved = _saved[f];
      if (saved != null) File('$_ws/$f').writeAsStringSync(saved);
    }
    if (stock) return;
    if (android) {
      // The pin runs Gradle, which needs the stock environment (Java, the
      // SDK, the Gradle home); Bazel's own client environment stays as it
      // is for every build, so the script is written and run apart.
      final script = '${c.scratch}/android_pin.sh';
      final built = await _b!.must([
        'run',
        '--disk_cache=',
        '--script_path=$script',
        '//:android_pin',
      ]);
      final pin = await runCmd(_stockCmd(c, [script]), log: log);
      if (!pin.ok) throw StateError('android_pin failed: ${pin.tail()}');
      _pin = (elapsedSeconds(built.stderr) ?? built.seconds) + pin.seconds;
    }
    final build = File('$_ws/BUILD.bazel');
    final text = build.readAsStringSync();
    if (!text.contains(depsAnchor)) {
      throw StateError('BUILD.bazel has no line "${depsAnchor.trim()}"');
    }
    build.writeAsStringSync(
      text.replaceFirst(depsAnchor, '$depsAnchor        "@deps//:$package",\n'),
    );
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
      target,
    ]);
    if (!d.ok) throw StateError('run ${run + 1} failed: ${d.tail()}');
    final log = File(execLog).readAsStringSync();
    final executed = executedByOwner(log);
    final untouched = untouchedReruns(executed, _added);
    if (untouched.isNotEmpty) {
      throw StateError(
        'adding $package (the lock adds ${(_added.toList()..sort()).join(', ')}) ran '
        '${untouched.length} actions of other packages: ${untouched.take(20).join('; ')}',
      );
    }
    return Measured(
      elapsedSeconds(d.stderr) ?? d.seconds,
      mnemonics: mnemonics(log),
      extra: {
        if (android) 'pin_s': _pin,
        'added': _added.toList()..sort(),
        'executed': executed.values.fold<int>(0, (a, b) => a + b),
        'owners': {
          for (final MapEntry(:key, :value) in executed.entries)
            '${key.owner} ${key.mnemonic}': value,
        },
      },
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

/// The packages the lock [after] has under `packages` and [before] has not.
Set<String> addedPackages(String before, String after) {
  Set<String> names(String lock) {
    final packages = (loadYaml(lock) as Map?)?['packages'];
    return packages is Map ? {for (final k in packages.keys) '$k'} : {};
  }

  return names(after).difference(names(before));
}

/// Whether an action owned by [owner] (a label) may run when a lock adds
/// [added]: one of the app's own targets (the main repository), a target of
/// an added package's repository (`<hub>__<package>`), or an added plugin's
/// Android library (`p_<package>__<variant>`, in the Android model's hub).
bool ownedByAdded(String owner, Set<String> added) {
  final slash = owner.indexOf('//');
  if (slash < 0) return false;
  final repo = owner.substring(0, slash).replaceAll('@', '');
  if (repo.isEmpty) return true;
  final colon = owner.lastIndexOf(':');
  final name = colon > slash ? owner.substring(colon + 1) : '';
  return added.any((p) => repo.endsWith('__$p') || name.startsWith('p_${p}__'));
}

/// The actions of [executed] that adding [added] should not have run, as
/// `<owner> <mnemonic> x<count>`, sorted.
List<String> untouchedReruns(
  Map<({String owner, String mnemonic}), int> executed,
  Set<String> added,
) => [
  for (final MapEntry(:key, :value) in executed.entries)
    if (!ownedByAdded(key.owner, added)) '${key.owner} ${key.mnemonic} x$value',
]..sort();

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
