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

Map<String, Object?> _verdict(List<int> archive) =>
    scan.scanArchiveVerdict(archive);

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
}
