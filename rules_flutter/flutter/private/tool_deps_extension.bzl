"""Module extension for internal pure-Dart tool dependency hubs.

Declares the `dev_tool_deps` and `gen_l10n_deps` pub hubs separately from the
public `flutter` extension so consumer builds that do not build targets needing
those hubs never evaluate or create their repositories.
"""

load("@rules_dart//dart/pub:yaml_parser.bzl", "parse_pubspec_lock")
load("//flutter/private:flutter_pub_lock_hub.bzl", "flutter_pub_lock_hub")
load("//flutter/private:flutter_pub_overlays.bzl", "spoke_overlay_roots")
load("//flutter/private:flutter_pub_package.bzl", "flutter_pub_package")
load("//flutter/private:flutter_pub_tag.bzl", "flutter_pub_tag")
load("//flutter/private:pub_lock_sdks.bzl", "hosted_package_sha256")

visibility(["//flutter/..."])

def register_tool_pub_hub(
        module_ctx,
        pub_tag,
        hub_rule = flutter_pub_lock_hub,
        spoke_rule = flutter_pub_package):
    """Registers a pure-Dart hosted pub hub and its spoke repositories.

    Args:
        module_ctx: The module extension context used to read the lockfile.
        pub_tag: A `flutter_tool_deps.pub` tag naming `name` and `lock`.
        hub_rule: Repository rule callable that creates the hub repository.
        spoke_rule: Repository rule callable that creates each package spoke.

    Returns:
        The sorted list of hosted package names registered for the hub.
    """
    hub_name = pub_tag.name
    lock_pkgs = parse_pubspec_lock(module_ctx.read(pub_tag.lock))
    package_names = sorted(lock_pkgs.keys())
    overlay_roots = spoke_overlay_roots([])

    hub_rule(
        name = hub_name,
        hub_name = hub_name,
        packages = package_names,
    )

    for pkg_name in package_names:
        info = lock_pkgs[pkg_name]
        if info.get("source") != "hosted":
            fail(
                "flutter_tool_deps hub '%s' supports only hosted packages, got '%s'" %
                (hub_name, pkg_name),
            )
        desc = info.get("description", {})
        base_url = desc.get("url", "https://pub.dev") if type(desc) == "dict" else "https://pub.dev"
        spoke_rule(
            name = hub_name + "__" + pkg_name,
            package_name = pkg_name,
            version = info.get("version", ""),
            sha256 = hosted_package_sha256(pkg_name, info, pub_tag.lock),
            base_url = base_url,
            hub_name = hub_name,
            lock_packages = package_names,
            overlay_roots = overlay_roots,
            pubspec_lock = pub_tag.lock,
        )
    return package_names

def _tool_deps_extension_impl(module_ctx):
    """Resolves `flutter_tool_deps.pub` tags for `ai_rules_flutter` internal tools."""
    for mod in module_ctx.modules:
        for pub_tag in mod.tags.pub:
            register_tool_pub_hub(module_ctx, pub_tag)
    return module_ctx.extension_metadata(reproducible = True)

flutter_tool_deps = module_extension(
    implementation = _tool_deps_extension_impl,
    tag_classes = {
        "pub": flutter_pub_tag,
    },
    doc = "Resolves internal tool pub hubs lazily so consumer workspaces never create them unless needed.",
)
