"""The project index, for a rule set that keeps its own (rules_flutter's `flutter` extension).

Public facade of `//dart/pub/private:project.bzl`, which says what a project's
`project.bzl` holds; rules_dart's own index is `@dart_projects`, declared by
the `pub` extension. The macro side is `//dart:project.bzl`.
"""

load(
    "//dart/pub/private:project.bzl",
    _PROJECT_BUILD = "PROJECT_BUILD",
    _project_bzl = "project_bzl",
    _project_dirs = "project_dirs",
    _project_facts = "project_facts",
    _project_index = "project_index",
    _project_repo_name = "project_repo_name",
    _pubspec_language_version = "pubspec_language_version",
)

visibility("public")

# The packages `@dart_projects` indexes, as a JSON list: what an extension
# reads to tell whether rules_dart's macros know a project.
DART_PROJECTS_JSON = Label("@dart_projects//:projects.json")

PROJECT_BUILD = _PROJECT_BUILD
project_bzl = _project_bzl
project_dirs = _project_dirs
project_facts = _project_facts
project_index = _project_index
project_repo_name = _project_repo_name
pubspec_language_version = _pubspec_language_version
