import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:runfiles/runfiles.dart';

/// Resolves a runfile from [envKey] (`$(rlocationpaths ...)`), matching [suffix].
File resolveRunfile(Runfiles runfiles, String envKey, {String suffix = ''}) {
  final raw = Platform.environment[envKey];
  if (raw == null || raw.trim().isEmpty) {
    throw StateError('Missing environment variable $envKey');
  }
  final candidates = raw
      .split(RegExp(r'\s+'))
      .where((token) => token.isNotEmpty && token.endsWith(suffix))
      .toList();
  if (candidates.isEmpty) {
    throw StateError('No path in $envKey ($raw) ends with "$suffix"');
  }
  final rloc = candidates.first;
  var resolved = runfiles.rlocation(rloc);
  if ((resolved.isEmpty || !File(resolved).existsSync()) &&
      rloc.startsWith('_main/')) {
    resolved = runfiles.rlocation(
      'rules_flutter_pub_scc/${rloc.substring('_main/'.length)}',
    );
  }
  final file = File(resolved);
  if (!file.existsSync()) {
    throw StateError('Runfile for $envKey ($rloc) not found at $resolved');
  }
  return file;
}

/// Parses a ZIP archive into lazy byte readers keyed by entry name.
Map<String, Uint8List Function()> readZipArchive(Uint8List archiveBytes) {
  final view = ByteData.sublistView(archiveBytes);
  final eocd = _findEndOfCentralDirectory(archiveBytes, view);
  final count = view.getUint16(eocd + 10, Endian.little);
  var cursor = view.getUint32(eocd + 16, Endian.little);
  final entries = <String, Uint8List Function()>{};

  for (var i = 0; i < count; i++) {
    final sig = view.getUint32(cursor, Endian.little);
    if (sig != 0x02014b50) {
      throw FormatException('Bad central directory signature at $cursor');
    }
    final method = view.getUint16(cursor + 10, Endian.little);
    final compressedLen = view.getUint32(cursor + 20, Endian.little);
    final nameLen = view.getUint16(cursor + 28, Endian.little);
    final extraLen = view.getUint16(cursor + 30, Endian.little);
    final commentLen = view.getUint16(cursor + 32, Endian.little);
    final localOffset = view.getUint32(cursor + 42, Endian.little);
    final name = utf8.decode(
      Uint8List.sublistView(archiveBytes, cursor + 46, cursor + 46 + nameLen),
    );
    entries[name] = () => _extractEntry(
      archiveBytes,
      view,
      localOffset,
      compressedLen,
      method,
      name,
    );
    cursor += 46 + nameLen + extraLen + commentLen;
  }
  return entries;
}

int _findEndOfCentralDirectory(Uint8List bytes, ByteData view) {
  final minOffset = math.max(0, bytes.length - 65557);
  for (var pos = bytes.length - 22; pos >= minOffset; pos--) {
    if (view.getUint32(pos, Endian.little) == 0x06054b50) {
      return pos;
    }
  }
  throw const FormatException('ZIP end-of-central-directory record not found');
}

Uint8List _extractEntry(
  Uint8List bytes,
  ByteData view,
  int localOffset,
  int compressedLen,
  int method,
  String name,
) {
  if (view.getUint32(localOffset, Endian.little) != 0x04034b50) {
    throw FormatException('Bad local file header for $name at $localOffset');
  }
  final localNameLen = view.getUint16(localOffset + 26, Endian.little);
  final localExtraLen = view.getUint16(localOffset + 28, Endian.little);
  final start = localOffset + 30 + localNameLen + localExtraLen;
  final slice = Uint8List.sublistView(bytes, start, start + compressedLen);
  if (method == 0) {
    return Uint8List.fromList(slice);
  }
  if (method == 8) {
    return Uint8List.fromList(ZLibCodec(raw: true).decode(slice));
  }
  throw UnsupportedError('Unsupported ZIP compression method $method on $name');
}

/// Decodes [key] from [entries] as UTF-8, failing if [key] is absent.
String readZipEntryUtf8(Map<String, Uint8List Function()> entries, String key) {
  final reader = entries[key];
  if (reader == null) {
    throw StateError('Missing archive entry: $key');
  }
  return utf8.decode(reader());
}
