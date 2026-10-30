"""Which files of a target the `dart_analyze` aspect checks.

Kept apart from `dart_analyze_aspect.bzl`, which declares the aspect, so that
file holds the action plumbing rather than the target-file discovery.
"""

load("//dart:providers.bzl", "DartAnalyzableInfo", "DartInfo")

def analyze_own_files(target, entry, package_srcs):
    """Splits a target's checkable Dart files into own and generated.

    Args:
      target: The target under the aspect.
      entry: The target's `DartAnalyzableInfo.srcs`, or an empty list.
      package_srcs: The target's `DartAnalyzableInfo.package_srcs`, or an
        empty list.

    Returns:
      `(own, generated_by_path)`: dicts keyed by file path, or `(None, None)`
      when the target has no source Dart file of its own to check.
    """
    own = {}
    generated_by_path = {}
    for f in [f for f in target[DefaultInfo].files.to_list() + entry + package_srcs if f.extension == "dart"]:
        if f.short_path.startswith("../"):
            continue
        if f.is_source:
            own[f.path] = f
        else:
            generated_by_path[f.path] = f
    if not own:
        return None, None
    return own, generated_by_path

def analyze_target_info(target):
    """Returns `(info, entry, package_srcs)` for an analyzable target.

    Args:
      target: The target under the aspect.

    Returns:
      The target's `DartInfo` closure, its `DartAnalyzableInfo.srcs` (empty
      when the target is not analyzable), and its package's own `lib/` files
      from `DartAnalyzableInfo.package_srcs` (empty too in that case).
    """
    if DartAnalyzableInfo in target:
        info = target[DartAnalyzableInfo].dart_info
        entry = target[DartAnalyzableInfo].srcs.to_list()

        # A package's own `lib/` files, which a target's `DefaultInfo` (a web
        # bundle, a test executable) need not list. Absent from records built
        # against an older rules_dart.
        package_srcs = getattr(target[DartAnalyzableInfo], "package_srcs", depset()).to_list()
    else:
        info = target[DartInfo]
        entry = []
        package_srcs = []
    return info, entry, package_srcs
