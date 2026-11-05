"""The table behind the curated code-asset registry, and the two functions over it.

Public as `@rules_dart//dart/ext:registry.bzl`; this file holds the
implementation so the pub repository code (`dart/pub/private`) reads the table
without loading the ruleset-API module above it. `_ENTRIES` stays **private**
and its shape is free to change.

Entries are version-bounded because an asset id is a path inside a *particular*
version of a package. `min_version` is inclusive, `max_version` exclusive;
either may be empty for an open bound.
"""

load("//dart/private:versions.bzl", "parse_semver")

visibility(["//dart/..."])

_ENTRIES = {
    "sqlite3": [
        struct(
            min_version = "2.0.0",
            max_version = "",
            labels = ["@rules_dart//dart/ext/sqlite3:code_asset"],
        ),
    ],
    # The native library is built from the 0.6.1 archive itself, and its symbol
    # table must match the Dart side index for index: one version only.
    "webcrypto": [
        struct(
            min_version = "0.6.1",
            max_version = "0.6.2",
            labels = ["@rules_dart//dart/ext/webcrypto:code_asset"],
        ),
    ],
}

def curated_code_assets(package_name, version):
    """Returns curated `dart_code_asset` labels for a locked pub package.

    Args:
      package_name: The pub package name.
      version: The exact version resolved from the lock file.

    Returns:
      List of label strings; empty when rules_dart curates nothing for this
      package at this version.
    """
    entries = _ENTRIES.get(package_name)
    if not entries:
        return []

    parsed = parse_semver(version)
    for entry in entries:
        if entry.min_version and parsed < parse_semver(entry.min_version):
            continue
        if entry.max_version and parsed >= parse_semver(entry.max_version):
            continue
        return list(entry.labels)
    return []

def curated_packages():
    """Returns the pub package names rules_dart curates assets for.

    Used to tell a user which packages have a replacement available when their
    lock pins an unsupported version.

    Returns:
      Sorted list of package names.
    """
    return sorted(_ENTRIES.keys())
