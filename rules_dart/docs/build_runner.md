# `build_runner` builders under Bazel

`dart_build_runner` runs the `build_runner` builders of your lock
(`json_serializable`, `freezed`, `built_value`, `mockito`, `drift_dev`,
`injectable_generator`, `go_router_builder`, ...) as a Bazel action. It writes
the same bytes as `dart run build_runner build`.

## What it does

- One `dart_build_runner` target builds the generated files of one Dart
  package. All builders that apply to the package run in that one action.
- The action runs `build_runner`'s own build engine. Builder order, phases,
  `auto_apply`, `generate_for`, options and post-process builders work as in a
  stock build.
- The runner comes from your lock. Every `pub.from_lock()` hub compiles it from
  `build_runner`'s engine plus every package of the lock that defines builders:
  a package that depends on `build`, `build_config` or `source_gen` and whose
  whole dependency closure is in the lock. Its entry point is written from those
  packages' `build.yaml`, as `build_runner` writes
  `.dart_tool/build/entrypoint/build.dart`. rules_dart names no builder.
- The action runs as a persistent worker (mnemonic `DartBuildRunner`). The
  worker keeps `build_runner`'s build state per target, so an edit rebuilds only
  what `build_runner watch` would rebuild.
- Outputs are byte-equal to `dart run build_runner build`.
  `e2e/build_runner` checks this against checked-in references in
  `e2e/build_runner/reference`.

## Setup

The lock needs `build_runner` 2.8.0 or later, plus the builder packages you use
(usually as dev dependencies):

```sh
dart pub add dev:build_runner dev:json_serializable json_annotation
```

`MODULE.bazel`:

```starlark
pub = use_extension("@rules_dart//dart/pub:extensions.bzl", "pub")
pub.from_lock(
    name = "pub_deps",
    lock = "//:pubspec.lock",
)
use_repo(pub, "pub_deps")
```

The hub then has:

- `@pub_deps//build_runner`: the runner, for `dart_build_runner.runner`;
- `@pub_deps//build_runner:runner`: the runner binary, for
  `build_runner_sdk_summary.runner`;
- `@pub_deps//:package_graph.json`: the lock's package graph, in the shape of
  pub's `.dart_tool/package_graph.json`.

`BUILD.bazel` next to the package's `pubspec.yaml`:

```starlark
load("@rules_dart//dart:defs.bzl", "dart_build_runner", "dart_library")

OUTS = ["lib/src/address.g.dart", "lib/src/user.g.dart"]

dart_build_runner(
    name = "gen",
    outs = OUTS,
    runner = "@pub_deps//build_runner",
    deps = ["@pub_deps//:json_annotation"],
)

dart_library(
    name = "json_ser",
    srcs = glob(["lib/**/*.dart"], exclude = OUTS) + [":" + o for o in OUTS if o.startswith("lib/")],
    package_name = "json_ser",
    deps = ["@pub_deps//:json_annotation"],
)
```

List every generated file you need in `outs`, relative to the package root. Add
each one to the `srcs` of the rule that uses it, as `":" + out`. Gazelle can
write all of this for you: see [Gazelle](#gazelle). A generated
test file (`test/foo_test.mocks.dart`) belongs to the test that imports it, not
to the library.

Builder options stay in the package's `build.yaml`, exactly as with stock
`build_runner`:

```yaml
targets:
  $default:
    builders:
      json_serializable:
        generate_for:
          - lib/src/**
        options:
          field_rename: snake
```

## Attributes

| Attribute           | Meaning                                                                                                                                                                                                                               |
| ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `outs`              | Required. The generated files to build, relative to the Dart package root (`lib/src/user.g.dart`). Each must be a file `build_runner build` writes. Files of `build_to: cache` builders stay inside the action; do not list them.     |
| `runner`            | Required. The lock's runner, `@<hub>//build_runner`.                                                                                                                                                                                  |
| `srcs`              | The package's own files. Defaults to every file of the package except `outs` and BUILD files: what the builders see in a stock build. With a smaller list, a builder that searches the package and could match a left-out file fails. |
| `deps`              | The package's dependencies, as for its `dart_library`.                                                                                                                                                                                |
| `data`              | Other files the build reads. Use it for the `pubspec.yaml` and `build.yaml` of a dependency that is your own package, so its builders and options apply as in a stock build.                                                          |
| `pubspec`           | The package's `pubspec.yaml`. Defaults to `pubspec.yaml`. Its directory is the package root, in this Bazel package or below it.                                                                                                       |
| `sdk_summary`       | A `build_runner_sdk_summary`, for a package that imports Flutter. Defaults to the runner's plain Dart one.                                                                                                                            |
| `build_runner_args` | `build_runner build` flags: `--release`, `--define=<builder>=<option>=<value>`, `--config=<name>`.                                                                                                                                    |

Common attributes (`visibility`, `tags`, ...) work as usual.

A dependency that is your own package and has its own `build.yaml`:

```starlark
dart_build_runner(
    name = "gen",
    outs = ["lib/injection.config.dart"],
    data = ["//pkgs/injectable_micro:pubspec.yaml"],
    runner = "@pub_deps//build_runner",
    deps = ["//pkgs/injectable_micro", "@pub_deps//:get_it", "@pub_deps//:injectable"],
)
```

## `build_runner` flags

`build_runner_args` takes the flags of `build_runner build` that change what is
built:

- `--release`: `release_options` in `build.yaml` replace `options`
  (`e2e/build_runner/pkgs/json_release`).
- `--define=<builder>=<option>=<value>`: builder options from the command line,
  over those in `build.yaml` (`e2e/build_runner/pkgs/json_define`):

  ```starlark
  build_runner_args = ["--define=json_serializable:json_serializable=field_rename=kebab"],
  ```

- `--config=<name>`: reads `build.<name>.yaml` instead of `build.yaml`. The file
  must be in `srcs` (it is by default).

Flags that name directories, outputs or build filters are refused: `outs`
decides what is built.

## Flutter

A package that imports Flutter needs an SDK summary with Flutter's `dart:ui`.
Make one with `build_runner_sdk_summary` and pass it as `sdk_summary`. The
runner comes from rules_dart's `pub.from_lock()` over the same lock that
`flutter.pub()` reads (`rules_flutter/e2e/build_runner`):

```starlark
# MODULE.bazel
pub = use_extension("@rules_dart//dart/pub:extensions.bzl", "pub")
pub.from_lock(
    name = "build_deps",
    lock = "//go_router_pkg:pubspec.lock",
)
use_repo(pub, "build_deps")
```

```starlark
# BUILD.bazel
load("@rules_dart//dart:defs.bzl", "build_runner_sdk_summary", "dart_build_runner")

build_runner_sdk_summary(
    name = "flutter_sdk_summary",
    embedder = "@flutter_sky_engine//:sky_engine",
    runner = "@build_deps//build_runner:runner",
)

dart_build_runner(
    name = "gen",
    outs = ["lib/routes.g.dart"],
    runner = "@build_deps//build_runner",
    sdk_summary = ":flutter_sdk_summary",
    deps = ["@deps//:flutter", "@deps//:go_router"],
)
```

Builders run on the Dart VM. A builder package whose dependencies reach the
Flutter SDK is not compiled into the runner.

## Custom generators

A generator of your own that is not a `build_runner` builder is a
`dart_binary` run by skylib's `run_binary` (`e2e/codegen`):

```starlark
load("@bazel_skylib//rules:run_binary.bzl", "run_binary")

run_binary(
    name = "message_part",
    srcs = ["lib/message.dart"],
    outs = ["lib/message.g.dart"],
    args = ["--input", "$(execpath lib/message.dart)", "--output", "$(execpath lib/message.g.dart)"],
    tool = "//tools:part_gen",
)
```

## Gazelle

`bazel run //:gazelle` writes the `dart_build_runner` of each Dart package
whose lock has builders, and adds the generated files to the rules that use
them. A stock project that runs `dart run build_runner build` needs no hand
edits to its BUILD files.

### Setup

Gazelle reads the builders of the lock from the pub hub:
`@<hub>//build_runner:builders.json`, which the hub writes from the
`build.yaml` of the lock's builder packages with `package:build_config`.
Gazelle does not read any `build.yaml` itself. Give the file to the `gazelle`
target:

```starlark
# gazelle:dart_pub_deps_repo pub_deps

gazelle(
    name = "gazelle",
    data = ["@pub_deps//build_runner:builders.json"],
    gazelle = "gazelle_bin",
)
```

The hub is the one `# gazelle:dart_pub_deps_repo` names, or `pub_deps`. Two
directives change that, for the directory and below:

| Directive                         | Meaning                                                                        |
| --------------------------------- | ------------------------------------------------------------------------------ |
| `# gazelle:dart_build_runner hub` | Read the builders of the pub hub `hub`.                                        |
| `# gazelle:dart_build_runner off` | Write no code generation: per-directory rules, as for a lock without builders. |

The lock must be in a Bazel package (a `BUILD.bazel` next to `pubspec.lock`,
empty is enough) for `pub.from_lock(lock = ...)` to name it.

### What Gazelle writes

For a Dart package (a directory with `pubspec.yaml`) whose lock has a builder
that writes to the source tree (`build_to: source`), Gazelle writes every rule
of the package's `lib/`, `bin/` and `test/` in the BUILD file next to
`pubspec.yaml`, because Bazel declares a generated file only in the package
that builds it:

```starlark
dart_library(
    name = "app",
    package_name = "app",
    srcs = [
        "lib/src/models/user.dart",
        ":lib/src/models/user.g.dart",
    ],
    visibility = ["//visibility:public"],
    deps = ["@pub_deps//:json_annotation"],
)

dart_test(
    name = "user_service_test",
    srcs = [":test/user_service_test.mocks.dart"],
    main = "test/user_service_test.dart",
    deps = [
        ":app",
        "@pub_deps//:mockito",
        "@pub_deps//:test",
    ],
)

dart_build_runner(
    name = "gen",
    outs = [
        "lib/src/models/user.g.dart",
        "test/user_service_test.mocks.dart",
    ],
    runner = "@pub_deps//build_runner",
    deps = [
        "@pub_deps//:json_annotation",
        "@pub_deps//:mockito",
        "@pub_deps//:test",
    ],
)
```

- `dart_library`: every Dart file under `lib/`, and the generated ones as
  `":" + path`.
- `dart_test`: one per `test/**_test.dart`, named after its path under
  `test/`; `srcs` holds the `test/` helpers it imports and the generated files
  they name.
- `dart_binary`: one per file directly in `bin/` (`<name>_bin` when the
  library has its name).
- `dart_build_runner`: the generated files as `outs`, and as `deps` what the
  package's files import. Gazelle keeps the name of an existing one, and
  deletes it when the package names no generated file any more.
- `build_runner_sdk_summary` named `flutter_sdk_summary`, for a package whose
  files import `package:flutter` or `package:flutter_test`, set as the
  `dart_build_runner`'s `sdk_summary` (see [Flutter](#flutter)). Its
  `embedder` is `@flutter_sky_engine//:sky_engine`, rules_flutter's engine
  repository, which `MODULE.bazel` must `use_repo`.

A package whose lock has no such builder, or with `off`, keeps the
per-directory rules.

### Which files are generated

Gazelle cannot run the builders. A file is an output when both hold:

1. a Dart file of the package names it, by `part`, `import` or `export`, as a
   relative URI or `package:<self>/...`;
2. a builder of the lock with `build_to: source` writes it, by its
   `build_extensions`, for a file of the package (`lib/src/user.dart` gives
   `lib/src/user.g.dart` for `.dart: [.g.dart]`; `^`, `{{}}`, `$lib$` and
   `$package$` work as in `build_runner`).

For the builders of `json_serializable`, `freezed`, `built_value`, `drift`,
`retrofit`, `riverpod` and `go_router` (`part` directives), `mockito` and
`injectable` (imported `.mocks.dart`, `.config.dart`, exported `.module.dart`)
this gives the files stock `build_runner` writes. `auto_apply` and a
builder's default `generate_for` do not narrow the guess: the package's own
`build.yaml`, which Gazelle does not read, can widen both, and a file a source
names must come from somewhere.

Where the guess can be wrong:

- A named file no builder writes (no annotation, a builder switched off or its
  `generate_for` narrowed in `build.yaml`, a hand-written part named like a
  generated one) is declared anyway. The build fails, naming the file:
  ``No builder wrote `lib/src/plain.g.dart` of package app; ...``. Remove the
  `part`, add the annotation, or switch Gazelle off for the package.
- A builder option that changes `build_extensions` (mockito's
  `build_extensions`) is not seen: Gazelle uses the extensions the builder
  package declares.
- A generated file no Dart file of the package names is not declared: a
  non-Dart output, or one only another package imports. The build does not
  need it.
- Imports that only a generated file makes (a type a mock refers to from a
  package the test does not import) are not in `deps` until the file is
  checked in; the strict dependency check names the missing package.
- A first-party dependency's `pubspec.yaml` and `build.yaml` are not passed
  as `data`.
- A package is taken for a Flutter one when one of its files imports
  `package:flutter` or `package:flutter_test`; one that reaches Flutter only
  through another package gets no `sdk_summary` (see below).
- A directory under `lib/`, `bin/` or `test/` with a BUILD file of its own is
  a separate Bazel package: Gazelle keeps its per-directory rules and says on
  stderr which generated file it cannot declare there.

Another rule of the BUILD file that declares a named file in `out` or `outs`
(a `run_binary` of your own) writes it: Gazelle adds it to `srcs` and leaves it
out of the `dart_build_runner`.

### Checked-in generated files

A generated file that is also on disk (projects using `build_to: source` often
commit them) is declared as an output and listed once, as `":" + path`. The
build uses what the builders write, never the checked-in copy, which may be
stale; what the copy imports still counts for `deps`.

## Errors

A lock without `build_runner` fails every target that uses its runner:

```text
The lock of the pub hub "pub_deps" has no build_runner, which runs the builders of `dart_build_runner`. Add it as a dev dependency (`dart pub add dev:build_runner`) and run `dart pub get`.
```

A lock with `build_runner` older than 2.8.0:

```text
The lock of the pub hub "pub_deps" has build_runner 2.7.0; `dart_build_runner` supports build_runner 2.8.0 and later. Upgrade it (`dart pub upgrade build_runner`).
```

A file in `outs` that no builder writes:

```text
No builder wrote `lib/plain.g.dart` of package my_pkg; `build_runner build` writes no file there either. It is in `outs` because a `part`, `import` or `export` of the package names it (Gazelle declares every generated file a source names). Either a builder should write it (an annotation is missing, or the builder is disabled in `build.yaml`), or that directive should go; then re-run Gazelle, or edit `outs` if you wrote it by hand.
```

A builder that searches the package (`findAssets`) and could see a file that
is not in `srcs`. The result would differ from a build that saw the whole
package, so the action fails:

```text
A builder searched package my_pkg for `<glob>`, which matches `<path>` (generated from `lib/src/service.dart`), and `lib/src/service.dart` is not an input of this target. Add it to `srcs`.
```

A package that depends on Flutter, with no `sdk_summary`:

```text
//app:gen: this package's dependencies include Flutter, whose `dart:ui` the plain Dart SDK summary lacks. Set `sdk_summary` to a `build_runner_sdk_summary` whose `embedder` is Flutter's `sky_engine`.
```

Other checks:

- An output outside the package: `output <path> is outside the Dart package at <dir>.`
- A `pubspec` that is not a `pubspec.yaml` in this Bazel package or below it.
- `build_runner_args` that name directories, outputs or build filters, or are
  not `build_runner build` flags.
- A builder error: the action prints `build_runner failed:` and the errors,
  plus the builders' log at `WARNING` and above.

## Limits

- Gazelle predicts the generated files from the sources; see
  [Gazelle](#gazelle) for where the prediction can be wrong.
- Verified with `build_runner` 2.16.1 (rules_dart's e2e) and 2.17.1
  (rules_flutter's e2e). 2.8 to 2.15 are accepted but untested.
- Post-process builders that write new files are untested.

## Migration

The per-builder shims, the generic codegen rules and Gazelle's codegen
emission are deleted. `dart_build_runner` replaces them.

| Deleted                                                                                                                                                        | Replacement                                                                                           |
| -------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| `json_serializable_library`, `freezed_library`, `built_value_library`, `mockito_library`, `copy_with_library`, `go_router_library`, `drift_library`            | One `dart_build_runner` per package, plus `":" + out` in the `dart_library` `srcs`                    |
| `stacked_router_library`, `stacked_locator_library`, `stacked_form_library`, `stacked_logger_library`, `stacked_dialog_library`, `stacked_bottomsheet_library` | Same                                                                                                  |
| `shared_part_library`, `library_builder_library` (`dart/ext/_shared`)                                                                                          | Same; `source_gen`'s combining builder runs inside `build_runner`                                     |
| `dart_codegen`, `dart_aggregate_codegen`, `dart_sqlcodegen` with a shim from `dart/ext/<builder>`                                                              | `dart_build_runner`                                                                                   |
| `dart_codegen` / `dart_aggregate_codegen` with your own generator                                                                                              | `run_binary` with a `dart_binary` tool (see [Custom generators](#custom-generators))                  |
| `config = "{...}"` on a macro or rule                                                                                                                          | `options:` (or `release_options:`) for the builder in `build.yaml`; `--define` in `build_runner_args` |
| `annotation_dep`                                                                                                                                               | The annotation package in `deps`, as for any import                                                   |
| `@rules_dart//dart/ext/tools:check_dual_build_collisions`                                                                                                      | None. Do not check in generated files, or exclude them from `srcs`                                    |
| `@rules_dart//dart/ext/<builder>:shim`                                                                                                                         | None. The runner is `@<hub>//build_runner`, built from your lock                                      |

The curated native code assets (`//dart/ext/sqlite3`, `//dart/ext/webcrypto`,
`//dart/ext:registry.bzl`) are gone too: packages' own build hooks run instead
(see `docs/pub.md`, "Build hooks").

### Before and after

Before:

```starlark
load("@rules_dart//dart:defs.bzl", "dart_library")
load("@rules_dart//dart/ext/json_serializable:defs.bzl", "json_serializable_library")

json_serializable_library(
    name = "models",
    srcs = ["lib/src/user.dart"],
    package_name = "my_pkg",
    language_version = "3.13",
    config = '{"field_rename": "snake", "explicit_to_json": true}',
)

dart_library(
    name = "my_pkg",
    srcs = glob(["lib/**/*.dart"], exclude = ["lib/src/user.dart", "lib/**/*.g.dart"]),
    package_name = "my_pkg",
    language_version = "3.13",
    deps = [":models"],
)
```

After:

```starlark
load("@rules_dart//dart:defs.bzl", "dart_build_runner", "dart_library")

OUTS = ["lib/src/user.g.dart"]

dart_build_runner(
    name = "gen",
    outs = OUTS,
    runner = "@pub_deps//build_runner",
    deps = ["@pub_deps//:json_annotation"],
)

dart_library(
    name = "my_pkg",
    srcs = glob(["lib/**/*.dart"], exclude = OUTS) + [":" + o for o in OUTS],
    package_name = "my_pkg",
    language_version = "3.13",
    deps = ["@pub_deps//:json_annotation"],
)
```

The old `config` string moves to `build.yaml`:

```yaml
targets:
  $default:
    builders:
      json_serializable:
        options:
          field_rename: snake
          explicit_to_json: true
```

Add `build_runner` and the builder packages to `pubspec.yaml` and run
`dart pub get`, so the lock has them.

### Gazelle

These directives are gone. Move what they set to `build.yaml` or to the BUILD
file:

| Directive                                                 | Now                                                                          |
| --------------------------------------------------------- | ---------------------------------------------------------------------------- |
| `# gazelle:dart_builder_runtime_dep <Annotation> <label>` | `# gazelle:resolve dart <package> <label>` for the runtime library's imports |
| `# gazelle:dart_builder_config <Annotation> <json>`       | `options:` for the builder in `build.yaml`                                   |
| `# gazelle:dart_language_version <major>.<minor>`         | Nothing: it only set `language_version` on the codegen rules Gazelle emitted |

Gazelle no longer emits per-builder codegen rules and no longer filters
generated files by a list of extensions (`baseline_generated_extensions.txt` is
gone). It writes one `dart_build_runner` per Dart package instead; see
[Gazelle](#gazelle).
