---
status: accepted
unenforceable: "No registered gate metric checks pub source support, archive scanning or git materialization; unit and e2e tests cover them"
---

# 0006. `pub.from_lock` resolves hosted and git packages, pinned and scanned

Source: `docs/ARCHITECTURE.md`, Design Decision 4.

## Context

`pub.from_lock` turns a `pubspec.lock` into Bazel repositories. Every package
it fetches is untrusted input, a git package is pinned by a commit rather than
an archive checksum, and a lock's pubspec graph may contain cycles that a
Bazel target graph cannot.

## Decision

- `hosted` and `git` packages are resolved. Any other source (`path`, `sdk`,
  ...) is skipped with one warning per lock, grouped by source.
- A `git` package is pinned by its lock file's `resolved-ref`; a `hosted`
  package by its `sha256`.
- Before extraction every fetch site scans the archive headers with
  `dart_pub_scanner` and refuses hard links, absolute or escaping symlinks,
  and entries whose own path is absolute or climbs out of the package root; a
  post-extraction walk stays behind it.
- A dependency cycle in the lock is merged into one multi-package
  `dart_library`. Planning caches each package's pubspec dependency names as
  facts in `MODULE.bazel.lock`, as hints that each fetched spoke verifies
  against its real pubspec.
- A `git` package is materialized from a fresh bare repository with a pinned
  git environment and streamed with `git archive`, so its bytes depend only on
  the pinned commit and the package's committed content.

## Alternatives ruled out

- Creating repositories for `path` or `sdk` packages.
- Extracting first and checking links afterwards only, which lets a hostile
  archive's links reach the file system.
- One library per package in a cycle, which would cycle in the target graph.
- A `git` checkout through host git configuration, templates, hooks or
  attributes.

## Consequences

- A package whose recorded dependency names differ from its real pubspec
  fails its fetch with the recovery steps, instead of failing analysis later.
- Wrong facts are recovered by removing the extension's entries from
  `MODULE.bazel.lock` and the copy in the output base, as the architecture
  document describes.
- A change to the git materialization must keep the bytes a pure function of
  the pinned commit on every host and OS.
