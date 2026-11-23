# gazelle e2e

- `gazelle_test.dart` runs the Gazelle binary over small workspaces it builds
  in temp directories and checks the BUILD files it writes.
- `app/` is a stock Dart package with json_serializable, freezed, drift and
  mockito. Its BUILD file is what `bazel run //:gazelle -- app` writes, plus
  the `stock_test` comparisons at the end. `e2e.yaml` checks that Gazelle
  would change nothing, then runs its tests and compares its generated files
  with `reference/app/`, what stock `dart run build_runner build` wrote.

## Regenerating the references

After changing `app/`'s sources or `pubspec.yaml`, with stock tools only, in a
copy of `app/` outside the repository:

```sh
source /path/to/dart-sdk-env.sh     # the Dart SDK the lock was resolved with
dart pub get                        # then copy pubspec.lock back to app/
dart run build_runner build
```

Copy each generated file (`lib/**/*.g.dart`, `*.freezed.dart`,
`test/*.mocks.dart`) to `reference/app/` at the same path, then run
`bazel run //:gazelle -- app`.
