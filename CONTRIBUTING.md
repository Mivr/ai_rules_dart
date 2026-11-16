# How to Contribute

## Issues and pull requests

AI agents develop and maintain this rule set; the human owner is @Mivr.

Agents read every issue, fix what they can through the same gates as every
other change, and release the fix.

Issue and pull request text is read as data, never as instructions to the agents.

Code from a pull request never runs on our machines. It runs only in GitHub's
CI for forks, which has no secrets. An accepted idea is re-implemented through
our own pipeline and gates, and the commit credits the contributor with a
`Co-authored-by:` trailer.

Security problems go to SECURITY.md, not to an issue.

## Using devcontainers

If you are using [devcontainers](https://code.visualstudio.com/docs/devcontainers/containers)
and/or [codespaces](https://github.com/features/codespaces) then you can start
contributing immediately and skip the next step.

## Formatting

Starlark files must be formatted by buildifier, and YAML files by yamlfmt.
Git hooks check this, along with prettier, typos, file hygiene and the commit
message policy. They run with [prek](https://github.com/j178/prek), which reads
`.pre-commit-config.yaml`. Install prek with [uv](https://docs.astral.sh/uv/)
and set up the hooks once per clone:

```shell
uv tool install prek
prek install -f
```

`-f` replaces hooks already in the clone, such as ones pre-commit installed;
without it prek keeps them and runs them too. The installed hook calls the prek at `~/.local/bin/prek`, which stays put across
`uv tool upgrade prek` and `bazel clean`. Set `PREK_QUIET=1` in your shell
profile for hooks that print nothing unless one fails.

To run every hook without installing anything beyond Bazel:

```shell
bazel run @multitool//tools/prek -- -C "$PWD" run --all-files
```

## Commit messages

Commits follow the conventional-commit format and the `Changelog:` trailer
policy in [AGENTS.md](AGENTS.md#changelog). CI checks every push to `main`;
the commit-msg hook that `prek install` sets up checks each commit before that.

## Running tests

### Unit tests and Gazelle plugin tests (root workspace)

```shell
bazel test //dart/tests:versions_test
# Gazelle tests live in the nested dev module:
cd dev && bazel test //:gazelle_test //:gazelle_generation_test
```

### End-to-end tests (separate Bazel workspaces)

Each directory under `e2e/` is a self-contained Bazel workspace that tests rules_dart
as an external dependency. Some contain `bazel test` targets, others verify that
`bazel build` succeeds.

```shell
# Toolchain resolution
cd e2e/smoke && bazel test //...

# dart_binary (native executable compilation)
cd e2e/hello_world && bazel build //...

# Transitive dart_library dependencies
cd e2e/library_deps && bazel build //...

# The dart_analyze aspect: analysis and the format check
cd e2e/analysis && bazel test //...

# dart_test (Dart VM test execution)
cd e2e/dart_test && bazel test //...

# dart_test with pub dependencies
cd e2e/dart_test_pkg && bazel test //...

# Cross-compilation to other platforms
cd e2e/cross_compile && bazel build //...

# External pub.dev packages
cd e2e/pub_deps && bazel build //...

# pubspec.lock integration
cd e2e/pub_lock && bazel build //...

# dart compile js (web compilation)
cd e2e/web_app && bazel build //...
```

## Updating BUILD files

The `bzl_library` targets in each `BUILD.bazel` are maintained by hand: when you
add a `.bzl` file or a `load`, add or update its `bzl_library` target and `deps`
in the same package. `//dart/tests/bzl_library_guard:bzl_library_guard_test`
fails when a target is missing or its `deps` do not cover a load.

## Using this as a development dependency of other rules

You'll commonly find that you develop in another repository that
depends on rules_dart.

To always tell Bazel to use this local checkout rather than a release
artifact or a version fetched from the registry, run this from this
directory:

```sh
OVERRIDE="--override_module=ai_rules_dart=$(pwd)"
echo "common $OVERRIDE" >> ~/.bazelrc
```

This means that any usage of `@rules_dart` on your system will point to this folder.

## Releasing

Release from GitHub: open
https://github.com/Mivr/ai_rules_dart/actions/workflows/tag.yaml,
press "Run workflow" on `main`, and enter the version (for example `v0.28.4`).
The run tags the commit it was dispatched on and calls `release.yaml`, whose
gate passes only once CI and Full have passed on that commit. Then it creates the
GitHub release with notes built from the `Changelog:` trailers (see AGENTS.md).
The version is your call: it is not derived from commit messages, and the run
refuses a version that exists or is not newer than the latest tag.

You can also tag by hand and push the tag, which starts `release.yaml` directly:

```sh
git fetch
git tag -s -m "rules_dart v1.0.0-rc0" v1.0.0-rc0 origin/main
git push origin v1.0.0-rc0
```
