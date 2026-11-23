Bump the Dart SDK to version $ARGUMENTS.

## Instructions

1. Read `docs/CHORES.md` § "Dart SDK Version Bump" for what a bump touches and the procedure.

2. Run `bazel run //dart/private/tools:update_cross_sdk_versions -- $ARGUMENTS` (add `--drop=<older patch of the same minor>` when $ARGUMENTS replaces a patch release). It writes `dart/private/versions.bzl` and `dart/private/module_compiler_versions.bzl` and needs the network. If it fails, stop and report the error.

3. Check the new `module_compiler_versions.bzl` row's `language_versions` against the `sdk:` lower bounds in the five SDK packages' pubspecs, as CHORES.md says.

4. Run the suites of CHORES.md step 3 with each listed version selected. If the module compiler does not build for $ARGUMENTS, stop and report: that is a change to `module_compiler.dart`, and the version stays unlisted.

5. If $ARGUMENTS becomes the default: set `dart_version` in the root `MODULE.bazel` and the `README.md` installation snippet, and check that `e2e/root_sdk_pin` still pins a different listed version.

6. Leave `dart/runfiles/pubspec.yaml`'s `environment.sdk` alone unless the new SDK actually falls outside it. That package is published to pub.dev, so its lower bound stays as low as remains compatible rather than tracking the newest SDK (see CHORES.md).

7. Run `dart run tool/refresh_locks.dart` to regenerate all lock files.

8. Pick one e2e workspace (e.g. `e2e/hello_world`) and run `bazel build //...` in it to verify the new SDK resolves correctly.

9. Commit with message: `chore: bump Dart SDK to $ARGUMENTS`
