# Public pub cycle-planning API

`//dart/pub:pub_scc.bzl` is the public entry point for the cycle planner, the
lockfile facts cache and the verification decisions `pub.from_lock()` uses. A
rule set with its own pub hub can load it instead of copying these modules:

- planner: `compute_sccs`, `package_dep_graph`, `scc_repo_name`;
- facts: `READER_SOURCE_LABELS`, `parser_schema`, `parser_texts_digest`,
  `hosted_fact_key`, `git_fact_key`, `fact_deps_error`, `lookup_fact_deps`,
  `split_scope_facts`, `record_scope_facts`, `scratch_pubspec_error`,
  `scope_pubspec_path`;
- verification: `scc_planned_deps_error`, `scc_member_deps_error`,
  `spoke_planned_deps_error`, `scc_members_connectivity_error`.

`compute_sccs` is deterministic and returns singletons; facts are hints keyed
by schema plus reader digest and verified against the real pubspec. To share
facts with rules_dart, read the bytes of every `READER_SOURCE_LABELS` label in
order and pass them to `parser_schema`.

`//dart/pub:yaml.bzl` reads YAML the same way rules_dart does: `yaml_to_json`
converts files with the pinned `yaml2json` in one process (from a module extension
or repository rule), and `lock_packages`, `pubspec_deps`,
`pubspec_sdk_constraint` and `pubspec_environment_error` make pub's checks
on the decoded data.

# How `pub.from_lock()` plans the package graph

Before it generates a repository, the `pub` extension learns every locked
package's dependency names: they decide which dependency cycles merge and
which labels each package's `dart_library` depends on. For a hosted package
it reads the server's listing, `GET <url>/api/packages/<name>` with
`Accept: application/vnd.pub.v2+json` (`<url>` is the lock entry's
`description.url`), the document `dart pub` itself reads. One request per
distinct package name, all in parallel; no archive is downloaded while
planning. Bazel runs at most `--http_max_parallel_downloads` (default 8) at a
time; a very large lock plans faster with a higher value in `.bazelrc`.

- The archive a build fetches is pinned by the lock's `sha256`, as always,
  and fetched from the listing's `archive_url`. A listing whose
  `archive_sha256` differs from the lock's fails the evaluation naming both
  values; a server that lists no `archive_sha256` still works.
- Every package repository compares its real `pubspec.yaml` with the names
  planning used and fails its fetch, naming the package, when they differ.
- A package the server cannot answer for (no listing, the locked version not
  listed, a body that is not JSON) is planned from its archive instead, and a
  `git` package from its checkout.
- What each package version planned to is recorded as an extension fact in
  `MODULE.bazel.lock`, keyed by name, version, `sha256` and server, so a
  re-evaluation requests nothing for packages it already planned.
- A package repository's attributes are that package's own (its coordinates,
  the names planning used and its own dependency labels): changing one lock
  entry refetches that entry's repository only, or the merged repository of a
  dependency cycle it joins or leaves.

## Shipping a plan with a lock

A module that gives its users a lock (rules_dart's own `ext_pub_deps`, say)
would make every one of them plan it, one request per package on their first
evaluation. `pub.from_lock(plan = ...)` names a checked-in plan of the lock
instead: what planning records for each hosted package, written ahead of time.

```sh
bazel run @rules_dart//dart/pub/plan -- write --lock path/to/pubspec.lock --out path/to/pub_plan.json
```

`write` reads each package's listing, one request at a time and at most four a
second, so it needs the network: the lock's server, or a mirror given with
`--server <url>` (the plan keeps naming the lock's own server). Whoever changes
one of the rules' own locks (`//dart/ext:pubspec.lock`, rules_flutter's
`//tools/tool_deps:pubspec.lock` and `//flutter/private/gen_l10n:pubspec.lock`)
regenerates its plan in the same change; `pub_plan_test` fails until they do. A package the plan covers is planned with no request and
is not recorded in `MODULE.bazel.lock`; a package it does not cover (the lock
changed, the plan did not) is planned as without a plan. Its entries are hints
like facts: every repository still checks them against the real pubspec.
`pub_plan_test(name, locks = {lock: plan})` from
`@rules_dart//dart/pub/plan:defs.bzl` fails when a plan no longer plans exactly
its lock's hosted entries.

## Building another rule set's packages on the planner

`//dart/pub:pub_plan.bzl` gives another module extension the same three steps:
`plan_pub_graph` (facts, shipped plans, listings, archives), `plan_scope_sccs`
(dependency cycles) and `own_dep_labels` (one package's own labels). Its package
repositories start from `PUB_LOCK_PACKAGE_ATTRS` and `fetch_pub_lock_archive`
in `//dart/pub:pub_lock_package.bzl`, and its hub is `pub_lock_hub`, whose
`files` attribute carries what the rule set adds next to the aliases.
rules_flutter's `flutter.pub` is built this way.

# What a `pub.from_lock()` hub holds for `build_runner`

Besides one target per package, every `pub.from_lock()` hub has:

- `@<hub>//:package_graph.json`: the lock's package graph, in the shape of
  pub's `.dart_tool/package_graph.json`;
- `@<hub>//build_runner`: the runner `dart_build_runner` uses, compiled from
  the lock's `build_runner` and every package of the lock that defines
  builders. `@<hub>//build_runner:runner` is the runner binary and
  `@<hub>//build_runner:sdk_summary` its plain Dart SDK summary.

A lock without `build_runner`, or with one older than 2.8.0, still gets the
`build_runner` target: it fails with a message when a target uses it. See
[build_runner.md](build_runner.md).

# Runtime package files

A pub package is more than its `lib/`: `pubspec.yaml`, `LICENSE`, a `hook/`
script, an asset directory a pubspec declares. Every generated spoke puts
those on its `dart_library`'s `data`, so they reach the runfiles of every
`dart_binary`/`dart_test` that depends on the package — a consumer that walks
a dependency's package root, like Flutter's plugin discovery, finds them
without a downstream patch. The same files are in
`DartInfo.transitive_package_files`, beside the per-package
`DartInfo.package_files` record that names each package's root. They never
join `DefaultInfo.files`, `DartInfo.transitive_resources`, or an action, so
analysis and compilation are byte-identical to a build without them.

`pub.from_lock()` and `pub.package()` take `package_files` as a trailing
`string_list`:

```starlark
pub.from_lock(
    name = "pub_deps",
    lock = "//:pubspec.lock",
    # The default. It never matches lib/**, BUILD* or WORKSPACE*.
    package_files = ["pubspec.yaml", "LICENSE*"],
)
```

The default is deliberately small. Globbing every non-`lib/` directory
(`test/`, `example/`, `doc/`, `tool/`) across hundreds of spokes multiplies
every test's runfiles tree, so that is opt-in: pass a broader glob such as
`package_files = ["assets/**"]`. Pass `package_files = []` to opt out for a
package whose non-`lib/` files must stay out of the graph. The generated glob
always excludes `lib/**`, `BUILD*` and `WORKSPACE*`, and a `.dart` file in a
hand-written `dart_library`'s `data` is refused at analysis. rules_flutter's
`flutter.pub` keeps its own asset, font and shader targets; `package_files`
does not duplicate them.

The default's cost is one file per spoke, plus a `LICENSE` where the package
ships one. This module's own `ext_pub_deps` materialises 58 package
repositories, so a test that depends on them all gains about two runfiles
entries per spoke — under two hundred files — rather than the thousands a
`glob(["**"])` over `test/`, `example/`, `doc/` and `tool/` would add. That is
why the broad glob is opt-in, never the default.

# `pub` root-wins precedence

One version per package stays the rule, and the root module picks it. A
dependency's `pub.package()` never changes the root's resolved version.

The root module pins a package two ways:

- declaring it with its own `pub.package(name, version, ...)`, or
- reading a lock that lists it with `pub.from_lock()` (a non-isolated hub;
  isolated hubs keep their own namespaced versions and never pin the global
  one).

A root lock's git entry pins like a hosted one: every non-root
`pub.package()` for that package is dropped at any version — a hosted
declaration never matches a git pin, even at the pin's own version string —
and the package resolves to the git spoke, with the package-named repository
generated as an alias to it:

```text
NOTE: Pub package "path" uses 1.4.0 from git 1111111111111111111111111111111111111111 in //:pubspec.lock, not 1.9.0 declared by module "dep_a".
```

When the root pins a package and a non-root module's `pub.package()`
declares another version, the root's version is the one resolved: every hub
aliases the package to the root's repository, and a module that `use_repo`s
the package by its `pub.package()` name keeps loading against the root's
version. Evaluation prints an informational NOTE naming the package, the
root's version and where it came from (the root's `pub.package()`, or the
lock's label), and each overridden version with the module that declared
it:

```text
NOTE: Pub package "path" uses 1.9.1 from the root module's pub.package(), not 1.9.0 declared by module "dep_a".
```

A non-root declaration that agrees with the pin is silent. A non-root
declaration at the pin's version with a different sha256 is an integrity
conflict, not a choice: evaluation fails naming both values. A root pin
chooses only the version, never the hash: a dropped declaration still faces
every same-version sha256 check it would face without the pin, against every
other non-root declaration and every non-isolated lock entry at that version,
and fails with the same wording.

Under `on_version_conflict = "upgrade"` the resolved version can come from
another lock, and the NOTE names the version that actually resolves and the
lock it comes from, never the root lock's lower version:

```text
NOTE: Pub package "path" uses 1.9.1 from //:other.lock, not 1.9.0 declared by module "dep_a".
```

Whenever any module declares `pub.package()` for a package, the
package-named repository exists. A root `pub.package()` pin materializes it
directly. A root lock pin instead resolves the package through the locks,
and the package-named repository is generated as a thin alias to the lock
spoke `dart_pub__<name>` (or to the merged repository holding the whole
cycle, when the spoke merged away). The spoke stays the single
materialization: hubs alias it, the alias names it, and the package's
registry URL, archive hash and transitive dependencies all come from the
lock, which a second materialization could not reproduce.

Without a root pin, `pub.package()` behaves as before: the single
declaration applies, and disagreeing non-root declarations fail. Inside the
root nothing changes either: the root's own `pub.package()` still overrides
the root's own locks, disagreeing root declarations still fail, and the
root's own locks settle through the usual cross-lock rules first.

## What a lock may not contain

`pubspec_lock_error` fails closed on every shape below, naming the lock.
`parse_pubspec_lock` fails with that error, so an unreadable lock never
becomes a silently empty hub:

- Content after a `...` line fails, naming the content's 1-based line; so
  does content after a second `---`, while a bare second `---` fails naming
  the marker's own line. A `---` before any content stays allowed, and so
  does a final `...`. Blank and `#` comment lines do not count as content.
- A tab in a content line's indentation fails, naming the line. A tab after
  the indentation stays allowed.
- Text after a quoted scalar's closing quote fails, naming the line. A
  trailing `#` comment after the closing quote stays allowed.
- A package name pub could never write (anything but letters, digits and
  underscores, or starting with a digit) fails, naming the name. Two names
  equal ignoring case fail, naming both.
- A package entry without a `source` fails; it is an error, never only a
  warning. A non-string `source` fails too.
- A package entry without a `version` fails. A non-string `version` (an
  unquoted float such as `1.10`, an int such as `3`) fails naming the
  entry's line, never showing the re-spelled value. A string that is not a
  semantic version as pub writes it (`MAJOR.MINOR.PATCH` with optional
  `-prerelease` and `+build`) fails as well.
- Two locks that pin the same git package version at the same resolved ref
  but different `path` values fail, naming the package, both paths, and
  both locks' hub name and lock label, in either lock order. Locks that
  agree on URL, ref and path still deduplicate silently.

# Where each package comes from

`pub.from_lock()` serves every entry of a `pubspec.lock` from the place
`dart pub get` took it from when it wrote the lock. The lock is the input:
nothing is resolved again.

| Lock entry                                           | `dart pub get`                                                                 | `pub.from_lock()`                                                                                       | rules_flutter's `flutter.pub`                                                               |
| ---------------------------------------------------- | ------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------- |
| `source: hosted`, any server (`description.url`)     | downloads the archive the server lists                                         | a package repository; the archive comes from the listing's `archive_url`, pinned by the lock's `sha256` | the same                                                                                    |
| `hosted` on a server that needs a token              | sends the token `dart pub token add` stored                                    | the same requests, with the token from a credential helper (below)                                      | the same                                                                                    |
| `source: git` (`url`, `ref`, `path`, `resolved-ref`) | checks out `resolved-ref`; `path` is the package's directory in the repository | a package repository from the commit `resolved-ref` names, at `path`; `ref` (a branch, say) is not read | the same                                                                                    |
| `source: path` inside the module                     | reads the directory                                                            | the module's own `dart_library` `//<dir>:<name>`; the hub aliases it (below)                            | a package repository linking the directory's files                                          |
| `source: path` outside the module, or absolute       | reads the directory                                                            | fails the evaluation, naming the package and the path                                                   | the same                                                                                    |
| `source: sdk`                                        | takes the package from the Flutter SDK                                         | the hub's target fails when used, naming the package and `flutter.pub`                                  | the SDK's packages; `sky_engine` through the toolchain; any other name fails the evaluation |
| any other `source`                                   | —                                                                              | fails the evaluation, naming the package and the source                                                 | the same                                                                                    |

`dependency_overrides`, in `pubspec.yaml` or in `pubspec_overrides.yaml`, need
nothing of their own: `dart pub get` writes the overriding package into the
lock (`dependency: "direct overridden"`) with the override's source, and the
rules serve it like any entry of that source. A hosted package that depends on
an overridden package builds against the override: a path fork, a git branch
or another version.

## Path packages

A path package is source in the module that owns the lock, not a download.
Its directory (the lock's directory joined with the entry's `path`) needs a
BUILD file with a `dart_library` named after the package, as Gazelle writes
it:

```starlark
# forks/typed_data/BUILD.bazel
dart_library(
    name = "typed_data",
    srcs = glob(["lib/**/*.dart"]),
    visibility = ["//visibility:public"],
    deps = ["@pub_deps//:collection"],
)
```

`@pub_deps//:typed_data` is an alias of `//forks/typed_data:typed_data`, and
every package repository that depends on `typed_data` depends on that target.
No repository is generated for it, so an edit to the package is an ordinary
edit to the module. A directory without a BUILD file gets a hub target that
fails when used, saying what to add. A path outside the module (or an absolute
one) fails the evaluation: Bazel builds only what is inside the module, so
move the package into it (as a pub workspace member, say) or depend on it from
a server or a git repository. See `e2e/pub_sources`.

## Build hooks

A package that ships `hook/build.dart` gets it run as `dart build` runs it:
through the Dart SDK's own `package:hooks_runner`, once per package and
target platform, in a sandboxed action with the C toolchain Bazel resolved for
that platform. The code assets it reports reach every `dart_binary` and
`dart_test` that depends on the package, as they would in a stock build, and
nothing names them in a BUILD file. A package's `hook/link.dart` runs where an
app links (`dart_link_hook`).

The hook sees only its package's own files, the Dart sources of its
dependencies and the C toolchain. Three things on the lock tag
(`pub.from_lock`, and `flutter.pub` in rules_flutter) widen that:

- **User defines.** `hooks: user_defines: <package>:` in the `pubspec.yaml`
  next to the lock, as in a stock build. Each hook gets only its own
  package's slice, so editing anything else in the pubspec reruns no hook.
  Relative paths in a define resolve against that pubspec's directory, as in
  a stock build; a file Bazel provides is under `external/<repo>/` there.
- **`hook_data`**: files outside the package that a hook reads, each mapped
  to the package, such as the source file a user define names:
  `hook_data = {"@sqlite3//:sqlite3.c": "sqlite3"}`.
- **`hook_network`**: packages whose hook may use the network. A hook runs
  offline (`block-network`) by default, and one that downloads fails with a
  message naming the package. Listing it gives that one action the network
  (`requires-network`) and nothing else. What it downloads is then neither
  pinned nor cached by content: the action's key is its inputs, so a changed
  download upstream does not rerun it, and a fresh machine or a cache miss
  fetches whatever is there now. The build is only as reproducible as the
  hook's own checks make it; prefer a user define that builds from source.

For example, `package:sqlite3` 3.x downloads a prebuilt library unless told
otherwise:

```yaml
# pubspec.yaml
hooks:
  user_defines:
    sqlite3:
      source: source
      path: external/sqlite3+/sqlite3.c
```

```starlark
# MODULE.bazel
bazel_dep(name = "sqlite3", version = "3.53.4")
pub.from_lock(
    name = "pub_deps",
    hook_data = {"@sqlite3//:sqlite3.c": "sqlite3"},
    lock = "//:pubspec.lock",
)
```

A hand-written `dart_library` sets `build_hook`, `hook_srcs` (the files its
hook reads, at least the hook) and, as needed, `hook_data`,
`hook_user_defines` and `hook_network`. A native library Bazel builds itself
is bound with `dart_code_asset` instead.

On Windows, with Bazel's MSVC toolchain (or clang-cl), a hook gets the
toolchain's `cl.exe`, `link.exe` and `lib.exe` as they are, and as its
Developer Command Prompt (`c_compiler.windows.developer_command_prompt`) a
generated script that sets the `INCLUDE`, `LIB` and `PATH` Bazel gives its
own compile and link actions; `package:native_toolchain_c` runs it once per
hook. A toolchain without those variables gets no script, and the hook runs
the `vcvars` script of the Visual Studio its `cl.exe` belongs to.

What does not work: a hook that needs a tool the C toolchain does not have
(CMake, `cargo`) fails in its own action, naming it; hooks get no assets from
other hooks' outputs (`assetsForBuild`); and a package inside a merged pub
dependency cycle cannot run its hook, which fails any binary that reaches it.

With `hermetic_cc_toolchain` (zig), every hook action rebuilds zig's libc
cache in its own sandbox, about 6 to 10 seconds per hook. Give zig a cache that
outlives the sandbox:

```
# .bazelrc
build --repo_env=HERMETIC_CC_TOOLCHAIN_CACHE_PREFIX=/path/to/zig-cache
build --sandbox_writable_path=/path/to/zig-cache
```

A small C hook then takes about 0.2 seconds, as it does with an LLVM toolchain.
The cache is zig's own, keyed by content, and it does not reach the outputs.

### Apple targets (macOS, iOS)

Build hooks do not run for macOS or iOS yet: nothing has run them on macOS CI.
There a package's hook action fails, naming the package and saying that build
hooks are not yet supported on Apple targets. Three packages keep the Bazel
replacement that served them before, on Apple OSes only, so an app that uses
them builds as it did: `sqlite3` (≥ 2.0.0, `//dart/ext/sqlite3`, the BCR
`sqlite3` module), `webcrypto` (0.6.1, `//dart/ext/webcrypto`) and, in
rules_flutter, `objective_c` 9.x (`ext/objective_c`). Their spokes select the
package's hook off and the replacement's `dart_code_asset` in on Apple OSes
(`//dart/private:apple_hook_replacements.bzl`). This goes when build hooks are
proven on macOS CI.

### Migrating from `ignore_hooks` and the curated code assets

`pub.from_lock(ignore_hooks = ...)`, `flutter.pub(ignore_hooks = ...)` and
`//dart/ext:registry.bzl` are removed, and the curated `//dart/ext/sqlite3` and
`//dart/ext/webcrypto` assets serve Apple targets only (above). Drop
`ignore_hooks`: the hooks now run.
A package whose hook downloads needs a user define or `hook_network`.

A `drift` or `sqlite3` user (any lock with `sqlite3` 3.x, which is what
`drift` resolves to) compiles SQLite from source, with no network at build
time. Add to the `pubspec.yaml` next to the lock (`path` is relative to that
file's directory: `external/sqlite3+/sqlite3.c` beside a root lock,
`../external/sqlite3+/sqlite3.c` for a lock in `app/`, as in
`e2e/gazelle`):

```yaml
hooks:
  user_defines:
    sqlite3:
      source: source
      path: external/sqlite3+/sqlite3.c
```

and to `MODULE.bazel`, on the `pub.from_lock` (or `flutter.pub`) tag of that
lock:

```starlark
bazel_dep(name = "sqlite3", version = "3.53.4")

pub.from_lock(
    name = "pub_deps",
    hook_data = {"@sqlite3//:sqlite3.c": "sqlite3"},
    lock = "//:pubspec.lock",
)
```

This replaces the curated asset. `hook_network = ["sqlite3"]` on the tag also
builds, but downloads a prebuilt library Bazel does not pin; use it only where
no amalgamation can be provided. A stock `dart test` outside
Bazel does not have `external/`; there, drop the define or point `path` at a
local amalgamation.
`webcrypto` builds
with CMake, which no C toolchain provides, so it needs `hook_network` and a
CMake on the hook's `PATH`, or a stock build.

## Private servers and tokens

A hosted package's server is its lock entry's `description.url`: pub.dev, or
any server that implements the hosted pub API (with or without a path, such
as `https://pub.example.com/repo/dart/`). Every request goes to that server;
nothing else is configured for it.

When the server needs a token, `dart pub get` sends the one
`dart pub token add <server>` stored in the user's home. A build does not read
the user's home. Bazel's downloader asks a
[credential helper](https://github.com/EngFlow/credential-helper-spec) for the
headers of every request it sends, so give the token to Bazel that way:

```
# .bazelrc.user (not checked in), or .bazelrc with a helper every developer has
common --credential_helper=pub.example.com=%workspace%/tools/pub_credentials
```

The helper is any executable that answers `get` with the header, for example:

```sh
#!/bin/sh
# tools/pub_credentials: the token comes from the environment of `bazel`.
[ "$1" = get ] || exit 1
cat > /dev/null
printf '{"headers":{"Authorization":["Bearer %s"]}}\n' "$PUB_EXAMPLE_TOKEN"
```

Both requests planning sends (the listing and, when the server cannot answer
for a version, the archive) and every archive a package repository fetches go
through it. Bazel records nothing the helper prints: the token is in no
lockfile, fact, repository attribute or log. An archive already in the
repository cache is found by its `sha256` and needs no request at all.

Without the token the server answers 401 and the evaluation (or, when the
plan is already in `MODULE.bazel.lock`, the package's repository) fails after
Bazel's own WARNING line with the status:

```text
pub package "t38_secret" 1.0.0: could not download the server's listing https://pub.example.com/repo/dart/api/packages/t38_secret or its archive https://pub.example.com/repo/dart/packages/t38_secret/versions/1.0.0.tar.gz (Bazel's WARNING above says why). If the server needs a token (`dart pub token add`), give it to Bazel with a credential helper for its host: `--credential_helper=pub.example.com=<helper>` in .bazelrc (see docs/pub.md, Private servers). ...
```

A server on plain `http://` works, more slowly: Bazel sends no unchecksummed
request over plain HTTP, so planning reads each package's archive (pinned by
the lock's `sha256`) instead of its listing.

# Workspaces

A Dart pub workspace is a root `pubspec.yaml` with a `workspace:` list of
member directories and one root `pubspec.lock`. Each member's `pubspec.yaml`
says `resolution: workspace` and has no lock of its own. Give the root lock to
`pub.from_lock` and list the members' pubspec files in `workspace_members`:

```starlark
pub.from_lock(
    name = "pub_deps",
    lock = "//:pubspec.lock",
    workspace_members = ["//a:pubspec.yaml", "//b:pubspec.yaml"],
)
```

With `workspace_members` empty (the default) nothing is checked and the lock
is read as before. When it is set, the extension checks at fetch time that:

- the root pubspec is the `pubspec.yaml` in the lock file's own directory (the
  label's package joined with the directory part of its name, so a lock
  `//:app/pubspec.lock` has the root `app/pubspec.yaml`), and that directory is
  what member directories are relative to. It has a `workspace:` list, and each
  member's directory is listed. A member label's directory is its package
  joined with the directory part of its name, and must lie inside the root's
  directory;
- a `workspace:` entry matches a member directory after `.` and empty segments
  are dropped (`pkgs/./a`, `./pkgs/b/`). `*` and `?` match within one segment
  and a `**` segment matches any number of segments (`pkgs/*`, `pkgs/**`,
  `pkgs/?`). An entry with `[` or `{` fails the check with a message naming
  the entry and saying the form is not supported: the check cannot judge it;
- a member whose own pubspec has a `workspace:` list contributes its entries,
  relative to its directory, to the listed set, recursively, so a member listed
  only that way passes;
- a `pubspec_overrides.yaml` next to a pubspec (the root's or a member's) is
  read when it exists, and its top-level keys replace those of that pubspec
  before any check, `workspace:` and `resolution:` included;
- each member's `pubspec.yaml` says `resolution: workspace`;
- no member's `name:` is a package in the lock or declared with
  `pub.package()`: a member name never resolves to a hosted or git package.

A violation fails the extension with `pub.from_lock "<hub>": member <label>:
<reason>`. The reason is one of: missing `resolution: workspace`,
`resolution:` set to another value, directory not listed in the root's
`workspace:`, no `workspace:` in the root pubspec, label outside the root's
directory, or the name clash. The message names only the failing member. An
unsupported `[` / `{` entry fails without a member prefix: the message names
the entry and the pubspec that lists it.

Members are ordinary Bazel packages, and so is the root when it is a package
itself. A member is not in the lock (pub resolves it as source), so it depends
on a sibling member through a `dart_library` label (`//a`), not through the
hub, and on locked packages through the hub (`@pub_deps//:path`). Each
member's BUILD file is the same as any package's: a `dart_library` named after
the package, with those deps. One lock is one hub: adding a dependency to one
member (and running `dart pub get`) fetches that package's repository and
regenerates the hub, and nothing else. See `e2e/pub_workspace`, three members
and a root package.
