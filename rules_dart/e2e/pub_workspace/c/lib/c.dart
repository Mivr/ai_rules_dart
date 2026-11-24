import 'package:b/b.dart';

/// Greets two files, through `b` and, under it, `a`.
String greetBoth(String first, String second) =>
    '${greetFile(first)} ${greetFile(second)}';
