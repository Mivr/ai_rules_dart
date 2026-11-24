---
status: accepted
unenforceable: "No registered gate metric checks how dart_test maps Bazel's filter, sharding, XML and timeout protocol onto package:test"
---

# 0011. `dart_test` runs `package:test` under its own runner, speaking Bazel's test protocol

Source: `docs/ARCHITECTURE.md`, Design Decision 9.

## Context

Bazel defines how a test framework honours `--test_filter`
(`TESTBRIDGE_TEST_ONLY`), sharding (`TEST_TOTAL_SHARDS`, `TEST_SHARD_INDEX`,
`TEST_SHARD_STATUS_FILE`), per-case results (`XML_OUTPUT_FILE`) and time
limits (`size`/`timeout`). A `package:test` file run directly implements none
of that and applies its own 30-second per-case timeout. The runner and the
test talk over a protocol private to one `package:test` version.

## Decision

- Where Bazel defines a behaviour, Bazel's wins.
- `dart_test` runs a `package:test` test under `package:test`'s runner with
  `--precompiled`: the test is compiled at build time from a generated
  bootstrap, and the launcher translates Bazel's variables into runner flags,
  passes `--timeout=none`, and converts the runner's JSON report into JUnit
  XML.
- The runner is built from the user's own `package:test` (`test_runner`, a
  kernel-mode `dart_binary`), once, in that package's pub spoke, and
  `dart_test` takes it from its direct deps (`DartTestRunnerInfo`).
- A test without `package:test` runs directly and refuses a filter or shards.

## Alternatives ruled out

- Running `package:test` files directly, which ignores Bazel's filter,
  shards, XML and timeout.
- A runner pinned by rules_dart, which could speak a different private
  protocol than the user's `package:test`.
- Silently ignoring a filter or shard request for a test that cannot honour
  it.

## Consequences

- `bazel test --test_filter` and sharding select real cases, and per-case
  results appear in Bazel's XML.
- Each `package:test` version gets its own runner build.
- `//dart:test_runner_snapshot` trains the runner into an app-JIT snapshot,
  under the fail-closed rules of ADR 0013.
