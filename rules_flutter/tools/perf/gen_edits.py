"""Edits applied to a generated workspace (body, API and app edits).

The bench applies these between measured builds; the edit targets come
from the manifest `gen_monorepo.py generate` writes next to the workspace.
"""

import os
import json

EDIT_MANIFEST_REL_PATH = "bench-edit-manifest.json"


def resolve_edit_path(workspace_dir, key):
    """Manifest edit target, validated (relative, contained, Dart, exists)."""
    manifest_path = os.path.join(workspace_dir, EDIT_MANIFEST_REL_PATH)
    with open(manifest_path, encoding="utf-8") as fh:
        manifest = json.load(fh)
    rel = manifest.get(key)
    if not rel:
        raise ValueError(
            "edit manifest '%s' is missing required key '%s'"
            % (manifest_path, key))
    if os.path.isabs(rel):
        raise ValueError("edit manifest has an absolute '%s' path" % key)
    if ".." in rel.split(os.sep):
        raise ValueError("edit manifest has an escaping '%s' path" % key)
    if not rel.endswith(".dart"):
        raise ValueError("edit manifest has a non-Dart '%s' path" % key)
    full = os.path.join(workspace_dir, rel)
    if not os.path.isfile(full):
        raise ValueError("edit manifest '%s' target '%s' does not exist"
                         % (key, full))
    return full


def apply_body_edit(workspace_dir, key="body_edit"):
    """Body-only edit keeping the public API (kernel outline) unchanged."""
    path = resolve_edit_path(workspace_dir, key)
    with open(path, encoding="utf-8") as fh:
        original = fh.read()
    if "i * 1]" in original:
        edited = original.replace("i * 1]", "i * 1 + 0]", 1)
    elif "var total = 1;" in original:
        edited = original.replace("var total = 1;", "var total = 2;", 1)
    elif "return " in original:
        pos = original.rfind("return ")
        edited = original[:pos] + "final _ = 0;\n  " + original[pos:]
    else:
        raise ValueError("unable to apply body-only edit to '%s'" % path)
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(edited)
    return original


def apply_api_edit(workspace_dir, key="api_edit"):
    """Public API edit (adding a member), changing the kernel outline."""
    path = resolve_edit_path(workspace_dir, key)
    with open(path, encoding="utf-8") as fh:
        original = fh.read()
    if "  /// The value.\n" in original:
        edited = original.replace(
            "  /// The value.\n",
            "  /// Added API.\n  int get extra => 1;\n\n  /// The value.\n",
            1)
    else:
        edited = original + "\n/// Added API.\nint addedApi0x0() => 1;\n"
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(edited)
    return original


def apply_app_edit(workspace_dir):
    """Behaviour-changing top-layer edit of the bench application.

    Bumps the first wired widget's displayed value, changing what the app
    renders without touching any package API.
    """
    path = os.path.join(workspace_dir, "app", "lib", "main.dart")
    with open(path, encoding="utf-8") as fh:
        original = fh.read()
    marker = "W"
    idx = original.find("              W")
    if idx < 0:
        raise ValueError(
            "unable to apply app edit: no wired widget in '%s'" % path)
    end = original.find("),", idx)
    if end < 0:
        raise ValueError(
            "unable to apply app edit: malformed widget line in '%s'" % path)
    line = original[idx:end]
    if marker not in line or "value" not in line:
        raise ValueError(
            "unable to apply app edit: unexpected widget line in '%s'" % path)
    edited = original[:end] + " + 1" + original[end:]
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(edited)
    return original
