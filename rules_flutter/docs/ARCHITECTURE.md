# Architecture

This document states how `rules_flutter` is built. Each claim cites the file
that shows it, with the line where that helps. The tree described is `main` at
the time of writing. Decisions behind these choices are recorded as ADRs in
[`docs/adr/`](adr/). Feature-level detail stays in the documents linked from
[Related documents](#related-documents).

## 1. Module layers

### Public facades: `flutter/*.bzl`

The public surface is the 14 `.bzl` files directly under `flutter/`: `defs.bzl`,
`utils.bzl`, `providers.bzl`, `toolchain.bzl`, `repositories.bzl`,
`extensions.bzl`, `android.bzl`, `ios.bzl`, `macos.bzl`, `web.bzl`, `linux.bzl`,
`windows.bzl`, `native_assets.bzl` and `dev_files.bzl`.
Consumers load these files and nothing under `flutter/private/`.

A facade re-exports; it holds little logic. `flutter/defs.bzl:50-126` binds the
private rule implementations to their public names, and `flutter/ios.bzl:68-106`
and `flutter/macos.bzl:66-94` do the same for the platform packaging rules.

### Implementation: `flutter/private/*`

The implementation is the 183 `.bzl` files directly under `flutter/private/`,
plus subdirectories such as `flutter/private/android_model/`. It holds rule
implementations, aspects, repository rules and the helpers they share. The Dart
programs those rules run live under `flutter/private/tools/`, for example
`kernel_filter.dart` and `merge_plists.dart`. The asset tool lives apart, in
`flutter/private/assets_tool/`, because it is compiled against the Flutter
release's own `package:flutter_tools` (section 3).

### Load directions

The rule is that facades load private files, private files load only
`flutter/providers.bzl` from the public layer, and nothing loads a facade except
a facade. In the tree:

- Facade to private: `flutter/defs.bzl:50-61` loads twelve
  `flutter/private/*.bzl` files.
- Facade to facade: `flutter/extensions.bzl:58` loads `:repositories.bzl`.
- Private to `providers.bzl`: `flutter/private/flutter_info.bzl:22` and
  `flutter/private/common.bzl:11` load `//flutter:providers.bzl`. That file
  loads nothing itself, so it is a leaf.
- Generated BUILD text: some private files emit
  `load("@rules_flutter//flutter:defs.bzl", ...)` into the repositories they
  create, for example `flutter/private/flutter_sdk_package.bzl:54`. That text is
  written into consumer-side repositories; it is not a load from this tree.

No private file loads a public entry point today.

Outside `flutter/`, this repository has two places that load private files:
`dart/flutter_sdk_binary.bzl:13` loads `//flutter/private:run_home.bzl`, and
`e2e/digest_mismatch/MODULE.bazel:35,52,54` names private repository rules. Both
are inside this repository. Nothing in the tree tells an outside consumer to
load a private file.

### rules_dart boundary

The Dart side comes from `ai_rules_dart` 0.31.0, which this module names
`rules_dart` (`MODULE.bazel:129`). `flutter/private/flutter_library.bzl:3-4`
loads `DartInfo`, `DartCodeAssetInfo` and the constructors `dart_info`,
`dart_package_identity`, `dart_analyzable_info_with_package` and friends from
`@rules_dart`. The rules call those constructors; no rules_flutter file builds a
`DartInfo` record by hand. The one direct `DartInfo(` call in the tree is a test
fixture, `flutter/tests/native_assets_test.bzl:416`.

rules_flutter reads `DartInfo` and does not change its fields. Flutter-specific
data goes in `FlutterInfo`, a separate provider that sits beside `DartInfo` on
the same target (section 2). The other Flutter provider that targets carry,
`FlutterKernelModuleInfo`, holds compile output for a `DartInfo` target
(`flutter/private/flutter_kernel_module.bzl:51-57`). Neither restates a
library's package identity or its sources.

### Layering check

rules_dart's strict-layering check refuses a source that imports a package none
of its direct `deps` provides. rules_flutter runs it on its program rules
through one private helper, `flutter/private/layering_check.bzl`, which is the
only Flutter file that loads `@rules_dart//dart:import_check.bzl` (a guard test
holds that line). The helper exposes the aspect for the rule's `deps`, the
attribute dict, the toolchain list and `layering_check()`, which runs the check
for a rule context and its own package record and returns the stamps for the
`_validation` output group. Building the target runs the checks of its own
sources and of every first-party library below it. The generated bootstrap is
not checked. An integration test resolves its entry from `main` or a single
`srcs` file, while rules_dart's executable check reads `ctx.file.main`, so
`layering_check_entry()` runs it over a stand-in context that names the
resolved entry. `flutter_drive_test` with a `.dart` driver is checked the same
way, with no package of its own; an executable driver adds nothing.

The check is on by default and the feature `dart_layering_check` turns it off
per package or per build, as in rules_dart. No attribute is added.

`dart:mirrors` is refused in every Flutter program and in every library below it, every other `dart:` library passes, and a library named in `--@rules_dart//dart:refused_dart_libraries` is refused in addition to it.

Checked rules: `flutter_test`, `flutter_application` (under the android, ios,
linux, macos and windows macros) and `flutter_web_bundle` (under
`flutter_web_app`), the web, Linux, Android and iOS `flutter_integration_test`
(its entry, `srcs` and `app_srcs` against the direct `deps`, with `package_name`
counting as provided) and `flutter_drive_test`. Each returns the check beside its other `_validation`
entries (an application keeps its link-hook verdicts). Every Flutter program
rule is checked but one target, the `flutter_application` that the iOS `flutter_integration_test` builds for
its generated bootstrap, which imports packages by design: it is built with the
feature off. The Android helper app is not checked either. A rule that joins the list adopts the helper and is added here.

## 2. Provider contracts

### `FlutterSdkInfo`: the toolchain's engine and tools

`FlutterSdkInfo` is declared at `flutter/providers.bzl:5`. It describes the
Flutter SDK a toolchain supplies: `dart`, `dartaotruntime`, `frontend_server`,
`flutter_tester`, `platform_kernel_dill`, `patched_sdk`, `impellerc`, the
shader library and `assets_tool`, the asset tool (section 3).
`flutter/toolchain.bzl:52` builds it in `flutter_toolchain`.

Some fields live on optional sub-toolchains (`gen_snapshot`,
`font_subset`, `linux_sysroot` and others). Read those through
`resolve_flutter_sdk_info(ctx)` (`flutter/providers.bzl:180`) and declare the
sub-toolchain types it needs; `FLUTTER_OPTIONAL_TOOLCHAINS`
(`flutter/providers.bzl:63`) lists them.

### `FlutterInfo`: what a library contributes

`FlutterInfo` is declared at `flutter/providers.bzl:270`. It carries the Flutter
channels a target contributes to its consumers: `plugins`, the native library
channels, `apple_plugin_libraries`, `data_assets` and the
others listed in that declaration. It carries no assets, fonts or shaders: a
package's own files travel in its `data` (section 3).

It is built in one place. `flutter/private/flutter_info.bzl:296` defines
`flutter_info()`, and `flutter/private/flutter_info.bzl:358` is the only
`FlutterInfo(` constructor call in the tree. `flutter_info()` takes what the
target contributes and merges every dependency's values. The rules that call it
are `flutter/private/flutter_library.bzl`, `flutter/private/flutter_plugin.bzl`
and `flutter/private/flutter_pub_scc_target.bzl`. A `deps` entry without
`FlutterInfo` is skipped, not an error (`flutter/private/flutter_info.bzl:342`).

A new Flutter channel is therefore a change to `flutter_info()` and to the
declaration, not to every rule.

### `DartInfo` and `DartAnalyzableInfo`: from rules_dart

`DartInfo` (`ai_rules_dart` `dart/providers.bzl:18`) is the Dart library
contract: sources, package identity, and the transitive closure. A target that
provides it can be a Dart dependency.

`DartAnalyzableInfo` (`dart/providers.bzl:86`) is the analyzer's closure for an
executable. A `flutter_library` also provides one, built by
`flutter_analyzable_info` (`flutter/private/flutter_library.bzl:18`). That
closure adds `package:sky_engine`, because the analyzer resolves `dart:ui` only
through `sky_engine`'s `lib/_embedder.yaml`
(`flutter/private/flutter_library.bzl:10-11`). `DartInfo` itself is left
unchanged there.

### Which provider decides what a `deps` entry may be

`DartInfo` decides. The `deps` attribute of each rule that takes Dart
dependencies is declared with `providers = [DartInfo]`:
`flutter/private/flutter_library.bzl:115`,
`flutter/private/flutter_kernel_target.bzl:31` and
`flutter/private/common.bzl:1178-1181` (the application rule's `deps`).
`FlutterInfo` is optional on each of those entries and contributes only when
present. A target that provides only `FlutterInfo` is refused by Bazel as a
`deps` entry.

## 3. Assets, fonts and shaders

rules_flutter keeps no model of Flutter's asset handling. The Flutter tool's
own code writes every bundle, and the app's `pubspec.yaml` says what it holds,
as it does for `flutter build`. [`assets.md`](assets.md) is the user's view.

### The asset tool

`flutter/private/assets_tool/flutter_assets_tool.dart` is a small program that
builds the objects `package:flutter_tools` expects (a Flutter root, a project
directory with its package config, an `Environment`) out of the files the
action declares, and calls the tool's own asset, licence, web bootstrap and
gen-l10n code. It copies none of that logic.

It is built per Flutter release. `flutter/private/flutter_assets_tool_repo.bzl`
stages `packages/flutter_tools/lib/` of the release's source, the framework's
shaders, and the hosted packages the tool imports, each pinned in
`flutter/private/flutter_assets_tool_versions.bzl`. `flutter_assets_tool`
(`flutter/private/flutter_assets_tool.bzl:203`) compiles it with the Dart SDK
bundled in that release, and the toolchain carries it as
`FlutterSdkInfo.assets_tool`.

### Where each is declared

- The app: its `pubspec.yaml` (`pubspec`) names its assets, fonts, shaders,
  flavors, transformers, deferred components and licences, and
  `pubspec_srcs` lists the files it names. Every bundling rule takes these
  through `BUNDLE_ATTRS` (`flutter/private/flutter_bundle.bzl:28-66`), with
  `pub_packages`, `asset_transformers`, `build_name` and `build_number`.
- A package: its `data` (`flutter/private/flutter_library.bzl:119`,
  `flutter/private/flutter_plugin.bzl:433`) holds its `pubspec.yaml`, its
  licence and the files its pubspec names. A pub spoke writes that list from
  the package's pubspec (`spoke_data_patterns`,
  `flutter/private/flutter_pub_package_helpers.bzl:25`).

### One action per bundle

`flutter_bundle` (`flutter/private/flutter_bundle.bzl:205`) runs the tool once
for an app's `flutter_assets/`. It is called from `flutter_application`
(`flutter/private/flutter_application.bzl:621`), `flutter_test`
(`flutter/private/flutter_test.bzl:291`) and the integration test rules
(`flutter/private/flutter_integration_test_common.bzl:464`). Web uses
`flutter_web_bundle` (`flutter/private/flutter_bundle.bzl:267`), called from
`flutter/private/flutter_web_application.bzl:473` and
`flutter/private/flutter_integration_test_web.bzl:377`; it also writes the web
app around the compiled program from the project's `web/` directory.

The tool forms every key, compiles shaders with the release's `impellerc`, and
writes `AssetManifest.bin`, `FontManifest.json` and `NOTICES.Z` as
`flutter build` does. A file the pubspec names that is not an input fails the
action, naming it. A debug build does not read what the compilers record, so a
Dart edit does not rerun the action; release and profile read the uses the AOT
compile (`--recorded-uses`) or dart2js and dart2wasm record, to shake icon
fonts (`_icon_tree_shaking`, `flutter/private/flutter_bundle.bzl`), as the
release's own icon tree shaker does.

## 4. Kernel compilation and platform packaging

### Two kernel paths

A test closure and an application compile differently. Both go through the same
`frontend_server` but make different choices about what to compile separately.

**Test closures.** `flutter_test` (`flutter/private/flutter_test.bzl:590`) calls
`_flutter_test_kernel` (`flutter/private/flutter_test.bzl:209`). Each `DartInfo`
dependency is compiled once into a `<name>.flutter.kmod` directory by
`flutter_kernel_module_aspect`, and the entry module links them with
`DartKernelLink` (`flutter/private/flutter_kernel_module.bzl:1-14`). The closure
is the only way to build a test's kernel: `flutter_module_tools`
(`flutter/private/flutter_kernel_module.bzl`) fails at analysis, naming each
reason, when a dependency has no module, the packages are inconsistent, a
source is duplicated, or the Flutter toolchain's Dart SDK has no module
compiler. The test's own `defines` are the configuration of its `deps`
(`flutter/private/flutter_defines_files.bzl`), and its native assets ride the
entry module's native-assets mapping.

**Applications.** `flutter_application`
(`flutter/private/flutter_application.bzl:113-115`), the standalone
`flutter_kernel_target` (`flutter/private/flutter_kernel_target.bzl:13`) and
`flutter_aot_target` (`flutter/private/flutter_aot_target.bzl:44`) all call
`flutter_compile_kernel` (`flutter/private/common.bzl:979`). A debug (JIT)
kernel is always the entry module linked with the closure's modules
(`_run_kernel_compile` in `flutter/private/common.bzl`): defines, the flavor
and `dart_defines` are the configuration of the `deps`, the native-assets
manifest rides the entry module, `--track-widget-creation` is a module
configuration, and the staged agent, native agent and registrant compile into
the entry under constant URIs with the closure's registrant twin of the SDK
`flutter` module. A debug program whose shape cannot be modular fails at
analysis, naming the target and the reason (another front-end flag, a
registrant with no twin, a dependency without a module). AOT, profile and
release take the whole-program `flutter_kernel_compile_action`
(`flutter/private/flutter_compile.bzl`), behind the `kernel_filter` read
guard; so do the integration-test apps and a custom rule that calls it.

A custom kernel built from `flutter_modular_test_kernel` or
`flutter_modular_app_kernel` (`flutter/utils.bzl:198` and
`flutter/utils.bzl:276`) has no whole-program fallback. It fails when a define,
a native asset or an ineligible closure would need one
(`flutter/private/flutter_kernel_module.bzl:1302-1333`).

Web does not use this kernel. `flutter_web_bundle` compiles Dart source directly
with dart2wasm and dart2js (`flutter/private/flutter_web_application.bzl:1-16`,
`flutter/private/flutter_web_compile.bzl:1-8`).

### Per-platform packaging

`flutter_application` (`flutter/private/flutter_application.bzl:555`) is the one
application rule. It outputs the kernel or AOT output, the `flutter_assets` tree
and the ICU data (`flutter/private/flutter_application.bzl:1-14`). It returns
them as a `FlutterApplicationInfo` (`flutter/providers.bzl:345`), built in
`_application_providers` (`flutter/private/flutter_application.bzl:392`).
Platform rules read that provider through an `application` attribute, which
accepts only targets that provide `FlutterApplicationInfo`:

- Android: `flutter_android_bundle`
  (`flutter/private/flutter_android_application.bzl:339`; the read is at
  `:262`).
- iOS: `flutter_ios_application`
  (`flutter/private/flutter_ios_application.bzl:52`), with the framework,
  native-frameworks and privacy-manifest rules beside it.
- macOS: `flutter_macos_framework`
  (`flutter/private/flutter_macos_application.bzl:275`).
- Linux: `flutter_linux_bundle_rule`
  (`flutter/private/flutter_linux_application.bzl:548`).
- Windows: `flutter_windows_runner_lib`
  (`flutter/private/flutter_windows_application.bzl:267`) takes an optional
  `application` (`:287`). When set, it compiles the transitive plugins' Windows
  C++ sources into the runner. The bundle rule is `flutter_windows_bundle_rule`
  (`flutter/private/flutter_windows_application.bzl:425`).
- Web: `flutter_web_bundle` (`flutter/private/flutter_web_application.bzl:932`)
  does not read `FlutterApplicationInfo`. See the note above.

Each platform's `*_registrant` rule generates the plugin registrant for its
platform (Android's is the Flutter tool's own, carried by the app's pinned
Gradle model). Platform rules add the host packaging: plist merging
(`flutter/private/flutter_plist_merge.bzl`), and the runner libraries
(`flutter_linux_runner_lib`, `flutter_windows_runner_lib`).

### What stays in `flutter_library` and what moves to the application

`flutter_library` collects. Its doc says it "Collects Flutter sources and the
package's own files, propagates DartInfo and FlutterInfo. Does not compile."
(`flutter/private/flutter_library.bzl:162`). It owns the sources, the `deps`,
the package's own files (`data`), and the providers.

The application rule compiles. It owns the kernel, the AOT step, the
native-assets manifest, the asset bundle and the plugin registrant wiring.
Nothing in `flutter_library` compiles a kernel.

The platform rule packages. It owns the host bundle layout and the manifests and
runner that the host requires.

## 5. Toolchain layout

### The rule set's own dependency

The Dart toolchain comes from `ai_rules_dart`, the sibling `rules_dart`
module in the same repository, which `MODULE.bazel` takes through a
`local_path_override`. Both modules come from one commit, so there is no
separate floor check.

### The Flutter SDK is a pinned, versioned download

Each supported release is listed in `flutter/private/versions.bzl`.
`FLUTTER_VERSIONS` (`flutter/private/versions.bzl:50`) maps a tag to its engine
revision and source-tarball digest. `ARTIFACT_CHECKSUMS`
(`flutter/private/versions.bzl:231`) maps each engine artifact to its sha256.
`flutter_source_sha256` and `flutter_artifact_sha256`
(`flutter/private/versions.bzl:60` and `:93`) read them, and fail when an
entry is missing.

The `flutter` module extension (`flutter/extensions.bzl`) declares the
toolchain. A `flutter.toolchain` tag takes `flutter_version` or `local_path`,
and exactly one of them (`flutter/extensions.bzl:298-300`). Version choice is
made by `select_toolchain_version` in `flutter/private/toolchain_selection.bzl`.
`docs/flutter-sdk-versions.md` covers the rules in detail.

### The one local-SDK exception

A root module may set `local_path` instead of `flutter_version`. The path names
a pre-extracted SDK on disk, and the repository rules read from it and never
download (`flutter/private/local_sdk.bzl:1-16`). The root module's choice
overrides non-root version requests, and a non-root module may not set
`local_path` (`flutter/private/toolchain_selection.bzl:177-185`,
`flutter/extensions.bzl:295-296`).

No `.bzl` file under `flutter/` reads `PATH` or `FLUTTER_ROOT` from the
environment, so no SDK is found on the host by search. The only host SDK is the
explicit `local_path` above.

### Every download is pinned

Every fetch in `flutter/**` goes through `pinned_download` or
`pinned_download_and_extract` (`flutter/private/download.bzl:50-92`). Each
refuses a digest that is not 64 lowercase hex characters, and refuses a digest
smuggled in as `integrity`. A grep of `flutter/` finds no raw `ctx.download` or
`download_and_extract` call outside that file.

Pub hosted packages carry the sha256 recorded in `pubspec.lock`
(`flutter/private/pub_lock_sdks.bzl:122`, `hosted_package_sha256`).

### How the Dart toolchain is taken

rules_flutter takes the host `dart` from rules_dart's exec-tools toolchain,
`@rules_dart//dart:exec_tools_toolchain_type`. `resolve_exec_dart`
(`flutter/providers.bzl:199`) reads it, and fails rather than fall back to the
SDK's `dart` (`flutter/providers.bzl:199-213`). Rules that run rules_flutter's
own Dart tools use it, for example `flutter/private/flutter_sdk_binary.bzl`.
`resolve_exec_dart_vm` (`flutter/providers.bzl:226`) returns that same
toolchain's `dart` and runtime files, for running a `.dill` tool on the exec
platform. It also never falls back to the SDK.

## 6. Build-graph invariants

A change must keep these true. Each names where the code holds it.

1. **One `rootUri` per package name.** `dart_info_multi` in rules_dart refuses
   two records that name one package, and says "one package name resolves to one
   `lib/` root" (`ai_rules_dart` `dart/private/dart_info.bzl:334-337`). An
   application drops transitive entries that would collide with its own root
   (`flutter/private/app_entrypoint.bzl:326-340`).
2. **No source owned by two targets.** A modular kernel fails on duplicate
   sources (`flutter/private/flutter_kernel_module.bzl:1333`). Asset and
   shader keys are formed only by the Flutter tool (section 3), so no two
   rules can disagree on one.
3. **No target cycle in a plugin graph.** Pub packages that depend on each other
   are merged into one strongly connected component repository
   (`flutter/private/flutter_pub_scc_target.bzl:1-10`, planned by rules_dart's
   `plan_scope_sccs` from `_plan_hub_graph` at `flutter/extensions.bzl:695`).
   The `cycle_breaks` argument removes a named spoke-to-spoke edge; it is
   checked against the lock and the planned dependency names at evaluation
   (`flutter/private/flutter_pub_cycle_breaks.bzl:1-15`), and each spoke checks
   its planned names against the fetched pubspec
   (`flutter/private/flutter_pub_package.bzl:1475`).
4. **No load of a private file from outside this repository.** Consumers load
   the facades in section 1. Section 1 lists the in-repository exceptions.
5. **No unpinned download.** Section 5 covers the Flutter SDK, engine artifacts,
   and pub packages. The Maven gap below is the one known exception.

## 7. Known gaps

These are true of the tree and are not yet fixed. Do not describe them as done.

- **Android Maven pins.** The rule set's own `maven.install` at
  `MODULE.bazel:340-373` names no `lock_file`, so its artifacts are not
  checksum-locked by this repository. `docs/dependencies.md:243-245` explains
  why the lock belongs at the consumer's root module. The defect has its own
  work item.
- **Private loads from facades.** The two exceptions in section 1 remain.

## Related documents

- [`assets.md`](assets.md): the asset bundle, written by the Flutter tool's
  own code from the pubspec, and the migration from the attribute-based rules.
- [`dependencies.md`](dependencies.md): dependency floors and the Maven lock
  file.
- [`flutter-sdk-versions.md`](flutter-sdk-versions.md): SDK pins, version
  selection and `local_path`.
- [`TESTING.md`](TESTING.md): how to test a change.
- [`adr/`](adr/): the accepted decisions this document rests on.
