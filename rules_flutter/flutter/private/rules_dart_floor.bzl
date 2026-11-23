"""Floor check for the resolved `ai_rules_dart` module.

`rules_flutter` needs `ai_rules_dart` 0.28.3 (see `MODULE.bazel`), but a root
module override (`archive_override`, `git_override`, `local_path_override`
or `single_version_override`) replaces that resolution while Bazel ignores
the overridden module's `bazel_dep` version. Release archives carry no module
version and overridden modules report none, so the version cannot be read:
this module probes the behaviour the floor exists for instead. The 0.21.0
pubspec reader refuses a non-map `environment`; the 0.20.0 one silently reads
past it. One tiny parse per extension evaluation keeps the check cheap, and
everything the check needs (the floor, the probe and the message) lives here
so a floor bump touches one file.
"""

load("@rules_dart//dart/pub:yaml_parser.bzl", "pubspec_sdk_constraint_error")

visibility(["//flutter/..."])

RULES_DART_FLOOR = "0.28.3"

# A pubspec-shaped stream the floor reader refuses and the previous release
# accepts: `pubspec_sdk_constraint_error` is public in both, reports None on
# 0.20.0 (a non-map environment is silently ignored) and an error on 0.21.0
# (`floor_probe in pubspec.yaml: "environment" field must be a map.`).
_FLOOR_PROBE = "name: floor_probe\nenvironment: 3\n"

def _floor_message():
    """Returns the failure message naming the module, floor and override fix."""
    return (
        "rules_flutter needs ai_rules_dart " + RULES_DART_FLOOR + " or newer, but the " +
        "resolved ai_rules_dart reads pubspecs like an older release: it accepts a " +
        "non-map `environment` that " + RULES_DART_FLOOR + " refuses. A root " +
        "archive_override, git_override, local_path_override or " +
        "single_version_override is probably pinning an older ai_rules_dart: raise " +
        "that override to " + RULES_DART_FLOOR + " or above, or drop it so the version " +
        "in rules_flutter's MODULE.bazel applies."
    )

def rules_dart_floor_error(read_error = pubspec_sdk_constraint_error):
    """Returns why the resolved `ai_rules_dart` predates the floor, or None.

    The injected `read_error` is `pubspec_sdk_constraint_error` by default;
    tests pass a stand-in that mimics an older reader. A None probe result
    means the reader accepts the non-map `environment`, so it is older than
    `RULES_DART_FLOOR` and the returned message says which override to
    change. A non-None result means the reader refuses it, so it meets the
    floor and there is no error.

    Args:
        read_error: Callable taking pubspec text and returning an error
            string or None, as `pubspec_sdk_constraint_error` does.

    Returns:
        The floor failure message, or None when the reader meets the floor.
    """
    if read_error(_FLOOR_PROBE) == None:
        return _floor_message()
    return None

def check_rules_dart_floor(read_error = pubspec_sdk_constraint_error):
    """Fails extension evaluation when `ai_rules_dart` predates the floor.

    Call this before creating any repository so toolchain-only consumers
    fail the same way `flutter.pub` consumers do.

    Args:
        read_error: Callable taking pubspec text and returning an error
            string or None, as `pubspec_sdk_constraint_error` does.
    """
    err = rules_dart_floor_error(read_error)
    if err != None:
        fail(err)
