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
///
/// Streaming: [scanArchiveFile] reads the archive as a stream
/// (`File.openRead()` through a gzip decoder), walks the tar headers chunk by
/// chunk, and skips entry data without keeping it — consumed input is dropped,
/// so a streamed scan holds only its undecided window (plus at most one
/// capped name record), never the archive. Any inflate failure (a multi-member
/// boundary the streaming decoder cannot cross, trailing pad bytes, a corrupt
/// body) falls back to re-reading the file with the exact in-memory logic, so
/// multi-member gzip, trailing-NUL padding, pax and GNU long-name handling
/// keep byte-identical verdicts on every path.
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

/// Control signal: the streaming walk needs more input. Caught in [_TarScan.pump];
/// never escapes at end of input (the cursor fails closed instead).
class _NeedMore implements Exception {
  const _NeedMore();
}

/// A byte cursor over the tar stream: preloaded whole (in-memory scan) or fed
/// chunk by chunk (file scan). Positions past the buffered bytes suspend the
/// walk until more input arrives, or fail it closed at end of input. Consumed
/// input is compacted away, so skipped entry data is never kept.
class _Cursor {
  _Cursor(this._buf, {this.eof = false});
  List<int> _buf;
  bool eof;
  int _pos = 0;

  /// True when [n] bytes are readable at the cursor.
  bool ready(int n) => _pos + n <= _buf.length;

  /// Requires [n] readable bytes at the cursor: suspends the walk when more
  /// input may still arrive, or fails it closed at end of input with the same
  /// truncation detail the whole-buffer scan reports.
  void ensure(int n) {
    if (!ready(n)) {
      if (eof) _unscannable('the tar archive is truncated');
      throw const _NeedMore();
    }
  }

  /// Reads one byte at [offset] past the cursor. Callers ensure readiness.
  int byte(int offset) => _buf[_pos + offset];

  /// Copies [n] bytes at [offset] past the cursor. Callers ensure readiness.
  List<int> slice(int offset, int n) =>
      _buf.sublist(_pos + offset, _pos + offset + n);

  /// Advances past [n] bytes. Consumed input is dropped by the next [add],
  /// so skipped entry data is never kept.
  void advance(int n) {
    _pos += n;
  }

  /// Appends streamed input, dropping consumed bytes first. The cursor may
  /// stand past the buffered bytes (entry data is skipped, never fetched),
  /// so only buffered bytes are dropped and the cursor keeps its offset.
  void add(List<int> chunk) {
    if (_pos >= 65536) {
      final drop = _pos < _buf.length ? _pos : _buf.length;
      _buf = _buf.sublist(drop);
      _pos -= drop;
    }
    _buf.addAll(chunk);
  }
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

/// Cuts the cursor's bytes at the first NUL pad byte, decoding the kept part
/// Latin-1. Reads [start] through [end] past the cursor; callers ensure.
String _cutNulAt(_Cursor cursor, int start, int end) {
  var cut = end;
  for (var i = start; i < end; i++) {
    if (cursor.byte(i) == 0) {
      cut = i;
      break;
    }
  }
  return latin1.decode(cursor.slice(start, cut - start), allowInvalid: false);
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

/// Parses one 512-byte header at the cursor. Joins `prefix` and `name` the way
/// the extractor does, so over-long paths classify under their full name.
/// Callers ensure the 512 bytes first.
_Header _parseHeader(_Cursor cursor) {
  var name = _cutNulAt(cursor, 0, 100);
  final prefix = _cutNulAt(cursor, 345, 500);
  if (prefix != '') name = '$prefix/$name';
  if (name == '') _unscannable('an entry has no name');
  return _Header(
    name,
    _parseNumber(cursor.slice(124, 12), 'size'),
    String.fromCharCode(cursor.byte(156)),
    _cutNulAt(cursor, 157, 257),
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

/// The offset-walk tar scan state: the input cursor, and the pending and
/// global name records. One instance scans one tar stream. The default
/// constructor preloads whole bytes (end of input from the start, exactly the
/// old whole-buffer scan); [_TarScan.streaming] starts empty and suspends
/// until fed.
class _TarScan {
  _TarScan(List<int> bytes)
    : _cursor = _Cursor(bytes, eof: true),
      _limit = bytes.length ~/ 512 + 2;
  _TarScan.streaming() : _cursor = _Cursor(<int>[]), _limit = null;
  final _Cursor _cursor;
  final int? _limit;
  int _steps = 0;
  bool _finished = false;
  String? _pname;
  String? _plink;
  String? _ppath;
  String? _plinkpath;
  int? _psize;
  String? _gpath;
  String? _glinkpath;

  /// True once the walk has seen the end-of-archive marker.
  bool get finished => _finished;

  /// Feeds one streamed chunk and walks as far as possible.
  _Refusal? pumpAfter(List<int> chunk) {
    _cursor.add(chunk);
    return pump();
  }

  /// Ends streamed input and runs the walk to a verdict: the first refusal,
  /// or null for a clean archive. Short input fails closed, as before.
  _Refusal? finish() {
    _cursor.eof = true;
    final refusal = pump();
    if (refusal != null) return refusal;
    if (!_finished) _unscannable('the tar archive is truncated');
    return null;
  }

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
  /// length. Record data sits 512 bytes past the cursor.
  void _storeNameRecord(String kind, int size) {
    // At end of input the check order matches the old scan exactly
    // (truncation first, then the length cap); while streaming, an over-cap
    // claim fails fast instead of buffering unbounded input.
    if (!_cursor.ready(512 + size)) {
      if (_cursor.eof) _unscannable('the tar archive is truncated');
      if (size > _maxCollectBytes) {
        _unscannable('a name record is too long to scan');
      }
      throw const _NeedMore();
    }
    if (size > _maxCollectBytes) {
      _unscannable('a name record is too long to scan');
    }
    final text = size == 0
        ? ''
        : latin1.decode(_cursor.slice(512, size), allowInvalid: false);
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
  /// the refusal, or null when the entry is benign. Callers ensure the 512
  /// header bytes; record data suspends until buffered.
  _Refusal? _entry() {
    final header = _parseHeader(_cursor);
    var kind = header.typeflag;
    if (kind == '\x00') kind = '0';
    // A pax `size=` override replaces the header size for the next entry.
    final size = _psize ?? header.size;
    _psize = null;
    final skip = 512 + size + (-size) % 512;
    if (kind == '1' || kind == '2') {
      final refusal = _classifyLink(header, kind);
      _cursor.advance(skip);
      return refusal;
    }
    // Every other entry carries a path too: an absolute or climbing file,
    // directory, or name-record path escapes the root the same way.
    final name = _resolve(header.name, _ppath ?? _pname, _gpath);
    if (_entryPathEscapes(name)) {
      _cursor.advance(skip);
      return _Refusal('path', name, '');
    }
    if (kind == 'L' || kind == 'K' || kind == 'x' || kind == 'g') {
      _storeNameRecord(kind, size);
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
    _cursor.advance(skip);
    return null;
  }

  /// Walks the tar stream header to header without touching file data and
  /// returns the first refusal, a clean end, or — streaming only — a
  /// suspension (null with [finished] false) when the buffered input runs
  /// out. The walk stops at the first zero block and ignores whatever follows
  /// it, the way the extractor does; a stream with no end marker fails
  /// closed. The whole-buffer scan keeps its exact step bound.
  _Refusal? pump() {
    try {
      for (;;) {
        if (_limit != null && _steps >= _limit) {
          _unscannable('the tar archive never terminates');
        }
        _steps++;
        _cursor.ensure(512);
        var zero = true;
        for (var j = 0; j < _zeroBlockLength; j++) {
          if (_cursor.byte(j) != 0) {
            zero = false;
            break;
          }
        }
        if (zero) {
          _finished = true;
          return null;
        }
        final refusal = _entry();
        if (refusal != null) return refusal;
      }
    } on _NeedMore {
      return null;
    }
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
    return _TarScan(inflated).finish();
  }
  return _TarScan(bytes).finish();
}

/// Scans archive bytes and returns the JSON verdict map: `{'ok': true}` for
/// a clean archive, `{'refusal': {'kind', 'path', 'target'}}` for the first
/// hostile entry in archive order, or `{'unscannable': '<detail>'}` for an
/// archive that cannot be read exactly. Public so the `pub_scan_test` unit
/// test drives the same code the executable runs; [main] only adds the file
/// read and the stdout print around it.
Map<String, Object?> scanArchiveVerdict(List<int> bytes) {
  try {
    return _verdictFor(_scanArchive(bytes));
  } on _Unscannable catch (e) {
    return {'unscannable': e.detail};
  }
}

/// Formats one walk outcome as the JSON verdict map.
Map<String, Object?> _verdictFor(_Refusal? refusal) => refusal == null
    ? {'ok': true}
    : {
        'refusal': {
          'kind': refusal.kind,
          'path': refusal.path,
          'target': refusal.target,
        },
      };

/// Streams [compressed] through the shared tar walker and returns the walk
/// outcome: the first refusal, or null for a clean archive. When [gzipped],
/// the bytes pass through one gzip decoder first; a clean walk then drains
/// the decoder to its end, so trailing junk still fails the inflate exactly
/// as the in-memory scan reports it (a plain tar's tail is ignored, as
/// before). A decoder failure throws [FormatException] for the caller to
/// re-scan from disk with the exact in-memory logic.
Future<_Refusal?> _scanStream(
  Stream<List<int>> compressed,
  bool gzipped,
) async {
  final walk = _TarScan.streaming();
  Stream<List<int>> source = compressed;
  if (gzipped) source = source.transform(gzip.decoder);
  await for (final chunk in source) {
    if (walk.finished) continue;
    final refusal = walk.pumpAfter(chunk);
    if (refusal != null) return refusal;
    if (walk.finished && !gzipped) return null;
  }
  return walk.finish();
}

/// Scans the archive file at [path] and returns the JSON verdict map, in the
/// same shape as [scanArchiveVerdict]. Reads the file as a stream
/// (`File.openRead()` through a gzip decoder), walks the tar headers chunk by
/// chunk, and skips entry data without keeping it. Refusals short-circuit:
/// the rest of the file is never read. Any inflate failure re-scans the file
/// with the exact in-memory logic, so multi-member gzip, trailing-NUL
/// padding, and corrupt bodies keep byte-identical verdicts.
Future<Map<String, Object?>> scanArchiveFile(String path) {
  final file = File(path);
  return _scanFile(file, file.readAsBytes);
}

/// Scans [bytes] with the streaming walk, fed in [chunkSize] pieces, and
/// returns the JSON verdict map. Public so the `pub_scan_test` unit test
/// proves the streaming walk gives the same verdicts as [scanArchiveVerdict]
/// at every chunking, including splits mid-header and mid-record.
Future<Map<String, Object?>> scanArchiveChunked(
  List<int> bytes,
  int chunkSize,
) {
  final chunks = <List<int>>[];
  for (var i = 0; i < bytes.length; i += chunkSize) {
    chunks.add(
      bytes.sublist(
        i,
        i + chunkSize > bytes.length ? bytes.length : i + chunkSize,
      ),
    );
  }
  return _scanSniffed(
    Stream.fromIterable(chunks),
    bytes.isEmpty ? null : _sniffGzip(bytes),
    () async => bytes,
  );
}

/// Reads the first two bytes of [file] to sniff the framing: gzip magic, or
/// plain tar. Returns null for an empty file.
Future<bool?> _sniffFile(File file) async {
  final head = <int>[];
  await for (final chunk in file.openRead(0, 2)) {
    head.addAll(chunk);
  }
  if (head.isEmpty) return null;
  return _sniffGzip(head);
}

/// Sniffs the framing off [head]: true for the gzip magic, else plain tar.
bool _sniffGzip(List<int> head) =>
    head.length >= 2 && head[0] == 31 && head[1] == 139;

/// Shared file/chunk driver: sniffs [gzipped] (null for empty input), runs
/// the streaming walk, and re-scans whole bytes from [reread] with the exact
/// in-memory logic when the streaming inflate fails.
Future<Map<String, Object?>> _scanSniffed(
  Stream<List<int>> compressed,
  bool? gzipped,
  Future<List<int>> Function() reread,
) async {
  try {
    if (gzipped == null) return {'unscannable': 'the archive is empty'};
    return _verdictFor(await _scanStream(compressed, gzipped));
  } on FormatException {
    return scanArchiveVerdict(await reread());
  } on _Unscannable catch (e) {
    return {'unscannable': e.detail};
  }
}

/// File driver: sniffs the framing off the file's head, then streams the
/// whole file through [_scanSniffed]. A file that cannot be opened or read
/// reports the same detail the old whole-file read did.
Future<Map<String, Object?>> _scanFile(
  File file,
  Future<List<int>> Function() reread,
) async {
  try {
    return await _scanSniffed(file.openRead(), await _sniffFile(file), reread);
  } on FileSystemException {
    return {'unscannable': 'the archive cannot be read'};
  }
}

/// CLI entrypoint: reads the archive file, scans its headers, and prints
/// the one JSON verdict to stdout, always exiting zero.
void main(List<String> args) async {
  Map<String, Object?> verdict;
  try {
    if (args.isEmpty) _unscannable('no archive path was given');
    verdict = await scanArchiveFile(args[0]);
  } on _Unscannable catch (e) {
    verdict = {'unscannable': e.detail};
  }
  print(jsonEncode(verdict));
}
