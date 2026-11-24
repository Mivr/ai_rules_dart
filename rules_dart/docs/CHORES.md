# Maintenance Chores

Central reference for all recurring maintenance tasks. Slash commands read this
file at runtime — keep file lists current as the repo evolves.

---

## Dart SDK Version Bump

**Trigger**: New stable Dart SDK release. The rules list only the current stable
SDKs: the new release, plus the default while it stays the default. Keep the
latest patch of each minor, so a new patch replaces the minor's earlier rows.

**What a bump touches**: two generated files, and two more only when the new
version becomes the default.

- `dart/private/versions.bzl` and `dart/private/module_compiler_versions.bzl`,
  written by one command (below): the five SDK archive checksums, the cross
  `gen_snapshot` and `dartaotruntime` checksums, and the module compiler's
  sources (the checksum of the SDK tag's source archive and its commit)
- When the new version becomes the default: `MODULE.bazel`
  (`dart.toolchain(dart_version = "...")`) and the installation snippet in
  `README.md`. Nothing else names the default: e2e workspaces, `dev/` and
  `tools/` inherit it, tests reach it through `@dart_toolchains//sdk/default`,
  the comma-patch and format tests run against every version in `TOOL_VERSIONS`,
  and `dart/tests/versions_test.bzl` checks the order, not a version
- Not touched: `dart/runfiles/pubspec.yaml`'s `environment.sdk` (published to
  pub.dev; keep the lower bound as low as stays compatible rather than tracking
  the newest SDK)

Three workspaces name versions because they exist to test one: `e2e/root_sdk_pin`
pins a listed version, which proves that the root's pin wins over rules_dart's own
request only while that version is not the default (when a bump makes it the
default, pin another listed version in its `MODULE.bazel` and
`test/version_test.dart`; with one version listed it can only pin the default),
`e2e/sdk_coupling` registers an exec and a target SDK (the same version; the rules
need the two to match, because a tool the exec SDK builds does not load in another
SDK's runtime), and `e2e/sdk_unknown_version` names a version that is not listed.
Change them only when the version they name leaves the table.

**Procedure**:

1. Confirm the release: `curl https://storage.googleapis.com/dart-archive/channels/stable/release/latest/VERSION`
2. `bazel run //dart/private/tools:update_cross_sdk_versions -- [--drop=<older patch of the same minor>] <version>`
   (one run, about half a minute): it adds the version to `TOOL_VERSIONS` (newest
   first) with the checksums the Dart bucket publishes, hashes the 22 cross
   binaries and the tag archive as it downloads them, reads the commit from the
   release's `VERSION` file, and drops the pins of a version that is no longer
   listed. A new `MODULE_COMPILER_SOURCES` row starts from the newest row's package
   language versions; check them against the `sdk:` lower bounds in
   `pkg/{_fe_analyzer_shared,build_integration,front_end,kernel,vm}/pubspec.yaml`
   of the tag (a value below what the sources use fails the tool's build)
3. Run the suites with each listed version selected: with the default, then
   with `dart_version` in `MODULE.bazel` set to each other listed version:
   `bazel test //dart/tests:all //dart/private/tools:all //dart/pub/... //docs/...`
   (this covers the module compiler tests, the `package:test` closure and the
   tool tests). If the front end's API moved, the module compiler does not
   build for the version: that is a change to `module_compiler.dart`, and the
   version stays unlisted until it builds on every listed SDK
4. If the version becomes the default: set `dart_version` in `MODULE.bazel` and
   the `README.md` snippet; check that `e2e/root_sdk_pin` still pins a version
   other than the default
5. `FORMATTER_SDK_SERIES` in `dart/private/format_mode.bzl` does not follow the
   SDK: it names the series the vendored `package:dart_style` formats like.
   `DartFormat` runs the SDK's own `dart format` for any other series, so a new
   default works without a change, and moves to the in-process formatter when
   `dart/ext` is re-vendored for it
6. Regenerate lock files: `cd tools && bazel run //refresh_locks`

**Verification**: the suites of step 3 pass for every listed version, and
`cd e2e/root_sdk_pin && bazel test //...` passes.

**Automation**: `/bump-dart-sdk {version}` slash command.

---

## Bazel Version Bump

**Trigger**: New Bazel release (typically minor/patch within 9.x).

**Files**:

- `.bazelversion`
- `e2e/smoke/.bazelversion`
- `e2e/hello_world/.bazelversion`
- `e2e/library_deps/.bazelversion`
- `e2e/dart_test/.bazelversion`
- `e2e/dart_test_pkg/.bazelversion`
- `e2e/analysis/.bazelversion`
- `e2e/analysis_failure/.bazelversion`
- `e2e/web_app/.bazelversion`
- `e2e/pub_deps/.bazelversion`
- `e2e/pub_lock/.bazelversion`
- `e2e/gazelle/.bazelversion`
- `e2e/cross_compile/.bazelversion`
- `e2e/pub_lock_conflict/.bazelversion`
- `e2e/pub_lock_cross_module/.bazelversion`
- `e2e/pub_lock_dedup/.bazelversion`
- `e2e/pub_lock_upgrade/.bazelversion`
- `e2e/codegen/.bazelversion`
- `e2e/ext_exemplar/.bazelversion`
- `e2e/fix/.bazelversion`
- `.github/workflows/ci.yaml` — `bazel_versions:` must match `.bazelversion`; the
  reusable workflow sets `USE_BAZEL_VERSION` from it, so a stale value means CI
  never tests the version developers run locally
- `.bcr/presubmit.yml` — `bazel:` matrix value (if major version changes)
- `docs/ARCHITECTURE.md` — prose naming the major Bazel version, currently
  "Bazel 9.x" (if major version changes)

**Procedure**:

1. Update all `.bazelversion` files to the new version
2. If the major version changed, update `.bcr/presubmit.yml` matrix and `docs/ARCHITECTURE.md`
3. Regenerate lock files: `cd tools && bazel run //refresh_locks`
4. Run `bazel test //dart/tests/...` to verify

**Verification**: `bazel test //dart/tests/...` passes.

**Automation**: `/bump-bazel {version}` slash command.

---

## Bazel Module Dependency Bumps

**Trigger**: Periodic (monthly) or when a dep releases a version we need.

**Files**:

- `MODULE.bazel` — `bazel_dep()` version strings
- E2e workspaces that duplicate deps:
  - `e2e/smoke/MODULE.bazel` — `bazel_skylib`, `rules_shell`
  - `e2e/codegen/MODULE.bazel` — `bazel_skylib`
  - `e2e/gazelle/MODULE.bazel` — `bazel_skylib`, `gazelle`, `rules_shell`,
    `apple_support`, `hermetic_cc_toolchain`
  - `e2e/cross_compile/MODULE.bazel` — `platforms`, `rules_platform`
  - `e2e/ext_exemplar/MODULE.bazel` — `gazelle`, `rules_go`, `sqlite3`,
    `rules_cc`, `platforms`, `apple_support`, `hermetic_cc_toolchain`
  - `e2e/build_hooks/MODULE.bazel` — `rules_cc`, `sqlite3`,
    `hermetic_cc_toolchain`
  - `e2e/fix/MODULE.bazel` — `bazel_skylib`
  - `e2e/sdk_coupling/MODULE.bazel` — `bazel_skylib`
- `e2e/ext_exemplar/sqlite3_binary/test/direct_test.dart` — asserts the exact
  `sqlite3.version.libVersion` string, so a `sqlite3` bump fails this test until
  the literal is updated to match

**Procedure**:

1. For each `bazel_dep` in root `MODULE.bazel`, check latest version on BCR
2. Update versions, skip any already current
3. Mirror version changes to e2e workspaces that duplicate the same deps
4. Regenerate lock files: `cd tools && bazel run //refresh_locks`
5. Run `bazel test //dart/tests/...` to verify

**Verification**: `bazel test //dart/tests/...` passes.

**Automation**: `/bump-deps` slash command.

---

## Lock File Refresh

**Trigger**: After any change to a `MODULE.bazel` file or its transitive deps,
to `.bazelversion`, and after any change to a `.bzl` file reachable from a
module extension. A lock records each extension's `bzlTransitiveDigest`, so
editing (or merely adding a load to) anything in `dart/pub/extensions.bzl`'s
closure invalidates the lock of **every** workspace using it, not just the one
whose `MODULE.bazel` moved. Under `--lockfile_mode=error`, which each module's
`.bazelrc` sets, that is a hard CI failure.

**Workspaces**: one repository holds both modules, so one tool refreshes them
all. It finds every directory with a `MODULE.bazel` (the two module roots,
`rules_dart/tools`, `rules_dart/dev` and every `e2e/` workspace) and skips the
few that are not workspaces of their own, each with its reason in
`skippedWorkspaces` (`tools/refresh_locks/lib/workspaces.dart`): the nested
modules consumed only from a parent workspace and the conformance overlays.
`bazel run //refresh_locks -- --list` prints both sets.

**Procedure**: from `rules_dart/tools`, with no `.bazelrc.user` in any
workspace (an `--override_module` line in one changes the module graph away
from the one CI resolves; the tool refuses to run until they are moved aside):

```sh
bazel run //refresh_locks                       # refresh every lockfile
bazel run //refresh_locks -- --check            # write nothing; list stale ones
bazel run //refresh_locks -- rules_flutter/e2e  # only workspaces under a path
```

Per workspace it runs `mod tidy --lockfile_mode=refresh` (registry hashes and a
canonical `MODULE.bazel`), `mod deps --lockfile_mode=update` (evaluates every
module extension of the graph, not only those the workspace's targets reach)
and `mod deps --lockfile_mode=error` (proves the lock stands alone), then stops
that workspace's Bazel server. `--check` runs only the last command. Two
workspaces run at a time (`--jobs=N`): each holds a Bazel server and asks the
registry, and `pub.dev` for the packages whose facts the lock does not yet
hold, so a refreshed lock makes the next run ask nothing. `--bazel=PATH` names
another Bazel or a wrapper, `--expunge` deletes each output base afterwards,
`--help` lists the rest. Logs of every command are in the directory it prints.
The tool exits 1 listing the stale or failed workspaces.

`e2e/pub_lock_conflict` fails on purpose (conflicting lock files), and the
workspaces whose hubs name a `file://FIXTURES_ROOT` registry that a CI step or
the e2e runner rewrites cannot evaluate their pub extension in place. They are
listed in `expectedFailures` with the text the failure must contain; their
lockfiles hold what Bazel wrote before it failed and nothing about pub, and
`--check` does not check them (Bazel calls such a lock stale whatever it holds).

**Other operating systems**: the lockfiles are made on Linux x64 and checked
there and on macOS and Windows. A lock holds one `general` entry per module
extension unless the extension declares `os_dependent` or `arch_dependent`;
then it holds one entry per system it ran on, and a lock made on Linux x64 has
none for the others (`--lockfile_mode=error` fails there with "does not exist
in the lockfile"). No extension of either module's graph declares that today:
the tool's `--check` fails, naming the extension, as soon as any lockfile
holds an entry keyed by system, which is the signal to add one made on that
system. The extensions' own source (`dart` sets both to false) and every
committed lockfile were read for this; nothing was run on macOS or Windows.
Two more things must hold on Windows: files are checked out with LF
(`rules_dart/.gitattributes` says so; a CRLF checkout changes the digest of
every `.bzl` file and of `pubspec.lock`), and the workspace holds no
`.bazelrc.user`.

**Verification**: `bazel run //refresh_locks -- --check` passes, and so does
`bazel build --nobuild --lockfile_mode=error //...` in a module root.

**Automation**: `/refresh-locks` slash command. CI's `mod-tidy` and `repo-checks`
jobs run the three commands on each module root and fail when they change a
file.

The `pubspec.lock` files of the in-repo Dart packages (`dart/ext/`,
`dart/private/tools/`, `dart/runfiles/`) are not touched by the tool: refresh
one with `bazel run @rules_dart//dart -- pub get` in its directory (the pinned
SDK, since a package's SDK floor can be ahead of the host's `dart`, with
`FLUTTER_ROOT` set for a Flutter-flavored lock), and regenerate the plan of
`dart/ext/pubspec.lock` as described in [pub.md](pub.md).

### Lockfile-off Exemptions

Every `e2e/` workspace reads its committed `MODULE.bazel.lock`, and no
`e2e/**/.bazelrc` may set `--lockfile_mode=off`: under that mode Bazel neither
reads nor checks the lock, so registry hashes are skipped, the `pub` planner
never takes its recorded-facts path, and stale locks go unnoticed. If an `e2e/`
workspace ever genuinely must run without a lockfile, list it below as
``- `e2e/<name>` — <reason>`` and remove its unused `MODULE.bazel.lock` rather
than keeping it as dead data.

(none)

---

## Platform / Toolchain Expansion

**Trigger**: Dart SDK adds support for a new platform (rare).

There are two distinct procedures. Pick by asking whether the platform can be a
**host** — i.e. whether Bazel itself publishes a release for that OS/CPU. If it
cannot, it is a cross-only target and costs no checksums.

### A new cross-only target (the common case)

**Files**:

- `dart/private/toolchains_repo.bzl` — add to `TARGET_ONLY_PLATFORMS`, then add
  it to each `CROSS_TARGETS` value it is reachable from
- `dart/private/tools/update_cross_sdk_versions.dart` — add to
  `crossTargetPlatforms` and `crossTargets` (they mirror `toolchains_repo.bzl`),
  then run it: it pins the new pairs' cross binaries for every listed version
- `e2e/cross_compile/BUILD.bazel` — add to `_TARGETS`
- `e2e/cross_compile/cross_compile_test.dart` — add its expected `EI_CLASS` and
  `e_machine` to the table; the suite asserts the architectures are pairwise
  distinct, so a new target must bring a new `e_machine`
- `dart/tests/cross_fixture/BUILD.bazel` — a `platform()` plus flag/ABI tests
- `dart/private/common.bzl` — extend `DART_ABI_CONSTRAINT_ATTRS` and
  `target_dart_abi` if the CPU is new, so code assets are not blocked for users
  who bring their own cc toolchain
- `docs/ARCHITECTURE.md` — platform list, toolchain counts, cross matrix

Explicitly **not** needed: a new key in each `TOOL_VERSIONS` entry (`hostPlatforms`
in `update_cross_sdk_versions.dart` stays as it is) and `.bcr/presubmit.yml`. A
cross toolchain reuses the host SDK's `dart` binary, so no SDK archive is
downloaded for the target and no archive checksum exists to fetch. BCR CI has no
runner for these CPUs either.

Before hard-coding the ELF table, confirm the real header bytes:

```sh
dart compile exe          -o /tmp/x hello.dart --target-os linux --target-arch <arch>
dart compile aot-snapshot -o /tmp/x.aot hello.dart --target-os linux --target-arch <arch>
file /tmp/x /tmp/x.aot
```

### A new host platform

**Files**: everything above, plus

- `dart/private/toolchains_repo.bzl` — `PLATFORMS` rather than `TARGET_ONLY_PLATFORMS`
- `dart/private/versions.bzl` — add the platform key to **every** version entry;
  `repositories.bzl` hard-errors on a missing key
- `dart/private/tools/update_cross_sdk_versions.dart` — add to `hostPlatforms`
  and `crossTargets`, then run it with `--force` (it hashes every artifact again)
  and fill the new key of every `TOOL_VERSIONS` entry by hand
- `.bcr/presubmit.yml` — add to the matrix if BCR has a runner

**Verification**: `bazel test //dart/tests/...` — `toolchains_test.bzl` asserts
the table invariants, including that every pinned version's checksum set matches
`PLATFORMS` exactly. Then `cd e2e/cross_compile && bazel test //...` for the
byte-level architecture check.

**Automation**: Manual — too rare and requires design decisions.

---

## E2e Pub Package Version Bumps

**Trigger**: When pub.dev packages used in e2e tests release new versions.

**Files**:

- `e2e/pub_deps/MODULE.bazel` — `pub.package()` version and sha256
- `e2e/pub_lock/pubspec.lock` — regenerate from `pubspec.yaml`

**Procedure**:

1. Check pub.dev for latest versions of packages used in e2e tests
2. Update `pub.package()` calls with new version and sha256
3. For `pub_lock`, run `dart pub get` in the e2e/pub_lock directory to refresh the lock file
4. Regenerate Bazel lock files

**Verification**: `bazel build //...` in affected e2e workspaces succeeds.

**Automation**: Manual — low frequency, requires checking sha256 hashes.

---

## In-repo Dart Package Maintenance

**Trigger**: Periodic or before a release.

**Packages**: `dart/runfiles/`

Each in-repo Dart package is publishable to pub.dev. Maintenance includes:

- **SDK constraint**: The `environment.sdk` lower bound in `pubspec.yaml`
  tracks the project's minimum supported Dart SDK. Updated by `/bump-dart-sdk`.
- **Dependencies**: Any pub dependencies need periodic bumping. Run
  `dart pub outdated` in the package directory to check, then `dart pub upgrade`
  to take what the current constraints allow.

  `dart/ext/` moves as a deliberate chore, not with the routine sweep. Its
  lock is `ext_pub_deps` (isolated): the packages rules_dart's own tools,
  tests and lints are built from (the pinned `analyzer`, `dart_style`,
  `hooks`, `data_assets`, `sqlite3`). It holds no code generators any more:
  `dart_build_runner` takes `build_runner` and the builders from the user's
  lock (see [build_runner.md](build_runner.md)). `e2e/codegen`,
  `e2e/dart_test_pkg`, and rules_dart_proto's `dart_proto` set floors on
  `analyzer`/`package_config` in their pubspecs to keep their locks no older
  than this one. To bump: `bazel run @rules_dart//dart -- pub upgrade` in
  `dart/ext/`, then `dart pub upgrade` in each pinned workspace, refresh the
  touched `MODULE.bazel.lock`s, and verify with `//dart/ext/...`,
  `e2e/codegen`, and a consuming app.

- **Lock file**: `pubspec.lock` is refreshed with `pub get` or `pub upgrade`
  (see Lock File Refresh); the Bazel lockfiles that depend on it with
  `cd tools && bazel run //refresh_locks`.
- **Version**: Committed as `0.0.0-dev`. The real version is injected from
  the git tag at publish time by the release workflow.
- **Publishing**: Handled automatically by the `pub-publish` job in the
  release workflow (`.github/workflows/release.yaml`).

**Verification**: `dart pub get` succeeds; `dart pub outdated` reports no
critical updates.

**Automation**: `/maintenance-audit` checks SDK constraint consistency and
outdated dependencies.

---

## CI Folder List Sync

**Trigger**: When adding or removing an e2e workspace.

**Files**:

- `.github/workflows/ci.yaml` — `folders` array in the test job

**Procedure**:

1. Compare `e2e/*/MODULE.bazel` against the `folders` array in `ci.yaml`
2. Add/remove entries to match

**Verification**: CI workflow runs all e2e workspaces.

**Automation**: `/maintenance-audit` detects drift.

---

## BCR Presubmit Config

**Trigger**: When changing the test module or Bazel version requirements.

**Files**:

- `.bcr/presubmit.yml` — module_path, platform matrix, bazel matrix

**Procedure**: Update the YAML to match current requirements.

**Verification**: BCR presubmit passes after publishing.

**Automation**: Manual — changes are rare and coupled to other chores.

---

## Documentation Accuracy

**Trigger**: After any structural change (new rules, new e2e workspaces, etc.).

**Files**:

- `docs/ARCHITECTURE.md` — provider table, testing table, design rationale
- `README.md` — examples table, installation snippet, version references

**Procedure**: Review hardcoded counts, tables, and version strings against actual state.

**Verification**: Visual inspection.

**Automation**: `/maintenance-audit` checks some of these.

---

## Multitool Version Bumps

**Trigger**: Periodic (monthly) or when a managed tool releases a version we need.

**Files**:

- `multitool.lock.json` — tool versions, URLs, and SHA-256 hashes

**Managed tools**: `git-cliff`, `prek`, `typos`, `yamlfmt`

**Procedure**:

1. For each tool in `multitool.lock.json`, check its GitHub releases for newer versions
2. Download archives for all platform variants (macOS/Linux, arm64/x86_64)
3. Compute SHA-256 hashes and update the lockfile entries
4. Regenerate lock files: `cd tools && bazel run //refresh_locks`
5. Run `bazel run @multitool//tools/yamlfmt -- -lint -gitignore_excludes "$PWD"` and
   `bazel run @multitool//tools/typos -- "$PWD"` to verify the updated tools work

**Verification**: Both tools run successfully against the repo.

Also update the matching `rev:` values in `.pre-commit-config.yaml` for yamlfmt
and typos to keep CI and local hooks in sync. When bumping prek, update
`prek-version` in `.github/workflows/ci.yaml` to match, and run
`uv tool upgrade prek` so the installed git hooks use the new version.

**Automation**: `/bump-multitool` slash command. Alternatively, install the
[multitool CLI](https://github.com/theoremlp/multitool) and run
`multitool --lockfile ./multitool.lock.json update`.

---

## Git Hook Bumps

**Trigger**: New versions of the git hooks (buildifier, etc.).

**Files**:

- `.pre-commit-config.yaml`

**Procedure**: Run `prek autoupdate`, then reconcile the revs that are
pinned to something else in this repo:

- `keith/pre-commit-buildifier` should track `buildifier_prebuilt` in
  `MODULE.bazel`, so the hook and CI format identically. Match on the buildifier
  version — the first three components — not the fourth, which is the ruleset's
  own packaging revision: `buildifier_prebuilt` 8.5.1.3 and 8.5.1.4 ship the
  same buildifier 8.5.1, and the mirror repo tags only some of those revisions
  (it has no 8.5.1.4). A fourth-component gap is not drift.
- `google/yamlfmt` and `crate-ci/typos` should track `multitool.lock.json`
  (see § "Multitool Version Bumps").
- `pre-commit/mirrors-prettier` is archived upstream; `v3.1.0` is the last
  stable tag and is expected to stay pinned. Do not "upgrade" it to the
  `v4.0.0-alpha` tags.

**Verification**: `prek run --all-files` passes.

**Automation**: Manual. These were previously assumed to be handled by
Renovate, but no Renovate config has ever existed in this repo, and the
buildifier and commitizen revs silently drifted as a result.

---

## GitHub Workflow Dependency Bumps

**Trigger**: Periodic or when a dependency releases a version we need.

**Files**: All `.github/workflows/*.yaml` files.

**Dependencies** (all `uses:` references across workflows):

- Actions: `actions/checkout`, `amannn/action-semantic-pull-request`,
  `dart-lang/setup-dart`, `j178/prek-action`
- Reusable workflows: `bazel-contrib/.github` (CI + release),
  `bazel-contrib/publish-to-bcr`

**Procedure**:

1. For each `uses:` reference, check the repo's tags/releases for newer versions
2. Update the version ref
3. For reusable workflows, review changelogs for new inputs or breaking changes
4. Keep `actions/checkout` version consistent across all workflows

**Verification**: CI workflow runs successfully.

**Automation**: `/bump-workflows` slash command. `/maintenance-audit` checks for outdated versions.
