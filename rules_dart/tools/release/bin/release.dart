/// The decisions of a release of one module of this repository.
///
///     cd rules_dart/tools
///     bazel run //release:release -- <command> [options]
///
/// See `--help`.
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:release/floor.dart';
import 'package:release/git.dart';
import 'package:release/modules.dart';
import 'package:release/release.dart';
import 'package:release/tools.dart';

const _usage = '''
The decisions of a release of one module of this repository.

  bazel run //release:release -- <command> [options]

Commands (each takes --module=rules_dart|rules_flutter)
  latest                 Print the newest released version (`v0.28.3`): the
                         module's baseline, or its newest tag.
  tag --version=vX.Y.Z   Print the tag for that version (`rules_dart-v0.29.0`)
                         when it may be created: a new, newer one. Else exit 1.
  next --to=REV [--published=FILE] [--since=REF]
                         Print the version REV should be released as, when a
                         commit since the newest published release that
                         touches the module carries a `Changelog:` entry other
                         than `skip`. Print nothing when there is none, or
                         when REV is already tagged.
  base --tag=TAG --published=FILE
                         Print the git ref the release notes of TAG start at.
  floor check            Fail, listing the places, when the floor of
                         rules_flutter on ai_rules_dart differs between
                         MODULE.bazel files, tables, docs and README.
  floor set X.Y.Z        Write that floor at all of them.
  tools build --platform=P --out=DIR [--work=DIR] [--bazel=CMD]
                         Build the module's prebuilt tool set twice, in two
                         consumer workspaces of the checkout with no cache,
                         and write tools-P.tar.gz and tools-P.json to DIR. When
                         the two builds differ, write only the sidecar, which
                         says what differed: that platform ships no tools.
                         A failed build exits non-zero.
  tools table --tag=TAG --artifacts=DIR --out=DIR --table=FILE [--download=URL]
                         Gather the tools-*.json sidecars under --artifacts,
                         check each archive against its sidecar, copy it to
                         --out under its release name, and write the table the
                         released module reads to --table. Prints one line for
                         the release notes.

Options
  --published=FILE       The tags that have a published release, one per line;
                         `-` reads them from standard input.
  --root=DIR             The repository root (default: found from the current
                         directory or \$BUILD_WORKING_DIRECTORY).

A commit is the module's when it touches the module's directory; one that
touches both modules belongs to both. The modules are listed in
.github/release.json.
''';

Future<void> main(List<String> args) async {
  if (args.isEmpty || args.first == '--help' || args.first == '-h') {
    stdout.write(_usage);
    return;
  }
  final String command = args.first;
  final rest = <String>[];
  final options = <String, String>{};
  for (final a in args.skip(1)) {
    if (a.startsWith('--') && a.contains('=')) {
      final int i = a.indexOf('=');
      options[a.substring(2, i)] = a.substring(i + 1);
    } else {
      rest.add(a);
    }
  }

  final String root =
      options['root'] ??
      await _gitRoot(
        Platform.environment['BUILD_WORKING_DIRECTORY'] ??
            Platform.environment['BUILD_WORKSPACE_DIRECTORY'] ??
            Directory.current.path,
      );
  try {
    switch (command) {
      case 'floor':
        _floor(root, rest);
      case 'tools':
        await _tools(root, rest, options);
      default:
        await _moduleCommand(command, root, options);
    }
  } on FormatException catch (e) {
    stderr.writeln('release: ${e.message}');
    exit(1);
  } on StateError catch (e) {
    stderr.writeln('release: ${e.message}');
    exit(1);
  }
}

void _floor(String root, List<String> rest) {
  if (rest.length == 1 && rest.first == 'check') {
    final List<String> problems = checkFloor(root);
    if (problems.isEmpty) {
      stdout.writeln(declaredFloor(root));
      return;
    }
    problems.forEach(stderr.writeln);
    stderr.writeln(
      'release: ${problems.length} place(s) disagree; '
      '`bazel run //release:release -- floor set X.Y.Z` writes one floor',
    );
    exit(1);
  }
  if (rest.length == 2 && rest.first == 'set') {
    final List<String> changed = setFloor(root, rest.last);
    stdout.writeln('floor ${rest.last}: changed ${changed.length} file(s)');
    changed.forEach((f) => stdout.writeln('  $f'));
    return;
  }
  stderr.write('usage: floor check | floor set X.Y.Z\n');
  exit(2);
}

Future<void> _moduleCommand(
  String command,
  String root,
  Map<String, String> options,
) async {
  final Map<String, ReleaseModule> modules = parseModules(
    File(p.join(root, '.github', 'release.json')).readAsStringSync(),
  );
  final String? name = options['module'];
  final ReleaseModule? module = modules[name];
  if (module == null) {
    stderr.writeln(
      'release: --module must be one of ${modules.keys.join(', ')}',
    );
    exit(2);
  }
  final List<String> tags = (await git(root, [
    'tag',
    '--list',
  ])).split('\n').where((t) => t.isNotEmpty).toList();

  switch (command) {
    case 'latest':
      stdout.writeln(showVersion(latestVersion(module, tags)));
    case 'tag':
      final String version = options['version'] ?? '';
      final String? problem = tagProblem(module, version, tags);
      if (problem != null) {
        stderr.writeln('release: $problem');
        exit(1);
      }
      stdout.writeln(module.tagOf(parseVersion(version)!));
    case 'base':
      final Version? target = parseVersion(
        _versionOfTag(module, options['tag']),
      );
      if (target == null) {
        stderr.writeln('release: --tag must be a tag of ${module.name}');
        exit(2);
      }
      stdout.writeln(notesBase(module, _published(options), before: target));
    case 'next':
      await _next(root, module, tags, options);
    default:
      stderr.write('release: unknown command "$command"\n$_usage');
      exit(2);
  }
}

String _versionOfTag(ReleaseModule module, String? tag) {
  final Version? v = tag == null ? null : module.versionOfTag(tag);
  return v == null ? '' : showVersion(v);
}

Future<void> _next(
  String root,
  ReleaseModule module,
  List<String> tags,
  Map<String, String> options,
) async {
  final String? to = options['to'];
  if (to == null) {
    stderr.writeln('release: next needs --to=REV');
    exit(2);
  }
  final String pointsAt = await git(root, ['tag', '--points-at', to]);
  if (pointsAt.split('\n').any((t) => module.versionOfTag(t) != null)) {
    stderr.writeln('release: $to is already tagged ($pointsAt)');
    return;
  }
  final String since =
      options['since'] ??
      notesBase(
        module,
        options.containsKey('published') ? _published(options) : tags,
      );
  final List<Commit> commits = await commitsTouching(
    root,
    since,
    to,
    module.name,
  );
  final Version? next = nextVersion(latestVersion(module, tags), commits);
  if (next == null) {
    stderr.writeln(
      'release: no Changelog entry in $since..$to that touches '
      '${module.name} (${commits.length} commits); nothing to release',
    );
    return;
  }
  stdout.writeln(showVersion(next));
}

List<String> _published(Map<String, String> options) {
  final String? file = options['published'];
  if (file == null) {
    stderr.writeln('release: this command needs --published=FILE');
    exit(2);
  }
  final String text = file == '-'
      ? _readStdin()
      : File(file).readAsStringSync();
  return const LineSplitter().convert(text).where((l) => l.isNotEmpty).toList();
}

String _readStdin() {
  final buffer = StringBuffer();
  String? line;
  while ((line = stdin.readLineSync()) != null) {
    buffer.writeln(line);
  }
  return buffer.toString();
}

Future<String> _gitRoot(String from) async {
  final ProcessResult r = await Process.run('git', [
    'rev-parse',
    '--show-toplevel',
  ], workingDirectory: from);
  if (r.exitCode != 0) {
    stderr.writeln('release: $from is not inside a git repository');
    exit(2);
  }
  return (r.stdout as String).trim();
}

ToolSet _toolSet(Map<String, String> options) {
  final ToolSet? set = toolSets[options['module']];
  if (set == null) {
    stderr.writeln('release: tools needs --module=${toolSets.keys.join('|')}');
    exit(2);
  }
  return set;
}

String _option(Map<String, String> options, String name) {
  final String? value = options[name];
  if (value == null || value.isEmpty) {
    stderr.writeln('release: this command needs --$name');
    exit(2);
  }
  return value;
}

Future<void> _tools(
  String root,
  List<String> rest,
  Map<String, String> options,
) async {
  final ToolSet set = _toolSet(options);
  switch (rest.join(' ')) {
    case 'build':
      await _toolsBuild(root, set, options);
    case 'table':
      _toolsTable(set, options);
    default:
      stderr.write('usage: tools build|table --module=M ...\n');
      exit(2);
  }
}

Future<void> _toolsBuild(
  String root,
  ToolSet set,
  Map<String, String> options,
) async {
  final String platform = _option(options, 'platform');
  if (!platforms.contains(platform)) {
    stderr.writeln(
      'release: --platform must be one of ${platforms.join(', ')}',
    );
    exit(2);
  }
  final out = Directory(_option(options, 'out'))..createSync(recursive: true);
  final String bazel = options['bazel'] ?? 'bazel';
  final work = Directory(
    options['work'] ??
        Directory.systemTemp.createTempSync('prebuilt_tools_').path,
  )..createSync(recursive: true);
  final String bazelVersion = File(p.join(root, set.module, '.bazelversion'))
      .readAsStringSync();
  final builds = <SetFiles>[];
  for (final n in [1, 2]) {
    final ws = Directory(p.join(work.path, 'build-$n'))
      ..createSync(recursive: true);
    File(p.join(ws.path, 'MODULE.bazel'))
        .writeAsStringSync(consumerModule(set, root));
    File(p.join(ws.path, 'BUILD.bazel')).writeAsStringSync('');
    File(p.join(ws.path, '.bazelversion')).writeAsStringSync(bazelVersion);
    // No cache: the second build must make every byte again.
    const noCache = ['--disk_cache=', '--remote_cache='];
    await _run(bazel, ['build', ...noCache, set.target], ws.path);
    final String files = await _run(
      bazel,
      ['cquery', ...noCache, '--output=files', set.target],
      ws.path,
      capture: true,
    );
    final set_ = <String, List<int>>{};
    for (final line in const LineSplitter().convert(files)) {
      if (line.trim().isEmpty) continue;
      final int at = line.indexOf('/prebuilt_set/');
      if (at < 0) continue;
      set_[line.substring(at + '/prebuilt_set/'.length)] = File(
        p.isAbsolute(line) ? line : p.join(ws.path, line),
      ).readAsBytesSync();
    }
    if (!set_.containsKey('tools.json')) {
      stderr.writeln('release: build $n of ${set.target} made no tools.json');
      exit(1);
    }
    builds.add(set_);
    await _run(bazel, ['shutdown'], ws.path);
  }
  final Object? manifest = jsonDecode(utf8.decode(builds.first['tools.json']!));
  final Object? version = manifest is Map<String, Object?>
      ? manifest[set.versionKey]
      : null;
  if (version is! String) {
    stderr.writeln('release: tools.json has no ${set.versionKey}');
    exit(1);
  }
  final List<String> problems = differences(builds[0], builds[1]);
  final String base = Sidecar.baseName(platform);
  String? digest;
  if (problems.isEmpty) {
    final List<int> archive = tarGz(builds.first);
    File(p.join(out.path, '$base.tar.gz')).writeAsBytesSync(archive);
    digest = sha256.convert(archive).toString();
    stdout.writeln(
      'tools: ${set.module} $version $platform: ${builds.first.length} files, '
      'reproducible, $digest',
    );
  } else {
    stderr.writeln(
      'tools: ${set.module} $version $platform is not reproducible; it ships '
      'no prebuilt tools:',
    );
    problems.forEach((l) => stderr.writeln('  $l'));
  }
  File(p.join(out.path, '$base.json')).writeAsStringSync(
    Sidecar(
      module: set.module,
      platform: platform,
      version: version,
      sha256: digest,
      problems: problems,
    ).encode(),
  );
}

void _toolsTable(ToolSet set, Map<String, String> options) {
  final String tag = _option(options, 'tag');
  final artifacts = Directory(_option(options, 'artifacts'));
  final out = Directory(_option(options, 'out'))..createSync(recursive: true);
  final String download =
      options['download'] ??
      'https://github.com/${Platform.environment['GITHUB_REPOSITORY'] ?? 'Mivr/ai_rules_dart'}/releases/download';
  final archives = <Sidecar, List<int>?>{};
  final Map<Sidecar, File> files = {};
  if (artifacts.existsSync()) {
    for (final e in artifacts.listSync(recursive: true)) {
      final String name = p.basename(e.path);
      if (e is! File || !name.startsWith('tools-') || !name.endsWith('.json')) {
        continue;
      }
      final s = Sidecar.parse(e.readAsStringSync());
      if (s.module != set.module) continue;
      final archive = File(e.path.replaceFirst(RegExp(r'\.json$'), '.tar.gz'));
      archives[s] = archive.existsSync() ? archive.readAsBytesSync() : null;
      files[s] = archive;
    }
  }
  final result = toolsTable(
    set: set,
    tag: tag,
    download: download,
    archives: archives,
  );
  for (final MapEntry<Sidecar, List<int>?> e in archives.entries) {
    if (e.key.sha256 == null) continue;
    files[e.key]!.copySync(
      p.join(out.path, assetName(tag, e.key.version, e.key.platform)),
    );
  }
  File(_option(options, 'table')).writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(result.table)}\n',
  );
  final shipped = <String>[
    for (final MapEntry<String, Object?> v
        in (result.table['tools']! as Map<String, Object?>).entries)
      for (final String platform in (v.value! as Map<String, Object?>).keys)
        '$platform (${v.key})',
  ];
  stdout.writeln(
    'Prebuilt tools: ${shipped.isEmpty ? 'none' : shipped.join(', ')}.'
    '${result.absent.isEmpty ? '' : ' Built from source on: ${result.absent.join('; ')}.'}',
  );
}

Future<String> _run(
  String exe,
  List<String> args,
  String dir, {
  bool capture = false,
}) async {
  final Process process = await Process.start(
    exe,
    args,
    workingDirectory: dir,
    mode: capture ? ProcessStartMode.normal : ProcessStartMode.inheritStdio,
  );
  final Future<String> out = capture
      ? process.stdout.transform(utf8.decoder).join()
      : Future.value('');
  if (capture) process.stderr.listen(stderr.add);
  final int code = await process.exitCode;
  if (code != 0) {
    stderr.writeln('release: $exe ${args.join(' ')} failed ($code) in $dir');
    exit(1);
  }
  return out;
}
