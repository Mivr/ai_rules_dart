import 'package:test/test.dart';

import 'update_cross_sdk_versions.dart';

void main() {
  test(
    'crossGenSnapshotFilename and crossDartaotruntimeFilename match CDN naming',
    () {
      expect(
        crossGenSnapshotFilename('linux-x64', 'linux-arm64'),
        'gen_snapshot_linux_x64_linux_arm64',
      );
      expect(
        crossGenSnapshotFilename('macos-arm64', 'linux-riscv64'),
        'gen_snapshot_macos_arm64_linux_riscv64',
      );
      expect(
        crossGenSnapshotFilename('windows-x64', 'linux-arm'),
        'gen_snapshot_windows_x64_linux_arm.exe',
      );
      expect(
        crossDartaotruntimeFilename('linux-riscv64'),
        'dartaotruntime_linux_riscv64',
      );
      expect(
        crossGenSnapshotUrl('3.13.5', 'linux-x64', 'linux-arm64'),
        'https://storage.googleapis.com/dart-archive/channels/stable/release/3.13.5/sdk/gen_snapshot_linux_x64_linux_arm64',
      );
      expect(
        crossDartaotruntimeUrl('3.13.5', 'linux-arm64'),
        'https://storage.googleapis.com/dart-archive/channels/stable/release/3.13.5/sdk/dartaotruntime_linux_arm64',
      );
    },
  );

  test('rejects unsupported host or target pairs', () {
    expect(
      () => crossGenSnapshotFilename('linux-x64', 'linux-x64'),
      throwsArgumentError,
    );
    expect(
      () => crossGenSnapshotFilename('unknown-host', 'linux-arm64'),
      throwsArgumentError,
    );
    expect(
      () => crossDartaotruntimeFilename('macos-arm64'),
      throwsArgumentError,
    );
  });

  test(
    'parseToolVersions and renderVersionsBzl round-trip pins deterministically',
    () {
      final sample =
          '''
"""Dart SDK versions"""

TOOL_VERSIONS = {
    "3.13.5": {
        "linux-x64": "${'a' * 64}",
    },
}
''';
      final List<String> versions = parseToolVersions(sample);
      expect(versions, ['3.13.5']);

      final String rendered = renderVersionsBzl(
        existingContent: sample,
        versions: versions,
        genSnapshotVersions: {
          '3.13.5': {'linux-x64_linux-arm64': 'b' * 64},
        },
        dartaotruntimeVersions: {
          '3.13.5': {'linux-arm64': 'c' * 64},
        },
      );
      expect(parseExistingNestedPins(rendered, 'CROSS_GEN_SNAPSHOT_VERSIONS'), {
        '3.13.5': {'linux-x64_linux-arm64': 'b' * 64},
      });
      expect(
        parseExistingNestedPins(rendered, 'CROSS_DARTAOTRUNTIME_VERSIONS'),
        {
          '3.13.5': {'linux-arm64': 'c' * 64},
        },
      );
    },
  );

  group('tables', () {
    final Map<String, String> hashes = {
      for (final p in hostPlatforms.keys) p: 'a' * 64,
    };
    final versionsBzl =
        'TOOL_VERSIONS = {\n'
        '${renderToolVersionEntry('3.13.5', hashes)}'
        '${renderToolVersionEntry('3.9.4', hashes)}'
        '}\n';

    test('renderToolVersionEntry lists every host platform and no other', () {
      final String entry = renderToolVersionEntry('3.14.1', hashes);
      expect(entry, startsWith('    "3.14.1": {\n'));
      for (final String platform in hostPlatforms.keys) {
        expect(entry, contains('        "$platform": "${'a' * 64}",\n'));
      }
      expect(entry, endsWith('    },\n'));
      expect(
        () => renderToolVersionEntry('3.14.1', {'linux-x64': 'a' * 64}),
        throwsStateError,
      );
    });

    test('insertToolVersion keeps the newest version first', () {
      String entry(String v) => renderToolVersionEntry(v, hashes);
      final String newest = insertToolVersion(
        versionsBzl,
        '3.14.1',
        entry('3.14.1'),
      );
      expect(parseToolVersions(newest), ['3.14.1', '3.13.5', '3.9.4']);
      final String middle = insertToolVersion(
        versionsBzl,
        '3.10.5',
        entry('3.10.5'),
      );
      expect(parseToolVersions(middle), ['3.13.5', '3.10.5', '3.9.4']);
      final String oldest = insertToolVersion(
        versionsBzl,
        '3.8.1',
        entry('3.8.1'),
      );
      expect(parseToolVersions(oldest), ['3.13.5', '3.9.4', '3.8.1']);
      expect(
        parseToolVersions(insertToolVersion(oldest, '3.9.9', entry('3.9.9'))),
        ['3.13.5', '3.9.9', '3.9.4', '3.8.1'],
      );
      expect(
        () => insertToolVersion(versionsBzl, '3.13.5', entry('3.13.5')),
        throwsStateError,
      );
    });

    test('removeToolVersion removes one entry and nothing else', () {
      final String removed = removeToolVersion(versionsBzl, '3.13.5');
      expect(parseToolVersions(removed), ['3.9.4']);
      expect(removed, isNot(contains('3.13.5')));
      expect(
        removed,
        'TOOL_VERSIONS = {\n'
        '${renderToolVersionEntry('3.9.4', hashes)}'
        '}\n',
      );
      expect(() => removeToolVersion(versionsBzl, '3.10.5'), throwsStateError);
    });

    const languageVersions = {
      'kernel': '3.13',
      'front_end': '3.13',
      'vm': '3.12',
    };
    String row(String v) => renderModuleCompilerRow(
      version: v,
      sha256: 'b' * 64,
      revision: 'c' * 40,
      languageVersions: languageVersions,
    );
    final moduleCompilerBzl =
        'MODULE_COMPILER_SOURCES = {\n'
        '${row('3.13.5')}'
        '${row('3.9.4')}'
        '}\n\n'
        'MODULE_COMPILER_HOSTED_PACKAGES = {\n'
        '    "path": struct(\n'
        '        version = "1.9.1",\n'
        '    ),\n'
        '}\n';

    test('renderModuleCompilerRow writes the row the table uses', () {
      expect(
        row('3.14.1'),
        '    "3.14.1": struct(\n'
        '        sha256 = "${'b' * 64}",\n'
        '        revision = "${'c' * 40}",\n'
        '        language_versions = {\n'
        '            "front_end": "3.13",\n'
        '            "kernel": "3.13",\n'
        '            "vm": "3.12",\n'
        '        },\n'
        '    ),\n',
      );
    });

    test('the module compiler rows are read, added in order and removed', () {
      expect(parseModuleCompilerVersions(moduleCompilerBzl), [
        '3.13.5',
        '3.9.4',
      ]);
      expect(parseLanguageVersions(moduleCompilerBzl), languageVersions);
      final String added = insertModuleCompilerRow(
        moduleCompilerBzl,
        '3.14.1',
        row('3.14.1'),
      );
      expect(parseModuleCompilerVersions(added), ['3.14.1', '3.13.5', '3.9.4']);
      final String removed = removeModuleCompilerRow(added, '3.13.5');
      expect(parseModuleCompilerVersions(removed), ['3.14.1', '3.9.4']);
      expect(removeModuleCompilerRow(added, '3.14.1'), moduleCompilerBzl);
      expect(removed, contains('MODULE_COMPILER_HOSTED_PACKAGES'));
      expect(
        () => removeModuleCompilerRow(moduleCompilerBzl, '3.10.5'),
        throwsStateError,
      );
    });
  });

  test('compareReleaseVersions orders by number, not by text', () {
    expect(compareReleaseVersions('3.14.1', '3.9.4'), greaterThan(0));
    expect(compareReleaseVersions('3.13.5', '3.13.10'), lessThan(0));
    expect(compareReleaseVersions('3.13.5', '3.13.5'), 0);
    expect(
      () => compareReleaseVersions('3.14.0-100.0.dev', '3.13.5'),
      throwsFormatException,
    );
  });

  test('parseSha256sum reads the digest of a .sha256sum file', () {
    expect(
      parseSha256sum('${'AB' * 32}  dartsdk-linux-x64-release.zip\n'),
      'ab' * 32,
    );
    expect(parseSha256sum('${'a' * 64}\n'), 'a' * 64);
    expect(parseSha256sum('<html>not found</html>'), isNull);
    expect(parseSha256sum(''), isNull);
  });

  test('parseReleaseRevision reads the commit of the release asked for', () {
    final body =
        '{"date": "2026-11-17", "version": "3.14.1", '
        '"revision": "${'d' * 40}"}';
    expect(parseReleaseRevision(body, '3.14.1'), 'd' * 40);
    expect(() => parseReleaseRevision(body, '3.14.0'), throwsFormatException);
    expect(
      () => parseReleaseRevision('{"version": "3.14.1"}', '3.14.1'),
      throwsFormatException,
    );
  });

  test('urls name the release the bucket and GitHub serve', () {
    expect(
      sdkArchiveUrl('3.14.1', 'linux-x64'),
      'https://storage.googleapis.com/dart-archive/channels/stable/release/3.14.1/sdk/dartsdk-linux-x64-release.zip',
    );
    expect(
      releaseVersionUrl('3.14.1'),
      'https://storage.googleapis.com/dart-archive/channels/stable/release/3.14.1/VERSION',
    );
    expect(
      tagArchiveUrl('3.14.1'),
      'https://github.com/dart-lang/sdk/archive/refs/tags/3.14.1.tar.gz',
    );
  });
}
