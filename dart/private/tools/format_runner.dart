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
import 'package:rules_dart_worker/worker_protocol.dart';
import 'package:rules_dart_worker/worker_tool_fs.dart';

const _argvBudget = 8000;

Future<void> main(List<String> rawArgs) async {
  final args = expandParamFiles(rawArgs);
  if (args.contains('--persistent_worker')) {
    await _runPersistentWorker();
    exit(0);
  }
  final code = await runFormatRequest(args, outSink: stdout, errSink: stderr);
  if (code != 0) exit(code);
}

Future<void> _runPersistentWorker() async {
  await for (final bytes in WorkerFrames(stdin)) {
    final request = WorkerRequest.read(bytes);
    if (request.cancel) continue;
    final output = StringBuffer();
    var code = 1;
    try {
      final expanded = expandParamFiles(request.arguments);
      code = await runFormatRequest(expanded, outSink: output, errSink: output);
    } on Object catch (e, st) {
      // A worker must answer every request, so this stays broad; the error
      // goes to the work response and to stderr (Bazel keeps worker stderr
      // in the worker log).
      stderr.writeln('format_runner: unhandled exception: $e');
      stderr.writeln(st);
      output
        ..writeln('format_runner: unhandled exception: $e')
        ..writeln(st);
      code = 1;
    }
    stdout.add(
      WorkerResponse(
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
  final parsed = _parseFormatArgs(args, errSink: errSink);
  if (parsed == null) return 64;
  final project = parsed.project;
  final manifest = parsed.manifest;
  final stamp = parsed.stamp;
  final languageVersion = parsed.languageVersion;

  final allowedSrcPaths = pruneStagedSrcFiles(project);

  final files = _readFormatManifest(
    project: project,
    manifest: manifest,
    allowedSrcPaths: allowedSrcPaths,
    errSink: errSink,
  );
  if (files == null) return 1;
  final projectRoot = p.normalize(p.absolute(project));
  final srcRoot = p.normalize(p.join(projectRoot, 'src'));

  final resolvedSdkVersion = _resolveSdkVersion(parsed.sdkVersion, parsed.dart);
  final mode = resolveFormatMode(resolvedSdkVersion, languageVersion);
  final parsedVersion = mode.parsedLanguageVersion;
  if (!mode.inProcess || parsedVersion == null) {
    if (parsed.dart case final dart?) {
      return _runSubprocessFallback((
        dart: dart,
        project: project,
        files: files,
        languageVersion: mode.languageVersion,
        stamp: stamp,
        outSink: outSink,
        errSink: errSink,
      ));
    }
    errSink.writeln(
      'format_runner: unsupported --language-version "$languageVersion" '
      'for SDK "$resolvedSdkVersion"',
    );
    return 64;
  }

  final outBuf = StringBuffer();
  final errBuf = StringBuffer();
  final session = _FormatSession(
    fileSystem: _BoundedFileSystem(
      IOFileSystem(),
      srcRoot: srcRoot,
      projectRoot: projectRoot,
    ),
    projectRoot: projectRoot,
    errBuf: errBuf,
  );

  final stopwatch = Stopwatch()..start();
  final outcome = await session.formatFiles(
    files,
    parsedVersion: parsedVersion,
    sdkLanguageVersion: mode.sdkLanguageVersion,
    outBuf: outBuf,
  );
  stopwatch.stop();
  return _reportFormatResult((
    project: project,
    stamp: stamp,
    fileCount: files.length,
    changedCount: outcome.changedCount,
    hadError: outcome.hadError,
    elapsedSeconds: (stopwatch.elapsedMilliseconds / 1000).toStringAsFixed(2),
    outBuf: outBuf,
    errBuf: errBuf,
    outSink: outSink,
    errSink: errSink,
  ));
}

/// Parsed `format_runner` command line; null after reporting a bad flag.
typedef _FormatArgs = ({
  String? dart,
  String? sdkVersion,
  String project,
  String manifest,
  String stamp,
  String languageVersion,
});

/// Parses the command line, requiring the project inputs.
_FormatArgs? _parseFormatArgs(
  List<String> args, {
  required StringSink errSink,
}) {
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
        return null;
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
    return null;
  }
  return (
    dart: dart,
    sdkVersion: sdkVersion,
    project: project,
    manifest: manifest,
    stamp: stamp,
    languageVersion: languageVersion,
  );
}

/// The manifest's files, refused when empty or outside the staged sources.
///
/// Returns null after reporting the problem.
List<String>? _readFormatManifest({
  required String project,
  required String manifest,
  required Set<String>? allowedSrcPaths,
  required StringSink errSink,
}) {
  final files = File(manifest)
      .readAsLinesSync()
      .where((l) => l.trim().isNotEmpty)
      .map((l) => _join(project, l.trim()))
      .toList();
  if (files.isEmpty) {
    errSink.writeln('format_runner: no files listed in manifest $manifest');
    return null;
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
        return null;
      }
    }
  }
  return files;
}

/// Per-file formatter options resolved against the staged project.
typedef _FormatOptions = ({
  int? pageWidth,
  TrailingCommas? trailingCommas,
  List<String> experimentFlags,
});

/// Formats one request's files with cached per-directory options.
class _FormatSession {
  _FormatSession({
    required this.fileSystem,
    required this.projectRoot,
    required this.errBuf,
  });

  final _BoundedFileSystem fileSystem;
  final String projectRoot;
  final StringBuffer errBuf;
  final Map<String, PackageConfig?> directoryConfigs = {};
  final Map<String, _FormatOptions> directoryOptions = {};
  final Set<String> failedReadPaths = {};

  /// Formats [files], reporting each file's outcome into [outBuf].
  Future<({int changedCount, bool hadError})> formatFiles(
    List<String> files, {
    required Version parsedVersion,
    required Version? sdkLanguageVersion,
    required StringBuffer outBuf,
  }) async {
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
        final probe = _probeForSdkOverride(text, sdkLanguageVersion);
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
        errBuf.writeln(
          '''Hit a bug in the formatter when formatting ${file.path}.
$err
Please report at github.com/dart-lang/dart_style/issues.''',
        );
        hadError = true;
      } on Object catch (err, stack) {
        errBuf.writeln(
          '''Hit a bug in the formatter when formatting ${file.path}.
Please report at github.com/dart-lang/dart_style/issues.
$err
$stack''',
        );
        hadError = true;
      }
    }
    return (changedCount: changedCount, hadError: hadError);
  }

  /// The nearest `package_config.json` at or above [file]'s directory,
  /// stopping at the staged project root.
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
    } on FileSystemException {
      // An unreadable package config resolves nothing: format without
      // package URIs, as when no config exists.
      return directoryConfigs[dir] = null;
    } on PackageConfigError {
      // An unparsable config (bad JSON, unknown version) resolves nothing
      // either: same fallback. Anything else propagates.
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

  /// The formatter options for [file]'s directory, read once and cached.
  Future<_FormatOptions> findOptions(File file) async {
    final dir = file.parent.path;
    if (directoryOptions[dir] case final cached?) return cached;
    _FormatOptions options = (
      pageWidth: null,
      trailingCommas: null,
      experimentFlags: <String>[],
    );
    try {
      final optionsFile = await findAnalysisOptions(
        fileSystem,
        await fileSystem.makePath(file.path),
        reportFailedRead: reportFailedRead,
        resolvePackageUri: (uri) => resolvePackageUri(file, uri),
      );
      options = (
        pageWidth: options.pageWidth,
        trailingCommas: options.trailingCommas,
        experimentFlags: _experimentFlags(optionsFile['analyzer']),
      );
      final formatterOptions = _formatterSettings(optionsFile['formatter']);
      options = (
        pageWidth: formatterOptions.pageWidth ?? options.pageWidth,
        trailingCommas:
            formatterOptions.trailingCommas ?? options.trailingCommas,
        experimentFlags: options.experimentFlags,
      );
    } on PackageResolutionException catch (exception) {
      errBuf.writeln(
        'Warning: Package resolution error when reading '
        '"analysis_options.yaml" file for "${file.path}":\n$exception',
      );
    }
    return directoryOptions[dir] = options;
  }

  /// The `enable-experiment` flags in an `analyzer` options section.
  List<String> _experimentFlags(Object? analyzer) {
    if (analyzer case Map<Object?, Object?> analyzerMap) {
      if (analyzerMap case {'enable-experiment': final experiment?}) {
        switch (experiment) {
          case final String flag:
            return [flag];
          case final List<Object?> flags:
            final parsed = <String>[];
            for (final flag in flags) {
              switch (flag) {
                case final String flag:
                  parsed.add(flag);
                default:
                  errBuf.writeln(
                    'Warning: "enable-experiment" option list should contain '
                    'only strings, but contained "$flag".',
                  );
              }
            }
            return parsed;
          default:
            errBuf.writeln(
              'Warning: "enable-experiment" option should be a string or '
              'list of strings, but was "$experiment".',
            );
        }
      }
    }
    return <String>[];
  }

  /// The `formatter` options section: page width and trailing commas.
  ({int? pageWidth, TrailingCommas? trailingCommas}) _formatterSettings(
    Object? formatter,
  ) {
    if (formatter case Map<Object?, Object?> formatterMap) {
      int? pageWidth;
      TrailingCommas? trailingCommas;
      if (formatterMap case {'page_width': int width}) {
        pageWidth = width;
      }
      if (formatterMap case {'trailing_commas': var commas}) {
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
      return (pageWidth: pageWidth, trailingCommas: trailingCommas);
    }
    return (pageWidth: null, trailingCommas: null);
  }
}

/// Writes the run's summary and stamp file, returning its exit code.
typedef _FormatReport = ({
  String project,
  String stamp,
  int fileCount,
  int changedCount,
  bool hadError,
  String elapsedSeconds,
  StringBuffer outBuf,
  StringBuffer errBuf,
  StringSink outSink,
  StringSink errSink,
});

/// Writes the run's summary and stamp file, returning its exit code.
int _reportFormatResult(_FormatReport report) {
  final time = report.elapsedSeconds;
  if (report.fileCount == 0) {
    report.outBuf.writeln('Formatted no files in $time seconds.');
  } else if (report.fileCount == 1) {
    report.outBuf.writeln(
      'Formatted 1 file (${report.changedCount} changed) in $time seconds.',
    );
  } else {
    report.outBuf.writeln(
      'Formatted ${report.fileCount} files (${report.changedCount} changed) '
      'in $time seconds.',
    );
  }

  var failed = false;
  final errStr = report.errBuf.toString();
  final outStr = report.outBuf.toString();
  report.errSink.write(_unstage(errStr, report.project));
  if (report.changedCount > 0 || report.hadError) {
    report.outSink.write(_unstage(outStr, report.project));
    failed = true;
  }
  if (_warned(errStr)) {
    report.errSink.writeln(
      'format_runner: `dart format` warned while reading analysis options, '
      'so the check would have run at stock defaults rather than the '
      'configured ones. Fix the options file named above.',
    );
    failed = true;
  }

  if (failed) {
    return 1;
  }
  File(report.stamp).writeAsStringSync('formatted\n');
  return 0;
}

/// A `dart format` CLI fallback invocation for one format request.
typedef _FallbackRequest = ({
  String dart,
  String project,
  List<String> files,
  String languageVersion,
  String stamp,
  StringSink outSink,
  StringSink errSink,
});

int _runSubprocessFallback(_FallbackRequest request) {
  final tempHome = Directory.systemTemp.createTempSync(
    'rules_dart_format_home.',
  );
  final env = <String, String>{
    'HOME': tempHome.path,
    'USERPROFILE': tempHome.path,
    'LOCALAPPDATA': tempHome.path,
    'APPDATA': tempHome.path,
  };
  var failed = false;
  try {
    for (final chunk in _chunks(request.files)) {
      final result = Process.runSync(
        request.dart,
        [
          'format',
          '--output=none',
          '--set-exit-if-changed',
          '--language-version=${request.languageVersion}',
          ...chunk,
        ],
        environment: env,
        stdoutEncoding: systemEncoding,
        stderrEncoding: systemEncoding,
      );
      request.errSink.write(_unstage(result.stderr as String, request.project));
      if (result.exitCode != 0) {
        request.outSink.write(
          _unstage(result.stdout as String, request.project),
        );
        failed = true;
      }
      if (_warned(result.stderr as String)) {
        request.errSink.writeln(
          'format_runner: `dart format` warned while reading analysis options, '
          'so the check would have run at stock defaults rather than the '
          'configured ones. Fix the options file named above.',
        );
        failed = true;
      }
    }
  } finally {
    if (tempHome.existsSync()) {
      try {
        tempHome.deleteSync(recursive: true);
      } on FileSystemException {
        // Ignore cleanup errors.
      }
    }
  }
  if (failed) return 1;
  File(request.stamp).writeAsStringSync('formatted\n');
  return 0;
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
