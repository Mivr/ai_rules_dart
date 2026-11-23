# Architecture decision records

Accepted decisions of rules_dart, seeded from the Design Decisions and the
provider contract in [ARCHITECTURE.md](../ARCHITECTURE.md) and from
[`ai-docs/performance/decisions.md`](../../ai-docs/performance/decisions.md).

| ADR                                                                  | Records                                                                                                                       |
| -------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| [0001](0001-platform-neutral-dartinfo-built-through-constructors.md) | Provider Design: platform-neutral `DartInfo`, built only through `dart_info()`, `dart_info_no_package()`, `dart_info_multi()` |
| [0002](0002-dartinfo-means-valid-as-a-dep.md)                        | Provider Design: `DartInfo` vs `DartAnalyzableInfo`                                                                           |
| [0003](0003-bazel-9-and-bzlmod-only.md)                              | Design Decision 1                                                                                                             |
| [0004](0004-host-and-cross-only-platforms.md)                        | Design Decision 2                                                                                                             |
| [0005](0005-compilation-modes-and-modular-kernels.md)                | Design Decision 3                                                                                                             |
| [0006](0006-pub-from-lock-hosted-and-git-packages.md)                | Design Decision 4                                                                                                             |
| [0007](0007-gazelle-plugin-in-the-core-module.md)                    | Design Decision 5                                                                                                             |
| [0008](0008-bazel-native-code-generation.md)                         | Design Decision 6                                                                                                             |
| [0009](0009-analysis-and-format-check-as-an-aspect.md)               | Design Decision 7                                                                                                             |
| [0010](0010-source-rewriting-through-run-targets.md)                 | Design Decision 8                                                                                                             |
| [0011](0011-test-runner-speaks-the-bazel-test-protocol.md)           | Design Decision 9                                                                                                             |
| [0012](0012-recorded-uses-and-link-hooks.md)                         | Design Decision 10                                                                                                            |
| [0013](0013-fail-closed-app-jit-training.md)                         | Design Decision 11                                                                                                            |
| [0014](0014-sdk-subset-in-test-runfiles.md)                          | Performance decision: SDK subset in test runfiles                                                                             |

Each ADR is `NNNN-<lowercase-slug>.md` and opens with YAML front matter
carrying `status` (`accepted`, `superseded` or `deprecated`). An accepted ADR
also carries either `enforced_by: [<metric ids>]`, naming only gate metrics
that check the decision, or `unenforceable: "<specific reason>"` when no gate
metric does. The provider invariants of ADRs 0001 and 0002 are also asserted
by `//dart/tests:architecture_invariants_test`.
