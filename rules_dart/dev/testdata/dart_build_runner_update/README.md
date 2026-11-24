# dart_build_runner_update

Code generation over existing BUILD files and checked-in files.

- `checked_in`: `lib/user.g.dart` is on disk; it is an output and listed once,
  as `:lib/user.g.dart`. `lib/message.g.dart` is written by the user's
  `run_binary`: in `srcs`, not in `outs`. A test gets the helper it imports.
- `renamed`: a `dart_build_runner` the user named `codegen` keeps its name;
  its stale output is replaced.
- `no_parts`: the last generated file is gone, so the `dart_build_runner` is
  deleted and the library loses the label.
- `split`: a `lib/BUILD.bazel` left from the per-directory layout. Gazelle
  keeps it and says on stderr that it cannot declare `lib/user.g.dart`.
- `off`: `# gazelle:dart_build_runner off` gives the per-directory rules.
- `tool`: binaries (the one named like the package becomes `tool_bin`), a
  `bin/` helper and its generated part.
- `stock`: a stock layout, as a person first writes it and as `flutter create`
  makes it: `lib/main.dart` beside the rest of `lib/`. The library lists all of
  `lib/`, `main.dart` included, and the test that imports
  `package:stock/main.dart` lists only its `main` and depends on the library.
  An executable whose `main` is `lib/main.dart` (a `flutter_application`, a
  `dart_binary`) takes it from that library.
