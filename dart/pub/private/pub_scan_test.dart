import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'pub_scan.dart' as scan;

/// Unit test for the pub archive header scanner (`pub_scan.dart`).
///
/// Drives [scan.scanArchiveVerdict] — the same code the AOT-compiled
/// `dart_pub_scanner` executable runs — over archives built inline, so the
/// tar-shape half of the scan (ustar `prefix`, GNU `L`/`K`, pax `x`/`g`,
/// octal sizes, gzip framing) is covered without downloading anything. The
/// Starlark half (per-entry policy, diagnostics) is covered by
/// `//dart/tests:pub_archive_scan_test`.
List<int> _put(List<int> header, int offset, String text, int length) {
  final raw = latin1.encode(text);
  final n = raw.length < length ? raw.length : length;
  header.setRange(offset, offset + n, raw);
  return header;
}

String _octal(int v, int width) => v.toRadixString(8).padLeft(width, '0');

List<int> _header(
  String name,
  String typeflag, {
  String linkname = '',
  int size = 0,
  String prefix = '',
}) {
  final h = List<int>.filled(512, 0);
  _put(h, 0, name, 100);
  _put(h, 124, '${_octal(size, 11)}\x00', 12);
  h[156] = typeflag.codeUnitAt(0);
  _put(h, 157, linkname, 100);
  _put(h, 257, 'ustar', 6);
  _put(h, 345, prefix, 155);
  var sum = 0;
  for (var i = 0; i < 512; i++) {
    sum += (i >= 148 && i < 156) ? 32 : h[i];
  }
  _put(h, 148, '${_octal(sum, 6)}\x00 ', 8);
  return h;
}

List<int> _entry(
  String name,
  String typeflag, {
  String linkname = '',
  List<int>? data,
  String prefix = '',
}) {
  final body = data ?? <int>[];
  final out = <int>[
    ..._header(
      name,
      typeflag,
      linkname: linkname,
      size: body.length,
      prefix: prefix,
    ),
    ...body,
  ];
  return [...out, ...List<int>.filled((-body.length) % 512, 0)];
}

List<int> _tar(List<List<int>> entries) => [
  ...entries.expand((e) => e),
  ...List<int>.filled(1024, 0),
];

String _paxRecord(String key, String value) {
  final kv = '$key=$value\n';
  var len = kv.length + 2;
  for (;;) {
    final next = kv.length + len.toString().length + 1;
    if (next == len) return '$len $kv';
    len = next;
  }
}

List<int> _pax(List<List<int>> entries, String records) =>
    _tar([_entry('pax', 'x', data: latin1.encode(records)), ...entries]);

List<int> _gz(List<int> tar) => GZipCodec().encode(tar);

/// CRC-32, the checksum a gzip trailer carries and whose low 16 bits an
/// `FHCRC` header carries. Computed bitwise so the test never shares the
/// scanner's lookup table.
int _crc32Of(List<int> bytes) {
  var c = 0xFFFFFFFF;
  for (final b in bytes) {
    c ^= b;
    for (var i = 0; i < 8; i++) {
      c = (c & 1) != 0 ? (c >>> 1) ^ 0xEDB88320 : c >>> 1;
    }
  }
  return ~c & 0xFFFFFFFF;
}

/// A hand-built RFC 1952 member header. A non-null [extra] sets `FEXTRA` (its
/// length goes in `XLEN`), a non-null [name] sets `FNAME`, a non-null
/// [comment] sets `FCOMMENT`, and [hcrc] appends the header CRC16. The CRC16
/// covers every header byte before it, `XLEN` included.
List<int> _gzHeader({
  List<int>? extra,
  String? name,
  String? comment,
  bool hcrc = false,
  bool corruptHcrc = false,
}) {
  var flg = 0;
  if (extra != null) flg |= 4;
  if (name != null) flg |= 8;
  if (comment != null) flg |= 16;
  if (hcrc) flg |= 2;
  final header = <int>[31, 139, 8, flg, 0, 0, 0, 0, 0, 3];
  if (extra != null) {
    header
      ..add(extra.length & 0xFF)
      ..add((extra.length >> 8) & 0xFF)
      ..addAll(extra);
  }
  if (name != null) header.addAll(<int>[...latin1.encode(name), 0]);
  if (comment != null) header.addAll(<int>[...latin1.encode(comment), 0]);
  if (hcrc) {
    final int crc16 = (_crc32Of(header) + (corruptHcrc ? 1 : 0)) & 0xFFFF;
    header
      ..add(crc16 & 0xFF)
      ..add((crc16 >> 8) & 0xFF);
  }
  return header;
}

/// A gzip member with [header] in place of the 10-byte header [GZipCodec]
/// wrote around [gz]'s deflate body and trailer. The body and trailer do not
/// depend on the header, so they stay valid.
List<int> _gzWithHeader(List<int> gz, List<int> header) => <int>[
  ...header,
  ...gz.sublist(10),
];

Map<String, Object?> _verdict(List<int> archive) =>
    scan.scanArchiveVerdict(archive);

Future<Map<String, Object?>> _verdictChunked(
  List<int> archive,
  int chunkSize,
) => scan.scanArchiveChunked(archive, chunkSize);

Future<Map<String, Object?>> _verdictFile(
  Directory dir,
  String name,
  List<int> archive,
) async {
  final file = File('${dir.path}/$name');
  await file.writeAsBytes(archive);
  return scan.scanArchiveFile(file.path);
}

Future<void> _expectMatchesAll(
  Directory dir,
  String name,
  List<int> archive,
  Map<String, Object?> expected,
) async {
  expect(_verdict(archive), expected);
  expect(await _verdictChunked(archive, 7), expected);
  expect(await _verdictChunked(archive, 1), expected);
  final chunks = <List<int>>[archive];
  expect(await scan.scanArchiveChunks(chunks), expected);
  expect(await _verdictFile(dir, name, archive), expected);
}

void _expectOk(List<int> archive) {
  expect(_verdict(archive), {'ok': true});
}

void _expectRefusal(
  List<int> archive,
  String kind,
  String path,
  String target,
) {
  expect(_verdict(archive), {
    'refusal': {'kind': kind, 'path': path, 'target': target},
  });
}

void _expectUnscannable(List<int> archive, String detail) {
  expect(_verdict(archive), {'unscannable': detail});
}

List<int> _file(String name, {String prefix = ''}) =>
    _entry(name, '0', data: [1, 2, 3], prefix: prefix);

/// A battery of archives covering every verdict shape: clean gzipped and
/// plain tars, each refusal kind, each truncation shape, and the gzip
/// framing variants (multi-member, trailing padding, trailing junk).
List<List<int>> _battery() => [
  _gz(_tar([_file('lib/a.dart')])),
  _tar([_file('lib/a.dart')]),
  _gz(_tar([_entry('lib/evil.dart', '1', linkname: '../outside.txt')])),
  _gz(_tar([_entry('lib/evil.dart', '2', linkname: '/etc/passwd')])),
  _gz(_tar([_file('/abs.dart')])),
  _gz(
    _tar([
      _entry('././@LongLink', 'L', data: [...latin1.encode('lib/ok.dart'), 0]),
      _file('lib/short.dart'),
    ]),
  ),
  _gz(_pax([_file('lib/a.dart')], _paxRecord('path', 'lib/pax.dart'))),
  _gz(_tar([_entry('lib/a.dart', 'Z')])),
  _gz(_tar([_file('lib/a.dart'), _file('lib/b.dart')])),
  [
    ..._gz(_tar([_file('lib/a.dart')])),
    ..._gz(_tar([_file('lib/b.dart')])),
  ],
  _gzWithHeader(
    _gz(_tar([_file('lib/a.dart')])),
    _gzHeader(extra: [1, 2, 3, 4], hcrc: true),
  ),
  [
    ..._gz(_tar([_file('lib/a.dart')])),
    ...List<int>.filled(100, 0),
  ],
  [
    ..._gz(_tar([_file('lib/a.dart')])),
    1,
    2,
    3,
  ],
  _header('lib/a.dart', '0', size: 100),
  [1, 2, 3],
  <int>[],
  _gz(
    _tar([
      _file('lib/a.dart'),
      _entry('lib/big.dart', '0', data: List<int>.filled(200000, 7)),
      _entry('lib/evil.dart', '1', linkname: 'lib/a.dart'),
    ]),
  ),
];

void main() {
  group('clean archives scan clean', () {
    test('a plain file entry', () {
      _expectOk(_gz(_tar([_file('lib/a.dart')])));
    });
    test('an in-package symlink', () {
      _expectOk(_gz(_tar([_entry('lib/b.dart', '2', linkname: 'a.dart')])));
    });
    test('a directory entry', () {
      _expectOk(_gz(_tar([_entry('lib/', '5')])));
    });
    test('a ustar prefix join', () {
      _expectOk(_gz(_tar([_file('lib/a.dart', prefix: 'pkg')])));
    });
    test('a GNU long name', () {
      final long = 'lib/${'a' * 112}.dart';
      _expectOk(
        _gz(
          _tar([
            _entry('././@LongLink', 'L', data: [...latin1.encode(long), 0]),
            _file('lib/short.dart'),
          ]),
        ),
      );
    });
    test('a pax path override', () {
      _expectOk(
        _gz(
          _pax([_file('lib/ignored.dart')], _paxRecord('path', 'lib/pax.dart')),
        ),
      );
    });
    test('a plain tar without gzip framing', () {
      _expectOk(_tar([_file('lib/a.dart')]));
    });
  });

  group('hostile entries are refused', () {
    test('a hard link out of the package', () {
      _expectRefusal(
        _gz(_tar([_entry('lib/evil.dart', '1', linkname: '../outside.txt')])),
        'hard-link',
        'lib/evil.dart',
        '../outside.txt',
      );
    });
    test('a hard link inside the package', () {
      _expectRefusal(
        _gz(_tar([_entry('lib/evil.dart', '1', linkname: 'lib/ok.dart')])),
        'hard-link',
        'lib/evil.dart',
        'lib/ok.dart',
      );
    });
    test('an absolute symlink', () {
      _expectRefusal(
        _gz(_tar([_entry('lib/evil.dart', '2', linkname: '/etc/passwd')])),
        'symlink',
        'lib/evil.dart',
        '/etc/passwd',
      );
    });
    test('an escaping symlink', () {
      _expectRefusal(
        _gz(
          _tar([_entry('lib/evil.dart', '2', linkname: '../../outside.txt')]),
        ),
        'symlink',
        'lib/evil.dart',
        '../../outside.txt',
      );
    });
    test('a GNU long-link hostile target', () {
      _expectRefusal(
        _gz(
          _tar([
            _entry(
              '././@LongLink',
              'K',
              data: [...latin1.encode('../../x'), 0],
            ),
            _entry('lib/evil.dart', '2', linkname: 'ignored'),
          ]),
        ),
        'symlink',
        'lib/evil.dart',
        '../../x',
      );
    });
    test('a pax linkpath hostile target', () {
      _expectRefusal(
        _gz(
          _pax([
            _entry('lib/evil.dart', '2'),
          ], _paxRecord('linkpath', '../../x')),
        ),
        'symlink',
        'lib/evil.dart',
        '../../x',
      );
    });
    test('a pax global hostile target', () {
      final records = _paxRecord('linkpath', '/etc/global');
      _expectRefusal(
        _gz(
          _tar([
            _entry('g', 'g', data: latin1.encode(records)),
            _entry('lib/evil.dart', '2'),
          ]),
        ),
        'symlink',
        'lib/evil.dart',
        '/etc/global',
      );
    });
    test('an absolute entry path', () {
      _expectRefusal(_gz(_tar([_file('/abs.dart')])), 'path', '/abs.dart', '');
    });
    test('a climbing entry path', () {
      _expectRefusal(
        _gz(_tar([_file('../outside.dart')])),
        'path',
        '../outside.dart',
        '',
      );
    });
    test('a mid-path climb', () {
      _expectRefusal(
        _gz(_tar([_file('lib/../../outside.dart')])),
        'path',
        'lib/../../outside.dart',
        '',
      );
    });
    test('a backslash climb', () {
      _expectRefusal(
        _gz(_tar([_file('..\\outside.dart')])),
        'path',
        '..\\outside.dart',
        '',
      );
    });
  });

  group('unreadable archives fail closed', () {
    test('an empty archive', () {
      _expectUnscannable([], 'the archive is empty');
    });
    test('garbage bytes', () {
      _expectUnscannable([1, 2, 3], 'the tar archive is truncated');
    });
    test('a truncated tar', () {
      _expectUnscannable(
        _header('lib/a.dart', '0', size: 100),
        'the tar archive is truncated',
      );
    });
    test('entries with no end marker', () {
      _expectUnscannable(
        [_file('lib/a.dart')].expand((e) => e).toList(),
        'the tar archive is truncated',
      );
    });
    test('a non-numeric size', () {
      final h = _header('lib/a.dart', '0');
      _put(h, 124, 'zzzzzzzzzzz\x00', 12);
      _expectUnscannable([
        ...h,
        ...List<int>.filled(512, 0),
      ], "an entry's size is not a number");
    });
    test('a negative or overflowing base-256 size fails closed', () {
      final List<int> h = _header('lib/a.dart', '0');
      h[124] = 0xFF;
      _expectUnscannable([
        ...h,
        ...List<int>.filled(512, 0),
      ], "an entry's size is not a number");
    });
    test('an overflowing pax size fails closed', () {
      const records = '35 size=99999999999999999999\n';
      _expectUnscannable(
        _gz(
          _tar([
            _entry('x', 'x', data: latin1.encode(records)),
            _file('lib/a.dart'),
          ]),
        ),
        'a pax size is not a number',
      );
    });
    test('an unknown entry kind', () {
      _expectUnscannable(
        _gz(_tar([_entry('lib/a.dart', 'Z')])),
        "an entry has kind 'Z', which cannot be scanned",
      );
    });
    test('a sparse entry', () {
      _expectUnscannable(
        _gz(_tar([_entry('lib/a.dart', 'S')])),
        'a sparse entry cannot be scanned',
      );
    });
  });

  group('gzip framing variants keep their verdicts', () {
    test('concatenated gzip members scan clean', () {
      _expectOk([
        ..._gz(_tar([_file('lib/a.dart')])),
        ..._gz(_tar([_file('lib/b.dart')])),
      ]);
    });
    test('a hostile entry split across gzip members is refused', () {
      final tar = _tar([
        _entry('lib/evil.dart', '1', linkname: '../outside.txt'),
      ]);
      final cut = tar.length ~/ 2;
      _expectRefusal(
        [..._gz(tar.sublist(0, cut)), ..._gz(tar.sublist(cut))],
        'hard-link',
        'lib/evil.dart',
        '../outside.txt',
      );
    });
    test('trailing NUL padding scans clean', () {
      _expectOk([
        ..._gz(_tar([_file('lib/a.dart')])),
        ...List<int>.filled(100, 0),
      ]);
    });
    test('trailing junk fails the inflate', () {
      _expectUnscannable([
        ..._gz(_tar([_file('lib/a.dart')])),
        1,
        2,
        3,
      ], 'the deflate stream cannot be decoded');
    });
  });

  group('the streaming walk matches the in-memory verdicts', () {
    for (final chunkSize in [1, 2, 3, 7, 511, 512, 513, 1024, 65536]) {
      test('chunk size $chunkSize', () async {
        for (final archive in _battery()) {
          expect(
            await _verdictChunked(archive, chunkSize),
            _verdict(archive),
            reason: 'archive of ${archive.length} bytes at chunk $chunkSize',
          );
        }
      });
    }
  });

  group('repeat determinism across chunk sizes and iterations', () {
    test('200 iterations of full battery at chunk size 7', () async {
      for (var iter = 0; iter < 200; iter++) {
        for (final List<int> archive in _battery()) {
          expect(
            await _verdictChunked(archive, 7),
            _verdict(archive),
            reason: 'iter $iter: archive of ${archive.length} bytes at chunk 7',
          );
        }
      }
    });

    test('repeated passes across multiple chunk sizes', () async {
      for (var pass = 0; pass < 5; pass++) {
        for (final chunkSize in [1, 2, 3, 5, 7, 16, 511, 512, 1024]) {
          for (final List<int> archive in _battery()) {
            expect(
              await _verdictChunked(archive, chunkSize),
              _verdict(archive),
              reason:
                  'pass $pass: archive of ${archive.length} bytes at chunk $chunkSize',
            );
          }
        }
      }
    });
  });

  group('gzip member framing and tail verification', () {
    late Directory dir;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('pub_scan_framing_test');
    });
    tearDown(() async {
      await dir.delete(recursive: true);
    });

    test('trailing junk at chunk boundaries fails closed', () async {
      final List<int> cleanGz = _gz(_tar([_file('lib/a.dart')]));
      const expected = <String, Object?>{
        'unscannable': 'the deflate stream cannot be decoded',
      };
      final List<int> chunkA1 = cleanGz.sublist(0, cleanGz.length - 4);
      final chunkA2 = <int>[...cleanGz.sublist(cleanGz.length - 4), 1, 2, 3];
      expect(
        await scan.scanArchiveChunks(<List<int>>[chunkA1, chunkA2]),
        expected,
      );

      expect(
        await scan.scanArchiveChunks(<List<int>>[
          cleanGz,
          <int>[1, 2, 3],
        ]),
        expected,
      );

      final junkArchive = <int>[...cleanGz, 1, 2, 3];
      expect(await _verdictChunked(junkArchive, 1), expected);
      expect(_verdict(junkArchive), expected);
      expect(await _verdictFile(dir, 'junk.tar.gz', junkArchive), expected);
    });

    test(
      'trailing NUL padding followed by non-zero byte fails closed',
      () async {
        final List<int> cleanGz = _gz(_tar([_file('lib/a.dart')]));
        final badPadding = <int>[...cleanGz, 0, 0, 0, 1];
        const expected = <String, Object?>{
          'unscannable': 'the deflate stream cannot be decoded',
        };
        await _expectMatchesAll(dir, 'bad_pad.tar.gz', badPadding, expected);
      },
    );

    test('trailing incomplete second member bytes fail closed', () async {
      final List<int> cleanGz = _gz(_tar([_file('lib/a.dart')]));
      const badDeflate = <String, Object?>{
        'unscannable': 'the deflate stream cannot be decoded',
      };
      const badMember = <String, Object?>{
        'unscannable': 'a gzip member is truncated',
      };
      await _expectMatchesAll(dir, 'tail_31.tar.gz', <int>[
        ...cleanGz,
        31,
      ], badDeflate);
      await _expectMatchesAll(dir, 'tail_31_139.tar.gz', <int>[
        ...cleanGz,
        31,
        139,
      ], badMember);
      await _expectMatchesAll(dir, 'tail_partial_hdr.tar.gz', <int>[
        ...cleanGz,
        31,
        139,
        8,
        0,
        0,
        0,
        0,
        0,
        0,
        3,
      ], badDeflate);
    });

    test('truncated and corrupted 8-byte trailers fail closed', () async {
      final List<int> cleanGz = _gz(_tar([_file('lib/a.dart')]));
      const badDeflate = <String, Object?>{
        'unscannable': 'the deflate stream cannot be decoded',
      };
      await _expectMatchesAll(
        dir,
        'trunc_trailer.tar.gz',
        cleanGz.sublist(0, cleanGz.length - 4),
        badDeflate,
      );
      final corruptCrc = <int>[...cleanGz];
      corruptCrc[corruptCrc.length - 8] ^= 1;
      await _expectMatchesAll(dir, 'bad_crc.tar.gz', corruptCrc, badDeflate);
      final corruptIsize = <int>[...cleanGz];
      corruptIsize[corruptIsize.length - 4] ^= 1;
      await _expectMatchesAll(
        dir,
        'bad_isize.tar.gz',
        corruptIsize,
        badDeflate,
      );
    });

    test('valid optional gzip header fields scan clean', () async {
      final List<int> tarGz = _gz(_tar([_file('lib/a.dart')]));
      const okVerdict = <String, Object?>{'ok': true};
      // A correct FHCRC covers the FEXTRA length bytes too, so this member is
      // clean only when XLEN is part of the header checksum.
      final List<int> extra = _gzWithHeader(
        tarGz,
        _gzHeader(extra: [1, 2, 3, 4], hcrc: true),
      );
      await _expectMatchesAll(dir, 'extra_hcrc.tar.gz', extra, okVerdict);
      final List<int> named = _gzWithHeader(
        tarGz,
        _gzHeader(name: 'pkg.tar', comment: 'built', hcrc: true),
      );
      await _expectMatchesAll(dir, 'named_hcrc.tar.gz', named, okVerdict);
      final List<int> all = _gzWithHeader(
        tarGz,
        _gzHeader(extra: const <int>[], name: 'n', comment: 'c', hcrc: true),
      );
      await _expectMatchesAll(dir, 'all_fields.tar.gz', all, okVerdict);
    });

    test('a gzip header split across chunks keeps one verdict', () async {
      final List<int> tarGz = _gz(_tar([_file('lib/a.dart')]));
      final List<int> header = _gzHeader(
        extra: [1, 2, 3, 4],
        name: 'n',
        comment: 'c',
        hcrc: true,
      );
      final List<int> archive = _gzWithHeader(tarGz, header);
      const okVerdict = <String, Object?>{'ok': true};
      expect(
        await scan.scanArchiveChunks(<List<int>>[
          header.sublist(0, 5),
          header.sublist(5),
          archive.sublist(header.length),
        ]),
        okVerdict,
      );
      expect(
        await scan.scanArchiveChunks(<List<int>>[
          archive.sublist(0, header.length),
          archive.sublist(header.length),
        ]),
        okVerdict,
      );
    });

    test('truncated optional gzip header fields fail closed', () async {
      const badHeader = <String, Object?>{
        'unscannable': 'a gzip header is truncated',
      };
      final List<int> extraHeader = _gzHeader(extra: [1, 2, 3, 4]);
      await _expectMatchesAll(
        dir,
        'trunc_extra_xlen.tar.gz',
        extraHeader.sublist(0, 11),
        badHeader,
      );
      await _expectMatchesAll(
        dir,
        'trunc_extra_data.tar.gz',
        extraHeader.sublist(0, 13),
        badHeader,
      );
      final List<int> nameHeader = _gzHeader(name: 'abc');
      await _expectMatchesAll(
        dir,
        'trunc_name.tar.gz',
        nameHeader.sublist(0, 12),
        badHeader,
      );
      final List<int> commentHeader = _gzHeader(comment: 'abc');
      await _expectMatchesAll(
        dir,
        'trunc_comment.tar.gz',
        commentHeader.sublist(0, 12),
        badHeader,
      );
      final List<int> hcrcHeader = _gzHeader(hcrc: true);
      await _expectMatchesAll(
        dir,
        'trunc_hcrc.tar.gz',
        hcrcHeader.sublist(0, hcrcHeader.length - 1),
        badHeader,
      );
    });

    test('a mismatched gzip header CRC fails closed', () async {
      final List<int> tarGz = _gz(_tar([_file('lib/a.dart')]));
      const badHeader = <String, Object?>{
        'unscannable': 'a gzip member has a bad header',
      };
      final List<int> bad = _gzWithHeader(
        tarGz,
        _gzHeader(extra: [9, 8], hcrc: true, corruptHcrc: true),
      );
      await _expectMatchesAll(dir, 'bad_hcrc.tar.gz', bad, badHeader);
    });

    test('deflate block types and trailer ISIZE trailing zeros', () async {
      const okVerdict = <String, Object?>{'ok': true};
      final List<int> storedGz = ZLibEncoder(
        gzip: true,
        level: 0,
      ).convert(_tar([_file('lib/a.dart')]));
      await _expectMatchesAll(dir, 'stored.tar.gz', storedGz, okVerdict);

      const badDeflate = <String, Object?>{
        'unscannable': 'the deflate stream cannot be decoded',
      };
      await _expectMatchesAll(dir, 'stored_junk.tar.gz', <int>[
        ...storedGz,
        1,
        2,
        3,
      ], badDeflate);

      final multiGz = <int>[
        ..._gz(_tar([_file('lib/a.dart')])),
        ..._gz(_tar([_file('lib/b.dart')])),
      ];
      await _expectMatchesAll(dir, 'multi.tar.gz', multiGz, okVerdict);

      final List<int> tarZero = _tar([_file('lib/a.dart')]);
      final paddedTarZero = <int>[..._gz(tarZero), ...List<int>.filled(50, 0)];
      await _expectMatchesAll(
        dir,
        'padded_zero.tar.gz',
        paddedTarZero,
        okVerdict,
      );
    });
  });

  group('scanArchiveFile reads real files', () {
    late Directory dir;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('pub_scan_test');
    });
    tearDown(() async {
      await dir.delete(recursive: true);
    });
    test('every battery verdict matches over real files', () async {
      var i = 0;
      for (final archive in _battery()) {
        expect(
          await _verdictFile(dir, 'a${i++}.tar.gz', archive),
          _verdict(archive),
          reason: 'archive of ${archive.length} bytes',
        );
      }
    });
    test('a missing file cannot be read', () async {
      expect(await scan.scanArchiveFile('${dir.path}/missing.tar.gz'), {
        'unscannable': 'the archive cannot be read',
      });
    });
    test('a refusal after a large entry short-circuits', () async {
      final archive = _gz(
        _tar([
          _entry('lib/big.dart', '0', data: List<int>.filled(200000, 7)),
          _entry('lib/evil.dart', '1', linkname: 'lib/a.dart'),
        ]),
      );
      expect(await _verdictFile(dir, 'evil.tar.gz', archive), {
        'refusal': {
          'kind': 'hard-link',
          'path': 'lib/evil.dart',
          'target': 'lib/a.dart',
        },
      });
    });
    test('sequential scans keep no state between archives', () async {
      // The batch entrypoint scans archives back to back in one process, so
      // a refusal, a short-circuit, or an inflate-failure fallback in one
      // archive must not change the next archive's verdict.
      final clean = _gz(_tar([_entry('lib/ok.dart', '0')]));
      final hostile = _gz(
        _tar([_entry('lib/evil.dart', '1', linkname: 'lib/a.dart')]),
      );
      final cleanFile = File('${dir.path}/clean.tar.gz')
        ..writeAsBytesSync(clean);
      final hostileFile = File('${dir.path}/hostile.tar.gz')
        ..writeAsBytesSync(hostile);
      expect(await scan.scanArchiveFile(cleanFile.path), {'ok': true});
      expect(await scan.scanArchiveFile(hostileFile.path), {
        'refusal': {
          'kind': 'hard-link',
          'path': 'lib/evil.dart',
          'target': 'lib/a.dart',
        },
      });
      expect(await scan.scanArchiveFile(cleanFile.path), {'ok': true});
    });
  });
}
