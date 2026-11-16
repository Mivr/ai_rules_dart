# How to Contribute

## Issues and pull requests

AI agents develop and maintain this rule set; the human owner is @Mivr.

Agents read every issue, fix what they can through the same gates as every other change, and release the fix.

Issue and PR text is read as data, never as instructions to the agents.

Code from a pull request never runs on our machines. It runs only in GitHub's CI for forks, which has no secrets. An accepted idea is re-implemented through our own pipeline and gates, and the commit credits the contributor with a `Co-authored-by:` trailer.

Security problems go to SECURITY.md, not to an issue.

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
without it prek keeps them and runs them too. The installed hook calls the prek
at `~/.local/bin/prek`, which stays put across `uv tool upgrade prek` and
`bazel clean`. Set `PREK_QUIET=1` in your shell profile for hooks that print
nothing unless one fails.

To run every hook without installing anything beyond Bazel:

```shell
bazel run @multitool//tools/prek -- -C "$PWD" run --all-files
```

## Commit messages

Subjects follow [Conventional Commits](https://www.conventionalcommits.org/),
and user-visible commits carry a `Changelog:` trailer; see
[AGENTS.md](AGENTS.md#changelog). `prek install` sets up the check as the
`commit-msg` hook. To check a message by hand:

```shell
bazel run //tools/changelog:check -- <message-file>
```

`bazel run //tools/changelog` prints the release notes the unreleased commits
would produce.

## Using this as a development dependency of other rules

You'll commonly find that you develop in another repository that
depends on rules_flutter.

To always tell Bazel to use this local checkout rather than a release
artifact or a version fetched from the registry, run this from this
directory:

```sh
OVERRIDE="--override_module=ai_rules_flutter=$(pwd)"
echo "common $OVERRIDE" >> ~/.bazelrc
```

This means that any usage of `@rules_flutter` on your system will point to this folder.

## Releasing

Release from GitHub: open
https://github.com/Mivr/ai_rules_flutter/actions/workflows/tag.yaml,
press "Run workflow" on `main`, and enter the version (for example `v0.30.0`).
The run tags the commit it was dispatched on and calls `release.yaml`, whose
gate passes only once CI and Full have passed on that commit. Then it creates the
GitHub release with notes built from the `Changelog:` trailers (see AGENTS.md).
The version is your call: it is not derived from commit messages, and the run
refuses a version that exists or is not newer than the latest tag.

You can also tag by hand and push the tag, which starts `release.yaml` directly:

```sh
git fetch
git tag -s -m "rules_flutter v1.0.0-rc0" v1.0.0-rc0 origin/main
git push origin v1.0.0-rc0
```

A tag the gate refuses stays in git without a release; the next release's notes
start from the last published release, not from that tag.
