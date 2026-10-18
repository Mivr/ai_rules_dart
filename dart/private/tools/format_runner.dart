// Build-action runner for the `dart_analyze` aspect's format check: `dart format`
// over a staged project directory.
//
// `dart format` produces no output artifact, but a Bazel action must; this
// runner forwards the formatter's diagnostics and writes the stamp file only
// on success. Pure Dart (no shell) so the action is portable to Windows.
//
// Files are named individually from a manifest rather than by handing the
// formatter the project directory. The staged project also holds the harness
// (stub pubspecs, package_config.json), the target's dependencies and any lint
// ruleset an options file pulls in — none of which are the target's to format.
//
// Supports both one-shot execution (with `@flagfile` expansion) and Bazel's
// `--persistent_worker` binary protobuf protocol over stdin/stdout, running
// `package:dart_style` in-process when the target's language version is
// supported and falling back to the SDK's `dart format` CLI otherwise.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_style/dart_style.dart';
// ignore: implementation_imports
import 'package:dart_style/src/analysis_options/analysis_options_file.dart';
// ignore: implementation_imports
import 'package:dart_style/src/analysis_options/file_system.dart';
// ignore: implementation_imports
import 'package:dart_style/src/analysis_options/io_file_system.dart';
import 'package:package_config/package_config.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';

const _argvBudget = 8000;

List<String> _expandParamFiles(List<String> args) {
  final out = <String>[];
  for (final arg in args) {
    if (arg.startsWith('@')) {
      out.addAll(File(arg.substring(1)).readAsLinesSync());
    } else {
      out.add(arg);
    }
  }
  return out;
}

Future<void> main(List<String> rawArgs) async {
  final args = _expandParamFiles(rawArgs);
  if (args.contains('--persistent_worker')) {
    await _runPersistentWorker();
    exit(0);
  }
  final code = await runFormatRequest(args, outSink: stdout, errSink: stderr);
  if (code != 0) exit(code);
}

Future<void> _runPersistentWorker() async {
  await for (final bytes in _Frames(stdin)) {
    final request = _WorkRequest.read(bytes);
    if (request.cancel) continue;
    final output = StringBuffer();
    var code = 1;
    try {
      final expanded = _expandParamFiles(request.arguments);
      code = await runFormatRequest(expanded, outSink: output, errSink: output);
    } on Object catch (e, st) {
      output
        ..writeln('format_runner: unhandled exception: $e')
        ..writeln(st);
      code = 1;
    }
    stdout.add(
      _WorkResponse(
        exitCode: code,
        output: output.toString(),
        requestId: request.requestId,
      ).write(),
    );
    await stdout.flush();
  }
}

/// The SDK `<major>.<minor>` series whose `dart format` rules match the
/// vendored `package:dart_style`, and the minimum patch within that series.
/// Mirrors `FORMATTER_SDK_SERIES` and `FORMATTER_MIN_SDK_PATCH` in
/// `dart/private/dart_analyze_aspect.bzl`.
const formatterSdkSeries = (3, 13);
const formatterMinSdkPatch = 4;
const formatterMinLanguageVersion = (2, 12);
const formatterMax2xMinor = 19;

final class FormatMode {
  const FormatMode({
    required this.inProcess,
    required this.languageVersion,
    required this.parsedLanguageVersion,
    required this.sdkLanguageVersion,
  });

  final bool inProcess;
  final String languageVersion;
  final Version? parsedLanguageVersion;
  final Version? sdkLanguageVersion;
}

(int, int, int)? _parseSdkVersion(String version) {
  final core = version.split('-').first.split('+').first.split('.');
  if (core.length < 2) return null;
  final major = int.tryParse(core[0]);
  final minor = int.tryParse(core[1]);
  if (major == null || minor == null || major < 0 || minor < 0) return null;
  var patch = 0;
  if (core.length >= 3) {
    final parsedPatch = int.tryParse(core[2]);
    if (parsedPatch == null || parsedPatch < 0) return null;
    patch = parsedPatch;
  }
  return (major, minor, patch);
}

(int, int)? _parseMajorMinor(String version) {
  final parts = version.split('.');
  if (parts.length != 2) return null;
  final major = int.tryParse(parts[0]);
  final minor = int.tryParse(parts[1]);
  if (major == null || minor == null || major < 0 || minor < 0) return null;
  return (major, minor);
}

/// Decides which formatter and language version `format_runner` uses.
///
/// Mirrors `resolve_format_mode` in `dart/private/dart_analyze_aspect.bzl`.
FormatMode resolveFormatMode(String sdkVersion, String languageVersion) {
  final sdk = _parseSdkVersion(sdkVersion);
  if (sdk == null) {
    return FormatMode(
      inProcess: false,
      languageVersion: languageVersion.isEmpty ? 'latest' : languageVersion,
      parsedLanguageVersion: null,
      sdkLanguageVersion: null,
    );
  }
  final (sdkMajor, sdkMinor, sdkPatch) = sdk;
  final sdkLv = Version(sdkMajor, sdkMinor, 0);
  final (int, int) lv;
  final String effectiveLv;
  if (languageVersion.isEmpty || languageVersion == 'latest') {
    lv = (sdkMajor, sdkMinor);
    effectiveLv = '$sdkMajor.$sdkMinor';
  } else {
    final parsed = _parseMajorMinor(languageVersion);
    if (parsed == null) {
      return FormatMode(
        inProcess: false,
        languageVersion: languageVersion,
        parsedLanguageVersion: null,
        sdkLanguageVersion: sdkLv,
      );
    }
    lv = parsed;
    effectiveLv = '${lv.$1}.${lv.$2}';
  }

  final parsedLv = Version(lv.$1, lv.$2, 0);
  final minLv = Version(
    formatterMinLanguageVersion.$1,
    formatterMinLanguageVersion.$2,
    0,
  );
  final sdkMatches =
      (sdkMajor, sdkMinor) == formatterSdkSeries &&
      sdkPatch >= formatterMinSdkPatch;
  final lvValid2x =
      lv.$1 == 2 &&
      lv.$2 >= formatterMinLanguageVersion.$2 &&
      lv.$2 <= formatterMax2xMinor;
  final lvValid3x = lv.$1 == 3 && lv.$2 >= 0 && lv.$2 <= formatterSdkSeries.$2;
  final lvSupported =
      (lvValid2x || lvValid3x) && parsedLv >= minLv && parsedLv <= sdkLv;
  final inProcess = sdkMatches && lvSupported;
  return FormatMode(
    inProcess: inProcess,
    languageVersion: effectiveLv,
    parsedLanguageVersion: inProcess ? parsedLv : null,
    sdkLanguageVersion: sdkLv,
  );
}

String _resolveSdkVersion(String? sdkVersionArg, String? dartPath) {
  if (sdkVersionArg != null && sdkVersionArg.isNotEmpty) {
    return sdkVersionArg;
  }
  if (dartPath != null && dartPath.isNotEmpty) {
    final versionFile = File(
      p.join(File(dartPath).parent.parent.path, 'version'),
    );
    if (versionFile.existsSync()) {
      return versionFile.readAsStringSync().trim();
    }
  }
  return Platform.version.split(' ').first;
}

final _langOverridePattern = RegExp(
  r'^(\s*//\s*@dart\s*=\s*)([0-9]+)\.([0-9]+)',
  multiLine: true,
);

String? _probeForSdkOverride(String text, Version? sdkLanguageVersion) {
  if (sdkLanguageVersion == null) return null;
  final match = _langOverridePattern.firstMatch(text);
  if (match == null) return null;
  final majorStr = match[2]!;
  final minorStr = match[3]!;
  final major = int.tryParse(majorStr);
  final minor = int.tryParse(minorStr);
  if (major == null || minor == null) return null;
  final overrideLv = Version(major, minor, 0);
  if (overrideLv <= sdkLanguageVersion) return null;
  final highMajor = '9' * majorStr.length;
  final highMinor = '9' * minorStr.length;
  return text.replaceRange(
    match.start,
    match.end,
    '${match[1]!}$highMajor.$highMinor',
  );
}

Future<int> runFormatRequest(
  List<String> args, {
  required StringSink outSink,
  required StringSink errSink,
}) async {
  String? dart;
  String? sdkVersion;
  String? project;
  String? manifest;
  String? stamp;
  String? languageVersion;
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg.isEmpty) continue;
    switch (arg) {
      case '--dart':
        dart = args[++i];
      case '--sdk-version':
        sdkVersion = args[++i];
      case '--project':
        project = args[++i];
      case '--manifest':
        manifest = args[++i];
      case '--stamp':
        stamp = args[++i];
      case '--language-version':
        languageVersion = args[++i];
      default:
        errSink.writeln('format_runner: unknown argument $arg');
        return 64;
    }
  }
  if (project == null ||
      manifest == null ||
      stamp == null ||
      languageVersion == null) {
    errSink.writeln(
      'format_runner: --project, --manifest, --stamp, and '
      '--language-version are required',
    );
    return 64;
  }

  final allowedSrcPaths = _pruneOrphanedStagedFiles(project);

  final files = File(manifest)
      .readAsLinesSync()
      .where((l) => l.trim().isNotEmpty)
      .map((l) => _join(project!, l.trim()))
      .toList();
  if (files.isEmpty) {
    errSink.writeln('format_runner: no files listed in manifest $manifest');
    return 1;
  }
  final projectRoot = p.normalize(p.absolute(project));
  final srcRoot = p.normalize(p.join(projectRoot, 'src'));
  if (allowedSrcPaths != null) {
    for (final file in files) {
      final normFile = p.normalize(p.absolute(file));
      if (p.isWithin(srcRoot, normFile) &&
          !allowedSrcPaths.contains(normFile)) {
        errSink.writeln(
          'format_runner: file not listed in src_manifest.txt: $file',
        );
        return 1;
      }
    }
  }

  final resolvedSdkVersion = _resolveSdkVersion(sdkVersion, dart);
  final mode = resolveFormatMode(resolvedSdkVersion, languageVersion);
  final parsedVersion = mode.parsedLanguageVersion;
  if (!mode.inProcess || parsedVersion == null) {
    if (dart != null) {
      return _runSubprocessFallback(
        dart: dart,
        project: project,
        files: files,
        languageVersion: mode.languageVersion,
        stamp: stamp,
        outSink: outSink,
        errSink: errSink,
      );
    }
    errSink.writeln(
      'format_runner: unsupported --language-version "$languageVersion" '
      'for SDK "$resolvedSdkVersion"',
    );
    return 64;
  }

  final outBuf = StringBuffer();
  final errBuf = StringBuffer();
  final fileSystem = _BoundedFileSystem(
    IOFileSystem(),
    srcRoot: srcRoot,
    projectRoot: projectRoot,
  );
  final directoryConfigs = <String, PackageConfig?>{};
  final directoryOptions =
      <
        String,
        ({
          int? pageWidth,
          TrailingCommas? trailingCommas,
          List<String> experimentFlags,
        })
      >{};
  final failedReadPaths = <String>{};

  Future<PackageConfig?> findDirPackageConfig(File file) async {
    final dir = file.parent.path;
    if (directoryConfigs.containsKey(dir)) {
      return directoryConfigs[dir];
    }
    try {
      var current = Directory(p.normalize(p.absolute(dir)));
      while (true) {
        final cfg = await findPackageConfig(current, recurse: false);
        if (cfg != null) {
          return directoryConfigs[dir] = cfg;
        }
        final normCurrent = p.normalize(current.path);
        if (normCurrent == projectRoot) break;
        final parent = current.parent;
        if (p.normalize(parent.path) == normCurrent) break;
        current = parent;
      }
      return directoryConfigs[dir] = null;
    } on Object {
      return directoryConfigs[dir] = null;
    }
  }

  Future<String?> resolvePackageUri(File file, Uri packageUri) async {
    final config = await findDirPackageConfig(file);
    if (config == null) return null;
    return config.resolve(packageUri)?.toFilePath();
  }

  void reportFailedRead(String path) {
    if (failedReadPaths.add(path)) {
      errBuf.writeln('Warning: Couldn\'t read file "$path".');
    }
  }

  Future<
    ({
      int? pageWidth,
      TrailingCommas? trailingCommas,
      List<String> experimentFlags,
    })
  >
  findOptions(File file) async {
    final dir = file.parent.path;
    if (directoryOptions[dir] case final cached?) return cached;
    int? pageWidth;
    TrailingCommas? trailingCommas;
    var experimentFlags = <String>[];
    try {
      final optionsFile = await findAnalysisOptions(
        fileSystem,
        await fileSystem.makePath(file.path),
        reportFailedRead: reportFailedRead,
        resolvePackageUri: (uri) => resolvePackageUri(file, uri),
      );
      if (optionsFile['analyzer'] case Map<Object?, Object?> analyzer) {
        if (analyzer case {'enable-experiment': final experiment?}) {
          switch (experiment) {
            case final String flag:
              experimentFlags = [flag];
            case final List<Object?> flags:
              for (final flag in flags) {
                switch (flag) {
                  case final String flag:
                    experimentFlags.add(flag);
                  default:
                    errBuf.writeln(
                      'Warning: "enable-experiment" option list should contain '
                      'only strings, but contained "$flag".',
                    );
                }
              }
            default:
              errBuf.writeln(
                'Warning: "enable-experiment" option should be a string or '
                'list of strings, but was "$experiment".',
              );
          }
        }
      }
      if (optionsFile['formatter'] case Map<Object?, Object?> formatter) {
        if (formatter case {'page_width': int width}) {
          pageWidth = width;
        }
        if (formatter case {'trailing_commas': var commas}) {
          switch (commas) {
            case 'automate':
              trailingCommas = TrailingCommas.automate;
            case 'preserve':
              trailingCommas = TrailingCommas.preserve;
            default:
              errBuf.writeln(
                'Warning: "trailing_commas" option should be "automate" or '
                '"preserve", but was "$commas".',
              );
          }
        }
      }
    } on PackageResolutionException catch (exception) {
      errBuf.writeln(
        'Warning: Package resolution error when reading '
        '"analysis_options.yaml" file for "${file.path}":\n$exception',
      );
    }
    return directoryOptions[dir] = (
      pageWidth: pageWidth,
      trailingCommas: trailingCommas,
      experimentFlags: experimentFlags,
    );
  }

  final stopwatch = Stopwatch()..start();
  var changedCount = 0;
  var hadError = false;

  for (final path in files) {
    final file = File(path);
    if (!file.existsSync()) {
      errBuf.writeln('No file or directory found at "$path".');
      hadError = true;
      continue;
    }
    final opts = await findOptions(file);
    final formatter = DartFormatter(
      languageVersion: parsedVersion,
      pageWidth: opts.pageWidth ?? DartFormatter.defaultPageWidth,
      trailingCommas: opts.trailingCommas,
      experimentFlags: opts.experimentFlags,
    );
    try {
      final text = file.readAsStringSync();
      final probe = _probeForSdkOverride(text, mode.sdkLanguageVersion);
      if (probe != null) {
        formatter.formatSource(SourceCode(probe, uri: file.path));
      }
      final source = SourceCode(text, uri: file.path);
      final output = formatter.formatSource(source);
      final changed = source.text != output.text;
      if (changed) {
        outBuf.writeln('Changed ${file.path}');
        changedCount++;
      }
    } on FormatterException catch (err) {
      errBuf.writeln(err.message(color: false));
      hadError = true;
    } on UnexpectedOutputException catch (err) {
      errBuf.writeln('''Hit a bug in the formatter when formatting ${file.path}.
$err
Please report at github.com/dart-lang/dart_style/issues.''');
      hadError = true;
    } on Object catch (err, stack) {
      errBuf.writeln('''Hit a bug in the formatter when formatting ${file.path}.
Please report at github.com/dart-lang/dart_style/issues.
$err
$stack''');
      hadError = true;
    }
  }

  stopwatch.stop();
  final time = (stopwatch.elapsedMilliseconds / 1000).toStringAsFixed(2);
  if (files.isEmpty) {
    outBuf.writeln('Formatted no files in $time seconds.');
  } else if (files.length == 1) {
    outBuf.writeln(
      'Formatted 1 file ($changedCount changed) in $time seconds.',
    );
  } else {
    outBuf.writeln(
      'Formatted ${files.length} files ($changedCount changed) in $time seconds.',
    );
  }

  var failed = false;
  final errStr = errBuf.toString();
  final outStr = outBuf.toString();
  errSink.write(_unstage(errStr, project));
  if (changedCount > 0 || hadError) {
    outSink.write(_unstage(outStr, project));
    failed = true;
  }
  if (_warned(errStr)) {
    errSink.writeln(
      'format_runner: `dart format` warned while reading analysis options, '
      'so the check would have run at stock defaults rather than the '
      'configured ones. Fix the options file named above.',
    );
    failed = true;
  }

  if (failed) {
    return 1;
  }
  File(stamp).writeAsStringSync('formatted\n');
  return 0;
}

int _runSubprocessFallback({
  required String dart,
  required String project,
  required List<String> files,
  required String languageVersion,
  required String stamp,
  required StringSink outSink,
  required StringSink errSink,
}) {
  final homeDir = '$stamp.home';
  final env = dart.endsWith('.exe')
      ? <String, String>{'USERPROFILE': homeDir, 'LOCALAPPDATA': homeDir}
      : <String, String>{'HOME': homeDir};
  var failed = false;
  try {
    for (final chunk in _chunks(files)) {
      final result = Process.runSync(
        dart,
        [
          'format',
          '--output=none',
          '--set-exit-if-changed',
          '--language-version=$languageVersion',
          ...chunk,
        ],
        environment: env,
        stdoutEncoding: systemEncoding,
        stderrEncoding: systemEncoding,
      );
      errSink.write(_unstage(result.stderr as String, project));
      if (result.exitCode != 0) {
        outSink.write(_unstage(result.stdout as String, project));
        failed = true;
      }
      if (_warned(result.stderr as String)) {
        errSink.writeln(
          'format_runner: `dart format` warned while reading analysis options, '
          'so the check would have run at stock defaults rather than the '
          'configured ones. Fix the options file named above.',
        );
        failed = true;
      }
    }
  } finally {
    final dir = Directory(homeDir);
    if (dir.existsSync()) {
      try {
        dir.deleteSync(recursive: true);
      } on FileSystemException {
        // Ignore cleanup errors.
      }
    }
  }
  if (failed) return 1;
  File(stamp).writeAsStringSync('formatted\n');
  return 0;
}

Set<String>? _pruneOrphanedStagedFiles(String project) {
  _pruneExtpkgs(project);
  final srcDir = Directory(p.join(project, 'src'));
  if (!srcDir.existsSync()) return null;
  final manifestFile = File(p.join(project, '.dart_tool', 'src_manifest.txt'));
  if (!manifestFile.existsSync()) return null;
  final lines = [
    for (final line in manifestFile.readAsLinesSync())
      if (line.trim().isNotEmpty) line.trim(),
  ];
  if (lines.contains('*')) return null;
  final allowedPaths = <String>{
    for (final line in lines)
      p.normalize(p.absolute(p.join(srcDir.path, line))),
  };
  for (final entity in srcDir.listSync(recursive: true, followLinks: false)) {
    if (entity is Directory) continue;
    final normPath = p.normalize(entity.absolute.path);
    if (!allowedPaths.contains(normPath)) {
      try {
        entity.deleteSync();
      } on FileSystemException {
        // Ignore if read-only or already removed.
      }
    }
  }
  return allowedPaths;
}

void _pruneExtpkgs(String project) {
  final normProject = p.normalize(p.absolute(project));
  if (!normProject.endsWith('.proj')) return;
  final extDir = Directory(
    '${normProject.substring(0, normProject.length - '.proj'.length)}.extpkgs',
  );
  if (!extDir.existsSync()) return;
  final extManifest = File(
    p.join(normProject, '.dart_tool', 'extpkgs_manifest.txt'),
  );
  if (!extManifest.existsSync()) return;

  final allowedFiles = <String>{};
  final allowedDirs = <String>[];
  for (final raw in extManifest.readAsLinesSync()) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) continue;
    if (trimmed.endsWith('/')) {
      allowedDirs.add(p.normalize(p.absolute(p.join(extDir.path, trimmed))));
    } else {
      allowedFiles.add(p.normalize(p.absolute(p.join(extDir.path, trimmed))));
    }
  }
  for (final entity in extDir.listSync(recursive: true, followLinks: false)) {
    if (entity is Directory) continue;
    final normPath = p.normalize(entity.absolute.path);
    final inAllowedDir = allowedDirs.any((dir) => p.isWithin(dir, normPath));
    if (!inAllowedDir && !allowedFiles.contains(normPath)) {
      try {
        entity.deleteSync();
      } on FileSystemException {
        // Ignore if read-only or already removed.
      }
    }
  }
}

/// Wraps [IOFileSystem] so upward directory walks for `analysis_options.yaml`
/// stop at `<project>/src` (or `<project>`) and never escape into the shared
/// Bazel execroot or host filesystem.
final class _BoundedFileSystem implements FileSystem {
  const _BoundedFileSystem(
    this._delegate, {
    required this.srcRoot,
    required this.projectRoot,
  });

  final IOFileSystem _delegate;
  final String srcRoot;
  final String projectRoot;

  Future<IOFileSystemPath> makePath(String path) => _delegate.makePath(path);

  @override
  Future<bool> fileExists(covariant IOFileSystemPath path) =>
      _delegate.fileExists(path);

  @override
  Future<FileSystemPath> join(covariant IOFileSystemPath from, String to) =>
      _delegate.join(from, to);

  @override
  Future<FileSystemPath?> parentDirectory(
    covariant IOFileSystemPath path,
  ) async {
    final norm = p.normalize(p.absolute(path.path));
    if (norm == srcRoot || norm == projectRoot) {
      return null;
    }
    return _delegate.parentDirectory(path);
  }

  @override
  Future<String> readFile(covariant IOFileSystemPath path) =>
      _delegate.readFile(path);
}

String _unstage(String out, String project) {
  final relative = project.replaceAll(r'\', '/');
  final absolute = Directory(project).absolute.path.replaceAll(r'\', '/');
  final normalized = p.normalize(p.absolute(project)).replaceAll(r'\', '/');
  return out
      .replaceAll('$normalized/src/', '')
      .replaceAll('$absolute/src/', '')
      .replaceAll('$relative/src/', '');
}

bool _warned(String err) =>
    const LineSplitter().convert(err).any((l) => l.startsWith('Warning:'));

Iterable<List<String>> _chunks(List<String> files) sync* {
  var current = <String>[];
  var length = 0;
  for (final f in files) {
    if (current.isNotEmpty && length + f.length + 1 > _argvBudget) {
      yield current;
      current = <String>[];
      length = 0;
    }
    current.add(f);
    length += f.length + 1;
  }
  if (current.isNotEmpty) {
    yield current;
  }
}

String _join(String project, String relative) =>
    '${project.replaceAll(r'\', '/')}/$relative';

final class _WorkRequest {
  _WorkRequest({
    required this.arguments,
    required this.inputs,
    required this.requestId,
    required this.cancel,
  });

  factory _WorkRequest.read(Uint8List bytes) {
    final arguments = <String>[];
    final inputs = <String, Uint8List>{};
    var requestId = 0;
    var cancel = false;
    final r = _Reader(bytes);
    while (!r.isDone) {
      final tag = r.varint();
      switch (tag >> 3) {
        case 1:
          arguments.add(r.string());
        case 2:
          final nested = r.submessage();
          var path = '';
          var digest = Uint8List(0);
          while (!nested.isDone) {
            final inputTag = nested.varint();
            switch (inputTag >> 3) {
              case 1:
                path = nested.string();
              case 2:
                digest = Uint8List.fromList(nested.bytes());
              default:
                nested.skip(inputTag & 7);
            }
          }
          if (path.isNotEmpty) {
            inputs[path] = digest;
          }
        case 3:
          requestId = r.varint();
        case 4:
          cancel = r.varint() != 0;
        default:
          r.skip(tag & 7);
      }
    }
    return _WorkRequest(
      arguments: arguments,
      inputs: inputs,
      requestId: requestId,
      cancel: cancel,
    );
  }

  final List<String> arguments;
  final Map<String, Uint8List> inputs;
  final int requestId;
  final bool cancel;
}

final class _WorkResponse {
  const _WorkResponse({
    required this.exitCode,
    required this.output,
    required this.requestId,
  });

  final int exitCode;
  final String output;
  final int requestId;

  Uint8List write() {
    final body = _Writer();
    if (exitCode != 0) {
      body
        ..varint((1 << 3) | 0)
        ..varint(exitCode);
    }
    if (output.isNotEmpty) {
      final utf8Bytes = utf8.encode(output);
      body
        ..varint((2 << 3) | 2)
        ..varint(utf8Bytes.length)
        ..raw(utf8Bytes);
    }
    if (requestId != 0) {
      body
        ..varint((3 << 3) | 0)
        ..varint(requestId);
    }
    final payload = body.takeBytes();
    final frame = _Writer()
      ..varint(payload.length)
      ..raw(payload);
    return frame.takeBytes();
  }
}

final class _Frames extends Stream<Uint8List> {
  _Frames(this._source);

  final Stream<List<int>> _source;

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    final controller = StreamController<Uint8List>();
    var buf = Uint8List(0);
    late final StreamSubscription<List<int>> sub;
    sub = _source.listen(
      (chunk) {
        final merged = Uint8List(buf.length + chunk.length);
        merged.setRange(0, buf.length, buf);
        merged.setRange(buf.length, merged.length, chunk);
        buf = merged;
        while (true) {
          var len = 0;
          var shift = 0;
          var pos = 0;
          while (true) {
            if (pos >= buf.length) return;
            final b = buf[pos++];
            len |= (b & 0x7f) << shift;
            if ((b & 0x80) == 0) break;
            shift += 7;
          }
          if (buf.length < pos + len) return;
          controller.add(
            Uint8List.fromList(Uint8List.sublistView(buf, pos, pos + len)),
          );
          final rem = buf.length - (pos + len);
          buf = rem == 0
              ? Uint8List(0)
              : Uint8List.fromList(Uint8List.sublistView(buf, pos + len));
        }
      },
      onError: controller.addError,
      onDone: controller.close,
      cancelOnError: cancelOnError,
    );
    controller
      ..onPause = sub.pause
      ..onResume = sub.resume
      ..onCancel = sub.cancel;
    return controller.stream.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }
}

final class _Reader {
  _Reader(this._buf);

  final Uint8List _buf;
  int _pos = 0;

  bool get isDone => _pos >= _buf.length;

  int varint() {
    var result = 0;
    var shift = 0;
    while (true) {
      final b = _buf[_pos++];
      result |= (b & 0x7f) << shift;
      if ((b & 0x80) == 0) return result;
      shift += 7;
    }
  }

  Uint8List bytes() {
    final len = varint();
    final slice = Uint8List.sublistView(_buf, _pos, _pos + len);
    _pos += len;
    return slice;
  }

  String string() => utf8.decode(bytes());

  _Reader submessage() => _Reader(bytes());

  void skip(int wireType) {
    switch (wireType) {
      case 0:
        varint();
      case 1:
        _pos += 8;
      case 2:
        _pos += varint();
      case 5:
        _pos += 4;
      default:
        throw FormatException('unsupported wire type: $wireType');
    }
  }
}

final class _Writer {
  final _buf = BytesBuilder(copy: false);

  void varint(int value) {
    var v = value;
    while (v < 0 || v >= 0x80) {
      _buf.addByte((v & 0x7f) | 0x80);
      v = v >>> 7;
    }
    _buf.addByte(v);
  }

  void raw(List<int> bytes) => _buf.add(bytes);

  Uint8List takeBytes() => _buf.takeBytes();
}
