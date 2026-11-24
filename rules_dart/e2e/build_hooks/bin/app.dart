// The program `app_test` runs, compiled ahead of time.
import 'package:native_add/native_add.dart';
import 'package:native_link/native_link.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  print('sqlite ${sqlite3.version.libVersion}');
  print('add ${add(2, 3)}');
  print('times ${const Factor(6).times(7)}');
}
