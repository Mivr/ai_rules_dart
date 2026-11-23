"""Selected module versions for the floor proof.

A repository rule reads the `MODULE.bazel` of every module in the checked-in
floor table and writes the version each resolved external repo actually
carries. `ai_rules_dart` resolves from its `archive_override` in the root
`MODULE.bazel`, so its version is parsed from that override. The resulting
`versions.json` is what `//:dependency_floors_test` compares with the floors
and their documented lifts.
"""

visibility("private")

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

def _version_from_archive_override(text, module):
    """The version declared in [module]'s `archive_override`, failing when absent or invalid."""
    for call in text.split("git_override(")[1:]:
        call_body = call.split(")")[0]
        if ('module_name = "%s"' % module) in call_body or ("module_name = '%s'" % module) in call_body:
            fail("%s uses git_override; archive_override is required" % module)

    found_override = None
    for call in text.split("archive_override(")[1:]:
        call_body = call.split(")")[0]
        if ('module_name = "%s"' % module) in call_body or ("module_name = '%s'" % module) in call_body:
            found_override = call_body
            break

    if not found_override:
        fail("no archive_override for %s in the root MODULE.bazel" % module)

    marker = "strip_prefix"
    idx = found_override.find(marker)
    if idx < 0:
        fail("no strip_prefix in archive_override for %s" % module)
    after = found_override[idx + len(marker):].strip()
    if not after.startswith("="):
        fail("malformed strip_prefix in archive_override for %s" % module)
    rest = after[1:].strip()
    quote = rest[0]
    if quote not in ('"', "'"):
        fail("invalid strip_prefix in archive_override for %s" % module)
    end_quote = rest.find(quote, 1)
    if end_quote < 0:
        fail("unclosed string in strip_prefix for %s" % module)
    strip_prefix_val = rest[1:end_quote]

    expected_prefix = "rules_dart-"
    if not strip_prefix_val.startswith(expected_prefix):
        fail("strip_prefix in archive_override for %s must start with %s, got %s" % (module, expected_prefix, strip_prefix_val))
    version_from_prefix = strip_prefix_val[len(expected_prefix):]

    tag_marker = "/v"
    tag_idx = found_override.find(tag_marker)
    if tag_idx < 0:
        fail("no /v<version>/ in archive_override urls for %s" % module)
    tag_rest = found_override[tag_idx + len(tag_marker):]
    slash_idx = tag_rest.find("/")
    if slash_idx < 0:
        fail("malformed /v<version>/ in archive_override urls for %s" % module)
    version_from_url = tag_rest[:slash_idx]

    if version_from_url != version_from_prefix:
        fail("version in URL (/v%s/) does not match strip_prefix (%s) in archive_override for %s" % (version_from_url, strip_prefix_val, module))

    return version_from_prefix

def _selected_version(rctx, root_source, module):
    """The version [module] resolves to in this workspace."""
    if module == "ai_rules_dart":
        return _version_from_archive_override(root_source, module)

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
    """Write every selected module version named by the floor table."""
    floors = json.decode(rctx.read(rctx.path(rctx.attr.floors)))
    root_source = rctx.read(rctx.path(rctx.attr.root_module))
    versions = {}
    for module in floors:
        versions[module] = _selected_version(rctx, root_source, module)
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
        "root_module": attr.label(
            allow_single_file = True,
            default = "//:MODULE.bazel",
            doc = "The root MODULE.bazel, read for the archive-overridden ai_rules_dart pin.",
        ),
    },
    doc = "Writes the selected version of every module in the floor table.",
)
