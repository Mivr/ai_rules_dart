import 'package:path/path.dart' as p;

/// Joins with `package:path`, a hosted dependency of this path package.
String greet(String who) => p.join('hello', who);
