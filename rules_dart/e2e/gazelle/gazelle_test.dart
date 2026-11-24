// Runs the Gazelle binary (with the Dart language) over small workspaces it
// builds in temp directories and checks the BUILD files it writes.
//
// Arguments: the gazelle binary's runfiles path, then the runfiles paths of
// the sample sources copied into the first workspace.
import 'dart:io';

import 'package:runfiles/runfiles.dart';

late final String gazelleBin;
var failed = false;

void fail(String message) {
  stdout.writeln('FAIL: $message');
  failed = true;
}

/// A throwaway repository root.
class Workspace {
  Workspace() : root = Directory.systemTemp.createTempSync('gazelle_e2e_');

  final Directory root;

  String path(String rel) => '${root.path}/$rel';

  void write(String rel, String content) {
    final file = File(path(rel));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
  }

  String read(String rel) => File(path(rel)).readAsStringSync();

  bool exists(String rel) => File(path(rel)).existsSync();

  /// `WORKSPACE` and an empty root `BUILD.bazel`, the markers Gazelle needs.
  void markRoot({String build = ''}) {
    write('WORKSPACE', '');
    write('BUILD.bazel', build);
  }

  /// Runs Gazelle on [target] (a path relative to the root; the root when
  /// omitted), with any [extra] flags before it.
  void gazelle({String target = '', List<String> extra = const []}) {
    final result = Process.runSync(gazelleBin, [
      '-lang',
      'dart',
      '-repo_root',
      root.path,
      ...extra,
      target.isEmpty ? root.path : path(target),
    ]);
    if (result.exitCode != 0) {
      fail(
        'gazelle exited ${result.exitCode}\n${result.stdout}${result.stderr}',
      );
    }
  }

  void check(String file, String pattern, String desc) {
    final content = read(file);
    if (content.contains(pattern)) {
      stdout.writeln('PASS: $file contains $desc');
    } else {
      fail(
        '$file missing $desc\n  Contents:\n'
        '${content.split('\n').map((l) => '    $l').join('\n')}',
      );
    }
  }

  void checkAbsent(String file, String pattern, String desc) {
    if (read(file).contains(pattern)) {
      fail('$file: $desc');
    } else {
      stdout.writeln('PASS: $desc');
    }
  }

  void dispose() => root.deleteSync(recursive: true);
}

void main(List<String> args) {
  final runfiles = Runfiles.create();
  gazelleBin = runfiles.rlocation(args[0]);
  final samples = args.skip(1).toList();

  // ---- Basic generation from the sample sources -------------------------
  var w = Workspace();
  for (final rlocation in samples) {
    // `_main/lib/greeter.dart` -> `lib/greeter.dart`.
    final rel = rlocation.substring(rlocation.indexOf('/') + 1);
    w.write(rel, File(runfiles.rlocation(rlocation)).readAsStringSync());
  }
  w.markRoot();
  w.gazelle();

  w.check('lib/BUILD.bazel', 'dart_library', 'dart_library rule');
  for (final src in [
    'greeter.dart',
    'platform_client.dart',
    'stub.dart',
    'io_impl.dart',
    'web_impl.dart',
  ]) {
    w.check('lib/BUILD.bazel', src, '$src in srcs');
  }
  w.check('bin/BUILD.bazel', 'dart_binary', 'dart_binary rule');
  w.check('bin/BUILD.bazel', 'hello.dart', 'hello.dart as main');
  w.check('bin/BUILD.bazel', 'show_import', 'show_import rule (show modifier)');
  w.check(
    'bin/BUILD.bazel',
    'deferred_import',
    'deferred_import rule (deferred modifier)',
  );
  w.check('bin/BUILD.bazel', '//lib', '//lib dep for modifier imports');
  w.check('test/BUILD.bazel', 'dart_test', 'dart_test rule');
  w.check('test/BUILD.bazel', 'greeter_test.dart', 'greeter_test.dart as main');
  w.dispose();
  if (failed) {
    stdout.writeln('SOME TESTS FAILED');
    exit(1);
  }
  stdout.writeln('--- Basic tests passed ---');

  // ---- dart_pub_deps_repo directive -------------------------------------
  w = Workspace();
  w.write('WORKSPACE', '');
  w.write('BUILD.bazel', '# gazelle:dart_pub_deps_repo pub_deps\n');
  w.write('lib/app.dart', '''
import 'package:shelf/shelf.dart';
import 'package:path/path.dart';
void main() {}
''');
  w.write('lib/BUILD.bazel', '');
  w.gazelle();
  w.check('lib/BUILD.bazel', '@pub_deps//:shelf', '@pub_deps//:shelf dep');
  w.check('lib/BUILD.bazel', '@pub_deps//:path', '@pub_deps//:path dep');
  w.dispose();

  // ---- dart_package_name directive emits package_name -------------------
  w = Workspace();
  w.markRoot();
  w.write('lib/BUILD.bazel', '# gazelle:dart_package_name my_app\n');
  w.write('lib/app.dart', "String hello() => 'hello';\n");
  w.gazelle();
  w.check('lib/BUILD.bazel', 'name = "my_app"', 'name = my_app');
  w.check(
    'lib/BUILD.bazel',
    'package_name = "my_app"',
    'package_name = my_app',
  );
  w.dispose();

  // ---- pubspec.yaml auto-detection of the package name ------------------
  w = Workspace();
  w.markRoot();
  w.write('lib/BUILD.bazel', '');
  w.write('pubspec.yaml', 'name: my_server\n');
  w.write('lib/app.dart', "String greet() => 'hi';\n");
  w.gazelle();
  w.check('lib/BUILD.bazel', 'name = "my_server"', 'name = my_server');
  w.check(
    'lib/BUILD.bazel',
    'package_name = "my_server"',
    'package_name = my_server',
  );
  w.dispose();

  // ---- gazelle:resolve directive override -------------------------------
  w = Workspace();
  w.write('WORKSPACE', '');
  w.write(
    'BUILD.bazel',
    '# gazelle:resolve dart shelf //third_party:shelf_custom\n',
  );
  w.write('lib/app.dart', '''
import 'package:shelf/shelf.dart';
import 'package:path/path.dart';
void main() {}
''');
  w.write('lib/BUILD.bazel', '');
  w.gazelle();
  w.check(
    'lib/BUILD.bazel',
    '//third_party:shelf_custom',
    'gazelle:resolve override for shelf',
  );
  w.check('lib/BUILD.bazel', '@path', 'default resolution for path');
  w.dispose();

  // ---- annotated sources get a plain dart_library -----------------------
  // Codegen belongs to `dart_build_runner`, which Gazelle does not emit: an
  // annotated source is an ordinary library source, with no codegen rule, no
  // per-builder macro and no load from `dart/ext` beside it.
  w = Workspace();
  w.markRoot(build: '# gazelle:dart_pub_deps_repo pub_deps\n');
  w.write('pubspec.yaml', 'name: my_models\nenvironment:\n  sdk: ^3.11.0\n');
  w.write('lib/user.dart', '''
import 'package:json_annotation/json_annotation.dart';
part 'user.g.dart';
@JsonSerializable()
class User {
  User({required this.id, required this.name});
  final int id;
  final String name;
}
''');
  w.gazelle();
  w.check(
    'lib/BUILD.bazel',
    'dart_library(',
    'dart_library for annotated source',
  );
  w.check('lib/BUILD.bazel', 'user.dart', 'annotated source in srcs');
  w.check(
    'lib/BUILD.bazel',
    '@pub_deps//:json_annotation',
    'annotation package resolved as a dep',
  );
  for (final emitted in [
    'dart_codegen',
    'dart_aggregate_codegen',
    'json_serializable_library',
    'dart/ext/',
  ]) {
    w.checkAbsent(
      'lib/BUILD.bazel',
      emitted,
      'annotated source emitted $emitted',
    );
  }
  w.dispose();

  // ---- code generation: one dart_build_runner in the package's BUILD ----
  // The builder facts a pub hub writes (`@<hub>//build_runner:builders.json`),
  // cut to source_gen's combining builder and mockito.
  w = Workspace();
  w.markRoot(build: '# gazelle:dart_pub_deps_repo pub_deps\n');
  w.write('facts.json', '''
{"version": 1, "builders": [
  {"key": "mockito:mockBuilder", "package": "mockito", "auto_apply": "dependents",
   "build_to": "source", "build_extensions": {".dart": [".mocks.dart"]},
   "applies_builders": [], "required_inputs": [], "runs_before": [],
   "is_optional": false, "generate_for": {"include": ["test/**"], "exclude": null}},
  {"key": "source_gen:combining_builder", "package": "source_gen", "auto_apply": "none",
   "build_to": "source", "build_extensions": {".dart": [".g.dart"]},
   "applies_builders": [], "required_inputs": [".g.part"], "runs_before": [],
   "is_optional": false, "generate_for": null}
]}
''');
  w.write('pkg/pubspec.yaml', 'name: pkg\n');
  w.write('pkg/lib/src/user.dart', '''
import 'package:json_annotation/json_annotation.dart';
part 'user.g.dart';
''');
  w.write('pkg/test/user_test.dart', '''
import 'package:pkg/src/user.dart';
import 'user_test.mocks.dart';
''');
  final facts = ['-dart_build_runner_facts=facts.json'];
  w.gazelle(extra: facts);
  for (final dir in ['pkg/lib', 'pkg/lib/src', 'pkg/test']) {
    if (w.exists('$dir/BUILD.bazel')) {
      fail('$dir/BUILD.bazel written: the package\'s rules belong next to its pubspec');
    } else {
      stdout.writeln('PASS: no $dir/BUILD.bazel');
    }
  }
  w.check('pkg/BUILD.bazel', 'dart_build_runner(', 'dart_build_runner');
  w.check('pkg/BUILD.bazel', '":lib/src/user.g.dart"', 'generated part in srcs');
  w.check(
    'pkg/BUILD.bazel',
    '":test/user_test.mocks.dart"',
    'generated mocks in the test',
  );
  final firstPkg = w.read('pkg/BUILD.bazel');
  w.gazelle(extra: facts);
  if (w.read('pkg/BUILD.bazel') == firstPkg) {
    stdout.writeln('PASS: second code generation run is a no-op');
  } else {
    fail('second run changed pkg/BUILD.bazel');
  }
  // Switched off: the per-directory rules, and no dart_build_runner.
  w.write('pkg/BUILD.bazel', '# gazelle:dart_build_runner off\n');
  w.gazelle(extra: facts);
  w.check('pkg/lib/src/BUILD.bazel', 'dart_library(', 'per-directory library');
  w.checkAbsent(
    'pkg/BUILD.bazel',
    'dart_build_runner(',
    'dart_build_runner written with generation off',
  );
  w.dispose();

  // ---- analysis options: per-directory targets and the root config ------
  w = Workspace();
  w.markRoot();
  w.write('analysis_options.yaml', 'linter: {rules: {}}\n');
  w.write(
    'tools/analysis_options.yaml',
    'include: package:very_good_analysis/analysis_options.yaml\n',
  );
  w.gazelle();

  w.check(
    'BUILD.bazel',
    'dart_analysis_options(',
    'root dart_analysis_options',
  );
  w.check(
    'tools/BUILD.bazel',
    'name = "analysis_options"',
    'nested options target',
  );
  w.check(
    'tools/BUILD.bazel',
    '"@very_good_analysis"',
    'package: include resolved into deps',
  );
  w.check('BUILD.bazel', 'dart_analysis_config(', 'dart_analysis_config');
  w.check('BUILD.bazel', '":analysis_options",', 'root options listed');
  w.check(
    'BUILD.bazel',
    '"//tools:analysis_options",',
    'nested options listed',
  );

  // A second full run changes nothing (what `gazelle -mode=diff` checks in CI).
  final firstRoot = w.read('BUILD.bazel');
  final firstTools = w.read('tools/BUILD.bazel');
  w.gazelle();
  if (w.read('BUILD.bazel') == firstRoot &&
      w.read('tools/BUILD.bazel') == firstTools) {
    stdout.writeln('PASS: second run is a no-op');
  } else {
    fail('second run changed the BUILD files');
  }

  // Partial runs never drop entries they did not visit, and list nothing
  // outside what they visit.
  w.write('extra/analysis_options.yaml', 'linter: {rules: {}}\n');
  w.gazelle(target: 'tools');
  w.check(
    'BUILD.bazel',
    '"//tools:analysis_options",',
    'nested entry kept by a run on tools/',
  );
  w.gazelle(extra: ['-r=false']);
  w.check(
    'BUILD.bazel',
    '"//tools:analysis_options",',
    'nested entry kept by a root-only run',
  );
  w.checkAbsent(
    'BUILD.bazel',
    '//extra',
    'a run that did not visit extra/ listed it',
  );
  w.gazelle();
  w.check(
    'BUILD.bazel',
    '"//extra:analysis_options",',
    'new directory listed by a full run',
  );

  File(w.path('extra/analysis_options.yaml')).deleteSync();
  w.gazelle();
  w.checkAbsent(
    'BUILD.bazel',
    '//extra',
    'a full run kept the entry of a deleted analysis_options.yaml',
  );

  // Removing every yaml never deletes the config: `.bazelrc` files name it.
  File(w.path('analysis_options.yaml')).deleteSync();
  File(w.path('tools/analysis_options.yaml')).deleteSync();
  w.gazelle();
  w.check(
    'BUILD.bazel',
    'dart_analysis_config(',
    'dart_analysis_config kept with nothing to list',
  );
  w.checkAbsent(
    'BUILD.bazel',
    ':analysis_options',
    'the empty config still lists a removed options target',
  );
  w.dispose();

  if (failed) {
    stdout.writeln('SOME TESTS FAILED');
    exit(1);
  }
  stdout.writeln('All Gazelle e2e tests passed');
}
