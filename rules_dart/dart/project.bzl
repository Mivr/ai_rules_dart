"""The macro side of the project index, for a rule set whose macros give its targets the same defaults.

Public facade of `//dart/private:project_defaults.bzl`, which `//dart:defs.bzl`
uses with `@dart_projects`. The repository side is `//dart/pub:project.bzl`.
"""

load(
    "//dart/private:project_defaults.bzl",
    _add_project_files = "add_project_files",
    _project_test_files = "project_test_files",
)

visibility("public")

add_project_files = _add_project_files
project_test_files = _project_test_files
