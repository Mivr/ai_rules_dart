"""The canonical name of the repository `flutter_dev` is built in.

The tool names the rules' aspect by it on the `bazel build` command line, so it
works whatever name the user's workspace gives the rules. `Label` is callable
only from a `.bzl` file.
"""

visibility(["//tools/flutter_dev/..."])

RULES_FLUTTER_REPO = Label("//flutter:dev_files.bzl").repo_name
