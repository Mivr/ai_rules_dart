"""What a pub package's build hook gets from the workspace: user defines, extra files, network.

A stock build reads `hooks.user_defines.<package>` from the workspace
`pubspec.yaml` and hands each hook its own slice. The `pub` extension does the
same once, at evaluation, and gives each spoke only its package's slice as a
JSON string, so a pubspec edit outside that slice changes no spoke and runs no
hook. Files a hook reads outside its package (`hook_data`) and the network
opt-in (`hook_network`) come from the `pub.from_lock` / `flutter.pub` tag.
"""

load("//dart/private:apple_hook_replacements.bzl", "APPLE_OS_CONSTRAINTS", "apple_hook_replacement")
load("//dart/pub/private:pub_workspace.bzl", "pub_workspace_root")
load("//dart/pub/private:yaml2json.bzl", "yaml_to_json")

visibility(["//dart/...", "@rules_flutter//flutter/..."])

HOOK_TAG_ATTRS = {
    "hook_data": attr.label_keyed_string_dict(
        doc = "Files outside a package that its build hook reads, each mapped to the package name: a source file a user define names, say (`{\"//:sqlite3.c\": \"sqlite3\"}`). Hooks run in a sandbox with only their package's files and these.",
        allow_files = True,
        default = {},
    ),
    "hook_network": attr.string_list(
        doc = "Packages whose build hook may use the network. A hook runs offline by default, and one that downloads at build time fails with a message naming the package. Listing it lets that one hook action reach the network: what it downloads is then neither pinned nor cached by Bazel, so the build is only as reproducible as the hook's own checks make it.",
        default = [],
    ),
}

def _execroot_path(label, path):
    """The exec-root-relative path of `path` in `label`'s repository."""
    root = label.workspace_root
    return root + "/" + path if root and path else root or path

def lock_hook_settings(ctx, lock_tags, shared_scope):
    """Reads each lock's workspace pubspec for `hooks.user_defines`.

    Args:
      ctx: The module extension context.
      lock_tags: Structs with `name`, `isolated`, `lock` (Label), `hook_data`
        (dict of Label to package name) and `hook_network` (list of package
        names).
      shared_scope: The spoke prefix of the shared scope; an isolated hub's
        scope is its name.

    Returns:
      A dict from scope prefix to a dict from package name to
      `struct(user_defines, pubspec, data, network, source)`, where
      `user_defines` is the package's slice as JSON (or ""), `pubspec` the
      exec-root-relative path of the pubspec it comes from, `data` the sorted
      canonical labels of its `hook_data`, `network` whether it may use the
      network, and `source` the lock naming them.
    """
    pubspecs = {}
    for tag in lock_tags:
        root = pub_workspace_root(tag.lock)

        # Watched whether or not it exists, so adding one re-evaluates.
        ctx.watch(root.pubspec)
        if ctx.path(root.pubspec).exists:
            pubspecs[root.pubspec] = True
    labels = pubspecs.keys()
    data = dict(zip(labels, yaml_to_json(ctx, labels, [str(label) for label in labels]))) if labels else {}

    scopes = {}
    for tag in lock_tags:
        settings = scopes.setdefault(tag.name if getattr(tag, "isolated", False) else shared_scope, {})
        root = pub_workspace_root(tag.lock)
        defines = {}
        pubspec = data.get(root.pubspec)
        if type(pubspec) == "dict":
            hooks = pubspec.get("hooks")
            if type(hooks) == "dict" and type(hooks.get("user_defines")) == "dict":
                defines = hooks["user_defines"]
        files = {}
        for label, package in getattr(tag, "hook_data", {}).items():
            files.setdefault(package, []).append(str(label))
        names = {name: True for name in list(defines.keys()) + list(files.keys()) + list(getattr(tag, "hook_network", []))}
        for name in names:
            entry = struct(
                user_defines = json.encode(defines[name]) if name in defines else "",
                pubspec = _execroot_path(tag.lock, root.dir + "/pubspec.yaml" if root.dir else "pubspec.yaml"),
                data = sorted(files.get(name, [])),
                network = name in getattr(tag, "hook_network", []),
                source = str(tag.lock),
            )
            previous = settings.get(name)
            if previous != None and (previous.user_defines, previous.data, previous.network) != (entry.user_defines, entry.data, entry.network):
                fail(("pub: package `%s` gets different build hook settings from %s and %s " +
                      "(`hooks.user_defines` in the pubspec next to each, or `hook_data` / " +
                      "`hook_network` on the tags); make them agree.") % (name, previous.source, entry.source))
            settings[name] = entry
    return scopes

def _string(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'

# Files of an extracted pub package a hook may read: everything but `lib/`
# (the library's `srcs` and `resources` already) and the files Bazel adds.
_HOOK_SRCS = (
    '    hook_srcs = glob(\n' +
    '        ["**"],\n' +
    '        exclude = ["lib/**", "BUILD", "BUILD.bazel", "WORKSPACE", "WORKSPACE.bazel", "REPO.bazel", "MODULE.bazel"],\n' +
    '        allow_empty = True,\n' +
    '    ),\n'
)

def _apple_select(apple, default):
    """BUILD text for a `select()` giving `apple` on Apple OSes and `default` elsewhere."""
    lines = ["select({\n"]
    for constraint in APPLE_OS_CONSTRAINTS:
        lines.append("        %s: %s,\n" % (_string(constraint), apple))
    lines.append('        "//conditions:default": %s,\n' % default)
    lines.append("    })")
    return "".join(lines)

def hook_attrs_block(build_hook, link_hook, settings, package_name = "", version = ""):
    """The hook attributes of a spoke's library, as BUILD text.

    A package with an Apple replacement (`apple_hook_replacement`) gets its
    build hook only off Apple OSes, and the replacement's code asset on them.

    Args:
      build_hook: Whether the package ships `hook/build.dart`.
      link_hook: Whether it ships `hook/link.dart`.
      settings: Its entry of `lock_hook_settings`, or None.
      package_name: The package's name, to look up an Apple replacement.
      version: Its resolved version.

    Returns:
      BUILD attribute lines, or "" for a package without hooks.
    """
    if not build_hook and not link_hook:
        return ""
    replacement = apple_hook_replacement(package_name, version) if build_hook else []
    text = ""
    if replacement:
        text += "    build_hook = %s,\n" % _apple_select("None", '"hook/build.dart"')
        text += "    code_assets = %s,\n" % _apple_select(
            "[%s]" % ", ".join([_string(label) for label in replacement]),
            "[]",
        )
    elif build_hook:
        text += '    build_hook = "hook/build.dart",\n'
    if link_hook:
        text += '    link_hook = "hook/link.dart",\n'
    text += _HOOK_SRCS
    if settings != None:
        if settings.user_defines:
            text += "    hook_user_defines = %s,\n" % _string(settings.user_defines)
            text += "    hook_pubspec = %s,\n" % _string(settings.pubspec)
        if settings.data:
            text += "    hook_data = [%s],\n" % ", ".join([_string(d) for d in settings.data])
        if settings.network:
            text += "    hook_network = True,\n"
    return text

# Repository-rule attributes carrying `lock_hook_settings` into a spoke.
PUB_HOOK_REPO_ATTRS = {
    "hook_user_defines": attr.string(
        doc = "The package's `hooks.user_defines` slice of the workspace pubspec, as JSON.",
        default = "",
    ),
    "hook_pubspec": attr.string(
        doc = "Exec-root-relative path of the pubspec the user defines come from.",
        default = "",
    ),
    "hook_data": attr.string_list(
        doc = "Canonical labels of files outside the package its build hook reads.",
        default = [],
    ),
    "hook_network": attr.bool(
        doc = "Whether the package's build hook may use the network.",
        default = False,
    ),
}

def hook_repo_attrs(settings):
    """The `PUB_HOOK_REPO_ATTRS` values for one package's spoke.

    Args:
      settings: Its entry of `lock_hook_settings`, or None.

    Returns:
      A dict to merge into the repository rule's attributes.
    """
    if settings == None:
        return {}
    return dict(
        hook_user_defines = settings.user_defines,
        hook_pubspec = settings.pubspec,
        hook_data = settings.data,
        hook_network = settings.network,
    )

def hook_settings_of_repo(attr):
    """Reads `PUB_HOOK_REPO_ATTRS` back from a repository rule's `attr`.

    Args:
      attr: The repository rule context's `attr`.

    Returns:
      A settings struct for `hook_attrs_block`.
    """
    return struct(
        user_defines = attr.hook_user_defines,
        pubspec = attr.hook_pubspec,
        data = attr.hook_data,
        network = attr.hook_network,
    )
