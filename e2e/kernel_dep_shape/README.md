# `kernel_dep_shape`: red workspace for the modular kernel import-shape refusal

A modular kernel compile must reject an import shape where a library
source reaches a dependency-defined source through a multi-root URI:
the front end would read the file from source while the plan links the
dependency's outline, so the linked kernel lacks the library. The same
refusal covers an entry source that reaches a dependency-defined source
through a relative or multi-root URI once the entry itself compiles from
a non-`package:` URI, even though that edge used to build and run: it
compiled the dependency's file from source into the entry instead of
linking the dependency's outline, so the refusal keeps the entry on the
`package:` spelling every other consumer links. The refusal fires in
every execution strategy (persistent worker and local), at the earliest
point (before the compiler runs), and names the importing file, the URI
as written, and the `package:` URI to use.

## Cases

- `//pkg:bad_lib_app` — must fail. `pkg/lib/a.dart` imports
  `org-dartlang-root:///dep/lib/d.dart`, a multi-root spelling of a source
  `//dep` defines under `package:dep/d.dart`. A bare library builds no
  kernel until a binary consumes it, so the app drives the compile; the
  failure is the library's:

  ```
  kernel_module: cannot compile package:pkg/a.dart: import 'org-dartlang-root:///dep/lib/d.dart' reaches a source its dependencies define under 'package:dep/d.dart'; import that instead.
  ```

- `//pkg:bad_bin` — must fail. The entry `pkg/bin/main.dart` compiles from
  its multi-root URI, so `import '../../dep/lib/d.dart'` resolves from
  source into `//dep`'s sources instead of linking them:

  ```
  kernel_module: cannot compile org-dartlang-root:///pkg/bin/main.dart: import '../../dep/lib/d.dart' reaches a source its dependencies define under 'package:dep/d.dart'; import that instead.
  ```

- `//pkg:good_app` — must succeed and print `dep`. The same edges spelled
  `package:` link `//dep`'s outline.

## Assertions (mirrored in `expected-failure` in `.github/workflows/ci.yaml`)

```sh
if bazel build //pkg:bad_lib_app 2>/dev/null; then
  echo "ERROR: build should have failed with the import-shape refusal"
  exit 1
fi
bazel build //pkg:bad_lib_app 2>&1 | grep -F -q "cannot compile package:pkg/a.dart: import 'org-dartlang-root:///dep/lib/d.dart' reaches a source its dependencies define under 'package:dep/d.dart'; import that instead."

if bazel build //pkg:bad_bin 2>/dev/null; then
  echo "ERROR: build should have failed with the import-shape refusal"
  exit 1
fi
bazel build //pkg:bad_bin 2>&1 | grep -F -q "cannot compile org-dartlang-root:///pkg/bin/main.dart: import '../../dep/lib/d.dart' reaches a source its dependencies define under 'package:dep/d.dart'; import that instead."

bazel build //pkg:good_app || exit 1
```

Each red case is also built with `--spawn_strategy=standalone` there: the
refusal must fire under the local strategy as well as the persistent
worker.
