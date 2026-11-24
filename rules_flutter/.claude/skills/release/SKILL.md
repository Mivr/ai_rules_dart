---
name: release
description: Drive a release of rules_flutter, which comes after the release of rules_dart whose floor it names, from this repository - check the proofs, choose and confirm the version, tag through the workflow, check the GitHub release, open the registry pull request when the owner says so. Use when the user asks to cut, ship, publish or release a new rules_dart or rules_flutter version.
---

# Release a module of this repository

`RELEASING.md` at the repository root is the run book: read it first and follow it. This skill only says how to
drive it with the user in the loop.

- **The owner decides** the version number, the merge to `main`, whether the registry pull request is opened,
  and whether `RELEASES_ENABLED` is turned on. Ask; never assume. Never push a tag by hand.
- **Order:** `rules_dart` first, then the floor commit (`cd rules_dart/tools && bazel run //release:release -- floor
  set X.Y.Z`), then `rules_flutter`.
- **Version:** `bazel run //release:release -- next --module=rules_dart --to=<sha> --published=<file>` suggests
  one from the commits that touch the module (a `feat` or `!` bumps the minor); preview the notes with
  `bazel run //changelog:changelog -- --tag rules_dart-vX.Y.Z`. Show both to the user and get the number
  confirmed.
- **Proofs:** the gate reads `Dart CI` and `Dart Full matrix` (`Flutter CI`, `Flutter Full`) on the commit; read
  them yourself first with `gh run list --workflow <file> --commit <sha>`, and the macOS and Windows jobs by eye.
- **Dispatch** `gh workflow run dart-tag.yaml --ref main -f version=vX.Y.Z` (`flutter-tag.yaml` for
  rules_flutter), watch the run, check the GitHub release (two archives, attestations, notes) and paste its
  `archive_override` block into a clean consumer.
- **Registry:** only when the owner says so: `gh workflow run dart-publish.yaml -f tag_name=rules_dart-vX.Y.Z`, then
  the registry pull request: mark it ready, wait for presubmit, and prove a clean consumer resolves the version
  (a merged pull request is not a served module; do not probe `bcr.bazel.build` for the module before the merge,
  the CDN caches a 404 for an hour). A publish job that fails with `Invalid username or token` is the expired
  `BCR_PUBLISH_TOKEN` (classic token, `repo` and `workflow` scopes), not the release: the release is done, only
  the registry half is missing. A registry presubmit that fails in seconds on `github_user_id` is the
  `metadata.json` of the template, which pins the maintainer's id, and any difference outside the `versions` array
  of `metadata.json` (a key order too) asks for a manual review.
- **Stop or undo** with the table in `RELEASING.md`. Do not power through a failed gate or a failed step: stop and
  tell the user.
