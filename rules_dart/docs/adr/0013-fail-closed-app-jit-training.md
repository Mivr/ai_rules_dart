---
status: accepted
unenforceable: "No registered gate metric exercises app-JIT training paths, their locks or the fallback flag; the jit lock and fallback tests do"
---

# 0013. App-JIT training is fail-closed

Source: `docs/ARCHITECTURE.md`, Design Decision 11;
`ai-docs/performance/decisions.md` ("Reproducibility is a hard requirement").

## Context

An app-JIT snapshot records the path it was trained at. Training under the
build's output root or sandbox makes the bytes depend on where the build ran,
and reproducibility is a hard requirement for every compiled output.

## Decision

- `dart_binary(compile_mode = "jit-snapshot")` and the test-runner snapshot
  train at a keyed absolute path, `/tmp/rules_dart_jit-<key>`, where `<key>`
  is 16 lowercase hex characters of a deterministic digest of the output's
  root-relative path, serialized by `/tmp/rules_dart_jit-<key>.lock`.
- A stale entry of ours at that path is removed unread and unfollowed before
  an atomic `mkdir(0700)` claim. Anything still unusable fails the action with
  the blocker's path, entry type, owner uid and remedies.
- The lock opens append-only for every user; a lock that will not open for
  writing, or one held past `--@rules_dart//dart:jit_snapshot_lock_timeout`
  seconds (default 300), fails the action.
- `--@rules_dart//dart:jit_snapshot_fallback=true` opts into a
  non-reproducible private-scratch fallback under a different action key, and
  both snapshot actions then carry `no-cache`.

## Alternatives ruled out

- Training in the sandbox or output root, which names them in the bytes.
- Silently training somewhere else when the keyed path is blocked, which would
  produce different bytes under the same action key.
- A shared lock, which would let a second training delete the first's live
  training directory.

## Consequences

- Two different targets train in parallel; only concurrent trainings of one
  output contend.
- A fallback-trained snapshot stays cached under the same action key until
  `bazel clean`, and is never uploaded to or served from a disk or remote
  cache.
- `--@rules_dart//dart:test_runner_snapshot=false` skips the runner snapshot.
