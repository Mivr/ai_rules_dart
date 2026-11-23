/// Hermetic Apple application bundle and archive packager for the `xtool`
/// cross-compilation backend.
///
/// Assembles unsigned iOS `.ipa` (`Payload/<AppName>.app/...`) and macOS
/// `.app.zip` (`<AppName>.app/Contents/...`) archives on any host OS (Linux or
/// macOS) without requiring Xcode, `actool`, `ibtool`, `codesign`, or external
/// system zip utilities, or signs them when `zsign` is provided.
///
/// Capabilities:
///   1. XML `Info.plist` merging, variable substitution (`$(EXECUTABLE_NAME)`,
///      `${PRODUCT_BUNDLE_IDENTIFIER}`, `${MACOSX_DEPLOYMENT_TARGET}`, etc.),
///      and standard Apple bundle metadata injection.
///   2. Framework resolution from `.framework` directories, wrapper tree
///      artifacts containing `*.framework`, or `.xcframework` bundles (selecting
///      the appropriate slice for `ios`, `ios_sim`, or `macos`).
///   3. Pure-Dart SHA-1 (RFC 3174) and SHA-256 (FIPS 180-4) digest computation
///      and Apple `_CodeSignature/CodeResources` XML property list generation
///      when signing with `zsign`.
///   4. Optional `zsign` invocation when a `zsign` binary is provided; unsigned
///      bundles omit `_CodeSignature/`.
///   5. Pure-Dart deterministic ZIP archive writer with Unix permission bits
///      (`0755` for executables and framework dylibs, `0644` for resources,
///      `0120777` for symbolic links) and fixed DOS epoch timestamps.
///
/// Usage:
///   dart xtool_pack.dart bundle \
///     --platform <ios|ios_sim|macos> \
///     --app-name <AppName> \
///     --bundle-id <com.example.app> \
///     --executable <path> \
///     --minimum-os-version <version> \
///     [--info-plist <path> ...] \
///     [--define <KEY=VALUE> ...] \
///     [--framework <path> ...] \
///     [--resource <src[=dest_rel]> ...] \
///     [--provisioning-profile <path>] \
///     [--entitlements <path>] \
///     [--zsign <path>] \
///     [--certificate <path>] \
///     [--certificate-password-file <path>] \
///     [--certificate-password-env <ENV_VAR>] \
///     [--temp-dir <path>] \
///     [--output-archive <path>] \
///     [--output-app-dir <path>]
library;

import 'dart:convert';
import 'dart:io';

import 'xtool_bundle.dart';
import 'xtool_runner.dart';

// ---------------------------------------------------------------------------
// Bundle version resolution (`resolve-version` subcommand)
// ---------------------------------------------------------------------------

/// Reads the `BUILD_EMBED_LABEL` value from a Bazel `stable-status.txt` file,
/// falling back to [fallbackBuildLabel] when absent.
String? _readBuildEmbedLabel(
  String? stableStatusPath,
  String fallbackBuildLabel,
) {
  String? embedLabel;
  if (stableStatusPath != null &&
      stableStatusPath.isNotEmpty &&
      File(stableStatusPath).existsSync()) {
    for (final String line in File(stableStatusPath).readAsLinesSync()) {
      if (line.startsWith('BUILD_EMBED_LABEL ')) {
        final String val = line.substring('BUILD_EMBED_LABEL '.length).trim();
        if (val.isNotEmpty) {
          embedLabel = val;
        }
        break;
      }
    }
  }
  if ((embedLabel == null || embedLabel.isEmpty) &&
      fallbackBuildLabel.isNotEmpty) {
    embedLabel = fallbackBuildLabel;
  }
  return embedLabel;
}

/// Matches [embedLabel] against [buildLabelPattern]'s `{name}` placeholders,
/// returning the captured group values.
Map<String, String> _matchLabelGroups(
  String buildLabelPattern,
  Map<String, String> captureGroups,
  String embedLabel,
) {
  final groupNames = <String>[];
  final String regexPattern = buildLabelPattern.replaceAllMapped(
    RegExp(r'\{([A-Za-z0-9_]+)\}'),
    (m) {
      final String name = m.group(1)!;
      final String? groupRegex = captureGroups[name];
      if (groupRegex == null) {
        throw ArgumentError(
          'Placeholder "{$name}" in build_label_pattern is not present in capture_groups.',
        );
      }
      groupNames.add(name);
      return '($groupRegex)';
    },
  );
  final RegExpMatch? match = RegExp('^$regexPattern\$').firstMatch(embedLabel);
  if (match == null) {
    throw ArgumentError(
      'Build label "$embedLabel" did not match build_label_pattern "$buildLabelPattern".',
    );
  }
  final values = <String, String>{};
  for (var i = 0; i < groupNames.length; i++) {
    values[groupNames[i]] = match.group(i + 1) ?? '';
  }
  return values;
}

String _substituteLabelGroups(String template, Map<String, String> values) {
  return template.replaceAllMapped(RegExp(r'\{([A-Za-z0-9_]+)\}'), (m) {
    final String name = m.group(1)!;
    return values[name] ?? m.group(0)!;
  });
}

/// The inputs for resolving bundle versions from a build label: templates,
/// label-matching rules, and the output path. Grouped so the resolver entry
/// point stays small.
class BundleVersionRequest {
  const new({
    required this.buildVersion,
    this.shortVersionString = '',
    this.buildLabelPattern = '',
    this.fallbackBuildLabel = '',
    this.captureGroups = const {},
    this.stableStatusPath,
    required this.outputPath,
  });

  /// The `build_version` template.
  final String buildVersion;

  /// The `short_version_string` template (defaults to [buildVersion]).
  final String shortVersionString;

  /// The regex the `BUILD_EMBED_LABEL` must match, if any.
  final String buildLabelPattern;

  /// The label used when no `stable-status.txt` entry exists.
  final String fallbackBuildLabel;

  /// The named capture-group patterns for label substitution.
  final Map<String, String> captureGroups;

  /// The `stable-status.txt` path, if any.
  final String? stableStatusPath;

  /// Where to write the resolved version JSON.
  final String outputPath;
}

/// Resolves `build_version` and `short_version_string` from a Bazel
/// `stable-status.txt` `BUILD_EMBED_LABEL` (or the request's fallback build
/// label) and the request's build-label pattern / capture groups, writing
/// JSON to the request's output path.
void resolveBundleVersion(BundleVersionRequest request) {
  final String buildVersion = request.buildVersion;
  final String buildLabelPattern = request.buildLabelPattern;
  String resolvedShort = request.shortVersionString.isNotEmpty
      ? request.shortVersionString
      : buildVersion;
  var resolvedBuild = buildVersion;

  if (buildLabelPattern.isNotEmpty) {
    final String? embedLabel = _readBuildEmbedLabel(
      request.stableStatusPath,
      request.fallbackBuildLabel,
    );
    if (embedLabel != null && embedLabel.isNotEmpty) {
      final Map<String, String> values = _matchLabelGroups(
        buildLabelPattern,
        request.captureGroups,
        embedLabel,
      );
      resolvedBuild = _substituteLabelGroups(resolvedBuild, values);
      resolvedShort = _substituteLabelGroups(resolvedShort, values);
    }
  }

  final outFile = File(request.outputPath);
  outFile.parent.createSync(recursive: true);
  outFile.writeAsStringSync(
    '${jsonEncode({'build_version': resolvedBuild, 'short_version_string': resolvedShort})}\n',
  );
}

// ---------------------------------------------------------------------------
// CLI entrypoint
// ---------------------------------------------------------------------------

Never _usageError(String message) {
  stderr.writeln(message);
  stderr.writeln(
    'Usage:\n'
    '  dart xtool_pack.dart bundle \\\n'
    '    --platform <ios|ios_sim|macos> \\\n'
    '    --app-name <AppName> \\\n'
    '    --bundle-id <com.example.app> \\\n'
    '    --executable <path> \\\n'
    '    --minimum-os-version <version> \\\n'
    '    [--family <iphone|ipad> ...] \\\n'
    '    [--version-file <path>] \\\n'
    '    [--info-plist <path> ...] \\\n'
    '    [--define <KEY=VALUE> ...] \\\n'
    '    [--framework <path> ...] \\\n'
    '    [--native-lib <path> ...] \\\n'
    '    [--resource <src[=dest_rel]> ...] \\\n'
    '    [--additional-content <subdir=src> ...] \\\n'
    '    [--provisioning-profile <path>] \\\n'
    '    [--entitlements <path>] \\\n'
    '    [--zsign <path>] \\\n'
    '    [--certificate <path>] \\\n'
    '    [--certificate-password-file <path>] \\\n'
    '    [--certificate-password-env <ENV_VAR>] \\\n'
    '    [--temp-dir <path>] \\\n'
    '    [--output-archive <path>] \\\n'
    '    [--output-app-dir <path>]',
  );
  exit(1);
}

/// Mutable parse state for `resolve-version` CLI arguments.
class _ResolveVersionArgState {
  String buildVersion = '1.0';
  String shortVersionString = '';
  String buildLabelPattern = '';
  String fallbackBuildLabel = '';
  final captureGroups = <String, String>{};
  String? stableStatusPath;
  String? outputPath;

  int apply(List<String> args, int i) {
    final String arg = args[i];
    String nextVal() {
      if (i + 1 >= args.length) {
        _usageError('Missing value for $arg.');
      }
      return args[++i];
    }

    switch (arg) {
      case '--control':
        _applyControlFile(nextVal());
      case '--build-version':
        buildVersion = nextVal();
      case '--short-version-string':
        shortVersionString = nextVal();
      case '--build-label-pattern':
        buildLabelPattern = nextVal();
      case '--fallback-build-label':
        fallbackBuildLabel = nextVal();
      case '--capture-group':
        _applyCaptureGroup(nextVal());
      case '--stable-status':
        stableStatusPath = nextVal();
      case '--output':
        outputPath = nextVal();
      default:
        _usageError('Unrecognized argument for resolve-version: $arg');
    }
    return i;
  }

  void _applyControlFile(String controlPath) {
    final dynamic decoded = jsonDecode(File(controlPath).readAsStringSync());
    if (decoded is! Map) {
      _usageError('Control file $controlPath must contain a JSON object.');
    }
    buildVersion =
        (decoded['build_version_pattern'] as String?) ?? buildVersion;
    shortVersionString =
        (decoded['short_version_string_pattern'] as String?) ??
        shortVersionString;
    buildLabelPattern =
        (decoded['build_label_pattern'] as String?) ?? buildLabelPattern;
    fallbackBuildLabel =
        (decoded['fallback_build_label'] as String?) ?? fallbackBuildLabel;
    stableStatusPath =
        (decoded['build_info_path'] as String?) ?? stableStatusPath;
    final dynamic cg = decoded['capture_groups'];
    if (cg is Map) {
      for (final MapEntry<dynamic, dynamic> entry in cg.entries) {
        captureGroups[entry.key.toString()] = entry.value.toString();
      }
    }
  }

  void _applyCaptureGroup(String kv) {
    final int eq = kv.indexOf('=');
    if (eq == -1) {
      _usageError('Expected KEY=REGEX for --capture-group, got "$kv".');
    }
    captureGroups[kv.substring(0, eq)] = kv.substring(eq + 1);
  }
}

void _runResolveVersionCli(List<String> args) {
  final state = _ResolveVersionArgState();
  for (var i = 0; i < args.length; i++) {
    i = state.apply(args, i);
  }
  final String? outputPath = state.outputPath;
  if (outputPath == null) {
    _usageError('Required flag for resolve-version: --output.');
  }

  try {
    resolveBundleVersion(
      BundleVersionRequest(
        buildVersion: state.buildVersion,
        shortVersionString: state.shortVersionString,
        buildLabelPattern: state.buildLabelPattern,
        fallbackBuildLabel: state.fallbackBuildLabel,
        captureGroups: state.captureGroups,
        stableStatusPath: state.stableStatusPath,
        outputPath: outputPath,
      ),
    );
  } on Object catch (e) {
    stderr.writeln('xtool_pack resolve-version failed: $e');
    exit(1);
  }
}

/// Mutable parse state for `compile-runner` CLI arguments.
class _CompileRunnerArgState {
  String? platform;
  String arch = 'arm64';
  String? appName;
  String minimumOsVersion = '14.0';
  bool sdkAvailable = false;
  String? sdkRootPath;
  String? swiftcPath;
  String? clangPath;
  final sourcePaths = <String>[];
  final headerPaths = <String>[];
  final modulemapPaths = <String>[];
  final frameworkPaths = <String>[];
  final sdkFrameworks = <String>[];
  final sdkDylibs = <String>[];
  String? outputPath;

  int apply(List<String> args, int i) {
    final String arg = args[i];
    String nextVal() {
      if (i + 1 >= args.length) {
        _usageError('Missing value for $arg.');
      }
      return args[++i];
    }

    switch (arg) {
      case '--platform':
        platform = nextVal();
      case '--arch':
        arch = nextVal();
      case '--app-name':
        appName = nextVal();
      case '--minimum-os-version':
        minimumOsVersion = nextVal();
      case '--sdk-available':
        sdkAvailable = nextVal().toLowerCase() == 'true';
      case '--sdk-root':
        sdkRootPath = nextVal();
      case '--swiftc':
        swiftcPath = nextVal();
      case '--clang':
        clangPath = nextVal();
      case '--source':
        sourcePaths.add(nextVal());
      case '--header':
        headerPaths.add(nextVal());
      case '--modulemap':
        modulemapPaths.add(nextVal());
      case '--framework':
        frameworkPaths.add(nextVal());
      case '--sdk-framework':
        sdkFrameworks.add(nextVal());
      case '--sdk-dylib':
        sdkDylibs.add(nextVal());
      case '--output':
        outputPath = nextVal();
      default:
        _usageError('Unrecognized argument for compile-runner: $arg');
    }
    return i;
  }

  RunnerCompileConfig build() {
    if (platform == null || appName == null || outputPath == null) {
      _usageError(
        'Required flags for compile-runner: --platform, --app-name, --output.',
      );
    }
    return RunnerCompileConfig(
      platform: platform!,
      arch: arch,
      appName: appName!,
      minimumOsVersion: minimumOsVersion,
      sdkAvailable: sdkAvailable,
      sdkRootPath: sdkRootPath,
      swiftcPath: swiftcPath,
      clangPath: clangPath,
      sourcePaths: sourcePaths,
      headerPaths: headerPaths,
      modulemapPaths: modulemapPaths,
      frameworkPaths: frameworkPaths,
      sdkFrameworks: sdkFrameworks,
      sdkDylibs: sdkDylibs,
      outputPath: outputPath!,
    );
  }
}

void _runCompileRunnerCli(List<String> args) {
  final state = _CompileRunnerArgState();
  for (var i = 0; i < args.length; i++) {
    i = state.apply(args, i);
  }

  try {
    compileRunner(state.build());
  } on Object catch (e) {
    stderr.writeln('xtool_pack compile-runner failed: $e');
    exit(1);
  }
}

/// Mutable parse state for `bundle` CLI arguments.
class _BundleArgState {
  String? platform;
  String? appName;
  String? bundleId;
  String? executablePath;
  String minimumOsVersion = '14.0';
  final families = <String>[];
  String? versionFilePath;
  final infoPlistPaths = <String>[];
  final defines = <String, String>{};
  final frameworkPaths = <String>[];
  final nativeLibPaths = <String>[];
  final resourceSpecs = <String>[];
  final additionalContentSpecs = <String>[];
  String? provisioningProfilePath;
  String? entitlementsPath;
  String? zsignPath;
  String? certificatePath;
  String? certificatePasswordFilePath;
  String? certificatePasswordEnv;
  var isolatedEnv = false;
  final declaredEnvVars = <String>{};
  String? tempDirPath;
  String? outputArchivePath;
  String? outputAppDirPath;

  int apply(List<String> args, int i) {
    final String arg = args[i];
    if (arg == '--certificate-password' ||
        arg.startsWith('--certificate-password=')) {
      throw ArgumentError(
        '--certificate-password is not permitted because command-line '
        'arguments are visible in process listings and build logs. '
        'Use --certificate-password-file <path> or '
        '--certificate-password-env <ENV_VAR> instead.',
      );
    }

    String nextVal() {
      if (i + 1 >= args.length) {
        throw ArgumentError('Missing value for $arg.');
      }
      return args[++i];
    }

    if (_applyIdentityFlag(arg, nextVal)) return i;
    if (_applySigningFlag(arg, nextVal)) return i;
    switch (arg) {
      case '--define':
        final String kv = nextVal();
        final int eq = kv.indexOf('=');
        if (eq == -1) {
          throw ArgumentError('Expected KEY=VALUE for --define, got "$kv".');
        }
        defines[kv.substring(0, eq)] = kv.substring(eq + 1);
      case '--isolated-env':
        isolatedEnv = true;
      case '--declared-env':
        declaredEnvVars.add(nextVal());
      default:
        throw ArgumentError('Unrecognized argument: $arg');
    }
    return i;
  }

  bool _applyIdentityFlag(String arg, String Function() nextVal) {
    switch (arg) {
      case '--platform':
        platform = nextVal();
      case '--app-name':
        appName = nextVal();
      case '--bundle-id':
        bundleId = nextVal();
      case '--executable':
        executablePath = nextVal();
      case '--minimum-os-version':
        minimumOsVersion = nextVal();
      case '--family':
        families.add(nextVal());
      case '--version-file':
        versionFilePath = nextVal();
      case '--info-plist':
        infoPlistPaths.add(nextVal());
      case '--framework':
        frameworkPaths.add(nextVal());
      case '--native-lib':
        nativeLibPaths.add(nextVal());
      case '--resource':
        resourceSpecs.add(nextVal());
      case '--additional-content':
        additionalContentSpecs.add(nextVal());
      default:
        return false;
    }
    return true;
  }

  bool _applySigningFlag(String arg, String Function() nextVal) {
    switch (arg) {
      case '--provisioning-profile':
        provisioningProfilePath = nextVal();
      case '--entitlements':
        entitlementsPath = nextVal();
      case '--zsign':
        zsignPath = nextVal();
      case '--certificate':
        certificatePath = nextVal();
      case '--certificate-password-file':
        certificatePasswordFilePath = nextVal();
      case '--certificate-password-env':
        certificatePasswordEnv = nextVal();
      case '--temp-dir':
        tempDirPath = nextVal();
      case '--output-archive':
        outputArchivePath = nextVal();
      case '--output-app-dir':
        outputAppDirPath = nextVal();
      default:
        return false;
    }
    return true;
  }

  Map<String, String> _buildResolvedEnv() {
    final resolvedEnv = <String, String>{};
    if (isolatedEnv) {
      for (final String key in declaredEnvVars) {
        if (key == 'TMPDIR' || key == 'TEST_TMPDIR') continue;
        final String? val = Platform.environment[key];
        if (val != null) {
          resolvedEnv[key] = val;
        }
      }
      if (certificatePasswordEnv != null &&
          certificatePasswordEnv!.isNotEmpty) {
        resolvedEnv.putIfAbsent(certificatePasswordEnv!, () => '');
      }
      return resolvedEnv;
    }
    for (final MapEntry<String, String> entry in Platform.environment.entries) {
      if (ambientHostEnvVars.contains(entry.key) &&
          !declaredEnvVars.contains(entry.key)) {
        continue;
      }
      if (entry.key == 'TMPDIR' || entry.key == 'TEST_TMPDIR') {
        continue;
      }
      resolvedEnv[entry.key] = entry.value;
    }
    if (certificatePasswordEnv == 'TMPDIR' ||
        certificatePasswordEnv == 'TEST_TMPDIR') {
      resolvedEnv[certificatePasswordEnv!] = '';
    }
    return resolvedEnv;
  }

  BundleConfig build() {
    if (platform == null ||
        appName == null ||
        bundleId == null ||
        executablePath == null ||
        (outputArchivePath == null && outputAppDirPath == null)) {
      throw ArgumentError(
        'Required flags: --platform, --app-name, --bundle-id, --executable, '
        'and at least one of --output-archive or --output-app-dir.',
      );
    }
    return BundleConfig(
      platform: platform!,
      appName: appName!,
      bundleId: bundleId!,
      executablePath: executablePath!,
      minimumOsVersion: minimumOsVersion,
      families: families,
      versionFilePath: versionFilePath,
      infoPlistPaths: infoPlistPaths,
      defines: defines,
      frameworkPaths: frameworkPaths,
      nativeLibPaths: nativeLibPaths,
      resourceSpecs: resourceSpecs,
      additionalContentSpecs: additionalContentSpecs,
      provisioningProfilePath: provisioningProfilePath,
      entitlementsPath: entitlementsPath,
      zsignPath: zsignPath,
      certificatePath: certificatePath,
      certificatePasswordFilePath: certificatePasswordFilePath,
      certificatePasswordEnv: certificatePasswordEnv,
      tempDirPath: tempDirPath,
      outputArchivePath: outputArchivePath,
      outputAppDirPath: outputAppDirPath,
      environment: _buildResolvedEnv(),
    );
  }
}

/// Parses `bundle` CLI arguments into a [BundleConfig], throwing [ArgumentError]
/// on invalid or forbidden flags (such as plain-text `--certificate-password`).
BundleConfig parseBundleCliArgs(List<String> args) {
  final state = _BundleArgState();
  for (var i = 0; i < args.length; i++) {
    i = state.apply(args, i);
  }
  return state.build();
}

void main(List<String> args) {
  if (args.isEmpty) {
    _usageError(
      'Missing subcommand (expected "bundle", "compile-runner", or "resolve-version").',
    );
  }

  final String subcommand = args.first;
  if (subcommand == 'compile-runner') {
    _runCompileRunnerCli(args.sublist(1));
    return;
  }
  if (subcommand == 'resolve-version') {
    _runResolveVersionCli(args.sublist(1));
    return;
  }
  if (subcommand != 'bundle') {
    _usageError(
      'Unknown subcommand "$subcommand" (expected "bundle", "compile-runner", or "resolve-version").',
    );
  }

  final BundleConfig config;
  try {
    config = parseBundleCliArgs(args.sublist(1));
  } on ArgumentError catch (e) {
    _usageError('${e.message}');
  }

  try {
    assembleBundle(config);
  } on Object catch (e) {
    stderr.writeln('xtool_pack failed: $e');
    exit(1);
  }
}
