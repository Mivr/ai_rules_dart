/// Lockfile guard: internal `flutter.pub` hubs stay reproducible and never
/// pollute consumer `MODULE.bazel.lock` facts or generated repositories.
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

String _anchorFilePath() {
  final Map<String, String> env = Platform.environment;
  final String? anchor = env['GUARD_ROOT_ANCHOR'];
  final String? srcDir = env['TEST_SRCDIR'];
  if (anchor != null &&
      srcDir != null &&
      File('$srcDir/$anchor').existsSync()) {
    return '$srcDir/$anchor';
  }
  final String? manifest = env['RUNFILES_MANIFEST_FILE'];
  if (anchor != null && manifest != null && File(manifest).existsSync()) {
    for (final String entry in File(manifest).readAsLinesSync()) {
      if (entry.startsWith('$anchor ')) {
        return entry.substring(anchor.length + 1);
      }
    }
  }
  return 'flutter/tests/flutter_pub_internal_hubs_guard_test.dart';
}

String _locateRepoRoot() {
  final String? workspaceEnv =
      Platform.environment['BUILD_WORKSPACE_DIRECTORY'];
  if (workspaceEnv != null && File('$workspaceEnv/MODULE.bazel').existsSync()) {
    return workspaceEnv;
  }
  final String resolved = File(_anchorFilePath()).resolveSymbolicLinksSync();
  final String candidate = File(resolved).parent.parent.parent.path;
  if (!File('$candidate/MODULE.bazel').existsSync()) {
    throw StateError('Cannot locate rules_flutter root at $candidate');
  }
  return candidate;
}

Map<String, Object?> _readJsonObject(String path) {
  final Object? decoded = jsonDecode(File(path).readAsStringSync());
  if (decoded is Map<String, Object?>) {
    return decoded;
  }
  throw FormatException('Expected top-level JSON object in $path');
}

Map<String, Object?> _jsonSection(
  Map<String, Object?> parent,
  String key,
) => switch (parent[key]) {
  final Map<String, Object?> map => map,
  _ => const <String, Object?>{},
};

void _expectNoFlutterExtension(Map<String, Object?> lockJson, String label) {
  for (final section in const <String>['moduleExtensions', 'facts']) {
    final Map<String, Object?> entries = _jsonSection(lockJson, section);
    for (final String key in entries.keys) {
      expect(
        key.contains('flutter:extensions.bzl%flutter'),
        isFalse,
        reason: '$label contains unexpected $section key $key',
      );
    }
  }
}

Set<String> _hostedPackagesInPubspecLock(String path) {
  final hosted = <String>{};
  String? currentPkg;
  for (final String line in File(path).readAsLinesSync()) {
    final RegExpMatch? pkgMatch = RegExp(
      r'^  ([a-z0-9_]+):\s*$',
    ).firstMatch(line);
    if (pkgMatch != null) {
      currentPkg = pkgMatch.group(1);
      continue;
    }
    if (currentPkg != null && line.trim() == 'source: hosted') {
      hosted.add(currentPkg);
    }
  }
  return hosted;
}

Set<String> _factHostedPackages(Map<String, Object?> extFacts) {
  final packages = <String>{};
  for (final String key in extFacts.keys) {
    final List<String> parts = key.split('/');
    if (parts.length >= 3 && parts[1] == 'hosted') {
      packages.add(parts[2]);
    }
  }
  return packages;
}

const _toolHubs = <String>['dev_tool_deps', 'gen_l10n_deps'];

void _expectPubSccExcludesToolHubs(String root) {
  final Map<String, Object?> pubSccLock = _readJsonObject(
    '$root/e2e/pub_scc/MODULE.bazel.lock',
  );
  final Map<String, Object?> facts = _jsonSection(pubSccLock, 'facts');
  const flutterKey = '@@ai_rules_flutter+//flutter:extensions.bzl%flutter';

  expect(
    facts.containsKey(flutterKey),
    isTrue,
    reason: 'e2e/pub_scc/MODULE.bazel.lock must record flutter facts',
  );

  final Map<String, Object?> extFacts = _jsonSection(facts, flutterKey);
  final Set<String> covered = _factHostedPackages(extFacts);
  final Set<String> lockHosted = _hostedPackagesInPubspecLock(
    '$root/e2e/pub_scc/pubspec.lock',
  );
  const expectedPackages = <String>{
    'characters',
    'collection',
    'material_color_utilities',
    'meta',
    'vector_math',
  };
  expect(lockHosted, equals(expectedPackages));
  expect(extFacts.length, equals(expectedPackages.length));
  expect(covered, equals(expectedPackages));

  for (final pkg in const <String>{
    'args',
    'dwds',
    'intl',
    'vm_service',
    'watcher',
  }) {
    expect(covered.contains(pkg), isFalse);
  }

  _expectLockExtensionsExcludeToolHubs(pubSccLock, flutterKey);
}

void _expectLockExtensionsExcludeToolHubs(
  Map<String, Object?> lockJson,
  String flutterKey,
) {
  final Map<String, Object?> moduleExtensions = _jsonSection(
    lockJson,
    'moduleExtensions',
  );
  for (final String extKey in moduleExtensions.keys) {
    expect(
      extKey.contains('flutter_tool_deps'),
      isFalse,
      reason: 'consumer lockfile must not evaluate flutter_tool_deps',
    );
  }
  final Map<String, Object?> flutterExt = _jsonSection(
    moduleExtensions,
    flutterKey,
  );
  final Map<String, Object?> general = _jsonSection(flutterExt, 'general');
  final Map<String, Object?> repoSpecs = _jsonSection(
    general,
    'generatedRepoSpecs',
  );
  expect(repoSpecs, isNotEmpty);
  for (final String repoName in repoSpecs.keys) {
    for (final String hub in _toolHubs) {
      expect(
        repoName == hub ||
            repoName.startsWith('${hub}__') ||
            repoName.startsWith('$hub-'),
        isFalse,
        reason: 'consumer flutter extension created tool repo $repoName',
      );
    }
  }
}

void _expectRootToolHubDeclarations(String root) {
  final String module = File('$root/MODULE.bazel').readAsStringSync();
  for (final String hub in _toolHubs) {
    expect(
      module,
      contains('flutter_tool_deps.pub(\n    name = "$hub",'),
      reason: '$hub must be declared on the lazily evaluated extension',
    );
    expect(
      module.contains('flutter.pub(\n    name = "$hub",'),
      isFalse,
      reason: '$hub on the flutter extension would reach every consumer',
    );
  }
  expect(module, contains('use_repo(flutter_tool_deps, '));
  for (final RegExpMatch m in RegExp(
    r'use_repo\(flutter,([^)]*)\)',
  ).allMatches(module)) {
    for (final String hub in _toolHubs) {
      expect(m.group(1), isNot(contains('"$hub"')));
    }
  }
  expect(
    RegExp(
      r'flutter_dev\s*=\s*use_extension\(\s*"//flutter:extensions\.bzl",\s*'
      r'"flutter",\s*dev_dependency\s*=\s*True,\s*\)',
    ).hasMatch(module),
    isTrue,
    reason: 'root-only flutter_dev proxy must set dev_dependency = True',
  );
  expect(
    module.contains('use_repo(flutter_dev'),
    isFalse,
    reason: 'root module must resolve @dev_tool_deps through flutter_tool_deps',
  );
}

void _expectNoE2eImportsToolHubFromFlutter(String root) {
  for (final FileSystemEntity dir in Directory('$root/e2e').listSync()) {
    final module = File('${dir.path}/MODULE.bazel');
    if (!module.existsSync()) {
      continue;
    }
    for (final RegExpMatch m in RegExp(
      r'use_repo\(\s*flutter,([^)]*)\)',
    ).allMatches(module.readAsStringSync())) {
      for (final String hub in _toolHubs) {
        expect(
          m.group(1),
          isNot(contains('"$hub"')),
          reason: '${module.path} imports $hub from the flutter extension',
        );
      }
    }
  }
}

/// Entrypoint for the internal-hubs lockfile guard tests.
void main() {
  final String root = _locateRepoRoot();

  test('root MODULE.bazel.lock contains no flutter extension entry', () {
    _expectNoFlutterExtension(
      _readJsonObject('$root/MODULE.bazel.lock'),
      'MODULE.bazel.lock',
    );
  });

  test('e2e/smoke has no flutter.pub hub and no flutter lockfile entry', () {
    final String smokeModule = File(
      '$root/e2e/smoke/MODULE.bazel',
    ).readAsStringSync();
    expect(
      smokeModule.contains('flutter.pub('),
      isFalse,
      reason: 'e2e/smoke/MODULE.bazel must not declare any flutter.pub hubs',
    );
    _expectNoFlutterExtension(
      _readJsonObject('$root/e2e/smoke/MODULE.bazel.lock'),
      'e2e/smoke/MODULE.bazel.lock',
    );
  });

  test('e2e/pub_scc/MODULE.bazel.lock facts and repos exclude tool hubs', () {
    _expectPubSccExcludesToolHubs(root);
  });

  test('the tool pub hubs live on flutter_tool_deps, not on flutter', () {
    _expectRootToolHubDeclarations(root);
  });

  test('no e2e workspace imports a tool hub from the flutter extension', () {
    _expectNoE2eImportsToolHubFromFlutter(root);
  });

  test('the xtool SDK repository is registered through the hub only', () {
    final String module = File('$root/MODULE.bazel').readAsStringSync();
    expect(
      RegExp(
        r'register_toolchains\([^)]*flutter_xtool_darwin_sdk',
      ).hasMatch(module),
      isFalse,
    );
    expect(
      module,
      contains('register_toolchains("@flutter_toolchains//:all")'),
    );
  });
}
