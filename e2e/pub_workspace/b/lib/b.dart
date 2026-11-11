import 'package:a/a.dart';
import 'package:path/path.dart' as p;

/// Greets the file name of `path`.
String greetFile(String path) => greet(p.basename(path));
