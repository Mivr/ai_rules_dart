"""Resolves the canonical Bazel repo name of `//tools/dev_tool` at load
time.

The dev_tool's runfiles_helper passes this value to `Runfiles.create` so
apparent → canonical translations against `_repo_mapping` resolve from
this binary's own perspective. Under bzlmod the canonical name is `_main`
when ai_rules_flutter is the main module, `ai_rules_flutter+` when it ships as
a dep — `Label(...).workspace_name` returns whichever applies.

Lives in its own `.bzl` because `Label` is only callable from Starlark
files, not directly from BUILD files.
"""

visibility(["//tools/dev_tool/..."])

SOURCE_REPO = Label("//tools/dev_tool:flutter_bazel").workspace_name
