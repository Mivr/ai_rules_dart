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
      final versions = parseToolVersions(sample);
      expect(versions, ['3.13.5']);

      final rendered = renderVersionsBzl(
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
}
