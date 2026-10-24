/// Header-first archive scan refusing hard links and escaping entries.
///
/// A pub archive is pinned by sha256, but that pins the archive bytes, not
/// what the extracted package ends up holding: `ctx.extract` turns a tar
/// hard-link entry into a real hard link, so an entry whose target climbs out
/// of the extraction directory makes a "package file" share bytes with a file
/// elsewhere on the build host. The post-extraction walk
/// (`pub_symlink.bzl`) cannot see hard links — a hard link is a regular file
/// whose realpath is itself — so the decision comes from the archive's own
/// entry headers, before any extracted content is trusted.
///
/// This program is the scanning half of `pub_archive_scan.bzl`: it reads one
/// archive file and prints one JSON verdict to stdout, always exiting zero:
/// `{"ok": true}` for a clean archive, `{"refusal": {"kind", "path",
/// "target"}}` for the first hostile entry in archive order, or
/// `{"unscannable": "<detail>"}` for an archive it cannot read exactly. The
/// Starlark half (`pub_scan.bzl`) formats those verdicts with the same
/// messages the pure-Starlark scan used, so refusals read exactly as before.
///
/// Covered tar shapes match the old scan: ustar names (with `prefix`), GNU
/// long names and long links (`L`/`K`), and pax extended and global headers
/// (`x`/`g`, honouring `path=`, `linkpath=` and `size=`). Sizes parse as
/// octal or base-256. Unknown entry kinds, sparse entries, corrupt headers,
/// and truncated streams are unscannable: a package the scanner cannot read
/// exactly is not a package the build trusts. Every hard-link entry is
/// refused whatever its target; symlink entries are refused when their target
/// is absolute or climbs out of the package root (the walk's lexical rule);
/// any entry whose own path is absolute or climbs out of the root is refused
/// too. Per-byte integrity (gzip CRC32, tar checksums) is deliberately not
/// re-verified: the lock's sha256 already pins every byte. The gzip ISIZE
/// size check is not repeated either: truncation past the sha256 pin is
/// impossible, and the required tar end-of-archive marker catches a cut
/// stream at the tar layer.
///
/// Determinism: the verdict is a pure function of the archive bytes. Path
/// rules use the strictest reading on every OS (backslash counts as a
/// separator everywhere), so verdicts are identical on Linux, macOS and
/// Windows. Field text decodes as Latin-1, preserving byte values one to one.
import 'dart:convert';
import 'dart:io';

/// Cap on collected GNU long-name, long-link and pax record data. Real names
/// stay far below it; anything past it is hostile, not a package path.
const _maxCollectBytes = 1048576;

/// The tar end-of-archive marker: the walk stops at the first 512-byte zero
/// block and ignores whatever follows it, the way the extractor does.
const _zeroBlockLength = 512;

/// Fails the scan closed with an unscannable-archive detail.
Never _unscannable(String detail) => throw _Unscannable(detail);

/// An archive the scanner cannot read exactly. Caught in [main] and reported
/// as an `unscannable` verdict, never as a clean scan.
class _Unscannable implements Exception {
  _Unscannable(this.detail);
  final String detail;
  @override
  String toString() => detail;
}

/// A refused entry: its kind, its root-relative path, and its raw target
/// (empty for entries that carry no target).
class _Refusal {
  _Refusal(this.kind, this.path, this.target);
  final String kind;
  final String path;
  final String target;
}

/// Returns true for absolute paths on any OS: POSIX (`/etc/passwd`) and
/// Windows drive or UNC targets (`C:/secret`, `\\host\share`). The input is
/// slash-normalized, so a leading backslash already reads as `/`.
bool _isAbsolute(String path) {
  if (path.startsWith('/')) return true;
  if (path.length >= 2 && path[1] == ':') return true;
  return false;
}

/// Returns true when a tar entry path escapes the package root: absolute
/// paths, and relative paths whose `..` segments climb above the root.
/// Applies the walk's path rule (`symlink_escapes_package` with an empty
/// holding directory) to entry paths, so the header scan and the
/// post-extraction walk never disagree.
bool _entryPathEscapes(String name) {
  final normalized = name.replaceAll('\\', '/');
  if (_isAbsolute(normalized)) return true;
  var depth = 0;
  for (final seg in normalized.split('/')) {
    if (seg == '' || seg == '.') continue;
    if (seg == '..') {
      if (depth == 0) return true;
      depth--;
    } else {
      depth++;
    }
  }
  return false;
}

/// Returns true when a symlink target escapes its package root: the walk's
/// lexical rule (`symlink_escapes_package` in `pub_symlink.bzl`). Absolute
/// targets escape, and relative targets escape when their `..` segments climb
/// above the directory holding the link. An empty target is broken and
/// treated as escaping.
bool _symlinkEscapes(String linkPath, String target) {
  if (target == '') return true;
  final normalized = target.replaceAll('\\', '/');
  if (_isAbsolute(normalized)) return true;
  var depth = 0;
  final holding = linkPath.split('/');
  // The link name itself is the last segment; only its directory holds it.
  for (var i = 0; i < holding.length - 1; i++) {
    final seg = holding[i];
    if (seg == '' || seg == '.') continue;
    depth++;
  }
  for (final seg in normalized.split('/')) {
    if (seg == '' || seg == '.') continue;
    if (seg == '..') {
      if (depth <= 0) return true;
      depth--;
    } else {
      depth++;
    }
  }
  return false;
}

/// Cuts [bytes] at its first NUL pad byte, decoding the kept part Latin-1.
String _cutNulAt(List<int> bytes, int start, int end) {
  var cut = end;
  for (var i = start; i < end; i++) {
    if (bytes[i] == 0) {
      cut = i;
      break;
    }
  }
  return latin1.decode(bytes.sublist(start, cut), allowInvalid: false);
}

/// Parses a tar numeric field: octal, or base-256 when flagged by the top bit
/// of the first byte. Anything else must be octal digits with NUL or space
/// padding; anything unparsable fails the scan closed.
int _parseNumber(List<int> field, String what) {
  if (field[0] >= 128) {
    var v = field[0] - 128;
    for (var i = 1; i < field.length; i++) {
      v = v * 256 + field[i];
    }
    return v;
  }
  final text = latin1
      .decode(field, allowInvalid: false)
      .split('\x00')
      .first
      .trim();
  if (text == '') return 0;
  var v = 0;
  for (final unit in text.codeUnits) {
    final d = unit - 0x30;
    if (d < 0 || d > 7) _unscannable("an entry's $what is not a number");
    v = v * 8 + d;
  }
  return v;
}

/// One parsed 512-byte tar header block.
class _Header {
  _Header(this.name, this.size, this.typeflag, this.linkname);
  final String name;
  final int size;
  final String typeflag;
  final String linkname;
}

/// Parses one 512-byte header at [pos]. Joins `prefix` and `name` the way the
/// extractor does, so over-long paths classify under their full name.
_Header _parseHeader(List<int> bytes, int pos) {
  var name = _cutNulAt(bytes, pos, pos + 100);
  final prefix = _cutNulAt(bytes, pos + 345, pos + 500);
  if (prefix != '') name = '$prefix/$name';
  if (name == '') _unscannable('an entry has no name');
  return _Header(
    name,
    _parseNumber(bytes.sublist(pos + 124, pos + 136), 'size'),
    String.fromCharCode(bytes[pos + 156]),
    _cutNulAt(bytes, pos + 157, pos + 257),
  );
}

/// Pax `path=`, `linkpath=` and `size=` overrides parsed from record data.
typedef _PaxRecords = ({String? path, String? linkpath, int? size});

/// Parses pax record data into its scan-relevant records. Only `path=`,
/// `linkpath=` and `size=` affect the scan; the rest are ignored. A malformed
/// record fails the scan closed.
_PaxRecords _parsePaxRecords(String text) {
  String? path;
  String? linkpath;
  int? size;
  for (final line in text.split('\n')) {
    if (line == '') continue;
    final space = line.indexOf(' ');
    if (space < 0) _unscannable('a pax record has no length prefix');
    final record = line.substring(space + 1);
    final eq = record.indexOf('=');
    if (eq < 0) _unscannable('a pax record has no key');
    final key = record.substring(0, eq);
    final val = record.substring(eq + 1);
    if (key == 'path') {
      path = val;
    } else if (key == 'linkpath') {
      linkpath = val;
    } else if (key == 'size') {
      var v = 0;
      for (final unit in val.trim().codeUnits) {
        final d = unit - 0x30;
        if (d < 0 || d > 9) _unscannable('a pax size is not a number');
        v = v * 10 + d;
      }
      size = v;
    }
  }
  return (path: path, linkpath: linkpath, size: size);
}

/// The offset-walk tar scan state: the input bytes, the header cursor, and
/// the pending and global name records. One instance scans one tar stream.
class _TarScan {
  _TarScan(this._bytes);
  final List<int> _bytes;
  int _pos = 0;
  String? _pname;
  String? _plink;
  String? _ppath;
  String? _plinkpath;
  int? _psize;
  String? _gpath;
  String? _glinkpath;

  /// Drops this entry's name records after it is classified, so they never
  /// leak into the next entry. A pax `size=` override survives: the next
  /// entry's data length consumes it.
  void _clearPending() {
    _pname = null;
    _plink = null;
    _ppath = null;
    _plinkpath = null;
  }

  /// Resolves one entry field across its override sources: a GNU
  /// long-name/long-link record or a pax `path=`/`linkpath=` record set for
  /// this entry wins; otherwise a pax global record wins; otherwise the
  /// header field stands.
  String _resolve(String header, String? pending, String? global) {
    if (pending != null) return pending;
    if (global != null) return global;
    return header;
  }

  /// Classifies a hard-link/symlink entry against the pending name records,
  /// refusing hostile entries. Returns the refusal, or null when benign.
  _Refusal? _classifyLink(_Header header, String kind) {
    final name = _resolve(header.name, _ppath ?? _pname, _gpath);
    final target = _resolve(header.linkname, _plinkpath ?? _plink, _glinkpath);
    _clearPending();
    if (_entryPathEscapes(name)) return _Refusal('path', name, target);
    if (kind == '1') return _Refusal('hard-link', name, target);
    if (_symlinkEscapes(name, target)) return _Refusal('symlink', name, target);
    return null;
  }

  /// Stores a GNU long-name/long-link or pax record into the pending state.
  /// Global records (`g`) persist for every later entry; extended records
  /// (`x`) apply to the next entry only, with `size=` replacing its data
  /// length.
  void _storeNameRecord(String kind, int size, int dataPos) {
    if (dataPos + size > _bytes.length)
      _unscannable('the tar archive is truncated');
    if (size > _maxCollectBytes)
      _unscannable('a name record is too long to scan');
    final text = size == 0
        ? ''
        : latin1.decode(
            _bytes.sublist(dataPos, dataPos + size),
            allowInvalid: false,
          );
    if (kind == 'L') {
      _pname = text.split('\x00').first;
    } else if (kind == 'K') {
      _plink = text.split('\x00').first;
    } else {
      final recs = _parsePaxRecords(text);
      if (kind == 'g') {
        if (recs.path != null) _gpath = recs.path;
        if (recs.linkpath != null) _glinkpath = recs.linkpath;
      } else {
        _ppath = recs.path;
        _plinkpath = recs.linkpath;
        _psize = recs.size;
      }
    }
  }

  /// Classifies the header at the cursor and advances past the entry. Returns
  /// the refusal, or null when the entry is benign.
  _Refusal? _entry() {
    final header = _parseHeader(_bytes, _pos);
    var kind = header.typeflag;
    if (kind == '\x00') kind = '0';
    // A pax `size=` override replaces the header size for the next entry.
    final size = _psize ?? header.size;
    _psize = null;
    final dataPos = _pos + 512;
    if (kind == '1' || kind == '2') {
      final refusal = _classifyLink(header, kind);
      _pos = dataPos + size + (-size) % 512;
      return refusal;
    }
    // Every other entry carries a path too: an absolute or climbing file,
    // directory, or name-record path escapes the root the same way.
    final name = _resolve(header.name, _ppath ?? _pname, _gpath);
    if (_entryPathEscapes(name)) {
      _pos = dataPos + size + (-size) % 512;
      return _Refusal('path', name, '');
    }
    if (kind == 'L' || kind == 'K' || kind == 'x' || kind == 'g') {
      _storeNameRecord(kind, size, dataPos);
    } else if (kind == '0' ||
        kind == '5' ||
        kind == 'D' ||
        kind == '3' ||
        kind == '4' ||
        kind == '6') {
      _clearPending();
    } else if (kind == 'S') {
      _unscannable('a sparse entry cannot be scanned');
    } else {
      _unscannable("an entry has kind '$kind', which cannot be scanned");
    }
    _pos = dataPos + size + (-size) % 512;
    return null;
  }

  /// Walks the tar stream header to header without touching file data and
  /// returns the first refusal, or null for a clean archive. The walk stops
  /// at the first zero block and ignores whatever follows it, the way the
  /// extractor does; a stream with no end marker fails closed.
  _Refusal? scan() {
    final n = _bytes.length;
    final limit = n ~/ 512 + 2;
    for (var i = 0; i < limit; i++) {
      if (_pos + 512 > n) _unscannable('the tar archive is truncated');
      var zero = true;
      for (var j = 0; j < _zeroBlockLength; j++) {
        if (_bytes[_pos + j] != 0) {
          zero = false;
          break;
        }
      }
      if (zero) return null;
      final refusal = _entry();
      if (refusal != null) return refusal;
    }
    _unscannable('the tar archive never terminates');
  }
}

/// Skips one NUL-terminated gzip header string (name or comment).
int _skipGzipString(List<int> bytes, int pos) {
  for (;;) {
    if (pos >= bytes.length) _unscannable('a gzip header is truncated');
    if (bytes[pos] == 0) return pos + 1;
    pos++;
  }
}

/// Parses one gzip member header at [pos] and returns the deflate-body start.
/// Only the framing is parsed here; the body is inflated by the caller.
int _parseGzipHeader(List<int> bytes, int pos) {
  if (pos + 10 > bytes.length) _unscannable('a gzip member is truncated');
  if (bytes[pos] != 31 || bytes[pos + 1] != 139 || bytes[pos + 2] != 8) {
    _unscannable('a gzip member has a bad header');
  }
  final flags = bytes[pos + 3];
  pos += 10;
  if (flags & 4 != 0) {
    if (pos + 2 > bytes.length) _unscannable('a gzip header is truncated');
    final xlen = bytes[pos] + bytes[pos + 1] * 256;
    pos += 2;
    if (pos + xlen > bytes.length) _unscannable('a gzip header is truncated');
    pos += xlen;
  }
  if (flags & 8 != 0) pos = _skipGzipString(bytes, pos);
  if (flags & 16 != 0) pos = _skipGzipString(bytes, pos);
  if (flags & 2 != 0) {
    if (pos + 2 > bytes.length) _unscannable('a gzip header is truncated');
    pos += 2;
  }
  return pos;
}

/// Scans archive bytes for refused entries: the first hostile entry in
/// archive order, or null for a clean archive. Sniffs the framing — gzip
/// members (inflated, then walked by header offsets) or a plain tar (walked
/// directly). Trailing NUL padding past the last gzip member is skipped, the
/// way the old scan tolerated pub.dev's padded tarballs; any other trailing
/// bytes fail the inflate closed.
_Refusal? _scanArchive(List<int> bytes) {
  if (bytes.isEmpty) _unscannable('the archive is empty');
  if (bytes.length >= 2 && bytes[0] == 31 && bytes[1] == 139) {
    var end = bytes.length;
    while (end > 0 && bytes[end - 1] == 0) {
      end--;
    }
    final trimmed = bytes.sublist(0, end);
    _parseGzipHeader(trimmed, 0);
    late List<int> inflated;
    try {
      inflated = GZipCodec().decode(trimmed);
    } on FormatException {
      _unscannable('the deflate stream cannot be decoded');
    }
    return _TarScan(inflated).scan();
  }
  return _TarScan(bytes).scan();
}

/// Scans archive bytes and returns the JSON verdict map: `{'ok': true}` for
/// a clean archive, `{'refusal': {'kind', 'path', 'target'}}` for the first
/// hostile entry in archive order, or `{'unscannable': '<detail>'}` for an
/// archive that cannot be read exactly. Public so the `pub_scan_test` unit
/// test drives the same code the executable runs; [main] only adds the file
/// read and the stdout print around it.
Map<String, Object?> scanArchiveVerdict(List<int> bytes) {
  try {
    final refusal = _scanArchive(bytes);
    return refusal == null
        ? {'ok': true}
        : {
            'refusal': {
              'kind': refusal.kind,
              'path': refusal.path,
              'target': refusal.target,
            },
          };
  } on _Unscannable catch (e) {
    return {'unscannable': e.detail};
  }
}

/// CLI entrypoint: reads the archive file, scans its headers, and prints
/// the one JSON verdict to stdout, always exiting zero.
void main(List<String> args) {
  Map<String, Object?> verdict;
  try {
    if (args.isEmpty) _unscannable('no archive path was given');
    late List<int> bytes;
    try {
      bytes = File(args[0]).readAsBytesSync();
    } on FileSystemException {
      _unscannable('the archive cannot be read');
    }
    verdict = scanArchiveVerdict(bytes);
  } on _Unscannable catch (e) {
    verdict = {'unscannable': e.detail};
  }
  print(jsonEncode(verdict));
}
