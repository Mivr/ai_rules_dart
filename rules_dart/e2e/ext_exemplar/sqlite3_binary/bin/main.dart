import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

/// A plain `package:sqlite3` program — no `dart:ffi` ceremony. sqlite3's own
/// build hook builds libsqlite3, and the binary embeds its code asset, so
/// `sqlite3`'s `@Native` bindings resolve against it at runtime (relative to
/// the executable).
void main() {
  final db = sqlite3.openInMemory()
    ..execute('CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT);')
    ..execute("INSERT INTO t (id, name) VALUES (1, 'hello');");
  final rows = db.select('SELECT name FROM t WHERE id = ?;', [1]);
  final name = rows.single['name'] as String;
  db.close();
  if (name != 'hello') {
    stderr.writeln('FAIL: expected "hello", got "$name"');
    exit(1);
  }
  // `const` forces resolution during constant evaluation, in the front end.
  const channel = String.fromEnvironment(
    'BUILD_CHANNEL',
    defaultValue: 'UNSET',
  );
  stdout
    ..writeln('sqlite3 ok: $name (libVersion ${sqlite3.version.libVersion})')
    ..writeln('channel: $channel');
}
