# Architecture

This document states how `rules_flutter` is built. Each claim cites the file
that shows it, with the line where that helps. The tree described is `main` at
the time of writing. Decisions behind these choices are recorded as ADRs in
[`docs/adr/`](adr/). Feature-level detail stays in the documents linked from
[Related documents](#related-documents).

## 1. Module layers

### Public facades: `flutter/*.bzl`

The public surface is the 15 `.bzl` files directly under `flutter/`: `defs.bzl`,
`utils.bzl`, `providers.bzl`, `toolchain.bzl`, `repositories.bzl`,
`extensions.bzl`, `android.bzl`, `ios.bzl`, `macos.bzl`, `web.bzl`, `linux.bzl`,
`windows.bzl`, `native_assets.bzl`, `native_hot_patch.bzl` and `dev_files.bzl`.
Consumers load these files and nothing under `flutter/private/`.

A facade re-exports; it holds little logic. `flutter/defs.bzl:49-91` binds the
private rule implementations to their public names, and `flutter/ios.bzl:68-106`
and `flutter/macos.bzl:66-94` do the same for the platform packaging rules.

### Implementation: `flutter/private/*`

The implementation is the 159 `.bzl` files directly under `flutter/private/`,
plus subdirectories such as `flutter/private/gen_l10n/`. It holds rule
implementations, aspects, repository rules and the helpers they share. The Dart
programs those rules run live under `flutter/private/tools/`, for example
`generate_asset_manifest.dart` and `kernel_filter.dart`.

### Load directions

The rule is that facades load private files, private files load only
`flutter/providers.bzl` from the public layer, and nothing loads a facade except
a facade. In the tree:

- Facade to private: `flutter/defs.bzl:49-59` loads eleven
  `flutter/private/*.bzl` files.
- Facade to facade: `flutter/extensions.bzl:58` loads `:repositories.bzl`.
- Private to `providers.bzl`: `flutter/private/flutter_info.bzl:20`,
  `flutter/private/common.bzl:11` and `flutter/private/asset_keys.bzl:16` load
  `//flutter:providers.bzl`. That file loads nothing itself, so it is a leaf.
- Generated BUILD text: some private files emit
  `load("@rules_flutter//flutter:defs.bzl", ...)` into the repositories they
  create, for example `flutter/private/flutter_sdk_package.bzl:54`. That text is
  written into consumer-side repositories; it is not a load from this tree.

Two real exceptions exist today. Neither is a pattern to copy:

- `flutter/private/flutter_integration_android_app.bzl:7` loads
  `//flutter:android.bzl` for two version constants.
- `flutter/private/flutter_integration_test.bzl:65` loads the same file for the
  same constants.

Outside `flutter/`, this repository has two places that load private files:
`dart/flutter_sdk_binary.bzl:13` loads `//flutter/private:run_home.bzl`, and
`e2e/digest_mismatch/MODULE.bazel:35,52,54` names private repository rules. Both
are inside this repository. Nothing in the tree tells an outside consumer to
load a private file.

### rules_dart boundary

The Dart side comes from `ai_rules_dart` 0.28.0, which this module names
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

`FlutterSdkInfo` is declared at `flutter/providers.bzl:3`. It describes the
Flutter SDK a toolchain supplies: `dart`, `dartaotruntime`, `frontend_server`,
`flutter_tester`, `platform_kernel_dill`, `patched_sdk`, `impellerc` and the
shader library. `flutter/toolchain.bzl:22` builds it in `flutter_toolchain`.

Some fields live on optional sub-toolchains (`gen_snapshot`, `const_finder`,
`font_subset`, `linux_sysroot` and others). Read those through
`resolve_flutter_sdk_info(ctx)` (`flutter/providers.bzl:171`) and declare the
sub-toolchain types it needs; `FLUTTER_OPTIONAL_TOOLCHAINS`
(`flutter/providers.bzl:59`) lists them.

### `FlutterInfo`: what a library contributes

`FlutterInfo` is declared at `flutter/providers.bzl:254`. It carries the Flutter
channels a target contributes to its consumers: `assets`, `shader_srcs`,
`plugins`, the native library channels, `apple_plugin_libraries` and the others
listed in that declaration, and the pub channels `pub_fonts`, `pub_assets` and
`pub_shaders`.

It is built in one place. `flutter/private/flutter_info.bzl:262` defines
`flutter_info()`, and `flutter/private/flutter_info.bzl:319` is the only
`FlutterInfo(` constructor call in the tree. `flutter_info()` takes what the
target contributes and merges every dependency's values. The rules that call it
are `flutter/private/flutter_library.bzl`, `flutter/private/flutter_plugin.bzl`,
`flutter/private/flutter_material_icons.bzl` and
`flutter/private/flutter_pub_scc_target.bzl`. A `deps` entry without
`FlutterInfo` is skipped, not an error (`flutter/private/flutter_info.bzl:278`).

A new Flutter channel is therefore a change to `flutter_info()` and to the
declaration, not to every rule.

### `DartInfo` and `DartAnalyzableInfo`: from rules_dart

`DartInfo` (`ai_rules_dart` `dart/providers.bzl:18`) is the Dart library
contract: sources, package identity, and the transitive closure. A target that
provides it can be a Dart dependency.

`DartAnalyzableInfo` (`dart/providers.bzl:86`) is the analyzer's closure for an
executable. A `flutter_library` also provides one, built by
`flutter_analyzable_info` (`flutter/private/flutter_library.bzl:477`). That
closure adds `package:sky_engine`, because the analyzer resolves `dart:ui` only
through `sky_engine`'s `lib/_embedder.yaml`
(`flutter/private/flutter_library.bzl:471-476`). `DartInfo` itself is left
unchanged there.

### Which provider decides what a `deps` entry may be

`DartInfo` decides. The `deps` attribute of each rule that takes Dart
dependencies is declared with `providers = [DartInfo]`:
`flutter/private/flutter_library.bzl:645`,
`flutter/private/flutter_kernel_target.bzl:31` and
`flutter/private/common.bzl:2215-2217` (the application rule's `deps`).
`FlutterInfo` is optional on each of those entries and contributes only when
present. A target that provides only `FlutterInfo` is refused by Bazel as a
`deps` entry.

## 3. Assets, fonts and shaders

### Where each is declared

- Assets: the `assets` attribute of `flutter_library`
  (`flutter/private/flutter_library.bzl`), which fills `FlutterInfo.assets`. Pub
  packages declare theirs under `flutter.assets` in `pubspec.yaml`.
  `flutter/private/flutter_pubspec.bzl` reads that block, and the generated
  spoke passes the entries to `flutter_library` as `pkg_assets`, which fills
  `FlutterInfo.pub_assets`.
- Fonts: `flutter_font_family` (`flutter/defs.bzl:83`, defined in
  `flutter/private/flutter_font_family.bzl`). Pub packages declare theirs under
  `flutter.fonts`, and their contributions reach `FlutterInfo.pub_fonts`.
- Shaders: the `shaders`, `shader_includes` and `require_sksl_shaders`
  attributes of the application rule (`FLUTTER_APPLICATION_ATTRS`,
  `flutter/private/common.bzl:2214` and `:2252-2262`). Pub packages declare
  theirs under `flutter.shaders`; they reach `FlutterInfo.pub_shaders` as
  `pkg_shaders`.
- Bundling: `flutter_asset_bundle` (`flutter/defs.bzl:82`, implemented in
  `flutter/private/flutter_asset_bundle.bzl`).

### How asset keys and URIs are formed

A key is the bundle-relative name the engine asks for.
`flutter/private/asset_keys.bzl` forms it once, in the target that lists the
asset. An app asset is keyed by its path relative to the listing target's
package directory. A dependency package's asset is keyed
`packages/<package>/<path>` (`flutter/private/asset_keys.bzl:1-14`). The key
then travels with the file in `FlutterInfo.assets`, so no later step computes it
again.

`flutter/private/asset_uri.bzl` normalizes each entry the way flutter_tools
reads it. `normalize_asset_uri` (`flutter/private/asset_uri.bzl:337`) decodes
percent-escapes and resolves dot segments; `encode_asset_key`
(`flutter/private/asset_uri.bzl:424`) writes the spelling the engine requests.
The module's header (`flutter/private/asset_uri.bzl:1-25`) names the
flutter_tools version it mirrors.

A key collision fails. `fail_asset_key_conflict`
(`flutter/private/asset_keys.bzl:145`) reports two files that claim one key.

### How shaders and their includes are compiled

Shaders compile through `impellerc`. `SHADER_PLATFORM_FLAGS`
(`flutter/private/flutter_shader_compile.bzl:16`) gives each target platform its
runtime stages. The `tester` entry, used by `flutter test`, selects `--sksl` and
`--runtime-stage-vulkan`.

Which compile runs depends on the consumer:

- A test compiles its shaders for `tester`. `flutter_tester_shader_aspect`
  (`flutter/private/common.bzl:2181`) compiles the transitive shaders, and
  `flutter_test` uses them (`flutter/private/flutter_test.bzl:480`).
- An app compiles them for its own platform through the app aspect
  (`flutter/private/common.bzl:2164`). Web has its own aspect at `:2161`.
- `flutter_compile_shaders` (`flutter/private/common.bzl:1229`) compiles any
  shader that dependencies do not already supply.

A shader sees only the `shader_includes` it declares, because each compile runs
in a sandbox that holds only its declared inputs
(`flutter/private/common.bzl:2256-2260`). Two shaders that claim one bundle path
fail (`flutter/private/common.bzl:1118-1135`, the `_shader_jobs` docstring).

### Bundle assembly and `NOTICES.Z`

Tests and apps use one bundle step. `flutter_build_assets`
(`flutter/private/common.bzl:1504`) is called from `flutter_application`
(`flutter/private/flutter_application.bzl:491`), `flutter_test`
(`flutter/private/flutter_test.bzl:290`), the web application and the
integration test rule. Each passes a `make_bundle_inputs` value
(`flutter/private/common.bzl:1417`).

The bundle action is `flutter_asset_bundle_action`
(`flutter/private/flutter_asset_bundle_action.bzl:309`). It runs the Dart tool
`//flutter/private/tools:generate_asset_manifest`
(`flutter/private/flutter_asset_bundle.bzl:27`). That tool writes
`AssetManifest.bin` and `FontManifest.json`
(`flutter/private/tools/generate_asset_manifest.dart:296-299`).

`NOTICES.Z` is written by `_writeNotices`
(`flutter/private/tools/generate_asset_manifest.dart:480-497`). It concatenates
the inline `notices` text and then each existing `license_files` entry, joined
by `---`, and gzips the result. The `license_files` attribute is declared at
`flutter/private/common.bzl:2294` and
`flutter/private/flutter_asset_bundle.bzl:115`.

## 4. Kernel compilation and platform packaging

### Two kernel paths

A test closure and an application compile differently. Both go through the same
`frontend_server` but make different choices about what to compile separately.

**Test closures.** `flutter_test` (`flutter/private/flutter_test.bzl:590`) calls
`_flutter_test_kernel` (`flutter/private/flutter_test.bzl:209`). Each `DartInfo`
dependency is compiled once into a `<name>.flutter.kmod` directory by
`flutter_kernel_module_aspect`, and the entry module links them with
`DartKernelLink` (`flutter/private/flutter_kernel_module.bzl:1-14`). The closure
is modular only when `flutter_modular_test_tools`
(`flutter/private/flutter_kernel_module.bzl:1093`) returns tools: the mode is
enabled, every dependency is modular, the packages are consistent, the target
has no code assets or own defines, no source is duplicated, and the SDK is the
same (`flutter/private/flutter_kernel_module.bzl:1135-1147`). Otherwise
`flutter_test` falls back to one whole-program compile of its sources
(`flutter/private/flutter_test.bzl:209-240`).

**Applications.** `flutter_application`
(`flutter/private/flutter_application.bzl:113-115`), the standalone
`flutter_kernel_target` (`flutter/private/flutter_kernel_target.bzl:13`) and
`flutter_aot_target` (`flutter/private/flutter_aot_target.bzl:44`) all call
`flutter_compile_kernel` (`flutter/private/common.bzl:979`). It chooses the path
in `_run_kernel_compile` (`flutter/private/common.bzl:971`). The modular path is
taken only for a non-AOT, non-profile compile of the `flutter` frontend target
with no registrant, agent, native-assets manifest, recorded uses, extra frontend
flags, defines or define flagfiles (`flutter/private/common.bzl:892-900`), and
only when modular tools exist. Every other build, including AOT and profile,
takes the whole-program `flutter_kernel_compile_action`
(`flutter/private/flutter_compile.bzl:602`). An opt-in incremental worker
applies to JIT whole-program compiles only
(`flutter/private/flutter_compile.bzl:199-214`, and
[`docs/incremental-kernel.md`](incremental-kernel.md)).

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
- Web: `flutter_web_bundle` (`flutter/private/flutter_web_application.bzl:1578`)
  does not read `FlutterApplicationInfo`. See the note above.

Each platform's `*_registrant` rule generates the plugin registrant for its
platform. Platform rules add the host packaging: manifest merging
(`flutter/private/flutter_android_manifest_merge.bzl`), plist merging
(`flutter/private/flutter_plist_merge.bzl`), and the runner libraries
(`flutter_linux_runner_lib`, `flutter_windows_runner_lib`).

### What stays in `flutter_library` and what moves to the application

`flutter_library` collects. Its doc says it "collects Flutter sources and
assets, propagates DartInfo and FlutterInfo. Does not compile."
(`flutter/private/flutter_library.bzl:720`). It owns the sources, the `deps`,
the asset, font and shader declarations, and the providers.

The application rule compiles. It owns the kernel, the AOT step, the
native-assets manifest, the asset bundle and the plugin registrant wiring.
Nothing in `flutter_library` compiles a kernel.

The platform rule packages. It owns the host bundle layout and the manifests and
runner that the host requires.

## 5. Toolchain layout

### The rule set's own dependency

The Dart toolchain comes from `ai_rules_dart` 0.28.0 (`MODULE.bazel:129`).
`flutter/private/rules_dart_floor.bzl` refuses an older resolved release, and
the floor is `RULES_DART_FLOOR` in that file.

### The Flutter SDK is a pinned, versioned download

Each supported release is listed in `flutter/private/versions.bzl`.
`FLUTTER_VERSIONS` (`flutter/private/versions.bzl:48`) maps a tag to its engine
revision and source-tarball digest. `ARTIFACT_CHECKSUMS`
(`flutter/private/versions.bzl:282`) maps each engine artifact to its sha256.
`flutter_source_sha256` and `flutter_artifact_sha256`
(`flutter/private/versions.bzl:107` and `:144`) read them, and fail when an
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
own Dart tools use it, for example `flutter/private/flutter_shader_compile.bzl`.
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
   sources (`flutter/private/flutter_kernel_module.bzl:1333`). Two assets with
   one key fail (`flutter/private/asset_keys.bzl:145`). Two shaders with one
   bundle path fail (`flutter/private/common.bzl:1118-1135`).
3. **No target cycle in a plugin graph.** Pub packages that depend on each other
   are merged into one strongly connected component repository
   (`flutter/private/flutter_pub_scc_target.bzl:1-10`, planned by
   `plan_flutter_pub_sccs` at `flutter/private/flutter_pub_scc.bzl:315`). The
   `cycle_breaks` argument removes a named spoke-to-spoke edge; it is checked
   against the lock and the pubspec
   (`flutter/private/flutter_pub_cycle_breaks.bzl:1-12`,
   `flutter/private/flutter_pub_package.bzl:1483-1485`).
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

- [`incremental-kernel.md`](incremental-kernel.md): the opt-in incremental
  worker for JIT compiles.
- [`pub-assets.md`](pub-assets.md): how a pub package's `flutter.assets` become
  bundle keys.
- [`dependencies.md`](dependencies.md): dependency floors and the Maven lock
  file.
- [`flutter-sdk-versions.md`](flutter-sdk-versions.md): SDK pins, version
  selection and `local_path`.
- [`TESTING.md`](TESTING.md): how to test a change.
- [`adr/`](adr/): the accepted decisions this document rests on.
