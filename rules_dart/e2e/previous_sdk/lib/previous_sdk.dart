/// Joins path segments with `package:path`, a dependency from the lock.
library;

import 'package:path/path.dart' as p;

/// The POSIX path of [segments], joined.
String joinAll(List<String> segments) => p.posix.joinAll(segments);
