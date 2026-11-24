# Dependencies

Which Bazel modules `rules_flutter` pulls into a consumer's graph, for which
feature, and what each costs. Every regular `bazel_dep` in `MODULE.bazel`
declares the minimum this repository supports, not the release its own CI
happens to compile; a comment beside each declaration names the symbol,
package or attribute that sets that minimum. Bzlmod's Minimal Version Selection
(MVS) then picks the highest version anywhere in the graph, so the values in
the table below are floors a consumer can keep, not pins that force it
forward.

## Declared floors

| Module | Minimum | The symbol, package or attribute that sets it |
|---|---|---|
| `bazel_skylib` | 1.8.0 | `@bazel_skylib//:bzl_library.bzl`, `//rules:build_test.bzl`, `//rules:common_settings.bzl`, `//rules:expand_template.bzl`, `//rules:write_file.bzl` and `//lib:unittest.bzl`, loaded by our rules, tests and `ai_rules_dart`'s BUILD files. |
| `package_metadata` | 0.0.5 | `@package_metadata//licenses/rules:license.bzl`, `@package_metadata//purl:purl.bzl` (`purl.bazel()`) and `@package_metadata//rules:package_metadata.bzl`, loaded by this module's root BUILD and by `ai_rules_dart`. |
| `platforms` | 1.1.0 | `@platforms//:incompatible`, `@platforms//os:{android,ios,linux,macos,windows}` and `@platforms//cpu:{aarch64,arm64,x86_64}`, used by our platform definitions and `target_compatible_with` constraints. |
| `rules_cc` | 0.2.20 | The opt-in native-asset C++ path: `@rules_cc//cc:cc_shared_library.bzl`, `@rules_cc//cc:objc_library.bzl`, `@rules_cc//cc/common:cc_shared_library_info.bzl` and `@rules_cc//cc:find_cc_toolchain.bzl`. |
| `apple_support` | 2.2.0 | `@apple_support//constraints:{device,simulator}`, `@apple_support//platforms:ios_arm64` and the `@apple_support//crosstool:setup.bzl` `apple_cc_configure_extension` that `MODULE.bazel` joins. |
| `rules_apple` | 4.5.3 | `@rules_apple//apple:ios.bzl`, `@rules_apple//apple:macos.bzl`, `@rules_apple//apple:versioning.bzl`, the framework/app-intent imports and the internal `AppleBundleInfo` constructor. |
| `rules_swift` | 3.5.0 | `@rules_swift//swift:swift.bzl` (`swift_library`) and the `SwiftInfo`/`swift_interop_info` surface, at `compatibility_level = 3`. |
| `rules_kotlin` | 2.3.0 | `@rules_kotlin//kotlin:jvm.bzl` (`kt_jvm_library`) and `//kotlin:core.bzl` (`define_kt_toolchain`, `kt_kotlinc_options`, `kt_ksp_plugin`), which compile an app's and its plugins' Kotlin from the pinned Gradle model. A Flutter 3.47 app resolves the Kotlin 2.4.0 standard library; the compiler of `rules_kotlin` 2.2 and older refuses its metadata. |
| `rules_java` | 9.0.0 | `@rules_java//java:defs.bzl` (`java_binary`, `java_import`, `java_library`, `java_plugin`, `java_test`), `@rules_java//java/common:java_info.bzl` (`JavaInfo`) and the Java toolchain rules. |
| `ai_rules_dart` (repo `rules_dart`) | 0.28.3 | `@rules_dart//dart:defs.bzl`, `@rules_dart//dart:utils.bzl`, `@rules_dart//dart/pub:pub_scc.bzl` and `@rules_dart//dart/pub:yaml.bzl` (`yaml_to_json`), and `dart_analysis_config(baseline = ...)`. The floor is the first `rules_dart` release cut from this repository that has every one of them; this repository's own builds take the sibling `rules_dart/` directory, whatever the number says. No release has `yaml.bzl` yet, so 0.28.3 is a placeholder until one is cut (a BCR entry is pending too). |
| `llvm` | 0.8.17 | `@llvm//extensions:llvm_toolchain_minimal.bzl` and the `llvm-toolchain-minimal-<os>-<cpu>` repos, on the opt-in xtool Darwin SDK path and for this repository's own hermetic tests. |

`dev_dependency` declarations (`rules_multitool`, `buildifier_prebuilt`,
`bazelrc-preset.bzl`) never reach a consumer and carry no floor.

## Transitive MVS lifts

A floor is what `rules_flutter` itself declares. When a dependency requires a
higher version of one of our other dependencies, MVS selects that higher
version; that is the dependency's requirement, not a bump caused by our
declaration. These are the lifts in a consumer graph that has no other
requirements:

| Lifted module | Our floor | Resolved | Lifted by | Because |
|---|---|---|---|---|
| `bazel_skylib` | 1.8.0 | 1.9.2 | `ai_rules_dart` | Its own `bazel_dep` asks for 1.9.2. `llvm` 0.8.17 asks for 1.9.0, which is lower. |
| `package_metadata` | 0.0.5 | 0.0.13 | `ai_rules_dart` | Its own `bazel_dep` asks for 0.0.13. |
| `rules_cc` | 0.2.20 | 0.2.26 | `ai_rules_dart` | Its own `bazel_dep` asks for 0.2.26. `llvm` 0.8.17 asks for 0.2.22, which is lower. |
| `apple_support` | 2.2.0 | 2.9.1 | `rules_cc` 0.2.26 | `rules_cc` 0.2.25 and newer add a regular `bazel_dep` on `apple_support`; 0.2.26 asks for 2.9.1. `rules_cc` reaches that version through `ai_rules_dart`. |
| `rules_java` | 9.0.0 | 9.3.0 | `rules_kotlin` 2.3.0 | Its dependency `rules_android` 0.7.1 asks for 9.3.0 (`rules_kotlin` itself asks for 8.9.0). |

Every other floor resolves at its declared version in that graph: `platforms`
1.1.0, `rules_apple` 4.5.3, `rules_swift` 3.5.0, `rules_kotlin` 2.3.0 and
`llvm` 0.8.17. (`rules_flutter` no longer declares `rules_android`,
`rules_jvm_external` or `rules_go`: an app's Android side is built by AGP's own
tools from the pinned Gradle model. `rules_kotlin` still brings `rules_android`
and `rules_jvm_external` into the module graph, and `ai_rules_dart` brings
`rules_go`; no repository of theirs is fetched by a Flutter Android build.) `ai_rules_dart` is the sibling
`rules_dart/` directory in `e2e/min_versions`: its declared floor is checked,
but it has no resolved version.

The lift table is asserted, not just documented: `e2e/min_versions` declares
every floor, pins the floors that can bind, and its
`//:dependency_floors_test` reads each selected module's own `MODULE.bazel`
through `@resolved_module_versions`. A lifted module is asserted at its lifted
value and attributed to the module above, never presented as
`rules_flutter`'s floor. The `ai_rules_dart` rows are what the floor release
requests; the workspace checks them against the requests in the sibling
`rules_dart/MODULE.bazel`, so a change there that moves one fails
`//:dependency_floors_test` until this table follows.

That workspace also downloads its Android SDK and NDK from Google with
checked-in sha256 values (`e2e/min_versions/android_repositories.bzl`) instead
of reading `ANDROID_HOME`/`ANDROID_NDK_HOME`. The floor build is therefore the
same on a developer host, a CI image with a preinstalled SDK, and the gate,
whose clean environment exports neither variable. The NDK repository is empty
on non-Linux hosts, where `//:android_build_test` is reported incompatible, so
macOS proves the Apple legs, the Dart app and the resolved floor table while
the Linux job builds the Android leg against the same floors.

## This repository's own builds

This checkout and its `bazel test //flutter/...` stay on the current releases
through root-only `single_version_override` lines in `MODULE.bazel`. Root
overrides are ignored when the module is used as a dependency, so they cannot
leak into a consumer graph:

| Module | Current release |
|---|---|
| `bazel_skylib` | 1.9.2 |
| `package_metadata` | 0.0.13 |
| `rules_cc` | 0.2.26 |
| `apple_support` | 2.9.1 |
| `rules_apple` | 5.2.0 |
| `rules_swift` | 4.1.2 |
| `rules_kotlin` | 2.4.20 |
| `rules_java` | 9.9.0 |
| `llvm` | 0.8.19 |

`platforms` 1.1.0 is already current at its floor, so it needs no override. `ai_rules_dart` is the sibling `rules_dart/` directory
through a `local_path_override`, which supplies the version the source
`MODULE.bazel` intentionally leaves out.

## The version-floor trade-off

Bazel's MVS picks the *maximum* of the versions in the graph, so a floor is a
promise ("works at this version or newer"), not a pin. A consumer that names
no version of a module gets our floor — and the floor's own transitive deps,
which may be *older and heavier* than the current release's:

- An unpinned consumer resolves `rules_apple` 4.5.3, not 5.2.0 (that is what
  a plain consumer graph selects today). This repo's own builds stay on
  5.2.0 via a root-only `single_version_override` (consumers ignore that
  line), and `e2e/min_versions` pins 4.5.3 exactly to prove the floor
  builds. Flooring Apple selects its older transitive pins too, so if you
  want the newer Apple tree, add your own `bazel_dep(name = "rules_apple",
  version = "5.2.0")`: MVS then selects 5.2.0 for everyone, at the cost of
  tracking Apple's releases yourself.
- `rules_swift` and `apple_support` now have real floors (3.5.0 at
  compatibility level 3, and 2.2.0). They do **not** float below those
  versions: a consumer that declares nothing gets at least the floor, and
  only another module's higher request lifts them. `ai_rules_dart`
  lifts `apple_support` to 2.9.1 through `rules_cc` 0.2.26; that is the
  transitive lift table above, not a floating default.

## Opt-in paths and the error they can give

Some floors are structural for an optional path, and an older version fails at
analysis. Starlark cannot catch a missing external package or a symbol a `.bzl`
load needs and turn it into a custom version error, so this repository keeps
the path's floor at the version it needs instead of narrowing it:

- **Android Kotlin:** an app built from its pinned Gradle model compiles Kotlin
  with `rules_kotlin` on the Kotlin standard library the model resolved. An
  older `rules_kotlin` fails in the Kotlin compile action ("module was compiled
  with an incompatible version of Kotlin"), so the floor stays at 2.3.0.
- **xtool Darwin SDK:** `flutter.darwin_sdk` resolves llvm's
  `llvm-toolchain-minimal-<os>-<cpu>` repos through the extension and the
  `@flutter_xtool_darwin_sdk` repo rule. An older `llvm` fails at analysis
  when those repos or `@llvm//extensions:llvm_toolchain_minimal.bzl` cannot be
  resolved. The floor stays at 0.8.17.
- **Native-asset C++:** the opt-in native-asset path loads
  `@rules_cc//cc:cc_shared_library.bzl` and `@rules_cc//cc:objc_library.bzl`
  and compiles through the caller's C++ toolchain. An older `rules_cc` fails
  at analysis with the `rules_cc` load or toolchain error, so the floor stays
  at 0.2.20.

These paths are opt-in, so the floor does not force an upgrade on a consumer
that never builds them; it only says what rules_flutter supports when it does.

## BCR

`e2e/smoke` is the BCR test module (`.bcr/presubmit.yml`). It takes
`ai_rules_flutter` through a `local_path_override` and names its own current
dependencies, so it checks that a consumer on those releases still resolves
and builds; it does not pin the floors (that is `e2e/min_versions`' job). The
root-only `single_version_override` lines are not part of what BCR publishes:
Bazel applies them only to the root module's own resolution, and
`e2e/smoke` is a different root, so they cannot leak into the BCR graph. The
`ai_rules_dart` fork itself has no BCR entry yet, so the BCR test module and
the install instructions take it from the fork's GitHub release (see
`README.md`).

## Heavy transitive repos, and who brings them

`bazel mod explain <module>` in any consumer workspace prints the chains.
For a plain consumer (e.g. `e2e/smoke`) today:

- `rules_python` arrives via `rules_dart → protobuf → rules_pkg`,
  via `rules_android` (which `rules_kotlin` brings; plus through `abseil-py` and
  `rules_robolectric`), via `rules_apple`, via `llvm`, and via
  `re2 → pybind11_bazel`. None of these is `rules_flutter`'s own dep —
  removing ours (done) is all we can do; the rest belongs to those
  rulesets. Its `pypi__*` bootstrap hub repos materialize only when
  something evaluates `rules_python`'s toolchain extension.
- `rules_go` arrives via `rules_dart` (directly and through `gazelle`)
  and via `rules_android` (which `rules_kotlin` brings). The
  `go_toolchains`/`nogo` hub repos belong to its `go_sdk` extension.
  `rules_flutter` declares no Go SDK and no Go setting: nothing in a Flutter
  build resolves a Go toolchain.
- `llvm`'s `bazel_lib`, `rules_shell`, `tar.bzl`, `with_cfg.bzl`,
  `zlib-ng`, `zstd` module deps resolve in the graph but fetch only if
  something references them — for a plain consumer, nothing does.

## What a plain consumer pays for LLVM

`llvm` stays a regular (non-dev) `bazel_dep` because the xtool repo rule
resolves llvm's per-host prebuilt-toolchain repos in `rules_flutter`'s own
repo mapping, and that mapping needs the non-dev edge: `MODULE.bazel` runs
`use_extension("@llvm//extensions:llvm_toolchain_minimal.bzl", ...)` (joining
llvm's own instance, no tags) and `use_repo`s the four
`llvm-toolchain-minimal-<os>-<cpu>` repos. A `Label(...)` built in an
extension implementation cannot see them, and canonical repo names are
unstable across Bazel versions, so the extension passes the four apparent
names as plain strings and the repo rule builds the label itself — only for
the exec host, and only when the root module configured `flutter.darwin_sdk`
(or for this repo's own hermetic-LLVM script tests, which assert the linkage
with no SDK).

Concretely, a consumer that never opts into xtool pays:

- the module-graph edge (`llvm` and its deps appear in `bazel mod deps`)
  and the small `llvm` ruleset-repo fetch (Bazel reads the extension `.bzl`
  during evaluation);
- the version floors `llvm@0.8.17`'s own `MODULE.bazel` requires: without
  the edge, MVS would select `bazel_lib@3.2.2` (highest other requesters:
  `rules_kotlin`, `bazel_linux_packages`), `rules_python@1.8.0`
  (`rules_apple`), and `rules_shell@0.8.0` (`rules_android`,
  `rules_apple`, `rules_jvm_external`, `buildifier_prebuilt`,
  `bazel_linux_packages`); with it they resolve to those versions. Verify
  with `bazel mod explain bazel_lib rules_python rules_shell` —
  `llvm@0.8.17` is the requester naming the top version of each;
- four graph-only modules nothing else requests: `tar.bzl`, `with_cfg.bzl`,
  `zlib-ng` and `zstd` (no other resolved `MODULE.bazel` names them; only
  `tar.bzl` even materializes a repo, since the rest fetch solely on
  reference);
- **no** toolchain-archive download (verified: `@flutter_xtool_darwin_sdk`
  contains no `llvm/` tree for plain consumers, and no
  `llvm-toolchain-minimal-*` repo is fetched);
- **no** C/C++ toolchain registration (the eight `@llvm//toolchain:*`
  registrations are dev-only).

An opting-in consumer configures only the SDK — a nonexistent bundle path
fails the fetch on the path error before any LLVM download starts
(`e2e/xtool_sdk_invalid` pins this red path in CI).
