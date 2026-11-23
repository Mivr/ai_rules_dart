"""Selected module versions for the floor proof.

A repository rule reads the `MODULE.bazel` of every module in the checked-in
floor table and writes the version each resolved external repo actually
carries. `ai_rules_dart` is the sibling `rules_dart` of this checkout through a
`local_path_override`, which has no version, so it is left out: its floor is
checked as a declaration and its effect shows in the lifts it causes. The
resulting `versions.json` is what `//:dependency_floors_test` compares with the
floors and their documented lifts.
"""

visibility("private")

# The module taken from the sibling directory, not resolved from a registry.
_SIBLING = "ai_rules_dart"

def _version_from_module(text, module):
    """The first literal `version = "..."` in [text], failing when absent."""
    marker = 'version = "'
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith("#"):
            continue
        index = stripped.find(marker)
        if index < 0:
            continue
        rest = stripped[index + len(marker):]
        end = rest.find('"')
        if end >= 0:
            return rest[:end]
    fail("no module version in @%s//:MODULE.bazel" % module)

def _selected_version(rctx, module):
    """The version [module] resolves to in this workspace."""

    # Canonical repo names are independent of the root's apparent-name mapping:
    # a workspace that does not declare every module directly (the pre-fix
    # fixture does not) still has the selected module repo under `<name>+`.
    # `platforms` is the exception: Bazel keeps its canonical name unversioned.
    if module == "platforms":
        label = Label("@platforms//:MODULE.bazel")
    else:
        label = Label("@@%s+//:MODULE.bazel" % module)
    return _version_from_module(rctx.read(rctx.path(label)), module)

def _resolved_module_versions_impl(rctx):
    """Write every selected module version named by the floor table, but the sibling."""
    floors = json.decode(rctx.read(rctx.path(rctx.attr.floors)))
    versions = {}
    for module in floors:
        if module == _SIBLING:
            continue
        versions[module] = _selected_version(rctx, module)
    rctx.file("MODULE.bazel", 'module(name = "resolved_module_versions")\n')
    rctx.file(
        "BUILD.bazel",
        'exports_files(["versions.json"], visibility = ["//visibility:public"])\n',
    )
    rctx.file("versions.json", json.encode(versions) + "\n")

resolved_module_versions = repository_rule(
    implementation = _resolved_module_versions_impl,
    attrs = {
        "floors": attr.label(
            allow_single_file = True,
            doc = "The checked-in dependency floor table that names the modules to read.",
        ),
    },
    doc = "Writes the selected version of every module in the floor table but the sibling rules_dart.",
)
