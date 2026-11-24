# build_runner e2e

`dart_build_runner` against stock `dart run build_runner build`, byte for byte.

Each package under `pkgs/` builds its generated files with `dart_build_runner`
and compares every one with the file stock `build_runner` wrote, checked in
under `reference/<package>/` (`stock_reference_test` in `reference.bzl`, one
`diff_test` per file). The packages cover the builders of
`json_serializable`, `freezed`, `drift_dev`, `mockito`, `built_value_generator`,
`injectable_generator` (including a micro-package dependency, `injectable_micro`),
`retrofit_generator` and `riverpod_generator`, all of them in one package
(`combined`), `--release` (`json_release`) and `--define` (`json_define`).

`errors/` holds the failures `e2e.yaml` expects: a lock with build_runner 2.7.0
(`old`), a lock without build_runner (`none`), an output no builder writes
(`missing`), and a builder that searches the package for a file that is not an
input (`glob`). Their targets are `manual`.

## Regenerating the references

After changing `pubspec.lock` or a package's sources, regenerate the references
with stock tools only:

```sh
source /path/to/dart-sdk-env.sh     # the Dart SDK the lock was resolved with
dart pub get                        # in this directory (a pub workspace)
cd pkgs/<package>
dart run build_runner build         # json_release: add --release
                                    # json_define: add the two --define flags
                                    # from its BUILD.bazel
```

Then copy each file listed in the package's `OUTS` from `pkgs/<package>/` to
`reference/<package>/` at the same relative path, and delete the generated
files and `.dart_tool/` from `pkgs/<package>/`: the Bazel build must not see
stock's outputs among its sources.
