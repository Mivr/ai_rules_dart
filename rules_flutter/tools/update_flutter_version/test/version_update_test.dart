import 'dart:io';

import 'package:test/test.dart';

import '../artifact_list.dart';
import '../version_update.dart';

/// Writes [body] as `flutter/private/versions.bzl` under a temp dir, which is
/// what [readCurrentSysrootChecksums] reads.
Directory _writeVersionsBzl(String body) {
  final Directory dir = Directory.systemTemp.createTempSync('versions_bzl_');
  addTearDown(() => dir.deleteSync(recursive: true));
  File('${dir.path}/flutter/private/versions.bzl')
    ..createSync(recursive: true)
    ..writeAsStringSync(body);
  return dir;
}

void main() {
  group('resolveVersionRequest', () {
    test('resolves the version and the Flutter repo default', () {
      final VersionRequest request = resolveVersionRequest(['3.42.0']);
      expect(request.version, '3.42.0');
      expect(request.flutterRepo, '${request.workspaceDir}/references/flutter');
    });
  });

  group('renderVersionSnippet', () {
    test('renders the versions entry and every artifact section', () {
      final String sha = 'a' * 64;
      final String rendered = renderVersionSnippet(
        version: '3.42.0',
        engineRev: 'enginerev',
        materialFontsUrl: 'fonts/url',
        checksums: {
          '__source__': sha,
          'flutter_patched_sdk.zip': sha,
          'material_fonts.zip': sha,
        },
      );
      expect(
        rendered,
        startsWith(
          '\n=== Add to FLUTTER_VERSIONS in flutter/private/versions.bzl ===\n'
          '\n'
          '    "3.42.0": struct(\n'
          '        engine_revision = "enginerev",\n'
          '        material_fonts_url = "fonts/url",\n',
        ),
      );
      expect(rendered, contains('        source_sha256 = "$sha",\n'));
      expect(
        rendered,
        contains('        "flutter_patched_sdk.zip": "$sha",\n'),
      );
      // Unhashed artifacts read MISSING, as the failure report says they do.
      expect(rendered, contains('        "sky_engine.zip": "MISSING",\n'));
      expect(
        rendered,
        contains('        "material_fonts.zip": "$sha",\n'),
      );
      expect(
        rendered,
        endsWith(
          '        # Material design fonts (MaterialIcons-Regular.otf, Roboto family)\n'
          '        "material_fonts.zip": "$sha",\n'
          '    },\n',
        ),
      );
      // Every known artifact path gets exactly one line, in print order.
      final List<String> lines = rendered.split('\n');
      for (final String artifact in artifacts) {
        expect(
          lines.where((l) => l.contains('"$artifact"')),
          hasLength(1),
          reason: artifact,
        );
      }
    });

    test('an unhashed source tarball reads FIXME', () {
      final String rendered = renderVersionSnippet(
        version: '3.42.0',
        engineRev: 'enginerev',
        materialFontsUrl: 'fonts/url',
        checksums: const {},
      );
      expect(
        rendered,
        contains('        source_sha256 = "FIXME",\n'),
      );
    });
  });

  group('renderFailuresReport', () {
    test('lists every failure exactly as the updater prints it', () {
      expect(
        renderFailuresReport(['a.zip', 'b.zip']),
        '\n'
        'ERROR: 2 artifact(s) could not be downloaded and hashed:\n'
        '  a.zip\n'
        '  b.zip\n'
        'Their entries above read MISSING. Fix the download and re-run.\n',
      );
    });
  });

  group('readCurrentSysrootChecksums', () {
    test('reads both architectures from the versions.bzl block', () {
      final Directory dir = _writeVersionsBzl(
        'LINUX_SYSROOT_CHECKSUMS = {\n'
        '    "amd64": "${'a' * 64}",\n'
        '    "arm64": "${'b' * 64}",\n'
        '}\n',
      );
      expect(readCurrentSysrootChecksums(dir.path), {
        'amd64': 'a' * 64,
        'arm64': 'b' * 64,
      });
    });

    test('a missing block throws', () {
      final Directory dir = _writeVersionsBzl('FLUTTER_VERSIONS = {}\n');
      expect(
        () => readCurrentSysrootChecksums(dir.path),
        throwsFormatException,
      );
    });
  });

  group('readEngineSysrootChecksums', () {
    test('reads both bullseye entries', () {
      expect(
        readEngineSysrootChecksums({
          'bullseye_amd64': {'Sha256Sum': 'a' * 64},
          'bullseye_arm64': {'Sha256Sum': 'b' * 64},
        }, 'sysroots.json'),
        {'amd64': 'a' * 64, 'arm64': 'b' * 64},
      );
    });

    test('a moved generation names the entries it found', () {
      expect(
        () => readEngineSysrootChecksums({
          'trixie_riscv64': {'Sha256Sum': 'c' * 64},
        }, 'sysroots.json'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('trixie_riscv64'),
          ),
        ),
      );
    });
  });
}
