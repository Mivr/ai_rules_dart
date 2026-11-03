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
/// too. Per-byte integrity is checked explicitly: every gzip member's CRC32
/// and ISIZE trailer must match its inflated bytes, and the tar walk still
/// requires its end-of-archive marker. Tar header checksums are not
/// re-verified: the lock's sha256 already pins every byte, and the scanner's
/// own framing checks catch a stream that cannot be read exactly.
///
/// Determinism: the verdict is a pure function of the archive bytes. Path
/// rules use the strictest reading on every OS (backslash counts as a
/// separator everywhere), so verdicts are identical on Linux, macOS and
/// Windows. Field text decodes as Latin-1, preserving byte values one to one.
///
/// Streaming: [scanArchiveFile] reads the archive as a stream
/// (`File.openRead()`), decodes the gzip members and walks the tar headers
/// chunk by chunk, and skips entry data without keeping it — consumed input is
/// dropped, so a streamed scan holds only its 32 KiB deflate window and its
/// undecided tar window (plus at most one capped name record), never the
/// archive. Gzip member framing, the deflate body and the CRC32/ISIZE trailer
/// are decoded in pure Dart, so a member split across chunks, trailing pad
/// bytes and multi-member streams keep byte-identical verdicts on every path
/// and platform.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

const _badDeflate = 'the deflate stream cannot be decoded';

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
  _Cursor(this._buf);
  List<int> _buf;
  bool eof = false;
  int _pos = 0;

  /// True when [n] bytes are readable at the cursor.
  bool ready(int n) => _pos + n <= _buf.length;

  /// Requires [n] readable bytes at the cursor: suspends the walk when more
  /// input may still arrive, or fails it closed at end of input with the same
  /// truncation detail the whole-buffer scan reports.
  void ensure(int n) {
    if (ready(n)) return;
    if (eof) _unscannable('the tar archive is truncated');
    throw const _NeedMore();
  }

  /// Reads one byte at [offset] past the cursor. Callers ensure readiness.
  int byte(int offset) => _buf[_pos + offset];

  /// Copies [n] bytes at [offset] past the cursor. Callers ensure readiness.
  List<int> slice(int offset, int n) =>
      _buf.sublist(_pos + offset, _pos + offset + n);

  /// Advances past [n] bytes. Consumed input is dropped by the next [add],
  /// so skipped entry data is never kept.
  void advance(int n) => _pos += n;

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
bool _isAbsolute(String path) =>
    path.startsWith('/') || (path.length >= 2 && path[1] == ':');

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
    if (field[0] == 255) _unscannable("an entry's $what is not a number");
    var v = field[0] - 128;
    for (var i = 1; i < field.length; i++) {
      v = v * 256 + field[i];
      if (v < 0 || v > 0x1FFFFFFFFFFFFF) {
        _unscannable("an entry's $what is not a number");
      }
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
int _parsePaxSize(String val) {
  final text = val.trim();
  if (text.isEmpty) _unscannable('a pax size is not a number');
  var v = 0;
  for (final int unit in text.codeUnits) {
    final d = unit - 0x30;
    v = v * 10 + d;
    if (d < 0 || d > 9 || v < 0 || v > 0x1FFFFFFFFFFFFF) {
      _unscannable('a pax size is not a number');
    }
  }
  return v;
}

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
    if (key == 'path') path = val;
    if (key == 'linkpath') linkpath = val;
    if (key == 'size') size = _parsePaxSize(val);
  }
  return (path: path, linkpath: linkpath, size: size);
}

/// The offset-walk tar scan state: the input cursor, and the pending and
/// global name records. One instance scans one tar stream. The default
/// constructor preloads whole bytes (end of input from the start, exactly the
/// old whole-buffer scan); [_TarScan.streaming] starts empty and suspends
/// until fed.
class _TarScan {
  _TarScan.streaming() : _cursor = _Cursor(<int>[]);
  final _Cursor _cursor;
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
    _pname = _plink = _ppath = _plinkpath = null;
  }

  /// Resolves one entry field across its override sources: a GNU
  /// long-name/long-link record or a pax `path=`/`linkpath=` record set for
  /// this entry wins; otherwise a pax global record wins; otherwise the
  /// header field stands.
  String _resolve(String header, String? pending, String? global) =>
      pending ?? global ?? header;

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
    } else if (kind == 'g') {
      final recs = _parsePaxRecords(text);
      _gpath = recs.path ?? _gpath;
      _glinkpath = recs.linkpath ?? _glinkpath;
    } else {
      final recs = _parsePaxRecords(text);
      _ppath = recs.path;
      _plinkpath = recs.linkpath;
      _psize = recs.size;
    }
  }

  /// Classifies the header at the cursor and advances past the entry. Returns
  /// the refusal, or null when the entry is benign. Callers ensure the 512
  /// header bytes; record data suspends until buffered.
  _Refusal? _entry() {
    final header = _parseHeader(_cursor);
    final kind = header.typeflag == '\x00' ? '0' : header.typeflag;
    final size = _psize ?? header.size;
    _psize = null;
    final skip = 512 + size + (-size) % 512;
    if (kind == '1' || kind == '2') {
      final refusal = _classifyLink(header, kind);
      _cursor.advance(skip);
      return refusal;
    }
    final name = _resolve(header.name, _ppath ?? _pname, _gpath);
    if (_entryPathEscapes(name)) {
      _cursor.advance(skip);
      return _Refusal('path', name, '');
    }
    if ('LKxg'.contains(kind)) {
      _storeNameRecord(kind, size);
    } else if ('05D346'.contains(kind)) {
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

final Uint32List _crcTable = () {
  final t = Uint32List(256);
  for (var i = 0; i < 256; i++) {
    var c = i;
    for (var j = 0; j < 8; j++) {
      c = (c >>> 1) ^ ((c & 1) * 0xEDB88320);
    }
    t[i] = c;
  }
  return t;
}();

int _crc32(List<int> bytes) {
  var c = 0xFFFFFFFF;
  for (final b in bytes) {
    c = _crcTable[(c ^ b) & 0xFF] ^ (c >>> 8);
  }
  return ~c;
}

final Uint8List _codeOrder = base64Decode('EBESAAgHCQYKBQsEDAMNAg4BDw==');

class _HuffmanTree {
  _HuffmanTree(this.table, this.maxBits);
  final Uint32List table;
  final int maxBits;

  static _HuffmanTree? build(List<int> lens, int max, [bool isDist = false]) {
    var maxBits = 0;
    var totalSymbols = 0;
    final count = Uint16List(max + 1);
    for (final l in lens) {
      if (l > max) return null;
      if (l > 0) {
        count[l]++;
        if (l > maxBits) maxBits = l;
        totalSymbols++;
      }
    }
    if (totalSymbols == 0) {
      return isDist ? _HuffmanTree(Uint32List(1), 0) : null;
    }
    if (isDist && totalSymbols == 1 && count[1] == 1) {
      final t = Uint32List(2);
      t[0] = t[1] = (lens.indexOf(1) << 8) | 1;
      return _HuffmanTree(t, 1);
    }
    var left = 1;
    for (var len = 1; len <= max; len++) {
      left = (left << 1) - count[len];
      if (left < 0) return null;
    }
    if (left != 0) return null;

    final nextCode = Uint16List(maxBits + 1);
    var code = 0;
    for (var b = 1; b <= maxBits; b++) {
      nextCode[b] = code = (code + count[b - 1]) << 1;
    }

    final table = Uint32List(1 << maxBits);
    for (var sym = 0; sym < lens.length; sym++) {
      final int len = lens[sym];
      if (len == 0) continue;
      final int c = nextCode[len]++;
      var rev = 0;
      for (var i = 0; i < len; i++) {
        rev = (rev << 1) | ((c >> i) & 1);
      }
      final fill = 1 << (maxBits - len);
      for (var k = 0; k < fill; k++) {
        table[rev | (k << len)] = (sym << 8) | len;
      }
    }
    return _HuffmanTree(table, maxBits);
  }

  int decode(int Function(int) peek, void Function(int) consume) {
    // An empty distance tree is legal only while no length symbol refers to
    // it; reaching a distance code through it is an invalid stream.
    if (maxBits == 0) _unscannable(_badDeflate);
    final int entry = table[peek(maxBits)];
    consume(entry & 0xFF);
    return entry >> 8;
  }
}

final _HuffmanTree _fixedLitTree = () {
  final lengths = List<int>.filled(288, 8);
  lengths.fillRange(144, 256, 9);
  lengths.fillRange(256, 280, 7);
  return _HuffmanTree.build(lengths, 9)!;
}();

final _HuffmanTree _fixedDistTree = _HuffmanTree.build(
  List<int>.filled(32, 5),
  5,
  true,
)!;

enum _S { sniff, tar, hdr, blk, strd, dyn, huff, trlr, tail, done }

class _ArchiveScanner {
  List<int> _buf = <int>[];
  int _pos = 0;
  int _bitBuf = 0;
  int _bitCount = 0;
  bool _eof = false;
  bool _tailNul = false;

  _S _state = _S.sniff;
  _TarScan? _walk;
  _Refusal? _refusal;

  final _window = Uint8List(32768);
  int _windowPos = 0;
  int _memberBytes = 0;
  int _crc = 0xFFFFFFFF;

  final _outBuf = Uint8List(8192);
  int _outPos = 0;
  int _bFinal = 0;
  int _storedLen = -1;
  _HuffmanTree? _litTree;
  _HuffmanTree? _distTree;

  final List<int> _dyn = List<int>.filled(4, 0);
  List<int>? _codeLengths;
  List<int>? _dynLengths;
  _HuffmanTree? _clTree;

  bool _needBits(int n) {
    while (_bitCount < n) {
      if (_pos >= _buf.length) {
        if (_eof) _unscannable(_badDeflate);
        return false;
      }
      _bitBuf |= _buf[_pos++] << _bitCount;
      _bitCount += 8;
    }
    return true;
  }

  int _peek(int n) => _bitBuf & ((1 << n) - 1);

  void _consume(int n) {
    _bitBuf >>= n;
    _bitCount -= n;
  }

  int _readBits(int n) {
    final int val = _peek(n);
    _consume(n);
    return val;
  }

  void _align() => _consume(_bitCount % 8);

  bool _needBytes(int n, [String msg = _badDeflate]) {
    _align();
    if (_buf.length - _pos >= n - (_bitCount ~/ 8)) return true;
    if (_eof) _unscannable(msg);
    return false;
  }

  int _readByte() {
    if (_bitCount >= 8) return _readBits(8);
    _align();
    return _buf[_pos++];
  }

  int _readUint32() =>
      _readByte() |
      (_readByte() << 8) |
      (_readByte() << 16) |
      (_readByte() << 24);

  int _byteAt(int offset) {
    _align();
    return _buf[_pos + offset];
  }

  _Refusal? _emitByte(int b) {
    _outBuf[_outPos++] = b;
    _window[_windowPos] = b;
    _windowPos = (_windowPos + 1) & 0x7FFF;
    _memberBytes++;
    _crc = _crcTable[(_crc ^ b) & 0xFF] ^ (_crc >>> 8);
    return _outPos == _outBuf.length ? _flushOut() : null;
  }

  _Refusal? _flushOut() {
    if (_outPos == 0) return _refusal;
    final int count = _outPos;
    _outPos = 0;
    if (_walk != null && !_walk!.finished) {
      final _Refusal? r = _walk!.pumpAfter(_outBuf.sublist(0, count));
      if (r != null) _refusal = r;
    }
    return _refusal;
  }

  bool _sniff() {
    if (!_needBytes(1, 'the archive is empty')) return false;
    _walk ??= _TarScan.streaming();
    if (_byteAt(0) != 31) {
      _state = _S.tar;
    } else if (_buf.length - _pos < 2) {
      if (!_eof) return false;
      _state = _S.tar;
    } else {
      _state = _byteAt(1) == 139 ? _S.hdr : _S.tar;
    }
    return true;
  }

  /// Returns the offset just past the NUL ending the header text field at
  /// [from], or -1 when the terminator has not arrived yet. Nothing is
  /// consumed, so a header split across chunks resumes at the same position.
  int _headerTextEnd(int from) {
    final int nul = _buf.indexOf(0, _pos + from);
    if (nul >= 0) return nul - _pos + 1;
    if (_eof) _unscannable('a gzip header is truncated');
    return -1;
  }

  /// Parses one RFC 1952 member header. Nothing is consumed until every
  /// header byte is buffered, so a header split across chunks resumes at the
  /// same position instead of being read as a fresh member. The optional
  /// `FEXTRA` length counts as header bytes for `FHCRC`, per RFC 1952 §2.3.1.
  bool _parseMemberHeader() {
    if (!_needBytes(10, 'a gzip member is truncated')) return false;
    final int m0 = _byteAt(0);
    final int m1 = _byteAt(1);
    final int cm = _byteAt(2);
    final int flg = _byteAt(3);
    if (m0 != 31 || m1 != 139 || cm != 8 || (flg & 0xE0) != 0) {
      _unscannable('a gzip member has a bad header');
    }
    var end = 10;
    if ((flg & 4) != 0) {
      if (!_needBytes(end + 2, 'a gzip header is truncated')) return false;
      end += 2 + (_byteAt(end) | (_byteAt(end + 1) << 8));
      if (!_needBytes(end, 'a gzip header is truncated')) return false;
    }
    for (final int bit in const <int>[8, 16]) {
      if ((flg & bit) == 0) continue;
      end = _headerTextEnd(end);
      if (end < 0) return false;
    }
    if ((flg & 2) != 0) {
      if (!_needBytes(end + 2, 'a gzip header is truncated')) return false;
      final int crc16 = _byteAt(end) | (_byteAt(end + 1) << 8);
      if (crc16 != (_crc32(_buf.sublist(_pos, _pos + end)) & 0xFFFF)) {
        _unscannable('a gzip member has a bad header');
      }
      end += 2;
    }
    _pos += end;
    _memberBytes = 0;
    _windowPos = 0;
    _crc = 0xFFFFFFFF;
    _state = _S.blk;
    return true;
  }

  bool _readBlockHeader() {
    if (!_needBits(3)) return false;
    _bFinal = _readBits(1);
    final int bType = _readBits(2);
    if (bType == 1) {
      _litTree = _fixedLitTree;
      _distTree = _fixedDistTree;
    }
    _state = switch (bType) {
      0 => _S.strd,
      1 => _S.huff,
      2 => _S.dyn,
      _ => _unscannable(_badDeflate),
    };
    return true;
  }

  bool _readStored() {
    if (_storedLen < 0) {
      if (!_needBytes(4)) return false;
      final int len = _readByte() | (_readByte() << 8);
      if ((len ^ (_readByte() | (_readByte() << 8))) != 0xFFFF) {
        _unscannable(_badDeflate);
      }
      _storedLen = len;
    }
    while (_storedLen > 0) {
      if (!_needBytes(1) || _emitByte(_readByte()) != null) return false;
      _storedLen--;
    }
    _storedLen = -1;
    _state = _bFinal == 1 ? _S.trlr : _S.blk;
    return true;
  }

  void _repeatDyn(int val, int count, int total) {
    if (_dyn[3] + count > total) _unscannable(_badDeflate);
    _dynLengths!.fillRange(_dyn[3], _dyn[3] + count, val);
    _dyn[3] += count;
  }

  bool _decodeDynamicLengths(int total) {
    while (_dyn[3] < total) {
      if (!_needBits(14)) return false;
      final int sym = _clTree!.decode(_peek, _consume);
      if (sym < 16) {
        _dynLengths![_dyn[3]++] = sym;
      } else if (sym == 16) {
        if (_dyn[3] == 0) _unscannable(_badDeflate);
        _repeatDyn(_dynLengths![_dyn[3] - 1], 3 + _readBits(2), total);
      } else if (sym <= 18) {
        _repeatDyn(0, sym == 17 ? 3 + _readBits(3) : 11 + _readBits(7), total);
      } else {
        _unscannable(_badDeflate);
      }
    }
    return true;
  }

  bool _readDynamicHeader() {
    if (_dyn[0] == 0) {
      if (!_needBits(14)) return false;
      _dyn[0] = _readBits(5) + 257;
      _dyn[1] = _readBits(5) + 1;
      _dyn[2] = _readBits(4) + 4;
      _codeLengths = List<int>.filled(19, 0);
    }
    if (_clTree == null) {
      for (var i = _dyn[3]; i < _dyn[2]; i++) {
        if (!_needBits(3)) {
          _dyn[3] = i;
          return false;
        }
        _codeLengths![_codeOrder[i]] = _readBits(3);
      }
      _dyn[3] = 0;
      _clTree = _HuffmanTree.build(_codeLengths!, 7);
      if (_clTree == null) _unscannable(_badDeflate);
      _dynLengths = List<int>.filled(_dyn[0] + _dyn[1], 0);
    }
    final int total = _dyn[0] + _dyn[1];
    if (!_decodeDynamicLengths(total)) return false;
    final List<int> dyn = _dynLengths!;
    _litTree = _HuffmanTree.build(dyn.sublist(0, _dyn[0]), 15);
    _distTree = _HuffmanTree.build(dyn.sublist(_dyn[0]), 15, true);
    if (_litTree == null || _distTree == null) _unscannable(_badDeflate);
    _dyn.fillRange(0, 4, 0);
    _codeLengths = _dynLengths = _clTree = null;
    _state = _S.huff;
    return true;
  }

  int _decodeLength(int sym) {
    final int i = sym - 257;
    if (i == 28) return 258;
    if (i < 8) return i + 3;
    final int extra = (i - 4) >> 2;
    return (((4 | (i & 3)) << extra) + 3) + _readBits(extra);
  }

  int _decodeDistance(int sym) {
    if (sym < 4) return sym + 1;
    final int extra = (sym - 2) >> 1;
    return (((2 | (sym & 1)) << extra) + 1) + _readBits(extra);
  }

  bool _copyWindow(int length, int distance) {
    if (distance > _memberBytes || distance > 32768) _unscannable(_badDeflate);
    var srcPos = (_windowPos - distance) & 0x7FFF;
    for (var i = 0; i < length; i++) {
      if (_emitByte(_window[srcPos]) != null) return false;
      srcPos = (srcPos + 1) & 0x7FFF;
    }
    return true;
  }

  bool _readHuffman() {
    while (true) {
      if (!_needBits(48)) return false;
      final int sym = _litTree!.decode(_peek, _consume);
      if (sym < 256) {
        if (_emitByte(sym) != null) return false;
      } else if (sym == 256) {
        _state = _bFinal == 1 ? _S.trlr : _S.blk;
        return true;
      } else if (sym <= 285) {
        final int length = _decodeLength(sym);
        final int distSym = _distTree!.decode(_peek, _consume);
        if (distSym > 29) _unscannable(_badDeflate);
        if (!_copyWindow(length, _decodeDistance(distSym))) return false;
      } else {
        _unscannable(_badDeflate);
      }
    }
  }

  bool _readTrailer() {
    if (_flushOut() != null) return false;
    if (!_needBytes(8)) return false;
    if (_readUint32() != (~_crc & 0xFFFFFFFF) ||
        _readUint32() != (_memberBytes & 0xFFFFFFFF)) {
      _unscannable(_badDeflate);
    }
    _state = _S.tail;
    return true;
  }

  bool _readTail() {
    _align();
    while (_pos < _buf.length) {
      final int b = _byteAt(0);
      if (_tailNul || b == 0) {
        if (_readByte() != 0 && _tailNul) _unscannable(_badDeflate);
        _tailNul = true;
      } else if (b == 31) {
        if (!_needBytes(2)) return false;
        if (_byteAt(1) != 139) _unscannable(_badDeflate);
        _state = _S.hdr;
        return true;
      } else {
        _unscannable(_badDeflate);
      }
    }
    if (_eof) _state = _S.done;
    return _eof;
  }

  bool _stepTar() {
    if (_pos < _buf.length) {
      final List<int> chunk = _buf.sublist(_pos);
      _pos = _buf.length;
      final _Refusal? refusal = _walk!.pumpAfter(chunk);
      if (refusal != null) {
        _refusal = refusal;
        return false;
      }
      if (_walk!.finished) _state = _S.done;
    }
    if (_eof) {
      _state = _S.done;
      _refusal = _walk!.finish();
    }
    return false;
  }

  _Refusal? _pump() {
    while (_state != _S.done && _refusal == null) {
      final bool ok = switch (_state) {
        _S.sniff => _sniff(),
        _S.tar => _stepTar(),
        _S.hdr => _parseMemberHeader(),
        _S.blk => _readBlockHeader(),
        _S.strd => _readStored(),
        _S.dyn => _readDynamicHeader(),
        _S.huff => _readHuffman(),
        _S.trlr => _readTrailer(),
        _S.tail => _readTail(),
        _ => false,
      };
      if (!ok) break;
    }
    return _refusal;
  }

  _Refusal? add(List<int> chunk) {
    if (_pos >= 65536) {
      _buf = _buf.sublist(_pos);
      _pos = 0;
    }
    _buf.addAll(chunk);
    return _pump();
  }

  _Refusal? finish() {
    _eof = true;
    final _Refusal? refusal = _pump() ?? _flushOut();
    if (refusal != null) return refusal;
    if (_state == _S.tail) _state = _S.done;
    if (_state != _S.done) _unscannable(_badDeflate);
    return _walk?.finish();
  }
}

/// Scans archive bytes and returns the JSON verdict map: `{'ok': true}` for
/// a clean archive, `{'refusal': {'kind', 'path', 'target'}}` for the first
/// hostile entry in archive order, or `{'unscannable': '<detail>'}` for an
/// archive that cannot be read exactly.
Map<String, Object?> scanArchiveVerdict(List<int> bytes) {
  final scanner = _ArchiveScanner();
  try {
    return _verdictFor(scanner.add(bytes) ?? scanner.finish());
  } on _Unscannable catch (e) {
    return <String, Object?>{'unscannable': e.detail};
  }
}

/// Formats one walk outcome as the JSON verdict map.
Map<String, Object?> _verdictFor(_Refusal? r) => r == null
    ? const <String, Object?>{'ok': true}
    : <String, Object?>{
        'refusal': {'kind': r.kind, 'path': r.path, 'target': r.target},
      };

/// Feeds arbitrary [chunks] through the streaming archive scanner and returns
/// the JSON verdict map.
Future<Map<String, Object?>> scanArchiveChunks(List<List<int>> chunks) async {
  final scanner = _ArchiveScanner();
  try {
    for (final chunk in chunks) {
      final _Refusal? refusal = scanner.add(chunk);
      if (refusal != null) return _verdictFor(refusal);
    }
    return _verdictFor(scanner.finish());
  } on _Unscannable catch (e) {
    return <String, Object?>{'unscannable': e.detail};
  }
}

/// Scans [bytes] with the streaming walk, fed in [chunkSize] pieces, and
/// returns the JSON verdict map.
Future<Map<String, Object?>> scanArchiveChunked(
  List<int> bytes,
  int chunkSize,
) {
  final chunks = <List<int>>[];
  for (var i = 0; i < bytes.length; i += chunkSize) {
    final int end = i + chunkSize < bytes.length ? i + chunkSize : bytes.length;
    chunks.add(bytes.sublist(i, end));
  }
  return scanArchiveChunks(chunks);
}

/// Scans the archive file at [path] and returns the JSON verdict map, in the
/// same shape as [scanArchiveVerdict].
Future<Map<String, Object?>> scanArchiveFile(String path) async {
  if (path.isEmpty) return await scanArchiveChunks(<List<int>>[]);
  final scanner = _ArchiveScanner();
  try {
    await for (final chunk in File(path).openRead()) {
      final _Refusal? refusal = scanner.add(chunk);
      if (refusal != null) return _verdictFor(refusal);
    }
    return _verdictFor(scanner.finish());
  } on FileSystemException {
    return <String, Object?>{'unscannable': 'the archive cannot be read'};
  } on _Unscannable catch (e) {
    return <String, Object?>{'unscannable': e.detail};
  }
}

/// CLI entrypoint: scans each archive file in argument order and prints one
/// JSON verdict per line, always exiting zero.
void main(List<String> args) async {
  if (args.isEmpty) {
    print(
      jsonEncode(<String, Object?>{'unscannable': 'no archive path was given'}),
    );
    return;
  }
  for (final path in args) {
    print(jsonEncode(await scanArchiveFile(path)));
  }
}
