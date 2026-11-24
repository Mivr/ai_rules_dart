"""Extensions for bzlmod.

Installs a Flutter toolchain and optionally resolves pub dependencies
(including Flutter SDK packages like package:flutter).

Every module can define a toolchain version under the default name, "flutter".
The root module's request wins when it makes one (even when a dependency
requests a newer SDK); without a root request the latest of those versions
will be selected (the rest discarded), and will always be registered by
rules_flutter.

Additionally, the root module can define arbitrarily many more toolchain versions under different
names (the latest version will be picked for each name) and can register them as it sees fit,
effectively overriding the default named toolchain due to toolchain resolution precedence.

The root module can also register custom Flutter releases missing from
`flutter/private/versions.bzl` with `flutter.version(...)`, and can source a
toolchain out of a pre-extracted local SDK with
`flutter.toolchain(local_path = ...)` instead of downloading. See
docs/flutter-sdk-versions.md.
"""

load("@rules_dart//dart/pub:extensions.bzl", "touch_scanner_runtime_label")
load("@rules_dart//dart/pub:pub_lock_hub.bzl", "pub_lock_hub")
load("@rules_dart//dart/pub:pub_lock_package.bzl", "hook_repo_attrs", "lock_hook_settings")
load(
    "@rules_dart//dart/pub:pub_plan.bzl",
    "own_dep_labels",
    "plan_pub_graph",
    "plan_scope_sccs",
    "read_pub_plans",
)
load("@rules_dart//dart/pub:yaml.bzl", "lock_packages", "yaml_to_json")
load("//flutter/private:artifact_urls.bzl", "source_strip_prefix")
load("//flutter/private:flutter_assets_tool_repo.bzl", "flutter_assets_tool_repo")
load("//flutter/private:flutter_pub_android_package.bzl", "android_package_repo_name", "flutter_pub_android_package")
load("//flutter/private:flutter_pub_apple_pods.bzl", "hub_cocoapods_attrs")
load("//flutter/private:flutter_pub_apple_pods_hub.bzl", "hub_podfile_lock")
load("//flutter/private:flutter_pub_cycle_breaks.bzl", "apply_cycle_breaks", "cycle_breaks_lock_error")
load("//flutter/private:flutter_pub_git.bzl", "git_package_subdir")
load("//flutter/private:flutter_pub_lock_hub.bzl", "flutter_pub_hub_files", "hub_package_graph", "hub_scc_targets", "ios_native_deps_json")
load("//flutter/private:flutter_pub_maven.bzl", "path_spoke_maven_inputs")
load(
    "//flutter/private:flutter_pub_overlays.bzl",
    "hub_overlay_roots",
    "overlay_replaces_spoke",
    "spoke_overlay_roots",
)
load("//flutter/private:flutter_pub_package.bzl", "flutter_pub_git_package", "flutter_pub_package", "flutter_pub_path_package", "is_maven_dep_label")
load("//flutter/private:flutter_l10n_repo.bzl", "register_l10n_repos")
load("//flutter/private:flutter_pub_hubs.bzl", "register_pub_hubs_index")
load("//flutter/private:flutter_pub_path.bzl", "collect_path_deps", "foreign_lock_path_error", "is_absolute_lock_path", "is_relative_path_dependency", "workspace_relative_lock_path")
load("//flutter/private:flutter_pub_plugin_defines.bzl", "ios_plugin_defines_lock_error")
load("//flutter/private:flutter_pub_plugin_deps.bzl", "ios_plugin_deps_lock_error")
load("//flutter/private:flutter_pub_scc_spoke.bzl", "flutter_pub_scc_package")
load("//flutter/private:flutter_pub_tag.bzl", "flutter_pub_tag", "validate_swift_package_product_deps")
load("//flutter/private:flutter_pubspec.bzl", "parse_flutter_plugin_block")
load("//flutter/private:flutter_sdk_package.bzl", "declare_sdk_source", "declare_sdk_spokes")
load("//flutter/private:pub_lock_sdks.bzl", "hosted_package_sha256", "lock_flutter_constraint", "version_below_lower_bound")
load("//flutter/private:swiftpm_package.bzl", "swiftpm_package")
load("//flutter/private:swiftpm_resolved.bzl", "check_swiftpm_config_present", "check_swiftpm_dicts", "classify_swiftpm_pin", "pub_spoke_swiftpm_attrs", "read_swiftpm_pins", "swiftpm_spoke_attrs")
load("//flutter/private:toolchain_selection.bzl", "select_toolchain_source")
load("//flutter/private:versions.bzl", "custom_engine_base_url", "custom_source_url", "flutter_source_sha256", "merge_custom_versions", "unknown_version_message")
load("//flutter/private:xtool_darwin_sdk_repo.bzl", "resolve_darwin_sdk_from_modules")
load(":repositories.bzl", "flutter_register_toolchains")

visibility("public")

_DEFAULT_NAME = "flutter"

# Flutter SDK packages that exist as source under packages/ in the Flutter repo
# and that an app can depend on (`flutter_driver` depends on
# `fuchsia_remote_debug_protocol`). sky_engine is excluded — it provides dart:ui
# which is already in platform_strong.dill.
_FLUTTER_SDK_PACKAGES = {"flutter": True, "flutter_test": True, "flutter_driver": True, "flutter_goldens": True, "flutter_localizations": True, "flutter_web_plugins": True, "fuchsia_remote_debug_protocol": True, "integration_test": True}

def _unserved_sdk_package_error(hub_name, name, info):
    """The error for a `source: sdk` lock entry no SDK spoke serves (sky_engine aside)."""
    desc = info.get("description", {})
    sdk = desc.get("name", "") if type(desc) == "dict" else ""
    return (
        "flutter.pub hub \"{hub}\": package \"{pkg}\" comes from the \"{sdk}\" SDK (source: sdk), which " +
        "flutter.pub does not serve: it serves {served} from the Flutter SDK. Remove the dependency, " +
        "run `flutter pub get`, and commit the lock."
    ).format(hub = hub_name, pkg = name, sdk = sdk, served = ", ".join(sorted(_FLUTTER_SDK_PACKAGES.keys())))

def _fail_on_invalid_maven_deps(hub_name, android_maven_deps):
    """Refuse an `android_maven_deps` value that is not a Bazel label.

    Every value lands in a generated spoke deps list; a non-label is
    refused here, naming the hub and key, rather than emitted into
    BUILD text.
    """
    for _maven_key in android_maven_deps.keys():
        _maven_label = android_maven_deps[_maven_key]
        if not is_maven_dep_label(_maven_label):
            fail((
                "flutter.pub(name = \"{hub}\"): android_maven_deps[{key}] " +
                "is not a valid Bazel label ({label}). Map the " +
                "coordinate to a label in another repository " +
                "(\"@...\") or an absolute label (\"//...\") with no " +
                "quotes, backslashes or newlines."
            ).format(
                hub = hub_name,
                key = _maven_key,
                label = _maven_label,
            ))

flutter_toolchain = tag_class(
    attrs = {
        "name": attr.string(doc = """\
Base name for generated repositories, allowing more than one Flutter toolchain to be registered.
Overriding the default is only permitted in the root module.
""", default = _DEFAULT_NAME),
        "flutter_version": attr.string(
            doc = "Version of the Flutter SDK. Either this or `local_path` is " +
                  "required, never both. May name a stock release from " +
                  "flutter/private/versions.bzl or a custom version registered " +
                  "with `flutter.version` in the root module.",
            default = "",
        ),
        "local_path": attr.string(
            doc = "Path to a pre-extracted Flutter SDK (bin/cache layout) to " +
                  "source the toolchain from instead of downloading. Root-only, " +
                  "and mutually exclusive with `flutter_version`. A relative " +
                  "path resolves against the main workspace root.",
            default = "",
        ),
    },
    doc = "Requests a Flutter SDK toolchain: either a downloadable release " +
          "via `flutter_version` or a pre-extracted local SDK via " +
          "`local_path` (exactly one of the two). `name` defaults to the " +
          "shared toolchain; the root module may register more under other names.",
)

flutter_version = tag_class(
    attrs = {
        "version": attr.string(
            doc = "Flutter release tag to register (e.g. `\"3.47.7\"`). Must " +
                  "not already be listed in flutter/private/versions.bzl.",
            mandatory = True,
        ),
        "engine_revision": attr.string(
            doc = "Engine commit hash the release's artifacts are published under.",
            mandatory = True,
        ),
        "source_sha256": attr.string(
            doc = "SHA-256 of the framework source tarball (`source_url`, by " +
                  "default the GitHub tag tarball of `version`).",
            mandatory = True,
        ),
        "material_fonts_url": attr.string(
            doc = "GCS path of the Material icon font bundle for the release " +
                  "(a full https:// URL is used as-is).",
            mandatory = True,
        ),
        "artifact_sha256": attr.string_dict(
            doc = "Engine artifact path → SHA-256, keyed exactly like " +
                  "ARTIFACT_CHECKSUMS. Every artifact the repositories fetch " +
                  "needs an entry; a needed artifact without one fails the " +
                  "fetch naming the artifact and the version.",
            default = {},
        ),
        "engine_base_url": attr.string(
            doc = "Replacement origin serving the engine revision directory " +
                  "(an enterprise build). Empty means the default GCS base. " +
                  "Plain mirrors stay Bazel's job (`--downloader_config`).",
            default = "",
        ),
        "source_url": attr.string(
            doc = "Replacement framework source tarball URL. Empty means the " +
                  "default GitHub tag tarball of `version`. Plain mirrors stay " +
                  "Bazel's job (`--downloader_config`).",
            default = "",
        ),
    },
    doc = "Registers a custom Flutter release missing from the built-in " +
          "version table, so `flutter.toolchain` can download it by tag. " +
          "Root-module-only.",
)

_flutter_plugin_overlays = tag_class(
    attrs = {
        "roots": attr.label_list(
            doc = "BUILD.bazel anchors for user-supplied overlay trees. Each " +
                  "label points at an `ext/BUILD.bazel` (or equivalent) that " +
                  "anchors a directory tree of `<package>/<version>/BUILD.bazel.tpl` " +
                  "overrides. A hub consults the root module's roots first, " +
                  "then its own module's roots (when that module is not the " +
                  "root), then the bundled `@rules_flutter//ext:BUILD.bazel`; " +
                  "a dependency's roots never reach the root's hubs or another " +
                  "module's hubs. A template declares " +
                  "its language version and its dependencies by placeholder " +
                  "(`{LANGUAGE_VERSION}`, `{DEPS}`), never by hand; see " +
                  "docs/TESTING.md \"Native Assets overlay authoring\".",
            allow_files = True,
            default = [],
        ),
    },
    doc = "Names overlay BUILD trees whose plugin templates replace the " +
          "generated ones for matching packages. Every hub reads the root " +
          "module's roots first, then its own module's roots; a " +
          "dependency's roots never reach the root's hubs or another " +
          "module's hubs.",
)

_flutter_darwin_sdk = tag_class(
    doc = (
        "Root-module-only configuration for the opt-in xtool Darwin SDK (`@flutter_xtool_darwin_sdk`). " +
        "Specify either `url` + `sha256` (hermetic) or `path` (local, non-hermetic). " +
        "IMPORTANT (Apple SDK licensing): `rules_flutter` never downloads or bundles an Apple SDK by default " +
        "(`url` and `path` both default to `\"\"`). Users must obtain and supply their own `darwin.artifactbundle` " +
        "(`iPhoneOS.sdk`, `iPhoneSimulator.sdk`, `MacOSX.sdk`) in compliance with the Apple Xcode and Apple SDKs Agreement."
    ),
    attrs = {
        "path": attr.string(
            doc = "Optional local filesystem path to a user-supplied `darwin.artifactbundle` for the xtool backend (local, non-hermetic; mutually exclusive with `url`). Subject to Apple's SDK licensing terms.",
            default = "",
        ),
        "url": attr.string(
            doc = "Optional URL to download a user-supplied `darwin.artifactbundle` archive for the xtool backend (hermetic; requires `sha256` and is mutually exclusive with `path`). No default URL is provided; users must supply their own SDK under Apple's terms.",
            default = "",
        ),
        "sha256": attr.string(
            doc = "Required SHA-256 checksum when `url` is specified.",
            default = "",
        ),
        "swift_toolchain_path": attr.string(
            doc = "Optional local path to the Linux Swift toolchain root directory (local, non-hermetic).",
            default = "",
        ),
    },
)

# Exec-host pairs the xtool repo can symlink a hermetic LLVM tree for, in a
# fixed order shared with the repo rule (index = 2 * is_macos + is_x86_64).
_LLVM_TOOL_EXECS = (
    ("linux", "aarch64"),
    ("linux", "x86_64"),
    ("macos", "aarch64"),
    ("macos", "x86_64"),
)

def _llvm_tool_repos_for_modules(*, modules, sdk_configured):
    """Apparent names of llvm's per-host prebuilt-toolchain repos.

    The names (`llvm-toolchain-minimal-<os>-<cpu>`) are imported into
    rules_flutter's own repo mapping by this module's `use_repo` on llvm's
    toolchain extension, so the xtool repo rule resolves them there — plain
    strings cross the extension boundary because a `Label(...)` built in an
    extension implementation cannot see them. The xtool repo only resolves
    (fetches) the entry matching the exec host, and only when the returned
    list is non-empty. The list is non-empty exactly when LLVM may be
    linked: the root module opted into a Darwin SDK, or this evaluation runs
    for rules_flutter itself (whose hermetic-LLVM script tests assert the
    linkage with no SDK configured). Plain consumers get `[]`: no LLVM label
    is ever built for them, so no LLVM repository is fetched.
    Same host mapping as `resource_dir_arg` in `@llvm//toolchain:selects.bzl`.
    """
    self_root = False
    for mod in modules:
        if mod.is_root and mod.name == "ai_rules_flutter":
            self_root = True
            break
    if not sdk_configured and not self_root:
        return []
    names = []
    for (exec_os, exec_cpu) in _LLVM_TOOL_EXECS:
        os_part = "darwin" if exec_os == "macos" else exec_os
        cpu_part = "amd64" if exec_cpu == "x86_64" else "arm64"
        names.append("llvm-toolchain-minimal-%s-%s" % (os_part, cpu_part))
    return names

def _collect_custom_tags(modules):
    """Collects `flutter.version` tags as structs for version-table merging."""
    return [
        struct(
            version = tag.version,
            engine_revision = tag.engine_revision,
            source_sha256 = tag.source_sha256,
            material_fonts_url = tag.material_fonts_url,
            artifact_sha256 = tag.artifact_sha256,
            engine_base_url = tag.engine_base_url,
            source_url = tag.source_url,
            is_root = mod.is_root,
        )
        for mod in modules
        for tag in mod.tags.version
    ]

def _read_pub_yaml(module_ctx):
    """Reads every `flutter.pub` tag's `pubspec.lock` and `Podfile.lock` in one `yaml2json` run.

    Each file is watched, so editing it re-evaluates the extension.

    Args:
        module_ctx: The module extension context.

    Returns:
        Dict of label string to the file's decoded top-level mapping.
    """
    labels = {}
    for mod in module_ctx.modules:
        for pub_tag in mod.tags.pub:
            labels[str(pub_tag.lock)] = pub_tag.lock
            if getattr(pub_tag, "ios_podfile_lock", None) != None:
                labels[str(pub_tag.ios_podfile_lock)] = pub_tag.ios_podfile_lock
    names = sorted(labels.keys())
    for name in names:
        module_ctx.watch(labels[name])
    return dict(zip(names, yaml_to_json(module_ctx, [labels[name] for name in names], names)))

def _collect_lock_floors(module_ctx, pub_yaml):
    """Collects pub-lock Flutter floors, keyed by lock label string.

    In download mode these are checked at evaluation; in local mode they
    travel with the toolchain registration and each host repo checks them
    once the SDK is read (the version is only known then).
    """
    lock_flutter_constraints = {}
    for mod in module_ctx.modules:
        for pub_tag in mod.tags.pub:
            constraint = lock_flutter_constraint(pub_yaml[str(pub_tag.lock)])
            if constraint:
                lock_flutter_constraints[str(pub_tag.lock)] = constraint
    return lock_flutter_constraints

def _collect_registrations(modules):
    """Validates `flutter.toolchain` tags and groups them by toolchain name."""
    registrations = {}
    for mod in modules:
        for toolchain in mod.tags.toolchain:
            if toolchain.name != _DEFAULT_NAME and not mod.is_root:
                fail("""\
                Only the root module may override the default name for the Flutter toolchain.
                This prevents conflicting registrations in the global namespace of external repos.
                """)
            if toolchain.local_path and not mod.is_root:
                fail("Only the root module may source a Flutter toolchain from a local SDK (local_path); dependencies must request downloadable versions.")
            if toolchain.local_path and toolchain.flutter_version:
                fail("flutter.toolchain(local_path = ...) is mutually exclusive with downloading: set exactly one of local_path and flutter_version.")
            if not toolchain.local_path and not toolchain.flutter_version:
                fail("flutter.toolchain() needs exactly one of flutter_version and local_path.")
            if toolchain.name not in registrations.keys():
                registrations[toolchain.name] = []
            registrations[toolchain.name].append(struct(
                version = toolchain.flutter_version,
                local_path = toolchain.local_path,
                is_root = mod.is_root,
                module = mod.name,
            ))
    return registrations

def _register_local_toolchain(name, local_path, lock_flutter_constraints, darwin_sdk, llvm_tool_repos):
    """Registers one local-SDK toolchain and its asset tool repo."""
    flutter_register_toolchains(
        name = name,
        local_path = local_path,
        flutter_constraints = lock_flutter_constraints,
        darwin_sdk_path = darwin_sdk.path,
        darwin_sdk_url = darwin_sdk.url,
        darwin_sdk_sha256 = darwin_sdk.sha256,
        darwin_sdk_swift_toolchain_path = darwin_sdk.swift_toolchain_path,
        darwin_sdk_llvm_tool_repos = llvm_tool_repos,
    )
    flutter_assets_tool_repo(
        name = name + "_assets_tool",
        local_path = local_path,
    )
    return struct(version = "", local_path = local_path, source_label = "")

def _register_download_toolchain(name, selected, merged, darwin_sdk, llvm_tool_repos):
    """Registers one downloaded toolchain and its asset tool repo."""
    if selected not in merged.versions:
        fail(unknown_version_message(selected))
    meta = merged.versions[selected]
    version_source_url = custom_source_url(selected, merged.source_urls)
    flutter_register_toolchains(
        name = name,
        flutter_version = selected,
        engine_revision = meta.engine_revision,
        source_sha256 = flutter_source_sha256(selected, merged.versions),
        material_fonts_url = meta.material_fonts_url,
        artifact_sha256s = merged.checksums[selected],
        engine_base_url = custom_engine_base_url(selected, merged.engine_base_urls),
        source_url = version_source_url,
        source_strip_prefix = source_strip_prefix(selected, version_source_url),
        darwin_sdk_path = darwin_sdk.path,
        darwin_sdk_url = darwin_sdk.url,
        darwin_sdk_sha256 = darwin_sdk.sha256,
        darwin_sdk_swift_toolchain_path = darwin_sdk.swift_toolchain_path,
        darwin_sdk_llvm_tool_repos = llvm_tool_repos,
    )

    # One extraction of the release's source tarball, shared by every SDK
    # package spoke and the asset tool built from its flutter_tools.
    # Declared unconditionally because bzlmod repositories are lazy: a
    # workspace that never references them never fetches the tarball.
    source_label = declare_sdk_source(
        name,
        selected,
        flutter_source_sha256(selected, merged.versions),
        version_source_url,
    )
    flutter_assets_tool_repo(
        name = name + "_assets_tool",
        flutter_version = selected,
        sdk_source = source_label,
    )
    return struct(version = selected, local_path = "", source_label = source_label)

def _register_all_toolchains(module_ctx, registrations, merged, lock_flutter_constraints, darwin_sdk):
    """Registers every requested toolchain; returns name → selected info."""
    selected_info = {}
    for name, requests in registrations.items():
        source = select_toolchain_source(name, requests)
        if source.note:
            # buildifier: disable=print
            print("NOTE: " + source.note)
        llvm_tool_repos = _llvm_tool_repos_for_modules(
            modules = module_ctx.modules,
            sdk_configured = darwin_sdk.configured,
        )
        if source.local_path:
            selected_info[name] = _register_local_toolchain(
                name,
                source.local_path,
                lock_flutter_constraints,
                darwin_sdk,
                llvm_tool_repos,
            )
            continue
        selected_info[name] = _register_download_toolchain(name, source.version, merged, darwin_sdk, llvm_tool_repos)
    return selected_info

def _check_pub_flutter_floor(lock_data, toolchain_info, pub_tag):
    """Fails when the lock's Flutter floor exceeds the pinned toolchain.

    This is the one moment where the SDK that resolved the lock and
    the SDK that will consume it are both in view. Pub does not
    record the resolver's version, but it does record the floor its
    solution needs; a toolchain below that floor cannot compile what
    the lock pins. A local SDK reads its version out of
    bin/cache/flutter.version.json at fetch time, so in local mode
    the floor travels with the toolchain registration (see above)
    and each host repo checks it once the SDK is read; only the
    download-mode pin is checked here.
    """
    flutter_constraint = lock_flutter_constraint(lock_data)
    flutter_version = toolchain_info.version
    if flutter_constraint and flutter_version and version_below_lower_bound(flutter_version, flutter_constraint):
        fail((
            "{lock} was resolved against a newer Flutter than this " +
            "build pins: the lock requires flutter {constraint}, and " +
            "flutter.toolchain() pins {version}.\n" +
            "Either raise flutter.toolchain(flutter_version = ...) or " +
            "re-resolve with the pinned toolchain:\n" +
            "    bazel run @rules_flutter//flutter:pub -- upgrade"
        ).format(
            lock = str(pub_tag.lock),
            constraint = flutter_constraint,
            version = flutter_version,
        ))

def _fail_on_odd_package_name(hub_name, package_name):
    """Refuse a lock package name that cannot survive BUILD emission.

    Pub package names are lowercase letters, digits and underscores, but a
    hand-edited lock can say anything; the name lands in spoke repository
    names, hub aliases and generated target names. Anything holding a quote,
    a backslash, a newline, whitespace or a label separator fails here,
    naming the hub and the package, rather than emitting it into BUILD text.
    """
    for ch in ['"', "\\", "\n", "\r", " ", "\t", ":", "/"]:
        if ch in package_name:
            fail((
                "flutter.pub hub \"{hub}\": package name {name} cannot be " +
                "a Bazel target name. Rename the package rather than " +
                "emitting a hub that cannot name it."
            ).format(
                hub = hub_name,
                name = repr(package_name),
            ))

def _classify_lock_packages(hub_name, lock_label, lock_pkgs):
    """Splits lock packages into hosted, git, path, Flutter-SDK, and all names."""
    hosted = {}
    git = {}
    path_pkgs = {}
    sdk_flutter = {}
    all_package_names = []
    for name, info in lock_pkgs.items():
        _fail_on_odd_package_name(hub_name, name)
        source = info.get("source", "unknown")
        if source == "hosted":
            hosted[name] = info
            all_package_names.append(name)
        elif source == "git":
            desc = info.get("description", {})
            desc = desc if type(desc) == "dict" else {}
            url = desc.get("url", "")
            if type(url) != "string" or not url:
                fail("flutter.pub hub \"{hub}\": git dependency \"{pkg}\" has no url in the lock. Re-resolve the lock.".format(
                    hub = hub_name,
                    pkg = name,
                ))
            path = desc.get("path", ".")
            git[name] = struct(
                version = info.get("version", ""),
                url = url,
                resolved_ref = str(desc.get("resolved-ref", "")).strip(),
                path = git_package_subdir(path if type(path) == "string" else "."),
            )
            all_package_names.append(name)
        elif source == "path":
            desc = info.get("description", {})
            entry_path = desc.get("path", "") if type(desc) == "dict" else ""
            relative_value = desc.get("relative", False) if type(desc) == "dict" else False
            if type(entry_path) != "string" or not entry_path or not is_relative_path_dependency(relative_value):
                fail("flutter.pub hub \"{hub}\": path dependency \"{pkg}\" has no workspace-relative path in the lock. Re-resolve the lock with a relative `path:` dependency.".format(
                    hub = hub_name,
                    pkg = name,
                ))
            if is_absolute_lock_path(entry_path):
                fail("flutter.pub hub \"{hub}\": path dependency \"{pkg}\" has absolute path {path} in the lock. Re-resolve the lock with a relative `path:` dependency inside the workspace.".format(
                    hub = hub_name,
                    pkg = name,
                    path = repr(entry_path),
                ))
            refusal = foreign_lock_path_error(hub_name, name, lock_label)
            if refusal:
                fail(refusal)
            path_pkgs[name] = struct(
                path = workspace_relative_lock_path(hub_name, name, lock_label, entry_path),
                version = info.get("version", ""),
            )
            all_package_names.append(name)
        elif source == "sdk":
            if name in _FLUTTER_SDK_PACKAGES:
                sdk_flutter[name] = info
                all_package_names.append(name)
            elif name != "sky_engine":
                fail(_unserved_sdk_package_error(hub_name, name, info))
        else:
            fail((
                "flutter.pub hub \"{hub}\": package \"{pkg}\" {version} has source \"{source}\", which " +
                "flutter.pub cannot serve: it serves hosted, git, path and sdk entries. Depend on the package " +
                "from a pub server, a git repository or a path inside the workspace, run `flutter pub get`, " +
                "and commit the lock."
            ).format(hub = hub_name, pkg = name, version = info.get("version", ""), source = source))
    return hosted, git, path_pkgs, sdk_flutter, all_package_names

def _workspace_root_of_lock(module_ctx, lock_label):
    """The workspace root holding a root-module lock file.

    A path dependency is workspace-relative, so the Android repository
    probe needs the root, not the lock's own directory. The lock is known
    to belong to the root module (see `foreign_lock_path_error`), so walk
    up its label's package components from the file's directory.

    Args:
        module_ctx: The module extension context.
        lock_label: The tag's lock label, in the root module.

    Returns:
        The absolute workspace root path string.
    """
    root = str(module_ctx.path(lock_label).dirname)
    package = lock_label.package
    if package:
        for _segment in package.split("/"):
            root = root.rpartition("/")[0]
    return root

def _path_packages_declaring_android(module_ctx, workspace_root, path_pkgs):
    """The path packages whose pubspec declares the `android` platform.

    The extension reads only the packages' own pubspecs, all in one `yaml2json`
    run, so a path package with no Android platform gets no Android
    repository at all. A missing pubspec reads as no Android platform; the
    path spoke's fetch reports the real problem.

    Args:
        module_ctx: The module extension context.
        workspace_root: The absolute workspace root.
        path_pkgs: Dict of path package name to its lock info struct.

    Returns:
        Dict of package name to True for each package whose
        `flutter.plugin.platforms.android` is present.
    """
    names = []
    paths = []
    for name in sorted(path_pkgs.keys()):
        pubspec_path = workspace_root + "/" + path_pkgs[name].path + "/pubspec.yaml"
        if not module_ctx.path(pubspec_path).exists:
            continue
        module_ctx.watch(pubspec_path)
        names.append(name)
        paths.append(pubspec_path)
    pubspecs = yaml_to_json(module_ctx, paths, [path_pkgs[name].path + "/pubspec.yaml" for name in names])
    return {
        name: True
        for name, pubspec in zip(names, pubspecs)
        if parse_flutter_plugin_block(pubspec).platforms.get("android", {})
    }

def _create_swiftpm_spokes(hub_name, pub_tag, module_ctx):
    """Creates one `swiftpm_package` spoke per SwiftPM pin.

    Reads the `swift_package_resolved` file, validates the sha256 and
    build-file dicts against it, and creates a
    `<hub>__swiftpm-<identity>` repo per pin. Unpinned entries still get a
    repo: it fails at fetch time (before any download) naming the
    `swift_package_sha256` fix. A `swift_package_build_files` entry swaps
    the generated BUILD file for a hand-written one; that file sees the
    package root (`Package.swift`, `Sources/...`, whatever the revision), for
    example `glob(["Sources/**/*.swift"])`.

    Args:
        hub_name: The hub repository name.
        pub_tag: The `flutter.pub` tag.
        module_ctx: The module context, for reading the resolved file.

    The resolved file is read here for the extension's own checks, but
    no hub-wide pin list reaches a spoke: each SwiftPM spoke gets only
    its own pin, and pub plugin spokes read the resolved file and
    checksum table lazily at fetch time. A pin or checksum edit
    therefore never changes a pure-Dart spoke.
    """
    config_error = check_swiftpm_config_present(
        str(pub_tag.swift_package_resolved) if pub_tag.swift_package_resolved else None,
        pub_tag.swift_package_sha256,
        pub_tag.swift_package_build_files,
    )
    if config_error:
        fail(config_error)
    if not pub_tag.swift_package_resolved:
        return
    resolved_label = str(pub_tag.swift_package_resolved)
    pins = read_swiftpm_pins(module_ctx.read(pub_tag.swift_package_resolved), resolved_label)
    if not pins.ok:
        fail(pins.error)
    dicts_error = check_swiftpm_dicts(
        pub_tag.swift_package_sha256,
        pub_tag.swift_package_build_files,
        [pin.identity for pin in pins.pins],
        resolved_label,
    )
    if dicts_error:
        fail(dicts_error)
    for pin in pins.pins:
        classified = classify_swiftpm_pin(pin, pub_tag.swift_package_sha256, hub_name, resolved_label)
        swiftpm_attrs = swiftpm_spoke_attrs(
            hub_name,
            pin,
            classified,
            pub_tag.swift_package_build_files.get(pin.identity),
        )
        swiftpm_package(
            name = swiftpm_attrs.name,
            identity = swiftpm_attrs.identity,
            hub_name = swiftpm_attrs.hub_name,
            archive_url = swiftpm_attrs.archive_url,
            sha256 = swiftpm_attrs.sha256,
            unpinned_error = swiftpm_attrs.unpinned_error,
            build_file = swiftpm_attrs.build_file,
        )
    return

def _collect_pub_hub(pub_tag, selected_info, user_overlay_roots, pub_yaml):
    """Checks one `flutter.pub` tag and classifies its lock for planning.

    Returns:
        A struct with the tag, its hub name, its packages by kind and its
        planning scope: the hosted and git packages, planned by rules_dart's planner
        in the hub's own namespace (`<hub>__<package>`).
    """
    hub_name = pub_tag.name
    podfile, lock_label = hub_podfile_lock(pub_tag, pub_yaml)

    validate_swift_package_product_deps(hub_name, pub_tag.swift_package_product_deps)
    _fail_on_invalid_maven_deps(hub_name, pub_tag.android_maven_deps)
    lock_data = pub_yaml[str(pub_tag.lock)]
    lock_pkgs = lock_packages(lock_data, str(pub_tag.lock))

    toolchain_info = selected_info.get(_DEFAULT_NAME)
    if not toolchain_info:
        fail("flutter.pub() requires a flutter.toolchain() to be registered.")

    _check_pub_flutter_floor(lock_data, toolchain_info, pub_tag)

    hosted_info, git, path_pkgs, sdk_flutter, all_package_names = _classify_lock_packages(hub_name, pub_tag.lock, lock_pkgs)
    cycle_error = cycle_breaks_lock_error(pub_tag.cycle_breaks, all_package_names, sdk_flutter)
    if cycle_error:
        fail(cycle_error)
    defines_error = ios_plugin_defines_lock_error(pub_tag.ios_plugin_defines, all_package_names, sdk_flutter)
    if defines_error:
        fail(defines_error)
    deps_error = ios_plugin_deps_lock_error(pub_tag.ios_plugin_deps, all_package_names, sdk_flutter)
    if deps_error:
        fail(deps_error)

    # Hosted packages are fetched by checksum only. An entry with no sha256
    # is a lock that predates the field, or was edited by hand; refuse it
    # rather than download unverified bytes.
    hosted = {}
    for name in sorted(hosted_info.keys()):
        info = hosted_info[name]
        desc = info.get("description", {})
        hosted[name] = struct(
            version = info.get("version", ""),
            sha256 = hosted_package_sha256(name, info, pub_tag.lock),
            url = desc.get("url", "https://pub.dev") if type(desc) == "dict" else "https://pub.dev",
        )
    return struct(
        hub_name = hub_name,
        pub_tag = pub_tag,
        overlay_roots = spoke_overlay_roots(user_overlay_roots),
        podfile = podfile,
        podfile_label = lock_label,
        hosted = hosted,
        git = git,
        path_pkgs = path_pkgs,
        sdk_flutter = sdk_flutter,
        all_package_names = sorted(all_package_names),
        toolchain_info = toolchain_info,
        scope = struct(hosted = hosted, git = git),
    )

def _plan_hub_graph(module_ctx, hub, plans):
    """Plans one hub's dependency cycles from the planned and the path packages' names.

    Hosted and git packages are planned by rules_dart's planner (`plans`).

    A path package has no server: its pubspec is read here, confined to the
    workspace. `cycle_breaks` drops its edges before the cycles are planned,
    and each break must name a dependency the package's pubspec declares.

    Returns:
        `struct(raw, kept, sccs)`: every package's planned names, the names
        left after `cycle_breaks`, and rules_dart's cycle plan.
    """
    raw = {name: plans[name]["deps"] for name in list(hub.hosted.keys()) + list(hub.git.keys())}
    raw.update(collect_path_deps(module_ctx, hub.hub_name, hub.path_pkgs, hub.pub_tag.lock))
    kept = {}
    for name in sorted(raw.keys()):
        applied = apply_cycle_breaks(name, raw[name], hub.pub_tag.cycle_breaks.get(name, []))
        if applied.error:
            fail(applied.error)
        kept[name] = applied.dependencies
    sccs = plan_scope_sccs(sorted(raw.keys()), {}, [hub.hub_name], hub.hub_name, kept)
    return struct(raw = raw, kept = kept, sccs = sccs)

def _flutter_spoke_attrs(hub, name, hook_settings):
    """The attributes every Flutter package repository of the hub shares, plus its own native and hook ones."""
    pub_tag = hub.pub_tag
    swiftpm_attrs = pub_spoke_swiftpm_attrs(pub_tag, include_ios_native_deps = True, plugin_name = name)
    return dict(
        hub_name = hub.hub_name,
        hub_packages = "@%s//:pub_packages.json" % hub.hub_name,
        plugin_defines = pub_tag.ios_plugin_defines.get(name, []),
        overlay_roots = hub.overlay_roots,
        package_resolved = swiftpm_attrs.package_resolved,
        package_sha256 = swiftpm_attrs.package_sha256,
        ios_native_deps = swiftpm_attrs.ios_native_deps,
        plugin_native_deps = swiftpm_attrs.plugin_deps,
        podfile_lock = swiftpm_attrs.podfile_lock,
        pubspec_lock = pub_tag.lock,
        **hook_repo_attrs(hook_settings.get(name))
    )

def _scc_member_spec(hub, member, plans, graph):
    """The `members_json` entry of one cycle member: its coordinates and planned names."""
    if member in hub.hosted:
        pkg = hub.hosted[member]
        return {
            "name": member,
            "source": "hosted",
            "version": pkg.version,
            "sha256": pkg.sha256,
            "url": plans[member]["archive_url"],
            "planned_deps": graph.raw[member],
        }
    if member in hub.git:
        pkg = hub.git[member]
        return {
            "name": member,
            "source": "git",
            "version": pkg.version,
            "url": pkg.url,
            "resolved_ref": pkg.resolved_ref,
            "path": pkg.path,
            "planned_deps": graph.raw[member],
        }
    path_info = hub.path_pkgs[member]
    return {
        "name": member,
        "source": "path",
        "path": path_info.path,
        "version": path_info.version,
        "planned_deps": graph.raw[member],
    }

def _emit_scc_spokes(hub, plans, graph, labels):
    """Creates one `flutter_pub_scc_package` per dependency cycle of the hub."""
    pub_tag = hub.pub_tag
    swiftpm_attrs = pub_spoke_swiftpm_attrs(pub_tag, include_ios_native_deps = True)
    for repo in sorted(graph.sccs.merged.keys()):
        members = graph.sccs.merged[repo]
        in_cycle = {m: True for m in members}
        outside = {}
        for m in members:
            for label in own_dep_labels(m, [d for d in graph.kept[m] if d not in in_cycle], labels):
                outside[label] = True
        if "flutter" in labels and "flutter" not in in_cycle:
            outside[labels["flutter"]] = True
        flutter_pub_scc_package(
            name = repo,
            repo_name = repo,
            hub_name = hub.hub_name,
            hub_packages = "@%s//:pub_packages.json" % hub.hub_name,
            members_json = json.encode([_scc_member_spec(hub, m, plans, graph) for m in members]),
            deps = sorted(outside.keys()),
            ios_plugin_defines = {m: pub_tag.ios_plugin_defines[m] for m in members if m in pub_tag.ios_plugin_defines},
            ios_plugin_deps = {
                m: str(pub_tag.ios_plugin_deps[m])
                for m in sorted(pub_tag.ios_plugin_deps)
                if m in in_cycle
            },
            overlay_roots = hub.overlay_roots,
            package_resolved = swiftpm_attrs.package_resolved,
            package_sha256 = swiftpm_attrs.package_sha256,
            ios_native_deps = swiftpm_attrs.ios_native_deps,
            podfile_lock = swiftpm_attrs.podfile_lock,
            pubspec_lock = pub_tag.lock,
        )

def _emit_pub_hub(module_ctx, hub, plans, hook_settings):
    """Generates one hub's repositories from its plan.

    Every package repository's attributes are its own: its coordinates, the
    names planning used, its own dependency labels (each the hub's alias,
    `@<hub>//:<dep>`), and the hub-wide plugin configuration. A package that
    an overlay replaces gets no Android repository: its spoke emits the
    overlay's Android template or the empty stub. Every other hosted package,
    and every path package that declares the `android` platform, gets a
    `<hub>-android-<package>` repository holding its Gradle model, fetched only
    when an Android target analyses the spoke's `android:lib` alias.
    """
    hub_name = hub.hub_name
    pub_tag = hub.pub_tag
    graph = _plan_hub_graph(module_ctx, hub, plans)
    labels = {name: "@%s//:%s" % (hub_name, name) for name in hub.all_package_names}

    for name in sorted(hub.hosted.keys()):
        pkg = hub.hosted[name]
        if name not in graph.sccs.members:
            flutter_pub_package(
                name = hub_name + "__" + name,
                package_name = name,
                version = pkg.version,
                sha256 = pkg.sha256,
                url = plans[name]["archive_url"],
                planned_deps = graph.raw[name],
                deps = own_dep_labels(name, graph.kept[name], labels),
                android_maven_deps = pub_tag.android_maven_deps,
                android_maven_ignore = pub_tag.android_maven_ignore,
                **_flutter_spoke_attrs(hub, name, hook_settings)
            )
        if not overlay_replaces_spoke(module_ctx, hub.overlay_roots, name, pkg.version):
            flutter_pub_android_package(
                name = android_package_repo_name(hub_name, name),
                package_name = name,
                version = pkg.version,
                hub_name = hub_name,
                sha256 = pkg.sha256,
                url = plans[name]["archive_url"],
                android_maven_deps = pub_tag.android_maven_deps,
                android_maven_ignore = pub_tag.android_maven_ignore,
            )

    for name in sorted(hub.git.keys()):
        pkg = hub.git[name]
        git_attrs = dict(url = pkg.url, resolved_ref = pkg.resolved_ref, git_path = pkg.path)
        if name not in graph.sccs.members:
            flutter_pub_git_package(
                name = hub_name + "__" + name,
                package_name = name,
                version = pkg.version,
                planned_deps = graph.raw[name],
                deps = own_dep_labels(name, graph.kept[name], labels),
                android_maven_deps = pub_tag.android_maven_deps,
                android_maven_ignore = pub_tag.android_maven_ignore,
                **dict(git_attrs, **_flutter_spoke_attrs(hub, name, hook_settings))
            )
        if not overlay_replaces_spoke(module_ctx, hub.overlay_roots, name, pkg.version):
            flutter_pub_android_package(
                name = android_package_repo_name(hub_name, name),
                package_name = name,
                version = pkg.version,
                hub_name = hub_name,
                android_maven_deps = pub_tag.android_maven_deps,
                android_maven_ignore = pub_tag.android_maven_ignore,
                **git_attrs
            )

    maven = path_spoke_maven_inputs(pub_tag)
    declares_android = _path_packages_declaring_android(module_ctx, _workspace_root_of_lock(module_ctx, pub_tag.lock), hub.path_pkgs)
    for name in sorted(hub.path_pkgs.keys()):
        path_info = hub.path_pkgs[name]
        if name not in graph.sccs.members:
            flutter_pub_path_package(
                name = hub_name + "__" + name,
                package_name = name,
                path = path_info.path,
                version = path_info.version,
                planned_deps = graph.raw[name],
                deps = own_dep_labels(name, graph.kept[name], labels),
                android_maven_deps = maven.deps,
                android_maven_ignore = maven.ignore,
                **_flutter_spoke_attrs(hub, name, hook_settings)
            )
        if name in declares_android and not overlay_replaces_spoke(module_ctx, hub.overlay_roots, name, path_info.version):
            flutter_pub_android_package(
                name = android_package_repo_name(hub_name, name),
                package_name = name,
                version = path_info.version,
                hub_name = hub_name,
                path = path_info.path,
                android_maven_deps = maven.deps,
                android_maven_ignore = maven.ignore,
            )

    _emit_scc_spokes(hub, plans, graph, labels)

    # A downloaded version's SDK spokes all link into the toolchain's one
    # shared source extraction; a local SDK's symlink the package out of the
    # local tree.
    declare_sdk_spokes(struct(hub_name = hub_name), sorted(hub.sdk_flutter.keys()), hub.toolchain_info)
    _create_swiftpm_spokes(hub_name, pub_tag, module_ctx)

    pod_hub = hub_cocoapods_attrs(hub_name, hub.all_package_names, hub.podfile, hub.podfile_label, pub_tag)
    pub_lock_hub(
        name = hub_name,
        hub_name = hub_name,
        spoke_prefix = hub_name,
        packages = hub.all_package_names,
        scc_targets = hub_scc_targets(graph.sccs.members),
        files = flutter_pub_hub_files(
            hub_name,
            hub.all_package_names,
            graph.sccs.members,
            pub_tag.swift_package_sha256,
            ios_native_deps_json(
                {key: str(pub_tag.swift_package_product_deps[key]) for key in pub_tag.swift_package_product_deps},
                pod_hub.ios_pod_deps,
                pod_hub.ios_pod_ignore,
                pod_hub.ios_pods_json,
            ),
            hub_package_graph(
                {name: pkg.version for pkgs in (hub.hosted, hub.git, hub.path_pkgs) for name, pkg in pkgs.items()},
                graph.raw,
            ),
        ),
    )

def _register_pub_hubs(module_ctx, selected_info, root_overlay_roots, pub_yaml):
    """Plans every `flutter.pub` tag with rules_dart's planner and generates its repositories.

    All hubs are planned together: one listing request per distinct hosted
    package name, none for a package the lockfile facts already plan.

    Returns:
        The facts to record, or None when no tag declares a hosted package.
    """
    hubs = []
    for mod in module_ctx.modules:
        for pub_tag in mod.tags.pub:
            hubs.append(_collect_pub_hub(
                pub_tag,
                selected_info,
                hub_overlay_roots(root_overlay_roots, _overlay_roots_of_module(mod), mod.is_root),
                pub_yaml,
            ))
    hook_settings = lock_hook_settings(module_ctx, [
        struct(
            name = hub.hub_name,
            isolated = True,
            lock = hub.pub_tag.lock,
            hook_data = hub.pub_tag.hook_data,
            hook_network = hub.pub_tag.hook_network,
        )
        for hub in hubs
    ], "") if hubs else {}
    if not any([hub.hosted or hub.git for hub in hubs]):
        for hub in hubs:
            _emit_pub_hub(module_ctx, hub, {}, hook_settings.get(hub.hub_name, {}))
        return None

    # The archive fallback scans through rules_dart's scanner; resolving its
    # label on every evaluation keeps cold and warm lockfiles identical.
    touch_scanner_runtime_label(module_ctx)
    recorded = {}
    plan_files = [hub.pub_tag.plan for hub in hubs if hub.pub_tag.plan]
    scope_plans = plan_pub_graph(
        module_ctx,
        [hub.scope for hub in hubs],
        recorded,
        read_pub_plans(module_ctx, plan_files),
        rule = "flutter.pub",
    )
    for hub, plans in zip(hubs, scope_plans):
        _emit_pub_hub(module_ctx, hub, plans, hook_settings.get(hub.hub_name, {}))
    return recorded

def _overlay_roots_of_module(mod):
    """Overlay roots one module declares, in tag order."""
    roots = []
    for tag in mod.tags.plugin_overlays:
        roots.extend(tag.roots)
    return roots

def _toolchain_extension(module_ctx):
    darwin_sdk = resolve_darwin_sdk_from_modules(module_ctx.modules)

    # Custom versions first: every later lookup resolves against the merged
    # tables, so a custom release behaves exactly like a stock one.
    merged = merge_custom_versions(_collect_custom_tags(module_ctx.modules))

    # Pub lock floors, collected before any toolchain registers: download mode
    # checks them at evaluation below, while local mode hands them to the
    # host repos, which check them against the local SDK's own version at
    # fetch time (the version is only known once the SDK is read).
    pub_yaml = _read_pub_yaml(module_ctx)
    lock_flutter_constraints = _collect_lock_floors(module_ctx, pub_yaml)

    registrations = _collect_registrations(module_ctx.modules)
    selected_info = _register_all_toolchains(module_ctx, registrations, merged, lock_flutter_constraints, darwin_sdk)

    # Collect user-supplied overlay roots from `flutter.plugin_overlays(...)`
    # tags. Each hub consults the root module's roots first, then its own
    # module's roots (see `hub_overlay_roots`): a dependency's overlays
    # never reach the root's hubs or another module's hubs.
    root_overlay_roots = []
    for mod in module_ctx.modules:
        if mod.is_root:
            root_overlay_roots.extend(_overlay_roots_of_module(mod))

    # Handle flutter.pub() tags — resolve pubspec.lock with Flutter SDK support.
    recorded = _register_pub_hubs(module_ctx, selected_info, root_overlay_roots, pub_yaml)

    # Which repositories are those hubs, for an app's default `pub_packages`,
    # and what gen-l10n writes for each project of their locks.
    register_pub_hubs_index(module_ctx)
    register_l10n_repos(module_ctx, pub_yaml)

    # Don't declare root_module_direct_deps: flutter_register_toolchains creates
    # many repos (iOS, Android, web, desktop, cross-compile per platform) and
    # each user workspace only needs a subset — a macOS-only app doesn't want
    # Android engine repos forced into its use_repo. Declaring a strict subset
    # makes `bazel mod tidy` strip out repos the user actually needs; declaring
    # the full set makes tidy force repos they don't. Letting users maintain
    # their own use_repo lists (rules_python does the same) is the right
    # tradeoff for an extension with this many optional outputs.
    if recorded:
        return module_ctx.extension_metadata(facts = recorded)
    return module_ctx.extension_metadata(reproducible = True)

flutter = module_extension(
    implementation = _toolchain_extension,
    tag_classes = {
        "toolchain": flutter_toolchain,
        "version": flutter_version,
        "pub": flutter_pub_tag,
        "plugin_overlays": _flutter_plugin_overlays,
        "darwin_sdk": _flutter_darwin_sdk,
    },
    doc = "Installs a Flutter SDK toolchain and optionally resolves pub dependencies including Flutter SDK packages.",
)
