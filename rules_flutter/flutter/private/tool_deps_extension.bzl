"""Module extension for internal pure-Dart tool dependency hubs.

Declares the `dev_tool_deps` and `gen_l10n_deps` pub hubs separately from the
public `flutter` extension so consumer builds that do not build targets needing
those hubs never evaluate or create their repositories.
"""

load("@rules_dart//dart/pub:yaml.bzl", "lock_packages", "yaml_to_json")
load("//flutter/private:flutter_pub_lock_hub.bzl", "flutter_pub_lock_hub")
load("//flutter/private:flutter_pub_overlays.bzl", "spoke_overlay_roots")
load("//flutter/private:flutter_pub_package.bzl", "flutter_pub_package")
load("//flutter/private:flutter_pub_tag.bzl", "flutter_pub_tag")
load("//flutter/private:pub_lock_sdks.bzl", "hosted_package_sha256")

visibility(["//flutter/..."])

def register_tool_pub_hub(
        pub_tag,
        lock_data,
        hub_rule = flutter_pub_lock_hub,
        spoke_rule = flutter_pub_package):
    """Registers a pure-Dart hosted pub hub and its spoke repositories.

    Args:
        pub_tag: A `flutter_tool_deps.pub` tag naming `name` and `lock`.
        lock_data: The tag's decoded `pubspec.lock`, from `yaml_to_json`.
        hub_rule: Repository rule callable that creates the hub repository.
        spoke_rule: Repository rule callable that creates each package spoke.

    Returns:
        The sorted list of hosted package names registered for the hub.
    """
    hub_name = pub_tag.name
    lock_pkgs = lock_packages(lock_data, str(pub_tag.lock))
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
    """Resolves `flutter_tool_deps.pub` tags for `ai_rules_flutter` internal tools.

    Every tag's lock is read in one `yq` run and watched.
    """
    tags = [pub_tag for mod in module_ctx.modules for pub_tag in mod.tags.pub]
    for pub_tag in tags:
        module_ctx.watch(pub_tag.lock)
    locks = yaml_to_json(module_ctx, [pub_tag.lock for pub_tag in tags], [str(pub_tag.lock) for pub_tag in tags])
    for pub_tag, lock_data in zip(tags, locks):
        register_tool_pub_hub(pub_tag, lock_data)
    return module_ctx.extension_metadata(reproducible = True)

flutter_tool_deps = module_extension(
    implementation = _tool_deps_extension_impl,
    tag_classes = {
        "pub": flutter_pub_tag,
    },
    doc = "Resolves internal tool pub hubs lazily so consumer workspaces never create them unless needed.",
)
