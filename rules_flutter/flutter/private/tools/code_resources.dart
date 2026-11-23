/// `_CodeSignature/CodeResources` generation for Apple bundles.
///
/// Collects the files of an assembled `.app` directory, hashes them with
/// the digests in `xtool_hash.dart`, and renders the Apple `CodeResources`
/// XML property list. Escapes XML with `plist_parse.dart`.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'plist_parse.dart' show escapeXml;
import 'xtool_hash.dart' show sha1Bytes, sha256Bytes;

typedef _Hashes = ({String sha1B64, String sha256B64});

// ---------------------------------------------------------------------------
// _CodeSignature/CodeResources generation
// ---------------------------------------------------------------------------

/// Lists every file under [bundleDir] relative to it, skipping signature
/// artifacts, excluded paths, and symbolic links.
List<String> _collectBundleRelativeFiles(
  Directory bundleDir,
  Set<String> excludedRelativePaths,
) {
  final relativeFiles = <String>[];

  void walk(Directory dir, String relPrefix) {
    final List<FileSystemEntity> children = dir.listSync(followLinks: false)
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final entity in children) {
      final String name = entity.uri.pathSegments
          .where((s) => s.isNotEmpty)
          .last;
      final relPath = relPrefix.isEmpty ? name : '$relPrefix/$name';
      if (relPath == '_CodeSignature' ||
          relPath.startsWith('_CodeSignature/') ||
          excludedRelativePaths.contains(relPath)) {
        continue;
      }
      if (entity is Link) {
        continue;
      } else if (entity is Directory) {
        walk(entity, relPath);
      } else if (entity is File) {
        relativeFiles.add(relPath);
      }
    }
  }

  if (bundleDir.existsSync()) walk(bundleDir, '');
  relativeFiles.sort();
  return relativeFiles;
}

/// Hashes [relativeFiles] (relative to [rootPath]) into the v1 (`files`) and
/// v2 (`files2`) CodeResources maps, omitting `Info.plist` and `PkgInfo`.
({
  Map<String, String> files1,
  Map<String, _Hashes> files2,
})
_hashBundleFiles(String rootPath, List<String> relativeFiles) {
  final files1 = <String, String>{};
  final files2 = <String, _Hashes>{};
  for (final relPath in relativeFiles) {
    final Uint8List bytes = File('$rootPath/$relPath').readAsBytesSync();
    final String sha1B64 = base64.encode(sha1Bytes(bytes));
    final String sha256B64 = base64.encode(sha256Bytes(bytes));
    // Per Apple CodeResources format, Info.plist and PkgInfo are omitted from
    // `files` / `files2` when rules2 omits them, or included in `files` for v1
    // resources. Including all non-Info.plist/PkgInfo files in both `files` and
    // `files2` matches standard codesign/zsign output.
    if (relPath != 'Info.plist' && relPath != 'PkgInfo') {
      files1[relPath] = sha1B64;
      files2[relPath] = (sha1B64: sha1B64, sha256B64: sha256B64);
    }
  }
  return (files1: files1, files2: files2);
}

/// Generates the XML contents of `_CodeSignature/CodeResources` for [bundleDir].
///
/// For iOS bundles or `.framework` directories, [bundleDir] is the `.app` or
/// `.framework` root. For macOS `.app` bundles, [bundleDir] is
/// `<AppName>.app/Contents`.
///
/// [excludedRelativePaths] specifies paths relative to [bundleDir] (using `/`)
/// that must not be listed in `CodeResources` (such as the main Mach-O
/// executable and `_CodeSignature/CodeResources` itself).
String generateCodeResources(
  Directory bundleDir, {
  Set<String> excludedRelativePaths = const {},
}) {
  final List<String> relativeFiles = _collectBundleRelativeFiles(
    bundleDir,
    excludedRelativePaths,
  );
  final (
    :Map<String, String> files1,
    :Map<String, _Hashes> files2,
  ) = _hashBundleFiles(
    bundleDir.path,
    relativeFiles,
  );
  return _renderCodeResourcesXml(files1, files2);
}

String _renderCodeResourcesXml(
  Map<String, String> files1,
  Map<String, _Hashes> files2,
) {
  final buf = StringBuffer()
    ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
    ..writeln(
      '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
      '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">',
    )
    ..writeln('<plist version="1.0">')
    ..writeln('<dict>')
    ..writeln('\t<key>files</key>')
    ..writeln('\t<dict>');
  for (final MapEntry<String, String> entry in files1.entries) {
    buf
      ..writeln('\t\t<key>${escapeXml(entry.key)}</key>')
      ..writeln('\t\t<data>${entry.value}</data>');
  }
  buf
    ..writeln('\t</dict>')
    ..writeln('\t<key>files2</key>')
    ..writeln('\t<dict>');
  for (final MapEntry<String, _Hashes> entry in files2.entries) {
    buf
      ..writeln('\t\t<key>${escapeXml(entry.key)}</key>')
      ..writeln('\t\t<dict>')
      ..writeln('\t\t\t<key>hash</key>')
      ..writeln('\t\t\t<data>${entry.value.sha1B64}</data>')
      ..writeln('\t\t\t<key>hash2</key>')
      ..writeln('\t\t\t<data>${entry.value.sha256B64}</data>')
      ..writeln('\t\t</dict>');
  }
  buf
    ..writeln('\t</dict>')
    ..writeln('\t<key>rules</key>')
    ..writeln('\t<dict>')
    ..writeln('\t\t<key>^</key>')
    ..writeln('\t\t<true/>')
    ..writeln('\t\t<key>^.*\\.lproj/</key>')
    ..writeln('\t\t<dict>')
    ..writeln('\t\t\t<key>optional</key>')
    ..writeln('\t\t\t<true/>')
    ..writeln('\t\t\t<key>weight</key>')
    ..writeln('\t\t\t<real>1000</real>')
    ..writeln('\t\t</dict>')
    ..writeln('\t</dict>')
    ..writeln('\t<key>rules2</key>')
    ..writeln('\t<dict>')
    ..writeln('\t\t<key>^</key>')
    ..writeln('\t\t<dict>')
    ..writeln('\t\t\t<key>weight</key>')
    ..writeln('\t\t\t<real>20</real>')
    ..writeln('\t\t</dict>')
    ..writeln('\t\t<key>^Info\\.plist\$</key>')
    ..writeln('\t\t<dict>')
    ..writeln('\t\t\t<key>omit</key>')
    ..writeln('\t\t\t<true/>')
    ..writeln('\t\t\t<key>weight</key>')
    ..writeln('\t\t\t<real>20</real>')
    ..writeln('\t\t</dict>')
    ..writeln('\t\t<key>^PkgInfo\$</key>')
    ..writeln('\t\t<dict>')
    ..writeln('\t\t\t<key>omit</key>')
    ..writeln('\t\t\t<true/>')
    ..writeln('\t\t\t<key>weight</key>')
    ..writeln('\t\t\t<real>20</real>')
    ..writeln('\t\t</dict>')
    ..writeln('\t</dict>')
    ..writeln('</dict>')
    ..writeln('</plist>');
  return buf.toString();
}

/// Writes `_CodeSignature/CodeResources` inside [bundleDir].
File writeCodeResources(
  Directory bundleDir, {
  Set<String> excludedRelativePaths = const {},
}) {
  final String xml = generateCodeResources(
    bundleDir,
    excludedRelativePaths: excludedRelativePaths,
  );
  final sigDir = Directory('${bundleDir.path}/_CodeSignature')
    ..createSync(recursive: true);
  final file = File('${sigDir.path}/CodeResources');
  file.writeAsStringSync(xml);
  return file;
}
