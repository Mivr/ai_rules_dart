"""The providers a `package:test` runner target carries.

Kept in a leaf file so `//dart:providers.bzl` can re-export them: the rule file
that builds them (`dart_test_runner.bzl`) itself loads `//dart:providers.bzl`.
"""

visibility(["//dart/..."])

DartTestRunnerInfo = provider(
    doc = "The `package:test` runner built from a `package:test` library.",
    fields = {
        "runner": "File: the runner the launcher runs — its kernel (`.dill`), or the app-JIT snapshot of it where one was built.",
        "sdk_version": "str: The Dart SDK version that compiled `runner` when it is a kernel, or empty.",
    },
)

DartTestRunnerSnapshotInfo = provider(
    doc = "The app-JIT snapshot of a `package:test` runner, or `None` where it cannot be built.",
    fields = {
        "snapshot": "File or None: the snapshot, written by the exec SDK's `dart`.",
    },
)
