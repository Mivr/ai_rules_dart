"""Bazel-built replacements for a few packages' build hooks, on Apple targets only.

Build hooks run through the SDK's hook runner on Linux, Android and Windows.
On macOS and iOS they are not proven yet (no macOS CI has run them), so there
a package's hook action fails, naming it, and the packages below keep the
Bazel replacement that served them before: the spoke selects its hook off and
this `dart_code_asset` in, on Apple OSes only. rules_flutter's
`ext/objective_c` overlay does the same for `objective_c`.

Goes when build hooks are proven on macOS CI.

Entries are version-bounded because an asset id is a path inside a particular
version of a package. `min_version` is inclusive, `max_version` exclusive;
either may be empty for an open bound.
"""

load("//dart/private:versions.bzl", "parse_semver")

visibility(["//dart/..."])

# The OS constraints a replacement applies to.
APPLE_OS_CONSTRAINTS = ["@platforms//os:macos", "@platforms//os:ios"]

_ENTRIES = {
    "sqlite3": [
        struct(
            min_version = "2.0.0",
            max_version = "",
            labels = ["@rules_dart//dart/ext/sqlite3:code_asset"],
        ),
    ],
    "webcrypto": [
        struct(
            min_version = "0.6.1",
            max_version = "0.6.2",
            labels = ["@rules_dart//dart/ext/webcrypto:code_asset"],
        ),
    ],
}

def apple_hook_replacement(package_name, version):
    """The `dart_code_asset` labels that replace a package's build hook on Apple OSes.

    Args:
      package_name: The pub package name.
      version: The version resolved from the lock, or "".

    Returns:
      List of label strings; empty when nothing replaces this package's hook.
    """
    entries = _ENTRIES.get(package_name)
    if not entries or not version:
        return []
    parsed = parse_semver(version)
    for entry in entries:
        if entry.min_version and parsed < parse_semver(entry.min_version):
            continue
        if entry.max_version and parsed >= parse_semver(entry.max_version):
            continue
        return list(entry.labels)
    return []
