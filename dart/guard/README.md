# `//dart/guard`: the shared directive-URI check

One check every Dart compile and analysis action runs: no directive spelling
may read an undeclared host file. This package publishes it so rule sets built
on rules_dart can enforce the same check in their own tools instead of copying
it.

Depend on it:

```python
load("@rules_dart//dart:defs.bzl", "dart_binary")

dart_binary(
    name = "my_runner",
    main = "my_runner.dart",
    deps = ["@rules_dart//dart/guard:directive_guard"],
)
```

Import it by its stable URI:

```dart
import 'package:rules_dart_guard/directive_guard.dart';
```

## API

Every check is pure and synchronous. Every failure is a diagnostic string,
never an exception: a check returns its diagnostics in path order, and the
empty list when clean. The caller prints each line and fails its action when
the list is not empty. Each line names the file, the directive and the URI:

```
<tool>: <path> <kind> '<uri>' is not a declared input.
```

* `findStagedDirectiveViolations(roots, {required tool})` — pass staged
  roots, get every directive under them that would read a file outside them.
  Reads every `.dart` file under `roots`; missing roots scan as empty. This
  is the check rules_dart's own runners enforce.
* `findDisallowedDirectives({path: source}, {tool})` — pass file contents,
  get every disallowed-scheme directive, without touching the filesystem.
* `resolveDirectiveUri(uri, fromKey, packageDirs)` — pass one URI, the
  importing file's workspace key and the package-name-to-directory map, get
  the key the front end reads, or null when the URI names no workspace file.
* `scanAllDirectiveUris(source)` — every URI-bearing directive of a source's
  prologue, without evaluating `if` conditions.
* Predicates for tools that stage their own trees: `isDisallowedDirectiveUri`,
  `isFileSchemeDirectiveUri`, `isEscapingPackageUri`, `hasEmptyPathSegment`,
  `resolveStagedRelativeTarget`, `normalizeStagedPath`, `decodeUriSegment`.

`e2e/guard_reuse` proves the reuse from outside: an external module whose own
`dart_test` imports this library by its `package:` URI and classifies
directives exactly as rules_dart does.
