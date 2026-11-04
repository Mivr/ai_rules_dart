# layering_check

Red by design. A target may import only the packages its own `deps` provide.

- `//:user` imports `package:leaf`, which only `//:mid` depends on: the build
  fails, naming the target, the file, the import and the package.
- `//:user_ok` adds `:leaf` to its `deps`: it builds.
- `//:facade_user` depends on a source-less facade re-exporting `leaf` and
  `mid`: it builds.
- `//:conditional` imports `leaf` only in an `if (dart.library.io)` alternative:
  the build fails, as every alternative is checked.
- `--features=-dart_layering_check` turns the check off for a build.

The `expected-failure` job in `.github/workflows/ci.yaml` runs these.
