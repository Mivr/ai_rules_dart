# Bazel rules for Dart and Flutter

This repository holds two Bazel modules, side by side:

| Directory | Module | What it is |
|---|---|---|
| [`rules_dart/`](rules_dart/README.md) | `ai_rules_dart` (`@rules_dart`) | Rules for Dart libraries, binaries, tests, pub packages, analysis and code generation |
| [`rules_flutter/`](rules_flutter/README.md) | `ai_rules_flutter` (`@rules_flutter`) | Rules for Flutter apps on Android, iOS, macOS, Linux, Windows and web, built on `rules_dart` |

Each directory is a Bazel workspace of its own, with its own `MODULE.bazel`, `.bazelversion`, `.bazelrc`, tests
and e2e workspaces: run Bazel from inside it. `rules_flutter` and its e2e workspaces take `ai_rules_dart` from
the sibling `rules_dart/` directory through `local_path_override`, so both modules always build from the same
commit.

The GitHub workflows of both modules live in `.github/workflows/`, named `dart-*.yaml` and `flutter-*.yaml`.
Each module's `AGENTS.md` and `CONTRIBUTING.md` describe how to work in it.

Each module is released on its own tag line (`rules_dart-v<version>`, `rules_flutter-v<version>`) from this
repository, with its own archive, notes and registry entry; [RELEASING.md](RELEASING.md) has the steps and what is
switched off until the owner turns it on.

Both modules are licensed under the Apache License 2.0; see [LICENSE](LICENSE).
