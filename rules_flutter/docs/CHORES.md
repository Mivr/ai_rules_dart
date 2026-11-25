# Maintenance Chores

Central reference for all recurring maintenance tasks. Slash commands read this
file at runtime — keep file lists current as the repo evolves.

---

## Flutter Version Bump

**Trigger**: New Flutter stable release.

**Authoritative source**: The Flutter reference repo tags are the source of truth for the
latest stable version. Do NOT rely on web searches — they may be stale. Run:

```sh
git -C references/flutter fetch --tags
git -C references/flutter tag -l '[0-9]*' | grep -v pre | sort -V | tail -5
```

The latest tag is the current stable release.

**What a bump touches**: two table files, the default, three README places and
the apps' own files.
The rules list the current stable line and the previous one (today 3.50 and
3.47: customers that have not migrated stay on the previous line). A patch
replaces its minor's earlier rows. A new minor does not drop the oldest listed
line by itself: a line is dropped only on the owner's word, and then its rows,
its `FLUTTER_SDK_LINES` entry, the `assets_tool/api_<line>` directory it alone
names, and its `e2e/previous_line` workspace move to the line that stays.

- `flutter/private/versions.bzl` — `FLUTTER_VERSIONS` and `ARTIFACT_CHECKSUMS`
- `flutter/private/flutter_assets_tool_versions.bzl` — the pin of the asset tool's
  source closure (the hosted packages the release's `flutter_tools` reaches, by
  hash, and its path packages). `update_flutter_version` prints the row when
  `FLUTTER_SDK_DIR` names the release's stock SDK (the archive, extracted)
- The Dart SDK the release carries: read `dart-sdk/version` in the release's own
  Dart SDK archive (`dart-sdk-linux-x64.zip`), not from a table. That Dart
  version needs rows in `rules_dart`'s `dart/private/versions.bzl` and
  `dart/private/module_compiler_versions.bzl`: one run of
  `bazel run //dart/private/tools:update_cross_sdk_versions -- <dart version>` in
  `rules_dart` writes both (see its `docs/CHORES.md`). A Flutter release whose
  Dart SDK has no module compiler cannot compile debug modules. Drop the old
  Dart version only with its Flutter line: every listed Flutter needs its own
  Dart's rows to build
- `flutter/private/sdk_lines.bzl` — a new minor that changes how stock builds
  (the icon shaker's input, a path in an archive, a `flutter_tools` call of the
  asset tool) gets its own `FLUTTER_SDK_LINES` entry, naming the stock change;
  rules read the entry from `FlutterSdkInfo.line` and compare no versions. Its
  `android_gradle_plugin` pair is the release's template AGP
  (`templateAndroidGradlePluginVersion` in `gradle_utils.dart`) and the oldest
  the apps use. A new `assets_tool_api` value is a copy of the newest
  `flutter/private/assets_tool/api_<line>/assets_tool_api.dart` fixed for the
  release's API, listed in `_apis` of `flutter_assets_tool.bzl`
- `MODULE.bazel` — `flutter_version` in the `flutter.toolchain()` call. This is
  the default: the `e2e/*` and `e2e/_overlay_tests/*` workspaces name no version
  and inherit it, and tests take the newest version in `FLUTTER_VERSIONS`
- `README.md` — the Flutter version in the Requirements table, the
  `MODULE.bazel` snippet under Getting started, and the `FlutterSdkInfo.version`
  example under Providers
- Every Flutter app's `pubspec.lock`: the release's packages pin versions of
  their own dependencies, so `flutter pub get --enforce-lockfile` fails in a
  workspace whose lock was made with the previous release. Run `flutter pub get`
  with the new stock SDK in each (and `git checkout` the `analysis_options.yaml`
  it rewrites)
- Every Android app: the `com.android.application` and
  `org.jetbrains.kotlin.android` versions of `android/settings.gradle(.kts)` must
  be at least the release's floors (`errorAGPVersion`, `errorKGPVersion` in its
  `DependencyVersionChecker.kt`), and each `android_model.json` is written again
  (`bazel run //:android_pin`, after `flutter pub get`): it names the engine of the
  release it was pinned with. `e2e/aar_host` and `e2e/digest_mismatch` name the
  engine revision themselves
- `e2e/smoke` registers a custom release (`3.50.10`) with a copy of the stock
  artifact table: copy `ARTIFACT_CHECKSUMS` of the new release into its
  `MODULE.bazel`, and its engine revision and source checksum, and set the
  `fake_sdk` files to the release

`flutter.pub` apps, the module compiler and the asset tool use the release's own
`flutter_tools` and Dart, so a change in either shows as a build failure of the
tool, not as a different output: read the failure for the stock change.

**Procedure**:

1. Fetch tags and identify the latest stable version (see above)
2. Download and extract the release's stock archive (`releases_linux.json` has
   its checksum) beside the older one
3. Run `FLUTTER_REPO=<clone> FLUTTER_SDK_DIR=<extracted archive> bazel run
   //tools/update_flutter_version -- <new-version>` (requires a Flutter reference
   repo with the tag; it computes every checksum the release needs in one run)
4. Copy the printed snippets into `flutter/private/versions.bzl` and
   `flutter/private/flutter_assets_tool_versions.bzl`, replacing the minor's
   earlier rows in both
5. Add the release's Dart SDK to `rules_dart` as above, then update
   `flutter_version` in `MODULE.bazel` and the README places
6. Fix the compile errors of the asset tool (`bazel build @flutter_toolchains//...`
   shows them): it follows the release's `flutter_tools` API. Calls that differ
   by line go in the line's `assets_tool_api.dart`, the rest stays shared; the
   asset tool of every listed release must still compile
7. Re-lock and re-pin the apps as above
8. Regenerate lock files

**Verification**: `bazel test //flutter/tests:all` and `cd e2e/smoke && bazel test //...`
on the default, `bazel test //...` with the previous line's version as the
`MODULE.bazel` default (not committed), and `cd e2e/previous_line && bazel test //...`

---

## Bazel Version Bump

**Trigger**: New Bazel release (typically minor/patch within 9.x).

**Files**:

- Every `.bazelversion` — the repo root plus one per workspace with a
  `MODULE.bazel`, including `e2e/_overlay_tests/*`. A workspace without one does
  not inherit the root's: bazelisk reads only its own workspace root and
  otherwise fetches the newest release, so a missing file silently runs a
  different Bazel than the rest of the sweep.
  `find . -name .bazelversion -not -path '*/bazel-*'` is the list.
- `.bcr/rules_flutter/presubmit.yml` (repository root) — `bazel:` matrix value (if major version changes)

**Procedure**:

1. Update all `.bazelversion` files to the new version
2. If the major version changed, update the `.bcr/rules_flutter/presubmit.yml` matrix
3. Regenerate lock files

**Verification**: `bazel build //...` passes.

**Automation**: `/bump-bazel {version}` slash command.

---

## Bazel Module Dependency Bumps

**Trigger**: Monthly, or when a dependency releases a version we need.

**Files**:

- `MODULE.bazel` — the `bazel_dep()` version is the **minimum** this
  repository supports, with a comment naming the symbol that sets it; the
  root-only `single_version_override` below it names the current release the
  repository compiles against
- `flutter/tests/dependency_floors.json` — the same floor, current release,
  resolved consumer version and lift attribution that the guard reads
- Every `e2e/*/MODULE.bazel` and `e2e/_overlay_tests/*/MODULE.bazel` — these
  declare their own `bazel_dep`s rather than inheriting the root's, so a floor
  change leaves them behind. `bazel_skylib`, `rules_cc` and `apple_support`
  appear in most; `rules_kotlin` in the Android ones; `llvm` only
  in `cross_compile_example`

**Procedure**:

1. Raise a floor only when the repository stops supporting the old version;
   name the new symbol, package or attribute in the root comment and update
   `flutter/tests/dependency_floors.json`
2. Move the current-release `single_version_override` when a newer release is
   adopted, and update the table's `current` entry
3. Keep the e2e workspaces at the declared floors, not at the current
   releases; `e2e/min_versions` proves the floors and the transitive lifts. On
   Linux `//...` builds the Dart app, the resolved-graph test and the Android
   leg; on macOS it builds the Dart app, that test and both Apple legs, while
   the Linux-only Android leg is reported incompatible.
4. Regenerate the root lock file (the e2e locks are intentionally stale)

**Verification**: `bazel test //flutter/tests/...`,
`cd e2e/min_versions && bazel test //...`, and the root lock passes with
`--lockfile_mode=error`. The Android leg's floor proof is
`cd e2e/min_versions && bazel test //:android_build_test` on Linux, which the
Linux job runs.

**Automation**: `/bump-deps` slash command.

---

## Lock File Refresh

**Trigger**: After any change to a `MODULE.bazel` file or its transitive deps,
to `.bazelversion` or to a `.bzl` file a module extension loads — the lock
records a format version (Bazel 9.1.0 writes 26, 9.2.0 writes 28), registry
hashes and each extension's digest.

**Every lockfile of the repository is committed and refreshed by one tool**,
the module root's and each `e2e/*` workspace's, in both modules. From
`rules_dart/tools`:

```sh
bazel run //refresh_locks               # refresh every lockfile
bazel run //refresh_locks -- --check    # write nothing; list the stale ones
```

The procedure, the options, the workspaces it skips and what lockfiles made on
Linux x64 lack for macOS and Windows are in `rules_dart/docs/CHORES.md`
("Lock File Refresh"). Move any `.bazelrc.user` aside first: an
`--override_module` line in it changes the module graph away from the one CI
resolves (the tool refuses to run while one exists).

There is deliberately no Python in the module graph, so no `rules_python`
bump, pip `facts` section, or per-host lock splicing exists to maintain. If a future change reintroduces a Python toolchain, this section
needs its refresh procedure back.

**Verification**: `bazel run //refresh_locks -- --check`, and `bazel test //...`
in the root.

**Automation**: `bazel run //refresh_locks` (see above).

---

## Release Archive Contents

**Trigger**: Adding or removing an e2e workspace, or any top-level directory.

**Files**: `.gitattributes`

The release archive is `git archive` output, so `export-ignore` decides what a
consumer downloads — and what BCR presubmit runs against. Extracting an archive
and building it is the only thing that catches either of these:

- **Patterns must be anchored with a leading `/`.** Without one they match a
  basename at any depth: `e2e/` would also strip any nested `e2e/` directory a
  shipped package globs, and that `glob` then fails the whole archive at load
  time with "glob pattern didn't match anything, but allow_empty is set to
  False". The archive does not build at all, and nothing in CI looks at it.
- **`e2e/smoke` has to stay in.** `.bcr/rules_flutter/presubmit.yml` (at the
  repository root) names it as `module_path`, and BCR resolves that inside the
  extracted archive. It was excluded along with the rest of `e2e/`.
- **Nothing in the archive may reach outside it.** The archive holds this module
  only, so `e2e/smoke` cannot name `../../../rules_dart`: its `MODULE.bazel` names
  a `rules_dart` release, and `e2e/smoke/.bazelrc.checkout` (left out of the
  archive) overrides it with the sibling directory in a checkout.
- **A tree is not a commit.** `release_prep.sh` runs `git archive <tag>` inside
  `rules_flutter/`; `git archive <tag>:rules_flutter` would archive a tree, and
  `export-subst` expands only for a commit.

`/e2e/*` is excluded wholesale and `/e2e/smoke` put back, so a new e2e workspace
is left out without a line here: the whole tree is 12MB against a 1.5MB archive.

**Verification**: `cd rules_flutter && git archive --format=tar HEAD | tar t` and
check that `e2e/smoke/` is present and no other e2e workspace is. To check it
builds, extract the archive somewhere clean and run `bazel build --nobuild //...`
— the load phase is what these mistakes break. `RELEASING.md` (repository root)
rehearses the whole release, archive and registry entry included, without a tag.

---

## BCR Presubmit Config

**Trigger**: When changing the test module or Bazel version requirements.

**Files**:

- `.bcr/rules_flutter/presubmit.yml` (repository root) — module_path, platform matrix, bazel matrix

**Procedure**: Update the YAML to match current requirements.

**Verification**: BCR presubmit passes after publishing.

**Automation**: Manual — changes are rare and coupled to other chores.

---

## Documentation Accuracy

**Trigger**: After any structural change (new rules, new e2e workspaces, etc.).

**Files**:

- `README.md` — examples table, installation snippet, version references. It is
  the architecture document too: `docs/ARCHITECTURE.md` was listed here long
  after it stopped existing, so check what a path names before trusting it
- `docs/TESTING.md` — the e2e workspace list, the sweep commands, the per-device
  tables
- `.github/workflows/ci.yaml` — the prose comments carry version claims of
  their own

**Procedure**: Review hardcoded counts, tables, and version strings against actual state.

**Verification**: Visual inspection.

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
4. Run `bazel run @multitool//tools/yamlfmt -- -lint .` and
   `bazel run @multitool//tools/typos -- .` to verify the updated tools work

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

**Procedure**: `renovate.json` extends `:enablePreCommit`, but treat this as
manual until you have actually seen a Renovate PR land here.

Reconcile the revs that track something else in this repo:

- `keith/pre-commit-buildifier` tracks `buildifier_prebuilt` in `MODULE.bazel`
  on the buildifier version — the first three components. The fourth is the
  ruleset's own packaging revision and the mirror repo tags only some of them
  (there is no 8.5.1.4), so a fourth-component gap is not drift.
- `google/yamlfmt` and `crate-ci/typos` track `multitool.lock.json` (see
  § "Multitool Version Bumps").
- `pre-commit/mirrors-prettier` is archived upstream; `v3.1.0` is the last
  stable tag and is expected to stay pinned.

**Verification**: `prek run --all-files` passes.

**Automation**: Manual, per above.

---

## GitHub Workflow Dependency Bumps

**Trigger**: Periodic or when a dependency releases a version we need.

**Files**: All `.github/workflows/*.yaml` files.

**Procedure**:

1. For each `uses:` reference, check the repo's tags/releases for newer versions
2. Update the version ref
3. For reusable workflows, review changelogs for new inputs or breaking changes

**Verification**: CI workflow runs successfully.
