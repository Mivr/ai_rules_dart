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
| `rules_android` | 0.8.0 | `@rules_android//flags:apk_signing_method` through the `apk_signing_v*` config_settings; the `flags/` package does not exist in 0.7.2 or 0.7.3. |
| `rules_kotlin` | 2.1.10 | `@rules_kotlin//kotlin:android.bzl` for `kt_android_library`, loaded by `flutter_android_app`. |
| `rules_java` | 9.0.0 | `@rules_java//java:java_import.bzl`, `@rules_java//java/common:java_info.bzl` (`JavaInfo`) and the Java toolchain rules. |
| `rules_jvm_external` | 6.8 | `@rules_jvm_external//:extensions.bzl` with `maven.install`/`maven.artifact`, `use_starlark_android_rules` and `aar_import_bzl_label`. |
| `ai_rules_dart` (repo `rules_dart`) | 0.28.3 | `@rules_dart//dart:defs.bzl`, `@rules_dart//dart:utils.bzl`, `dart_codegen(package_name = ...)`, `@rules_dart//dart/pub:pub_scc.bzl` and `dart_analysis_config(baseline = ...)`; the `Mivr/ai_rules_dart` release (a BCR entry is pending). |
| `rules_go` | 0.59.0 | `@rules_go//go/config:pure` and the Bazel 9 `CcInfo` import in `go/private/rules/cross.bzl`; 0.50.0 through 0.58.3 fail to load on Bazel 9. |
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
| `bazel_skylib` | 1.8.0 | 1.9.2 | `ai_rules_dart` 0.28.3 | Its own `bazel_dep` asks for 1.9.2. `llvm` 0.8.17 asks for 1.9.0, which is lower. |
| `package_metadata` | 0.0.5 | 0.0.13 | `ai_rules_dart` 0.28.3 | Its own `bazel_dep` asks for 0.0.13. |
| `rules_cc` | 0.2.20 | 0.2.26 | `ai_rules_dart` 0.28.3 | Its own `bazel_dep` asks for 0.2.26. `llvm` 0.8.17 asks for 0.2.22, which is lower. |
| `apple_support` | 2.2.0 | 2.9.1 | `rules_cc` 0.2.26 | `rules_cc` 0.2.25 and newer add a regular `bazel_dep` on `apple_support`; 0.2.26 asks for 2.9.1. `rules_cc` reaches that version through `ai_rules_dart` 0.28.3. |
| `rules_java` | 9.0.0 | 9.3.0 | `rules_android` 0.8.0 | Its own `bazel_dep` asks for 9.3.0. |
| `rules_jvm_external` | 6.8 | 6.9 | `rules_android` 0.8.0 | Its own `bazel_dep` asks for 6.9. |
| `rules_go` | 0.59.0 | 0.64.2 | `ai_rules_dart` 0.28.3 | Its own `bazel_dep` asks for 0.64.2. `llvm` 0.8.17 asks for 0.62.0, which is lower. |

Every other floor resolves at its declared version in that graph: `platforms`
1.1.0, `rules_apple` 4.5.3, `rules_swift` 3.5.0, `rules_android` 0.8.0,
`rules_kotlin` 2.1.10, `ai_rules_dart` 0.28.3 and `llvm` 0.8.17.

The lift table is asserted, not just documented: `e2e/min_versions` declares
every floor, pins the floors that can bind, and its
`//:dependency_floors_test` reads each selected module's own `MODULE.bazel`
through `@resolved_module_versions`. A lifted module is asserted at its lifted
value and attributed to the module above, never presented as
`rules_flutter`'s floor.

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
| `rules_jvm_external` | 7.1 |
| `rules_go` | 0.64.2 |
| `llvm` | 0.8.19 |

`platforms` 1.1.0, `rules_android` 0.8.0 and `ai_rules_dart` 0.28.3 are
already current at their floor, so they need no override. The git override of
`ai_rules_dart` at its 0.28.3 commit supplies the version the source
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
- `rules_android` stays at 0.8.0 with no lower option: the signing overlay
  reads `@rules_android//flags:apk_signing_method`, and that package exists
  only in 0.8.0+ (0.7.2 and 0.7.3 have no `flags/` directory at all), so
  every Android app fails at analysis with anything older. There is no
  version-tolerant way to read their flag.
- `rules_go` floors at 0.59.0 — the lowest rules_go that builds on Bazel 9
  (0.50.0 through 0.58.3 fail to load: `go/private/rules/cross.bzl` uses the
  native `CcInfo` symbol Bazel 9 removed; the `rules_cc` import landed in
  0.59.0). In practice `rules_android` already imposes the same floor, and
  the floor never binds anyway: `ai_rules_dart` 0.28.3 requires 0.64.2, so
  every graph selects that (`bazel mod explain rules_go` — verified even in
  the workspaces that declare only the 0.59.0 minimum). The floor is a
  Bazel 9 load minimum, not a tested configuration.
- `rules_swift` and `apple_support` now have real floors (3.5.0 at
  compatibility level 3, and 2.2.0). They do **not** float below those
  versions: a consumer that declares nothing gets at least the floor, and
  only another module's higher request lifts them. `ai_rules_dart` 0.28.3
  lifts `apple_support` to 2.9.1 through `rules_cc` 0.2.26; that is the
  transitive lift table above, not a floating default.

## Opt-in paths and the error they can give

Some floors are structural for an optional path, and an older version fails at
analysis. Starlark cannot catch a missing external package or a symbol a `.bzl`
load needs and turn it into a custom version error, so this repository keeps
the path's floor at the version it needs instead of narrowing it:

- **Android APK signing:** `flutter_android_app`'s overlay reads
  `@rules_android//flags:apk_signing_method`, which exists only from
  `rules_android` 0.8.0. A consumer on an older `rules_android` fails at
  analysis with a missing-package error naming `@rules_android//flags`, not a
  tailored version message. Mirroring the flag with our own default would
  sign differently from the consumer's `android_binary`, so the floor stays
  at 0.8.0.
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
  via `rules_android` (directly, plus through `abseil-py` and
  `rules_robolectric`), via `rules_apple`, via `llvm`, and via
  `re2 → pybind11_bazel`. None of these is `rules_flutter`'s own dep —
  removing ours (done) is all we can do; the rest belongs to those
  rulesets. Its `pypi__*` bootstrap hub repos materialize only when
  something evaluates `rules_python`'s toolchain extension.
- `rules_go` arrives via `rules_dart` (directly and through `gazelle`)
  and via `rules_android`. The `go_toolchains`/`nogo` hub repos belong to
  its `go_sdk` extension. Our own pinned `go_sdk.download` (Go 1.26.2,
  checksummed) is a regular dependency: it is evaluated in every consumer
  and sorts first in the toolchain order, but toolchain registration is
  lazy, so a plain consumer's `bazel build`/`bazel test` never fetches the
  SDK archive — only resolving a Go toolchain (the Android host tools) does.
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

## Android Maven lock files (`rules_android_maven`)

Android builds resolve artifacts through `rules_android_maven`, a `maven.install` defined across `rules_android`, `rules_flutter`, and consumer workspaces.

To ensure hermetic builds and prevent unchecksummed downloads, consumers should pin this install at the root of their workspace by adding `lock_file = "//:rules_android_maven_install.json",` to their `maven.install(name = "rules_android_maven", ...)` (or declaring one with just the name) and generating the lock with `bazel run @rules_android_maven//:pin`.

`rules_flutter` intentionally does not ship a lock file in its own `MODULE.bazel`. Under `rules_jvm_external` (6.9 `private/extensions/maven.bzl:630-637` and 7.1 `private/extensions/maven.bzl:784-793`), a dependency module's lock file is only used when the consumer's root module declares no same-named install; a root module's install always replaces the lock entry (defaulting to none if the root does not set `lock_file`). As a result, a library-level lock would silently stop applying as soon as a consumer adds or bumps an artifact. Additionally, `rules_jvm_external` allows only one module in the graph to pin an install name (6.9 `:653-661`, 7.1 `:810-817`). Root-level pinning guarantees that the merged artifact graph carries complete SHA-256 checksums and enforces `fail_if_repin_required`.
