// @dart=3.11
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:coverage/coverage.dart';

/// LCOV collection for `bazel coverage`, used by the `dart_test` launcher.
///
/// Bazel asks a test for coverage by setting `COVERAGE_OUTPUT_FILE` (where the
/// LCOV goes) and, optionally, `COVERAGE_MANIFEST` (the files it instruments).
/// The launcher then starts the VM with [CoverageConfig.vmFlags] and attaches a
/// [CoverageSession]: it reads the VM service URI the VM publishes, collects
/// every isolate as it pauses at exit, lets each one exit, and writes LCOV with
/// function and branch records. The VM keeps the test's own stdio, so what the
/// test prints still reaches test.log even if it hangs until Bazel kills it.
///
/// The pure half, [lcovFromCoverage], takes data and no process: the collected
/// JSON, the map from the source URIs the VM reports to workspace-relative
/// paths (written by `dart_test` as `RULES_DART_COVERAGE_MAP`), and the
/// manifest. A `// coverage:ignore` comment is never honoured, so uncovered
/// code stays visible in the report.

/// How long the VM may take to publish its service URI.
const _serviceUriTimeout = Duration(seconds: 60);

/// How long to keep retrying the connection to the VM service.
const _connectTimeout = Duration(seconds: 30);

/// How long collection may take to finish once the VM has exited.
const _finishTimeout = Duration(seconds: 60);

/// The failure of a coverage run, with the message that names what failed.
class CoverageFailure implements Exception {
  CoverageFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

/// What Bazel asked for and where the pieces are, for one test run.
class CoverageConfig {
  CoverageConfig({
    required this.output,
    required this.uriMapPath,
    required this.manifestPath,
    required this.serviceInfoPath,
  });

  /// The configuration for a run, or `null` when Bazel did not ask for
  /// coverage: `COVERAGE_OUTPUT_FILE` unset or empty.
  ///
  /// [locate] resolves a runfiles path to a file on disk. The map is
  /// mandatory under coverage: without it no `SF:` could be made workspace
  /// relative, so its absence is a [CoverageFailure], not an empty report.
  static CoverageConfig? fromEnvironment(
    Map<String, String> env, {
    required String Function(String) locate,
  }) {
    final String? output = env['COVERAGE_OUTPUT_FILE'];
    if (output == null || output.isEmpty) return null;
    final String? mapKey = env['RULES_DART_COVERAGE_MAP'];
    if (mapKey == null || mapKey.isEmpty) {
      throw CoverageFailure(
        'COVERAGE_OUTPUT_FILE is set but RULES_DART_COVERAGE_MAP is not: '
        'this test was not built by a dart_test that writes a coverage map',
      );
    }
    final String? manifest = env['COVERAGE_MANIFEST'];
    return CoverageConfig(
      output: output,
      uriMapPath: locate(mapKey),
      manifestPath: manifest == null || manifest.isEmpty ? null : manifest,
      // Per process, so a stale file from an earlier run is never read.
      serviceInfoPath:
          '${env['TEST_TMPDIR'] ?? Directory.systemTemp.path}/'
          'rules_dart_vm_service_$pid.json',
    );
  }

  final String output;
  final String uriMapPath;
  final String? manifestPath;
  final String serviceInfoPath;

  /// The VM flags that make the VM collectable: it serves on a free port,
  /// writes the URI it chose to [serviceInfoPath], holds every isolate at exit
  /// until it has been collected, and records branch coverage.
  List<String> get vmFlags => [
    '--pause-isolates-on-exit',
    '--enable-vm-service=0',
    '--branch-coverage',
    '--write-service-info=$serviceInfoPath',
  ];
}

/// The outcome of [lcovFromCoverage]: the LCOV text, a process exit code and
/// the message to print when that code is not zero.
typedef LcovResult = ({String lcov, int exitCode, String? error});

/// Maps collected coverage to LCOV text with workspace-relative `SF:` paths.
///
/// [coverageJson] is `package:coverage`'s `{"coverage": [...]}` collection.
/// [uriMap] maps each source URI the VM reports to the workspace-relative path
/// of its file; a source it does not name (the SDK, `package:test`) is not part
/// of the report. A non-null [manifest] keeps only the files it lists. Every
/// entry of [partial] names an isolate that did not report before the
/// collection: any entry makes the result a failure with no LCOV, since a
/// truncated report must never pass for a complete one. A collection with no
/// entry at all is a failure too, unless it was [scoped] to the packages
/// [packagesToCollect] names: then none of them may simply not have been loaded.
LcovResult lcovFromCoverage({
  required Map<String, dynamic> coverageJson,
  required Map<String, String> uriMap,
  Set<String>? manifest,
  List<String> partial = const [],
  bool scoped = false,
}) {
  if (partial.isNotEmpty) {
    return (
      lcov: '',
      exitCode: 1,
      error: 'partial coverage collection: ${partial.join('; ')}',
    );
  }
  final List<Map<String, dynamic>>? raw = (coverageJson['coverage'] as List?)
      ?.whereType<Map<String, dynamic>>()
      .toList();
  if (raw == null || (raw.isEmpty && !scoped)) {
    return (
      lcov: '',
      exitCode: 1,
      error: 'the VM reported no coverage for any isolate',
    );
  }
  final Map<String, HitMap> hits = HitMap.parseJsonSync(
    raw,
    checkIgnoredLines: false,
    ignoredLinesInFilesCache: {},
    resolver: _IdentityResolver(),
  );
  final byPath = <String, HitMap>{};
  for (final MapEntry<String, HitMap> entry in hits.entries) {
    final String? path = uriMap[entry.key];
    if (path == null) continue;
    if (manifest != null && !manifest.contains(_normalized(path))) continue;
    byPath.merge({path: entry.value});
  }
  return (lcov: _formatLcov(byPath), exitCode: 0, error: null);
}

/// LCOV text for [hits], one record per file in path order.
///
/// Unlike `package:coverage`'s formatter this writes `FNDA:0,<name>` for a
/// function that never ran, so `FNF` and `FNH` agree with the records.
String _formatLcov(Map<String, HitMap> hits) {
  final buffer = StringBuffer();
  for (final String path in hits.keys.toList()..sort()) {
    buffer.writeln('SF:$path');
    _writeFunctions(buffer, hits[path]!);
    _writeLines(buffer, hits[path]!);
    buffer.writeln('end_of_record');
  }
  return buffer.toString();
}

void _writeFunctions(StringBuffer buffer, HitMap map) {
  final Map<int, String>? names = map.funcNames;
  final Map<int, int>? counts = map.funcHits;
  if (names == null || counts == null) return;
  final List<int> lines = names.keys.toList()..sort();
  var hitFunctions = 0;
  for (final line in lines) {
    buffer.writeln('FN:$line,${names[line]}');
  }
  for (final line in lines) {
    final int count = counts[line] ?? 0;
    if (count > 0) hitFunctions++;
    buffer.writeln('FNDA:$count,${names[line]}');
  }
  buffer
    ..writeln('FNF:${lines.length}')
    ..writeln('FNH:$hitFunctions');
}

void _writeLines(StringBuffer buffer, HitMap map) {
  final Map<int, int> lineHits = map.lineHits;
  for (final int line in lineHits.keys.toList()..sort()) {
    buffer.writeln('DA:$line,${lineHits[line]}');
  }
  final int hit = lineHits.values.where((count) => count > 0).length;
  buffer
    ..writeln('LF:${lineHits.length}')
    ..writeln('LH:$hit');
  final Map<int, int>? branches = map.branchHits;
  if (branches == null) return;
  for (final int line in branches.keys.toList()..sort()) {
    buffer.writeln('BRDA:$line,0,0,${branches[line]}');
  }
}

/// The packages worth collecting from the VM.
///
/// Collecting function coverage asks the VM about every function of every
/// library it reports, which for the SDK, `package:test` and the rest of a
/// test's closure takes minutes. The report only has the files [uriMap] names
/// that the [manifest] (when there is one) lists, so only the `package:`
/// libraries of those files are asked for.
Set<String> packagesToCollect(
  Map<String, String> uriMap,
  Set<String>? manifest,
) {
  final packages = <String>{};
  for (final MapEntry<String, String> entry in uriMap.entries) {
    if (!entry.key.startsWith('package:')) continue;
    if (manifest != null && !manifest.contains(_normalized(entry.value))) {
      continue;
    }
    packages.add(entry.key.substring(8).split('/').first);
  }
  return packages;
}

/// Whether the files to report include one that no package owns.
///
/// A collection filtered by package name only reports libraries that belong to
/// one. The test's own entry file, and any source outside a package's `lib/`,
/// is such a library without a package, so the collection must be left
/// unfiltered when the manifest (or, without one, the map) names one.
bool needsEveryLibrary(Map<String, String> uriMap, Set<String>? manifest) {
  final packagedPaths = <String>{
    for (final MapEntry<String, String> entry in uriMap.entries)
      if (entry.key.startsWith('package:')) _normalized(entry.value),
  };
  for (final MapEntry<String, String> entry in uriMap.entries) {
    final String path = _normalized(entry.value);
    if (manifest != null && !manifest.contains(path)) continue;
    if (!packagedPaths.contains(path)) return true;
  }
  return false;
}

/// The paths a `COVERAGE_MANIFEST` lists, normalised for comparison.
Set<String> parseManifest(Iterable<String> lines) => {
  for (final line in lines)
    if (line.trim().isNotEmpty) _normalized(line),
};

/// A path as manifests and the coverage map both spell it: forward slashes, no
/// `./`, and an external repository's `../repo` and `external/repo` alike.
String _normalized(String path) {
  String out = path.trim().replaceAll(r'\', '/');
  while (out.startsWith('./')) {
    out = out.substring(2);
  }
  if (out.startsWith('../')) return out.substring(3);
  return out.startsWith('external/') ? out.substring(9) : out;
}

/// Reads the coverage map `dart_test` wrote: a JSON object of URI to path.
Map<String, String> readUriMap(String path) {
  final Object? decoded;
  try {
    decoded = jsonDecode(File(path).readAsStringSync());
  } on FileSystemException catch (e) {
    throw CoverageFailure('cannot read the coverage map $path: ${e.message}');
  } on FormatException catch (e) {
    throw CoverageFailure('the coverage map $path is not JSON: ${e.message}');
  }
  if (decoded is! Map<String, dynamic>) {
    throw CoverageFailure('the coverage map $path is not a JSON object');
  }
  return {for (final e in decoded.entries) e.key: e.value as String};
}

/// A resolver that returns each source as it is: the keys of the hit maps are
/// already the workspace-relative paths [lcovFromCoverage] puts in `SF:`.
class _IdentityResolver implements Resolver {
  @override
  String? get packagesPath => null;

  @override
  String? get packagePath => null;

  @override
  String? get sdkRoot => null;

  @override
  List<String> get failed => const [];

  @override
  String? resolve(String scriptUri) => scriptUri;

  @override
  String? resolveSymbolicLinks(String path) => path;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A `stderr` that remembers what `package:coverage` reports about isolates.
class _ErrorTap implements Stdout {
  _ErrorTap(this._inner, this.problems);

  final Stdout _inner;
  final List<String> problems;

  @override
  void writeln([Object? object = '']) {
    final line = '$object';
    if (line.startsWith('ERROR:')) problems.add(line);
    _inner.writeln(line);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Everything collected from the VM, or what went wrong collecting it.
typedef _Collected = ({
  Map<String, dynamic>? json,
  List<String> problems,
  _Inputs? inputs,
});

/// The map and manifest a collection is scoped and formatted by.
typedef _Inputs = ({Map<String, String> uriMap, Set<String>? manifest});

/// Reads the coverage map and, when Bazel gave one, the manifest.
_Inputs _readInputs(CoverageConfig config) {
  final String? manifestPath = config.manifestPath;
  return (
    uriMap: readUriMap(config.uriMapPath),
    manifest: manifestPath == null
        ? null
        : parseManifest(_readManifest(manifestPath)),
  );
}

/// The collection of one VM run, started when the VM is.
class CoverageSession {
  CoverageSession._(this._config, this._collected);

  /// Starts collecting from [vm], which must
  /// have been started with [CoverageConfig.vmFlags].
  factory CoverageSession.attach(CoverageConfig config, Process vm) {
    return CoverageSession._(config, _collect(config, vm));
  }

  final CoverageConfig _config;
  final Future<_Collected> _collected;

  /// Writes the LCOV once the VM has exited with [vmCode], and returns the
  /// process exit code: [vmCode] when coverage worked, otherwise non-zero with
  /// a message on stderr naming what failed.
  Future<int> finish(int vmCode) async {
    try {
      return await _finish(vmCode);
    } finally {
      _removeServiceInfo(_config.serviceInfoPath);
    }
  }

  Future<int> _finish(int vmCode) async {
    try {
      final _Collected collected = await _collected.timeout(
        _finishTimeout,
        onTimeout: () => (
          json: null,
          problems: ['collection did not finish after the VM exited'],
          inputs: null,
        ),
      );
      return _write(vmCode, collected);
    } on CoverageFailure catch (e) {
      return _failed(vmCode, e.message);
    }
  }

  int _write(int vmCode, _Collected collected) {
    final Map<String, dynamic>? json = collected.json;
    final _Inputs? inputs = collected.inputs;
    if (json == null || inputs == null) {
      return _failed(vmCode, collected.problems.join('; '));
    }
    final LcovResult result = lcovFromCoverage(
      coverageJson: json,
      uriMap: inputs.uriMap,
      manifest: inputs.manifest,
      partial: collected.problems,
      scoped: true,
    );
    final String? error = result.error;
    if (error != null) return _failed(vmCode, error);
    File(_config.output).writeAsStringSync(result.lcov);
    return vmCode;
  }

  int _failed(int vmCode, String message) {
    stderr.writeln('dart_test: coverage failed: $message');
    return vmCode == 0 ? 1 : vmCode;
  }
}

/// Deletes the VM's service file: scratch the run no longer needs.
void _removeServiceInfo(String path) {
  final file = File(path);
  try {
    if (file.existsSync()) file.deleteSync();
  } on FileSystemException {
    // Best effort: the report no longer depends on this file, and a failure
    // to remove it must not change the run's result.
  }
}

List<String> _readManifest(String path) {
  try {
    return File(path).readAsLinesSync();
  } on FileSystemException catch (e) {
    throw CoverageFailure('cannot read COVERAGE_MANIFEST $path: ${e.message}');
  }
}

/// Collects from [vm]; if that fails, kills it, since a VM paused at exit
/// would otherwise wait for a collector that is gone until Bazel's timeout.
Future<_Collected> _collect(CoverageConfig config, Process vm) async {
  final _Collected collected = await _collectFrom(config, vm.exitCode);
  if (collected.json == null) vm.kill();
  return collected;
}

Future<_Collected> _collectFrom(
  CoverageConfig config,
  Future<int> exited,
) async {
  try {
    final _Inputs inputs = _readInputs(config);
    // `collect` filters by package name. A source outside every package (the
    // test's own entry file, say) is only reported when the collection is left
    // unfiltered, and an empty set does that; the URI map and the manifest
    // still decide what reaches the report.
    final Set<String> scope = needsEveryLibrary(inputs.uriMap, inputs.manifest)
        ? <String>{}
        : packagesToCollect(inputs.uriMap, inputs.manifest);
    final Uri uri = await _awaitServiceUri(
      File(config.serviceInfoPath),
      exited,
    );
    final problems = <String>[];
    final Stdout realStderr = stderr;
    final Map<String, dynamic> json = await IOOverrides.runZoned(
      () => collect(
        uri,
        true,
        true,
        false,
        scope,
        functionCoverage: true,
        branchCoverage: true,
        timeout: _connectTimeout,
      ),
      stderr: () => _ErrorTap(realStderr, problems),
    );
    return (json: json, problems: problems, inputs: inputs);
  } on CoverageFailure catch (e) {
    return (json: null, problems: [e.message], inputs: null);
  } on Exception catch (e) {
    return (
      json: null,
      problems: ['cannot collect from the VM service: $e'],
      inputs: null,
    );
  }
}

/// Waits for the VM to publish the service URI it chose.
Future<Uri> _awaitServiceUri(File info, Future<int> exited) async {
  var vmExited = false;
  unawaited(exited.then((_) => vmExited = true));
  final DateTime deadline = DateTime.now().add(_serviceUriTimeout);
  while (DateTime.now().isBefore(deadline)) {
    final Uri? uri = _readServiceUri(info);
    if (uri != null) return uri;
    if (vmExited) {
      throw CoverageFailure('the VM exited before it published a service URI');
    }
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  throw CoverageFailure(
    'the VM did not publish a service URI within $_serviceUriTimeout',
  );
}

Uri? _readServiceUri(File info) {
  if (!info.existsSync()) return null;
  try {
    final Object? decoded = jsonDecode(info.readAsStringSync());
    final Object? uri = decoded is Map<String, dynamic> ? decoded['uri'] : null;
    return uri is String ? Uri.parse(uri) : null;
  } on FormatException {
    // The VM is still writing the file: read it again.
    return null;
  }
}
