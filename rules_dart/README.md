> **Built and maintained by AI agents.** `ai_rules_dart` is written, reviewed, tested and released by AI agents.
> Every change passes deterministic gates before it merges: hermeticity checks, byte-identical outputs, strict
> code-quality limits.
>
> **Open an issue or a PR.** Bugs, missing SDK features and slow builds are all welcome. Our agents read every
> one, fix what they can and release the fix.
>
> The goal is a fully autonomous Bazel rules workforce that keeps improving these rules, until they beat the
> hand-written alternatives.
>
> Security reports: [GitHub private advisory](https://github.com/Mivr/ai_rules_dart/security/advisories/new), reviewed by the human owner [@Mivr](https://github.com/Mivr). Continues [aran/rules_dart](https://github.com/aran/rules_dart) by Aran Donohue,
> with many thanks: see [History and thanks](#history-and-thanks).

# Bazel rules for Dart

Bazel rule set for building Dart applications and libraries.

## Installation

`ai_rules_dart` is released from [`Mivr/ai_rules_dart`](https://github.com/Mivr/ai_rules_dart), the repository that holds `rules_dart` and `rules_flutter`, each with its own tags and releases (`rules_dart-v<version>`). The notes of a release carry the block to paste, with the archive's real `integrity` hash, so every downloaded byte is verified. Add to your `MODULE.bazel`:

```starlark
bazel_dep(name = "ai_rules_dart", version = "<version>", repo_name = "rules_dart")
archive_override(
    module_name = "ai_rules_dart",
    urls = ["https://github.com/Mivr/ai_rules_dart/releases/download/rules_dart-v<version>/rules_dart-v<version>.tar.gz"],
    integrity = "<sha256-... from the release notes>",
    strip_prefix = "rules_dart-<version>",
)

dart = use_extension("@rules_dart//dart:extensions.bzl", "dart")
dart.toolchain(dart_version = "3.14.1")
use_repo(dart, "dart_toolchains")

register_toolchains("@dart_toolchains//:all")
```

The `repo_name` keeps the `@rules_dart//` labels used throughout these docs working.

A `dart.toolchain(...)` request from the root module takes precedence over
requests from dependencies (rules_dart's included), even when the root's version
is older; with no root request, the highest requested version is selected.

The SDKs this release lists are the current stable line, Dart 3.14.1 (the
default) and 3.14.0 (the Dart of Flutter 3.50.1), and the previous one, Dart
3.13.5 (the Dart of Flutter 3.47.7). Every rule works on each of them. On 3.13
`dart_format` runs the SDK's own `dart format`, since the formatter built into
the rules is 3.14's; on 3.14 it formats in process, as 3.14's `dart format` does.

## Usage

### Running the Dart SDK

No separate Dart SDK installation is needed. The toolchain downloads the SDK
automatically. To run the `dart` CLI directly:

```shell
bazel run @rules_dart//dart -- --version
bazel run @rules_dart//dart -- analyze lib/
bazel run @rules_dart//dart -- format lib/
```

> **Tip**: Consider using [`bazel_env`](https://github.com/buildbuddy-io/bazel_env.bzl)
> to put Bazel-managed tool binaries on your `PATH` for IDE and shell use.

### Rules

```starlark
load("@rules_dart//dart:defs.bzl", "dart_library", "dart_binary", "dart_test")

dart_library(
    name = "greeter",
    srcs = glob(["lib/**/*.dart"]),
)

dart_binary(
    name = "app",
    main = "bin/main.dart",
    deps = [":greeter"],
)

dart_test(
    name = "greeter_test",
    main = "test/greeter_test.dart",
    deps = [":greeter"],
)
```

A library also ships the files its package needs at run time but never compiles
with `data`:

```starlark
dart_library(
    name = "greeter",
    srcs = glob(["lib/**/*.dart"]),
    data = ["pubspec.yaml", "LICENSE"],
)
```

Those files ride `DefaultInfo.runfiles`, and transitively the runfiles of every
`dart_binary`/`dart_test` that depends on the library, so a program can read
them through `package:runfiles` or by walking a dependency's package root. They
are never in `DefaultInfo.files`, never in `DartInfo.transitive_resources`, and
never in an action's inputs, so shipping one does not recompile or re-analyze
anything. `DartInfo.transitive_package_files` carries their closure for a
consumer that would rather not walk runfiles. A `.dart` file in `data` is
refused at analysis: it belongs in `srcs`. Non-Dart files under `lib/` belong
in `resources`, which is the analyzer-visible half of the package.

### Tests

A `dart_test` whose `deps` include `package:test` runs under `package:test`'s
own runner, built from that same package, so Bazel's test features work:

- `bazel test --test_filter=<regex>` runs the cases whose names match.
- `shard_count` splits a file's cases across shards.
- `include_tags` and `exclude_tags` select or skip cases by `package:test` tag
  (such as `@Tags(['smoke'])`), where each entry is a complete selector
  evaluated on its own: `include_tags = ["smoke"]` runs only matching cases
  (`--tags`), and `exclude_tags = ["broken"]` skips them (`--exclude-tags`).
- Each case appears in Bazel's test report (`test.xml`).
- Bazel's `size`/`timeout` is the only time limit. `package:test`'s default
  30-second limit per case is switched off; a `timeout:` a test states on a
  case still applies.

`package:test` must be a direct entry in `deps` (for example `@deps//:test`),
not reached only through a helper library: the runner comes with that target.
A test whose `main` does not use `package:test` runs directly, and fails if
given a filter, shards or tag selectors, because it has no cases to select.

#### What a test of a project gets by default

A project is a directory with a `pubspec.yaml` that a `pub.from_lock` or
`pub.project` lock of the root module names: the lock's own directory, the members of the pub
workspace its pubspec declares, and its relative `path:` packages. The
`dart_library`, `dart_binary` and `dart_test` macros give a target in that
directory's BUILD file what `dart test` and `dart run` give it, with nothing
restated:

- **Language version.** A library compiles at the version pub writes for the
  pubspec (its `environment: sdk:` lower bound). A binary or a test is a member
  of the pubspec's package (`package_name` and `language_version` from it). A
  target that states `language_version`, `package_name` or `package` keeps
  what it states, and a library of the package that states another version
  than its test fails the build naming both.
- **Working directory.** A test runs in the project's directory in its
  runfiles (the `pubspec` attribute, set to the project's `pubspec.yaml`), as
  `dart test` runs it in the package's, so `File('test/fixtures/x.json')` and
  `File('pubspec.yaml')` resolve. A test outside a project runs in the runfiles
  root of the main repository.
- **Fixtures.** Every file under the project's `test/` that is not Dart source
  and not hidden is in the test's `data`, a name with a space included. A
  directory with its own BUILD file is a package of its own and is left out, and
  so is `failures/`. A file whose name cannot be a label (a `:`, a `\` or a
  control character) fails the package's tests at analysis, naming it. A file
  outside `test/` that a test reads is named in `data`. Editing a fixture reruns
  every test of the package.
- **`dart_test.yaml`.** The project's `dart_test.yaml` is in the test's
  `data`, and `package:test` reads it from the directory the test runs in, as
  under `dart test`: its tags, `skip`, `test_on` and presets apply. Its
  timeouts do not: Bazel's `size`/`timeout` is the limit.

Tests are declared in the project's own package, the BUILD file beside its
`pubspec.yaml`: a test in a BUILD file below it, such as `test/BUILD.bazel`,
gets none of these defaults.

A lock that another rule set resolves, such as rules_flutter's `flutter.pub`,
is named to these macros with `pub.project`, which indexes the lock's projects
and declares no hub, no package and no fetch. A lock that a `from_lock` tag
reads too names its projects once.

```starlark
pub = use_extension("@rules_dart//dart/pub:extensions.bzl", "pub")
pub.project(lock = "//app:pubspec.lock")
```

A binary or test that takes the pubspec's `name` fails the build when a
library of the same directory states another `package_name`, naming both and
the pubspec's name: one directory is one package, and pub names it after the
pubspec.

The runner starts from an app-JIT snapshot, trained on one run of it, so each
test starts faster than from its kernel. The snapshot is skipped when the exec
and target SDKs differ, and on Windows. The training targets a baseline CPU
rather than the build host's, which is meant to let a remote cache share the
snapshot across machines. Set `--@rules_dart//dart:test_runner_snapshot=false`
to run the kernel instead, for example when a snapshot misbehaves.

A `dart_test`'s runfiles carry only the parts of the SDK it needs to run its
kernel. A test that runs SDK commands itself (`dart format`, `dart compile`)
declares `@rules_dart//dart` in `data`, which brings the whole SDK.

Kernel compilation is modular by default for both `dart_test` and
`dart_binary(compile_mode = "kernel")` (including `package:test`'s
`test_runner`). Each `dart_library` compiles its own sources once, into one
kernel per group of libraries that import each other (`.kmod`), the module's
outline for downstream compilation (`.koutline`), and an index of those kernels.
The module compiler is built once per SDK, from the pinned sources of the Dart
SDK's own front end at that SDK's tag: the first build with an SDK fetches them
(a 39 MB archive) and compiles the tool (about 20 s).
A `dart_test` or kernel-mode `dart_binary` compiles only its own entry module and
links in only the `.kmod` kernels its imports reach, so a library no executable
imports is never linked. Editing a leaf library recompiles that library and the
dependents that reach its changed outline, not every test or kernel binary in the
repository, and `package:test` is compiled once rather than once per test.

One source belongs to one target, with one exception for the entry point: an
executable whose `main` a library in its own `deps` lists (a `dart_library`
over all of `lib/`, `lib/main.dart` included) takes `main` from that library.
Its entry module compiles no copy of the file: the program's `main` is the
library's, under the library's `package:` URI, as `dart run` names it. Any other
source the executable and a library both list, and a `main` that only a library
further down lists, fails the build naming both targets.

A library's module compiles the sources it declares that compile for the VM.
The compiler's own result decides which those are. A library that does not
compile, because it imports a `dart:` library the VM lacks such as `dart:html`,
is left out, and so is every library that imports one that is left out. So is a
library that imports or parts a file the module does not declare: another target
of a package split across targets may declare it. A conditional import takes its
VM alternative. Each module's `.vm_excluded.txt` sidecar lists the sources it left
out, and why. An executable that reaches one compiles it from source along with
its own code; if it still cannot, the compile fails naming the library, the
import and the module that left it out.
A kernel executable (`dart_test`, `dart_binary(compile_mode = "kernel")`) has no
other way to build its kernel: a shape the modules cannot take fails at analysis,
naming the target and the reason, and so does a library under an SDK whose
version has no module compiler. `modular_kernel = False` on a `dart_binary`
compiles the whole program with `gen_kernel` instead; only the rule set's own
tools need it.

`exe` and `aot-snapshot` binaries compile from sources by default, whatever
`modular_kernel` says: modules compile against the JIT platform, and at SDK
3.13.5 a module compile has no AOT target. Probed at that SDK, only
`dart.library.mirrors` differs (true on the JIT VM, false in AOT); `io`, `html`,
`js_interop`, `ffi`, `isolate`, `developer` and the other `dart.library.*` keys
agree, and `dart.vm.product` differs only for a module compiled with it false,
which only `dart_test` does. `dart_binary(link_modules = True)` opts an
individual `exe` or `aot-snapshot` target into the linked per-library kernel
path (modules, one link, then the whole-program steps over the linked kernel
with no `.dart` source as an input), so a body edit recompiles one module. It
applies to a target whose closure compiles as modules, with `dart.vm.product`
true and not the `dbg` compilation mode; any other target takes the source path. An opted-in target also runs one validation action over every `.dart`
file of its dependency closure, other repositories' packages included. The build
fails with one `<path>:<line>: <what>` line per `import` or `export` of
`dart:mirrors`, per `dart.library.mirrors` key of an `if (...)` configuration and
per `bool.fromEnvironment` call naming it; comments are skipped and a name built
at run time is out of reach. Unset `link_modules` to compile such a closure from
sources. The default stays the source path; revisit at the next SDK pin.

A `dart_test` or kernel-mode `dart_binary` embeds its closure's native code
assets in its entry module, as `gen_kernel --native-assets` does in a whole
program. Its own `defines`, and the `-D` entries of a kernel binary's
`dart_compile_flags`, are the configuration of its `deps`, so every module of its
closure and its entry compile with them, followed by the
`//dart:extra_dart_defines` flag; any other `dart_compile_flags` entry fails the
build, naming the target and the flag. Executables with equal `defines` share every
module; another set compiles the closure's modules once more. A `dart_binary`
carries its `defines` this way only when it can link modules (`kernel`, or
`link_modules = True`).

### Running snapshots and split debug info

A `dart_binary(compile_mode = "aot-snapshot")` or
`dart_binary(compile_mode = "jit-snapshot")` target is runnable with
`bazel run`, and `ctx.executable` consumers can start it the same way. The
`DefaultInfo.executable` is a launcher, not the raw `.aot` or `.jit` file: on
Unix it is `<name>.sh`, and on Windows it is `<name>.bat`. The launcher runs
the target's own pinned-SDK `dartaotruntime` (AOT) or `dart` VM (JIT) on the
snapshot in runfiles and forwards every command-line argument and the exit
code. A snapshot runs as a VM file form, which keeps the caller's environment
and writes nothing under `HOME`. The raw snapshot is still
`DefaultInfo.files` and is also the `snapshot` output group, so a build-only
consumer keeps receiving `<name>.aot` or `<name>.jit` at its usual path:

```sh
bazel build //app:app_aot
bazel build //app:app_aot --output_groups=snapshot
```

Every compiled `dart_binary` exposes the `snapshot` output group: the raw
`.aot`/`.jit` snapshot in those modes, the native executable in `exe`, and the
`.dill` kernel in `kernel`.

Set `split_debug_info = True` on an `exe` or `aot-snapshot` target to separate
the DWARF symbols for crash symbolication. The compile runs with
`--save-debugging-info` and `--dwarf-stack-traces`, writes `<name>.debug`, and
exposes it through the `debug_info` output group (it is also in
`DefaultInfo.files`):

```starlark
dart_binary(
    name = "app",
    main = "bin/main.dart",
    split_debug_info = True,
)
```

```sh
bazel build //app:app --output_groups=debug_info
```

`split_debug_info` is off by default and then produces no extra file. Setting
it on `kernel` or `jit-snapshot` fails analysis naming `compile_mode`, because
those modes do not produce a separate DWARF container.

### Using pub.dev packages

Declare individual packages with `pub.package()`:

```starlark
pub = use_extension("@rules_dart//dart/pub:extensions.bzl", "pub")
pub.package(
    name = "path",
    version = "1.9.1",
    sha256 = "75cca69d1490965be98c73ceaea117e8a04dd21217b37b292c9ddbec0d955bc5",
)
use_repo(pub, "path")
```

Then depend on them in your targets:

```starlark
dart_binary(
    name = "app",
    main = "main.dart",
    deps = ["@path//:path"],
)
```

For projects with many dependencies, use `pub.from_lock()` to import all
packages from a `pubspec.lock` file at once:

```starlark
pub = use_extension("@rules_dart//dart/pub:extensions.bzl", "pub")
pub.from_lock(
    name = "pub_deps",
    lock = "//:pubspec.lock",
)
use_repo(pub, "pub_deps")
```

Each hosted package is downloaded into its own external repository for better
caching and parallelism. Packages are available as `@pub_deps//:package_name`:

```starlark
dart_binary(
    name = "app",
    main = "main.dart",
    deps = [
        "@pub_deps//:path",
        "@pub_deps//:collection",
    ],
)
```

Each generated spoke also stages the package's non-`lib/` runtime files, so a
consumer that scans a dependency's package root — Flutter's plugin discovery
reading `pubspec.yaml`, say — finds it. `package_files` controls the glob on
both `pub.from_lock()` and `pub.package()`:

```starlark
pub.from_lock(
    name = "pub_deps",
    lock = "//:pubspec.lock",
    # The default, stated explicitly. It never matches lib/**, BUILD* or
    # WORKSPACE*.
    package_files = ["pubspec.yaml", "LICENSE*"],
)
```

The default is deliberately small: every pattern multiplies every dependent
test's runfiles tree across all pub spokes. Pass a broader glob
(`package_files = ["assets/**"]`) to opt in to more files, or
`package_files = []` to opt out entirely. Pubspec-declared asset, font and
shader directories outside `lib/` already reach a Flutter build through
rules_flutter's own asset targets; `package_files` is not a second mechanism
for those.

> **Note**: `pub.from_lock()` resolves **hosted** packages (i.e. packages
> from a pub registry such as pub.dev) and **git** packages. Packages with
> `path`, `sdk`, or any other source in the lock file are skipped: no
> repository is created for them, so `package:` imports of those packages fail
> to resolve unless they are provided another way. `sdk` packages (e.g.
> Flutter's) come from the SDK itself, not pub. For `path` dependencies,
> declare them with `pub.package()` or as local `dart_library` targets. Each
> `from_lock()` prints one summary of everything it skipped, grouped by
> source.
>
> A `git` package is pinned by its lock file's `resolved-ref`, the full
> 40-hex commit SHA it is checked out at — the commit SHA is the pin, rather
> than a `sha256` as for hosted packages. When the lock records a `path` for
> the package, only that subdirectory of the repository is fetched. A package
> whose symlinks escape its root fails the fetch.

Set `isolated = True` on a `pub.from_lock()` to keep that hub out of the shared
registry: its spokes are namespaced `<hub>__<pkg>`, it pins the versions in its
own lock (no `on_version_conflict` resolution with other hubs), and its
spokes depend only on other spokes of the same hub. Use this for standalone
tools that legitimately need a different version of a package (for example an
analyzer-based checker) from the rest of the build:

```starlark
pub.from_lock(
    name = "tool_deps",
    lock = "//tools:pubspec.lock",
    isolated = True,
)
```

An isolated hub ignores `pub.package()` declarations for packages it contains:
it builds and uses its own spoke at the version its lock pins, so an explicit
declaration does not override an isolated hub's version. A non-isolated hub
continues to honour `pub.package()` as before.

Pub allows two packages to depend on each other (`dio` and `dio_web_adapter`
do), which would turn the generated `dart_library` targets into a dependency
cycle. `pub.from_lock()` merges every such cycle into one `dart_library` that
carries all of the cycle's packages — each keeps its own `package_name` and
its own `lib/` root — so `@pub_deps//:dio` and `@pub_deps//:dio_web_adapter`
keep working with no cycle in the target graph.

### BUILD file generation with Gazelle

rules_dart includes a [Gazelle](https://github.com/bazelbuild/bazel-gazelle)
plugin that generates `BUILD.bazel` files from your Dart source tree.

Add `gazelle` to your `MODULE.bazel`:

```starlark
bazel_dep(name = "gazelle", version = "0.50.0")
```

Then create a root `BUILD.bazel` with the Gazelle targets:

```starlark
load("@gazelle//:def.bzl", "gazelle", "gazelle_binary")

gazelle_binary(
    name = "gazelle_bin",
    languages = [
        "@rules_dart//gazelle/dart",
    ],
)

gazelle(
    name = "gazelle",
    gazelle = "gazelle_bin",
)
```

Run Gazelle to generate or update BUILD files:

```shell
bazel run //:gazelle
```

Gazelle will scan `lib/`, `bin/`, and `test/` directories, emitting
`dart_library`, `dart_binary`, and `dart_test` targets respectively. It
resolves `import` statements to determine `deps`, including support for
`show` and `deferred` import modifiers.

When the lock has `build_runner` builders, Gazelle also writes one
`dart_build_runner` per Dart package, with the generated files its sources
name (`part 'user.g.dart';`, `import 'foo_test.mocks.dart';`) as outputs and in
the `srcs` of the rules that use them. It then writes all of the package's
rules in the BUILD file next to `pubspec.yaml`. It reads the builders from the
pub hub, so give the hub's facts to the `gazelle` target:

```starlark
gazelle(
    name = "gazelle",
    data = ["@pub_deps//build_runner:builders.json"],
    gazelle = "gazelle_bin",
)
```

See [Gazelle in `docs/build_runner.md`](./docs/build_runner.md#gazelle) for
what it writes and where its guess of the generated files can be wrong.

#### Directives

Add directives as comments in a `BUILD.bazel` file to control generation:

- **`# gazelle:dart_pub_deps_repo pub_deps`** — tells Gazelle which
  external repository holds pub.dev packages. Imports like
  `package:shelf/shelf.dart` are resolved to `@pub_deps//:shelf`.

- **`# gazelle:dart_package_name my_app`** — explicitly sets the
  `package_name` attribute on the generated `dart_library` rule. In a directory
  that already declares a `dart_package_metadata`, Gazelle emits
  `package = ":pkg"` on the rules it generates instead of an inline
  `package_name`, and warns when the declaration's name differs from the one the
  pubspec or this directive supplies.

- **`# gazelle:dart_build_runner pub_deps`** — the pub hub whose builders
  Gazelle reads (`@pub_deps//build_runner:builders.json`); the default is the
  `dart_pub_deps_repo` hub, else `pub_deps`. `off` writes no code generation
  for the directory and below.

- **`# gazelle:resolve dart foo //third_party:foo`** — overrides
  automatic dependency resolution for a Dart package (the `foo` of
  `package:foo/...` imports), mapping it to an explicit Bazel target.

#### pubspec.yaml auto-detection

If a `pubspec.yaml` file is present in the same directory as a `lib/`
folder, Gazelle reads the `name` field and uses it as both the target name
and `package_name` for the generated `dart_library`. This means most
projects need no directives at all.

#### Analysis options

For every directory holding an `analysis_options.yaml`, Gazelle emits a
`dart_analysis_options` named `analysis_options` (`analysis_options_yaml` if
another rule in that directory has the name) whose `deps` are the packages its
`include: package:<pkg>/...` lines name. In the root package it keeps one
`dart_analysis_config` named `analysis_config` listing all of them, which is the
target the `analysis_config` flag points at. A run on part of the tree
(`gazelle path/to/dir`, or `-r=false`) updates only the directories it visits
and keeps the config's other entries, so `gazelle -mode=diff` over the whole
repository in CI reports an `analysis_options.yaml` nobody listed.

### Code generation

`dart_build_runner` runs the `build_runner` builders of your lock
(`json_serializable`, `freezed`, `mockito`, `drift_dev`, ...) for one Dart
package and writes the same bytes as `dart run build_runner build`. The runner
is built from your lock (`@<hub>//build_runner`, which needs `build_runner`
2.8.0 or later in the lock), and builder options stay in your `build.yaml`.

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
    deps = ["@pub_deps//:json_annotation"],
)
```

A generator of your own runs as a `dart_binary` under skylib's `run_binary`
(see `e2e/codegen`). Gazelle writes `dart_build_runner` for you (see
[BUILD file generation with Gazelle](#build-file-generation-with-gazelle)).

See [`docs/build_runner.md`](./docs/build_runner.md) for attributes, Flutter,
`--release`/`--define`/`--config`, error messages, and migration from the
removed `*_library` builder macros and `dart_codegen` rules.

#### Stating a package's name once

Every rule that builds part of a package must agree on its `package_name` and
`language_version`: a library and a test of the same package, or several
`dart_library` targets that split one package. A `dart_package_metadata`
target declares them once and the rules point at it:

```starlark
load("@rules_dart//dart:defs.bzl", "dart_library", "dart_package_metadata", "dart_test")

dart_package_metadata(
    name = "pkg",
    package_name = "my_pkg",
    language_version = "3.11",
)

dart_library(
    name = "my_lib",
    srcs = glob(["lib/**/*.dart"]),
    package = ":pkg",
)

dart_test(
    name = "my_test",
    main = "test/my_test.dart",
    package = ":pkg",
    deps = [":my_lib"],
)
```

Set `package` or the inline attributes, never both — the rules refuse the
overlap rather than silently ignoring one. Because it is a target rather than a
macro, the rules referencing it can sit in different BUILD files, which is the
case nothing else covers.

This is not `pub.package()`, which fetches a published package from pub.dev;
`dart_package_metadata` states facts about a package you are building yourself.

#### Executables in a package

A `dart_binary` or `dart_test` in a project's directory is a member of the
pubspec's package by default (see "What a test of a project gets by default").
Elsewhere, a `dart_binary`, `dart_test`, `dart_js_binary` or `dart_wasm_binary` belongs to
no package unless it says so, and usually need not: its entrypoint takes the
language version of the package whose root directory contains it, as Dart does
for `bin/` and `test/`. A package with no `dart_library` has nothing to state
that version, so an executable may state it itself, with the same `package`, or
inline `package_name` / `language_version`, that a library takes:

```starlark
dart_binary(
    name = "tool",
    main = "bin/tool.dart",
    language_version = "3.6",
)
```

It is then a member of that package, rooted at its BUILD file's directory as a
`dart_library` there would be: the entrypoint compiles, analyzes and is
format-checked at that version. The package name defaults to the directory's
name. Everything it states must agree with its `deps`, or the build fails
naming both sides: a library of the same package (same directory) must state
the same name and the same `language_version`; a package in `deps` with the
same name must be rooted in the same directory; and each of the executable's
own files must sit in its directory and not inside another package's.

### Recommended Bazel settings

rules_dart ships `dart/consumer.bazelrc`, the settings only a bazelrc can set.
Import it from your `.bazelrc` with one line (the path is where you keep the
archive's file):

```
# .bazelrc
import %workspace%/third_party/rules_dart/dart/consumer.bazelrc
```

Each setting, and what it saves:

- `--reuse_sandbox_directories` saves the time to delete and recreate a sandbox
  directory for every action.
- `--nobuild_runfile_links` saves linking a runfiles tree for every binary and
  test on each build; use `--build_runfile_links` to run a built binary outside
  `bazel run`.
- `--experimental_shrink_worker_pool` saves the memory idle persistent workers
  (analyzer, kernel, `build_runner`) hold.
- `--incompatible_exclude_starlark_flags_from_exec_config` saves rebuilding the
  build tools for each set of `defines`: an executable's `defines` are the
  configuration of its `deps`, and without this flag the exec configuration
  inherits them.

None of them relaxes a gate, the lockfile mode, sandboxing or a checksum.

### Static analysis and formatting

`dart analyze` and the `dart format` check run as an aspect, `dart_analyze`,
over every Dart target a `bazel test` names. Enable it in `.bazelrc`, and list
every `analysis_options.yaml` in the repository in one `dart_analysis_config`:

```
# .bazelrc
test --aspects=@rules_dart//dart:analyze.bzl%dart_analyze
test --output_groups=+dart_analyze
test --output_groups=+dart_format
common --@rules_dart//dart:analysis_config=//:analysis_config
```

Each check is its own output group: keep the `dart_analyze` line for analysis,
the `dart_format` line for the format check, or both. A check whose group is
not requested does not run.

```starlark
# BUILD.bazel
load("@rules_dart//dart:defs.bzl", "dart_analysis_config", "dart_analysis_options")

dart_analysis_options(
    name = "analysis_options",
    src = "analysis_options.yaml",
    deps = ["@very_good_analysis"],  # packages its `include:` names
)

dart_analysis_config(
    name = "analysis_config",
    options = [
        ":analysis_options",
        "//tools:analysis_options",  # tools/analysis_options.yaml
    ],
)
```

Each file is judged by the nearest listed `analysis_options.yaml` above it, as
in the IDE, so every listed file must have that name. An options file may
`include:` another listed one by relative path (`include:
../analysis_options.yaml`). Any other yaml it includes comes from a package, by
`package:` URI, with that package in the `dart_analysis_options`'s `deps`: only
listed options files and those packages are staged, so a relative include of
any other file fails both checks rather than reading a file no target
declares. `bazel test //...` then
analyzes every Dart target it matches, and any diagnostic, down to an info,
fails the build. Only each target's own hand-written files are checked: its
dependencies are resolved but not re-checked (each is checked as a target of
its own), generated files are never checked, and targets in other repositories
(pub packages, other Bazel modules) are left to the module that owns them.
Options files from other repositories are refused; to share a ruleset across
modules, `include:` it from an options file of your own and put its package in
that `dart_analysis_options`'s `deps`. Tag a target `no-dart-analyze` to skip
its analysis, and `no-dart-format` to skip its format check; each tag leaves
the other check in place.

A `dart_binary`, `dart_test`, `dart_js_binary` or `dart_wasm_binary` has its
entrypoint checked, which is how you lint a `main.dart`: it sits outside any
package's `lib/`, so no `dart_library` will accept it, and it would otherwise be
the one file in a project nothing checks.

The format check runs `dart format --set-exit-if-changed` over the same files,
and fails the build if formatting would change any of them. Its settings are
the `formatter:` section (`page_width`, `trailing_commas`) of the same nearest
listed `analysis_options.yaml`, including what that file `include:`s, and a
file under no listed options file gets stock defaults. Options files the
config does not list are never read, whatever directory they sit in: the check
runs against a staged copy of your sources, not the sources themselves, so the
verdict cannot depend on files no target declares or on sandboxing settings.
If an options file cannot be read — an `include:` that does not resolve — the
check fails rather than quietly formatting at stock defaults, as `dart format`
itself would.

The language version selects the formatting _style_: below `3.7`, `dart format`
writes the old short style, and from `3.7` on the tall one. The check formats
each target at its own package's `language_version` (set on the `dart_library`
or its `dart_package_metadata`; Gazelle copies it from `pubspec.yaml`). An
executable's entrypoint takes the version of the package whose directory
contains it, as Dart does for `bin/` and `test/`, or the one the executable
states for itself (see [Executables in a package](#executables-in-a-package)). With no version stated, the
check uses the newest the SDK knows, so a package on an older version must
state it for the check to hold it to the style its own `dart format` produces.

`dart_format` is the check's `bazel run` counterpart: it rewrites files in your
workspace with the settings the check applies to them. It reads the same
`analysis_config`, which is why that flag goes under `common`, and stages the
options exactly as the check does, so each file gets its nearest listed
options file. Running the SDK's formatter over the workspace directly
(`bazel run @rules_dart//dart -- format`) cannot resolve an `include:` by
`package:` URI, because there is no package config for it to use, and the SDK
then ignores every key in the options file, not only the included ones.

```starlark
load("@rules_dart//dart:defs.bzl", "dart_format")

dart_format(name = "format")
```

```sh
bazel run //:format -- lib test  # files or directories, relative to where you run it
```

It formats at the newest language version the SDK knows unless you pass
`--language-version=<major>.<minor>`. The check uses each target's own
version, so pass it when formatting a package below `3.7`. Files outside the
workspace are refused: no listed options could govern them.

`dart_fix` applies the analyzer's automated fixes — the same quick-fixes an IDE
offers, driven by the lints your options enable. It fixes its target's own
files over the very project the `dart_analyze` aspect stages to analyze them,
under the same `analysis_config`, which is why that flag goes under `common`:
`bazel run` then sees the options `bazel test` checks against.

```starlark
load("@rules_dart//dart:defs.bzl", "dart_fix")

dart_fix(
    name = "fix",
    target = ":greeter",
)
```

```sh
bazel run //:fix              # write the fixes into your sources
bazel run //:fix -- --dry-run # print them as a diff, change nothing
```

Generated files are never rewritten: only files Bazel records as sources are
eligible, so codegen output stays resolvable to its importers without being
edited. A target tagged `no-dart-analyze` can still be fixed. To inspect what a
run would do without applying anything, build the outputs directly:

```sh
bazel build //:fix --output_groups=+dart_fix_manifest  # what was fixed, and what was skipped
bazel build //:fix --output_groups=+dart_fix_fixes     # the fixed files themselves
```

#### Analyzer summaries

`dart_analyze` checks each target against summaries of its dependencies, on by
default. Each dependency is summarized once, as its declarations without
function bodies, and the target is checked against those summaries rather than
against its dependencies' source. The check is faster, and a body edit in a
library no longer re-checks the libraries above it.

To analyze from staged transitive sources, turn summaries off in `.bazelrc`:

```
# .bazelrc
common --@rules_dart//dart:analyzer_summaries=false
```

In both modes, the pinned `analyzer_summary` worker is the sole analysis engine on
supported Dart SDKs (3.13 to 3.14, bounded by `ANALYZER_MIN_LANGUAGE_VERSION` and
`ANALYZER_MAX_LANGUAGE_VERSION` in `dart/private/dart_analyzer_summary.bzl`). With
the flag off, zero per-package summaries are built and `analyzer_summary` analyzes
staged sources with zero `--summary` flags. Flutter targets resolve `dart:ui` via
`sky_engine`'s embedder SDK summary in both modes.

Turning the flag off therefore no longer runs the SDK's own `dart analyze`: it
runs the pinned `package:analyzer` and the vendored linter, the same as with the
flag on, so both modes report the same diagnostics. They can differ from stock
`dart analyze`; a lint rule the SDK lacks
is accepted rather than reported as `undefined_lint`.

Stock SDK `dart analyze` via `analyze_runner` is used only as fallback in these
cases:

- The toolchain's Dart SDK is outside the supported range (< 3.13 or > 3.14).
- Its closure holds an unbacked embedder (a `lib/_embedder.yaml` outside Flutter's
  `sky_engine`).

When a target cannot be analyzed from summaries (such as an opaque `srcs_dir`
dependency or a package split across targets), it is analyzed over staged sources
by `analyzer_summary` without summaries.

The diagnostics come from rules_dart's pinned `package:analyzer` (14.5.0) and
`rules_dart_project_lints` hosted in the `analyzer_summary` worker, with lint rules
from `third_party/dart_linter`. `dart fix` still runs on the SDK, and the format check
is unchanged.

#### Checking targets `//...` does not reach

The `.bazelrc` setup checks the targets a test run names, so it never reaches a
target tagged `manual`, or a fixture that must not be built by a wildcard.
`dart_analysis_test` applies the same aspect to the targets it lists:

```starlark
load("@rules_dart//dart:defs.bzl", "dart_analysis_test")

dart_analysis_test(
    name = "fixtures_analysis_test",
    targets = [":manual_fixture"],
)
```

Both checks run on each listed target, less what its `no-dart-analyze` or
`no-dart-format` tag removes, under the same `analysis_config` flag, whatever
output groups the command line asks for. A violation fails the build of the
test. It is not the way to enable the checks — the `.bazelrc` setup is — only
the way to reach what that setup cannot name.

### Web compilation

`dart_js_binary` compiles a Dart entrypoint to JavaScript via `dart compile js`.
`dart_wasm_binary` compiles to WebAssembly via `dart compile wasm` (requires a
browser with WasmGC support).

```starlark
load("@rules_dart//dart:defs.bzl", "dart_js_binary", "dart_wasm_binary")

dart_js_binary(
    name = "app",
    main = "main.dart",
    deps = [":my_lib"],
)

dart_wasm_binary(
    name = "app_wasm",
    main = "main.dart",
    deps = [":my_lib"],
)
```

### Recorded uses and link hooks

A package can ship a `hook/link.dart` that decides what to include from how the
program uses the package: the compiler records each constant instance of a
`@RecordUse` class (and each constant call to a `@RecordUse` static method)
that survives tree-shaking. `dart_binary(record_use = True)` writes those uses
beside the executable, and `dart_link_hook` runs the link hooks in its `deps`
over them and collects the data assets they emit.

```starlark
load("@rules_dart//dart:defs.bzl", "dart_binary", "dart_library", "dart_link_hook")

dart_library(
    name = "glyphs",
    srcs = glob(["lib/**/*.dart"]),
    link_hook = "hook/link.dart",
    deps = ["@pub_deps//:data_assets", "@pub_deps//:hooks", "@pub_deps//:meta", "@pub_deps//:record_use"],
)

dart_binary(
    name = "app",
    main = "bin/main.dart",
    record_use = True,
    deps = [":glyphs"],
)

dart_link_hook(
    name = "app_assets",
    data_assets = ["package:glyphs/glyphs/index.json"],
    recorded_uses = ":app",
    deps = [":glyphs"],
)
```

Uses are recorded in the `exe` and `aot-snapshot` modes; in `kernel` and
`jit-snapshot` the hooks see none. The data assets a hook emits are declared by
id in `data_assets`, since Bazel names every output before the hooks run; the
build fails if a hook emits a different set, or if it fails itself, with the
hook's message. Pub packages that ship a link hook get `link_hook` set by
`pub.from_lock()`.

## Examples

The [`e2e/`](e2e/) directory contains complete working examples:

| Example                                               | What it demonstrates                                                                      |
| ----------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| [`hello_world`](e2e/hello_world/)                     | Minimal binary + all compile modes (`exe`, `aot-snapshot`, `kernel`, `jit-snapshot`)      |
| [`library_deps`](e2e/library_deps/)                   | Transitive `dart_library` dependencies, `srcs` attribute                                  |
| [`dart_test`](e2e/dart_test/)                         | Tests with and without deps, `srcs` for test helpers                                      |
| [`analysis`](e2e/analysis/)                           | The `dart_analyze` aspect's checks with `package:`-included options                       |
| [`fix`](e2e/fix/)                                     | `dart_fix` write-back, and that generated files are never rewritten                       |
| [`analyze_composition`](e2e/analyze_composition/)     | A lint ruleset shared from another Bazel module                                           |
| [`web_app`](e2e/web_app/)                             | JavaScript and WebAssembly compilation with library deps                                  |
| [`pub_deps`](e2e/pub_deps/)                           | Single pub.dev package via `pub.package()`                                                |
| [`pub_lock`](e2e/pub_lock/)                           | Multiple packages from `pubspec.lock` via `pub.from_lock()`                               |
| [`gazelle`](e2e/gazelle/)                             | Automatic BUILD file generation with Gazelle, code generation of a stock package included |
| [`cross_compile`](e2e/cross_compile/)                 | Cross-compilation to other platforms via `platform_data` transition                       |
| [`dart_test_pkg`](e2e/dart_test_pkg/)                 | `dart_test` with pub dependencies via `pub.from_lock()`                                   |
| [`pub_lock_dedup`](e2e/pub_lock_dedup/)               | Cross-lock-file package deduplication                                                     |
| [`pub_lock_upgrade`](e2e/pub_lock_upgrade/)           | Version conflict resolution with `on_version_conflict = "upgrade"`                        |
| [`pub_lock_conflict`](e2e/pub_lock_conflict/)         | Version conflict detection across lock files                                              |
| [`pub_lock_cross_module`](e2e/pub_lock_cross_module/) | `pub.from_lock()` across Bazel module boundaries                                          |
| [`build_runner`](e2e/build_runner/)                   | `dart_build_runner` with real builders, compared with stock `build_runner build`          |
| [`codegen`](e2e/codegen/)                             | Custom generators as `dart_binary` + `run_binary` over parts, re-exports and source sets  |
| [`ext_exemplar`](e2e/ext_exemplar/)                   | Native `code_assets` (sqlite3, webcrypto) and a pub cycle merged by `dart_package_member` |
| [`link_hook`](e2e/link_hook/)                         | `record_use` and a package's `hook/link.dart` emitting a data asset via `dart_link_hook`  |

> **Note**: Only the `exe` and `aot-snapshot` compile modes cross-compile via
> `--platforms`. `kernel` is a VM format that ignores target flags, and a JIT
> snapshot is host-only, so a cross-configured `jit-snapshot` target fails
> analysis: it is trained and run on the machine that builds it. `dart_test`
> always runs on the host. Linux targets are `linux-x64`,
> `linux-arm64`, `linux-riscv64` and `linux-arm` (armv7, selected by
> `@platforms//cpu:armv7`), reachable from every supported host. Cross-compiling
> fetches SDK artifacts at action time, so it needs network access. See
> [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for details.

## History and thanks

`ai_rules_dart` started as [aran/rules_dart](https://github.com/aran/rules_dart), written by
[Aran Donohue](https://github.com/aran). He designed this rule set and wrote 329 of its commits: the toolchain,
the pub integration, the analyzer and the compile modes that everything here still builds on. Thank you, Aran. This
project would not exist without your work, and its whole history is kept here with your name on every one of
those commits. Thanks also to [Paul Cody](https://github.com/pcj) for his upstream fix.

From October 15 to October 28, 2026 the rules were developed in the [Mivr/rules_dart](https://github.com/Mivr/rules_dart)
fork. They continue here as a standalone project: every upstream and fork commit, every tag and every release is
in this repository. The fork's closed issues stay where they are. New issues, releases and the BCR module
`ai_rules_dart` live here. Upstream's own rules continue at [aran/rules_dart](https://github.com/aran/rules_dart)
and on the BCR as `rules_dart`. We keep reading upstream and port its ideas with credit to their authors.
