/// How the runner spells the path of a declared file.
///
/// Not under `lib/` here: the pub hub copies it to `build_runner/lib/` beside
/// `runner.dart` (`pub_lock_hub.bzl`), where `runner.dart` imports it.
library;

import 'package:path/path.dart' as p;

/// The path [asset] (`lib/src/a.dart`, always `/`-separated: an asset id's
/// path) has below the package directory [packageDir], spelled as
/// `build_runner` spells it: every separator the host's.
///
/// The runner's in-memory file system is keyed by strings, and `build_runner`
/// asks for a file by the string it builds from the package's path and the
/// asset's segments. `p.join(dir, 'lib/src/a.dart')` keeps the `/` of the
/// asset on Windows (`c:\...\app\lib/src/a.dart`), where `build_runner`
/// asks for `c:\...\app\lib\src\a.dart`: every declared input was then
/// "not found" and no builder wrote anything (e2e/gazelle on Windows).
String declaredPath(String packageDir, String asset, {p.Context? context}) {
  final p.Context host = context ?? p.context;
  return host.joinAll([packageDir, ...p.posix.split(asset)]);
}
