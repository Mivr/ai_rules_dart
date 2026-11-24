"""The asset bundle of an app, written by the Flutter tool's own code.

Every rule that bundles assets calls `flutter_bundle` (or, for web,
`flutter_web_bundle`), which runs the release's asset tool
(`flutter_assets_tool.bzl`) as one action. The tool reads the app's
`pubspec.yaml` as `flutter build` does and writes what the tool writes:
assets and their variants, fonts, shaders, the manifests and `NOTICES`, and on
web the bootstrap files and the service worker.

The app's pubspec is the source of truth for what is bundled. The files it
names are inputs of the action: the app's own through `pubspec_srcs`, each
package's through its `data` (a pub spoke lists the files its pubspec names)
and the non-Dart files of its `lib/` (`resources`), where an asset spelled
`packages/<name>/<path>` is read from. A file the pubspec names that is not an
input fails the action, naming it.

What the action reads, per build mode: the pubspec and the files it names, the
pubspec and licence of every package in the package config, and the engine
tools that compile shaders. A release or profile build that shakes icons also
reads the app's kernel; a debug build never does, so a Dart edit does not
rerun it.
"""

load("@flutter_pub_hubs//:hubs.bzl", "PUB_HUBS", "PUB_HUBS_BY_PACKAGE")
load("@rules_dart//dart:providers.bzl", "DartInfo")
load("@rules_dart//dart:utils.bzl", "dart_info_no_package", "owned_package_records")
load("//flutter:providers.bzl", "FlutterInfo")
load("//flutter/private:flutter_assets_tool.bzl", "flutter_assets_tool_of")

visibility(["//flutter/..."])

FlutterPubPackagesInfo = provider(
    doc = "What a `flutter_pub_packages` target knows about its lock besides the packages.",
    fields = {
        "android_plugins": "list[str]: `<name> <version>` of every package of the lock that is a Flutter plugin with an Android implementation (as `.flutter-plugins-dependencies` lists them), sorted. What an app's Android pin depends on of the lock.",
        "package_graph": "File or None: the lock's package graph, in the shape of pub's `.dart_tool/package_graph.json`, without the project's own package.",
    },
)

def hub_packages_of_deps(hubs, deps):
    """The `packages` target of the hub the first of `deps` from one belongs to, or None.

    Args:
      hubs: `PUB_HUBS`: each hub's canonical repository name, to its `packages`.
      deps: The target's `deps` labels.

    Returns:
      A `Label`, or None.
    """
    for dep in deps:
        packages = hubs.get(dep.repo_name)
        if packages:
            return packages
    return None

def _hub_packages_of(deps):
    return hub_packages_of_deps(PUB_HUBS, deps)

def hub_packages_of_package(by_package, package):
    """The `packages` of the hub whose lock is in `package` or the nearest enclosing package.

    Args:
      by_package: `PUB_HUBS_BY_PACKAGE`: each package holding a hub's lock, to
        that hub's `packages` (None: two different locks).
      package: The target's package, `native.package_name()`.

    Returns:
      A `Label`, or None when no package on the way holds a lock, or the
      nearest one holds two different locks (then the first dependency's
      hub applies).
    """
    parts = package.split("/") if package else []
    for i in range(len(parts), -1, -1):
        candidate = "/".join(parts[:i])
        if candidate in by_package:
            return by_package[candidate]
    return None

def project_pub_packages(kwargs):
    """Sets `pub_packages` to the hub of the project's lock, unless it is set.

    For the app, test and web macros: the hub whose lock is in the target's
    package or the nearest enclosing one (`hub_packages_of_package`). Without
    one the rule's default, the first dependency's hub, applies.

    Args:
      kwargs: The target's arguments; changed in place.
    """
    if "pub_packages" in kwargs or native.repo_name():
        return
    packages = hub_packages_of_package(PUB_HUBS_BY_PACKAGE, native.package_name())
    if packages:
        kwargs["pub_packages"] = packages

BUNDLE_ATTRS = {
    "pubspec": attr.label(
        doc = "The app's `pubspec.yaml`, which says what is bundled, as it does for " +
              "`flutter build`. Its directory is the project directory. Without one, the " +
              "bundle holds only what the packages of `deps` contribute.",
        allow_single_file = [".yaml"],
    ),
    "pubspec_srcs": attr.label_list(
        doc = "The files `pubspec.yaml` names (assets, fonts, shaders, `web/`), and " +
              "`l10n.yaml` with the files it names. A file the pubspec names that is not " +
              "listed here fails the build, naming it.",
        allow_files = True,
    ),
    "pub_packages": attr.label(
        doc = "Every package of the lock (`@<hub>//packages`), so the package config " +
              "the tool reads lists dev dependencies too, as `pub get` writes it: " +
              "`NOTICES` holds their licences. By default (set by the macros) the `packages` " +
              "of the `flutter.pub` hub whose lock is in the target's package or the nearest " +
              "enclosing one; failing that, of the hub the first of `deps` that comes from " +
              "one belongs to; without a hub, the packages of `deps`.",
        providers = [DartInfo],
        # Only the packages' files are read, and they do not depend on the
        # configuration; in the app's own (say Android) configuration a package
        # such as `test`, whose runner needs a Dart toolchain, would not resolve.
        cfg = "exec",
    ),
    "_hub_packages": attr.label(
        doc = "The default of `pub_packages`: the `packages` of the hub of `deps`.",
        default = _hub_packages_of,
        providers = [DartInfo],
        cfg = "exec",
    ),
    "build_name": attr.string(
        doc = "The version name, as `flutter build --build-name` takes it; by default the " +
              "pubspec's `version`. It reaches `version.json`.",
    ),
    "build_number": attr.string(
        doc = "The build number, as `flutter build --build-number` takes it; by default " +
              "the pubspec's. It reaches `version.json`.",
    ),
    "asset_transformers": attr.label_keyed_string_dict(
        doc = "Executables run for the pubspec's asset `transformers`, each to the " +
              "package name the pubspec names: what `dart run <package>` runs for " +
              "`flutter build`.",
        cfg = "exec",
    ),
    "_bundle_sky_engine": attr.label(
        doc = "`package:sky_engine`, which every package config lists and whose licence is in `NOTICES`.",
        default = Label("@flutter_sky_engine//:sky_engine"),
        providers = [DartInfo],
    ),
}

# The tool's name for each bundling platform (`getTargetPlatformForName`).
_TOOL_PLATFORMS = {
    "android": "android",
    "ios": "ios",
    "linux": "linux-x64",
    "macos": "darwin",
    "tester": "flutter-tester",
    "web": "web-javascript",
    "windows": "windows-x64",
}

def _exec_root(short_path):
    """The exec-root-relative path of a source directory, from its short path."""
    if short_path.startswith("../"):
        return "external/" + short_path[3:]
    return short_path or "."

def _package_arg(record):
    """`--package` value of one `DartPackageInfo` record, or None for an unnamed one."""
    if not record.package_name:
        return None
    return "%s=%s=%s" % (record.package_name, _exec_root(record.lib_root), getattr(record, "language_version", ""))

def _dir_short_path(f):
    return f.short_path.rpartition("/")[0]

def _tool_sdk_rel(f, marker):
    """The part of `f`'s path from `marker` on, or None."""
    i = f.path.find(marker)
    return f.path[i:] if i >= 0 else None

def _pub_packages(ctx):
    return ctx.attr.pub_packages or ctx.attr._hub_packages

def lock_android_plugins(ctx):
    """The Android plugins of the app's own pub lock, or None when its packages come from another.

    The lock is the app's own when a `flutter.pub` hub reads the `pubspec.lock` of the app's
    package; an app in a subdirectory of a project whose hub it shares has a `pubspec.lock` of its
    own that no hub reads, and only the plugins it depends on are known.

    Args:
        ctx: The context of a rule with `BUNDLE_ATTRS`.

    Returns:
        `FlutterPubPackagesInfo.android_plugins` of the app's `pub_packages`, or None.
    """
    pub = _pub_packages(ctx)
    if not pub or FlutterPubPackagesInfo not in pub or ctx.label.repo_name:
        return None
    own = PUB_HUBS_BY_PACKAGE.get(ctx.label.package)
    return pub[FlutterPubPackagesInfo].android_plugins if own and own == pub.label else None

def _bundle_infos(ctx):
    infos = [d[DartInfo] for d in ctx.attr.deps if DartInfo in d]
    if _pub_packages(ctx):
        infos.append(_pub_packages(ctx)[DartInfo])
    infos.append(ctx.attr._bundle_sky_engine[DartInfo])
    return infos

def _bundle_pubspec(ctx, package_name):
    """The pubspec, and the directory it is the project of."""
    if ctx.file.pubspec:
        return ctx.file.pubspec
    pubspec = ctx.actions.declare_file(ctx.label.name + "_bundle/pubspec.yaml")
    ctx.actions.write(pubspec, "name: %s\n" % package_name)
    return pubspec

def _sanitized(name):
    return "".join([c if c.isalnum() or c == "_" else "_" for c in name.elems()]).lower()

def _common_args(ctx, tool, flutter_sdk_info, mode, flavor, args, inputs, extra_project_files = {}):
    """The arguments and inputs every command shares."""
    package_name = getattr(ctx.attr, "package_name", "") or _sanitized(ctx.label.name)
    pubspec = _bundle_pubspec(ctx, package_name)
    project = _dir_short_path(pubspec)
    args.add("--project", pubspec.dirname)
    args.add("--label", str(ctx.label))
    args.add("--flutter-version", flutter_sdk_info.version)
    args.add("--engine-revision", flutter_sdk_info.engine_revision)
    args.add("--mode", mode)
    if flavor:
        args.add("--flavor", flavor)
    if getattr(ctx.attr, "build_name", ""):
        args.add("--build-name", ctx.attr.build_name)
    if getattr(ctx.attr, "build_number", ""):
        args.add("--build-number", ctx.attr.build_number)
    args.add("--project-file", "pubspec.yaml=" + pubspec.path)
    inputs.append(pubspec)
    for rel in sorted(extra_project_files):
        args.add("--project-file", rel + "=" + extra_project_files[rel].path)
        inputs.append(extra_project_files[rel])
    for f in ctx.files.pubspec_srcs:
        if not f.short_path.startswith(project + "/") and project:
            fail("%s: %s in `pubspec_srcs` is not under the pubspec's directory %s." % (ctx.label, f.short_path, project))
        rel = f.short_path[len(project) + 1:] if project else f.short_path
        if rel in extra_project_files:
            continue
        args.add("--project-file", rel + "=" + f.path)
        inputs.append(f)

    infos = _bundle_infos(ctx)

    # Expanded at execution; the tool keeps the first entry of a name.
    args.add_all(
        depset(transitive = [i.transitive_packages for i in infos]),
        map_each = _package_arg,
        before_each = "--package",
        uniquify = True,
    )

    # Each package's own files, and the non-Dart files of its `lib/`: an asset
    # spelled `packages/<name>/<path>` is read from `lib/<path>` of package
    # `<name>`, whichever pubspec names it.
    package_files = depset(transitive = [getattr(i, "transitive_package_files", depset()) for i in infos] + [i.transitive_resources for i in infos])
    pub = _pub_packages(ctx)
    graph = pub[FlutterPubPackagesInfo].package_graph if pub and FlutterPubPackagesInfo in pub else None
    if graph:
        args.add("--package-graph", graph.path)
        inputs.append(graph)

    for f in tool.framework_shaders:
        args.add("--sdk", _tool_sdk_rel(f, "packages/flutter/lib/") + "=" + f.path)
    inputs.extend(tool.framework_shaders)
    if flutter_sdk_info.material_icons_font:
        args.add("--sdk", "bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf=" + flutter_sdk_info.material_icons_font.path)
        inputs.append(flutter_sdk_info.material_icons_font)
    if flutter_sdk_info.impellerc:
        args.add("--engine", "impellerc=" + flutter_sdk_info.impellerc.path)
        inputs.append(flutter_sdk_info.impellerc)
        for f in flutter_sdk_info.shader_lib:
            args.add("--shader-lib", _tool_sdk_rel(f, "shader_lib/")[len("shader_lib/"):] + "=" + f.path)
        inputs.extend(flutter_sdk_info.shader_lib)

    tools = []
    for target, package in ctx.attr.asset_transformers.items():
        run = target[DefaultInfo].files_to_run
        if not run.executable:
            fail("%s: asset transformer %s is not executable." % (ctx.label, target.label))
        args.add("--transformer", package + "=" + run.executable.path)
        tools.append(run)
    return package_files, tools

def _icon_tree_shaking(ctx, flutter_sdk_info, mode, app_dill, args, inputs):
    """Shakes the icon fonts as `flutter build` does: release and profile, from the kernel."""
    if mode == "debug" or not app_dill or not getattr(ctx.attr, "tree_shake_icons", False):
        return []
    if not flutter_sdk_info.const_finder or not flutter_sdk_info.font_subset:
        fail("%s: `tree_shake_icons` is set, but the Flutter toolchain has no `const_finder` or `font-subset` for the execution platform." % ctx.label)
    args.add("--tree-shake-icons")
    args.add("--app-dill", app_dill.path)
    args.add("--engine", "const_finder=" + flutter_sdk_info.const_finder.path)
    args.add("--engine", "font_subset=" + flutter_sdk_info.font_subset.path)
    args.add("--sdk", "bin/cache/dart-sdk/bin/dart=" + flutter_sdk_info.dart.path)
    inputs.extend([app_dill, flutter_sdk_info.const_finder, flutter_sdk_info.font_subset, flutter_sdk_info.dart])
    return [flutter_sdk_info.dart_vm_files]

def _run_tool(ctx, tool, command, args, inputs, transitive, tools, outputs, mnemonic, progress):
    args.use_param_file("@%s", use_always = True)
    args.set_param_file_format("multiline")
    ctx.actions.run(
        executable = tool.runtime,
        arguments = [tool.snapshot.path, command, args],
        inputs = depset(direct = [tool.snapshot] + inputs, transitive = transitive),
        tools = tools,
        outputs = outputs,
        # The tool's web code finds its templates under FLUTTER_ROOT, read
        # from the project directory it works in: the Flutter root it stages
        # beside it.
        env = {"FLUTTER_ROOT": "../flutter"},
        mnemonic = mnemonic,
        progress_message = progress,
        toolchain = None,
    )

def flutter_bundle(
        ctx,
        flutter_sdk_info,
        output_dir,
        target_platform,
        mode,
        flavor = None,
        app_dill = None,
        data_assets = None,
        native_assets_manifest = None,
        deferred_components = False):
    """Writes `flutter_assets/` as `flutter build` does for `target_platform`.

    Args:
      ctx: The rule context; its rule has `BUNDLE_ATTRS` and `deps`.
      flutter_sdk_info: The resolved `FlutterSdkInfo`.
      output_dir: The tree artifact to write, from `declare_flutter_assets_dir`.
      target_platform: `android`, `ios`, `linux`, `macos`, `windows` or `tester`.
      mode: `debug`, `profile` or `release`.
      flavor: The flavor, or None.
      app_dill: The app's kernel, which the icon tree shaker reads in release
        and profile; unused in debug.
      data_assets: depset of `FlutterDataAssetInfo`: the link hooks' data
        assets, bundled at `packages/<package>/<name>`.
      native_assets_manifest: The `NativeAssetsManifest.json` to bundle, or None.
      deferred_components: Whether deferred components' assets are split out.

    Returns:
      `output_dir`.
    """
    tool = flutter_assets_tool_of(flutter_sdk_info, ctx.label)
    if target_platform not in _TOOL_PLATFORMS:
        fail("%s: no asset bundle for platform %r." % (ctx.label, target_platform))
    args = ctx.actions.args()
    inputs = []
    args.add("--out", output_dir.path)
    args.add("--platform", _TOOL_PLATFORMS[target_platform])
    package_files, tools = _common_args(ctx, tool, flutter_sdk_info, mode, flavor, args, inputs)
    transitive = [package_files] + _icon_tree_shaking(ctx, flutter_sdk_info, mode, app_dill, args, inputs)
    if data_assets:
        # lint-allow: depset-flatten each hook data asset's file is an input and its package and name an argument; a link hook yields a handful
        for entry in data_assets.to_list():
            args.add("--data-asset", "%s=%s=%s" % (entry.package, entry.name, entry.file.path))
            inputs.append(entry.file)
    if native_assets_manifest:
        args.add("--native-assets-manifest", native_assets_manifest.path)
        inputs.append(native_assets_manifest)
    if deferred_components:
        args.add("--deferred-components")
    _run_tool(
        ctx,
        tool,
        "assets",
        args,
        inputs,
        transitive,
        tools,
        [output_dir],
        "FlutterAssets",
        "Bundling the assets of %{label}",
    )
    return output_dir

def flutter_web_bundle(
        ctx,
        flutter_sdk_info,
        output_dir,
        mode,
        web_build,
        web_sdk_files,
        flavor = None,
        app_dill = None,
        base_href = None,
        static_assets_url = None,
        pwa_strategy = None,
        renderer = None,
        wasm = False,
        source_maps = False,
        web_defines = {},
        use_local_canvaskit = False,
        dev_bootstrap = None,
        extra_project_files = {}):
    """Writes a web app's directory as `flutter build web` does, around its compiled files.

    Args:
      ctx: The rule context; its rule has `BUNDLE_ATTRS` and `deps`.
      flutter_sdk_info: The resolved `FlutterSdkInfo`.
      output_dir: The tree artifact to write.
      mode: `debug`, `profile` or `release`.
      web_build: The compiled files (`main.dart.js` and its parts,
        `main.dart.wasm`, `main.dart.mjs`, ...), Files or tree artifacts,
        copied into the output by name.
      web_sdk_files: The Flutter web SDK's files (`flutter_js/flutter.js`,
        `canvaskit/...`).
      flavor: The flavor, or None.
      app_dill: The app's kernel, for icon tree shaking in release.
      base_href: `--base-href`, or None.
      static_assets_url: `--static-assets-url`, or None.
      pwa_strategy: `--pwa-strategy`, or None.
      renderer: The web renderer name, or None.
      wasm: Whether the app is built with `--wasm`.
      source_maps: Whether source maps are kept.
      web_defines: `--web-define` values, by name.
      use_local_canvaskit: `--no-web-resources-cdn`: the renderer is
        loaded from the app's own server.
      dev_bootstrap: A File to write the `flutter_bootstrap.js` the dev
        loop serves beside a DDC build into, or None.
      extra_project_files: Project files the rule writes itself, by path
        under the project (a test harness's `web/index.html`); they win over
        `pubspec_srcs` at the same path.

    Returns:
      `output_dir`.
    """
    tool = flutter_assets_tool_of(flutter_sdk_info, ctx.label)
    args = ctx.actions.args()
    inputs = []
    outputs = [output_dir]
    args.add("--out", output_dir.path)
    for name in sorted(web_defines):
        args.add("--web-define", name + "=" + web_defines[name])
    if use_local_canvaskit:
        args.add("--use-local-canvaskit")

        # Stock bundles this file from the engine source as the fallback font
        # of a local CanvasKit; the Material fonts artifact carries the same bytes.
        material = None
        for t in ("@rules_flutter//flutter/private:material_icons_toolchain_type", "@rules_flutter//flutter:material_icons_toolchain_type"):
            if t in ctx.toolchains and ctx.toolchains[t]:
                material = ctx.toolchains[t]
                break
        roboto = getattr(material, "roboto_font", None)
        if roboto:
            args.add("--sdk", "engine/src/flutter/txt/third_party/fonts/Roboto-Regular.ttf=" + roboto.path)
            inputs.append(roboto)
    if dev_bootstrap:
        args.add("--dev-bootstrap", dev_bootstrap.path)
        outputs.append(dev_bootstrap)
    package_files, tools = _common_args(ctx, tool, flutter_sdk_info, mode, flavor, args, inputs, extra_project_files)
    transitive = [package_files] + _icon_tree_shaking(ctx, flutter_sdk_info, mode, app_dill, args, inputs)
    args.add("--sdk", "packages/flutter_tools/lib/src/web/file_generators/js/flutter_service_worker.js=" + tool.service_worker.path)
    inputs.append(tool.service_worker)
    for f in web_sdk_files:
        for marker in ("/flutter_js/", "/canvaskit/"):
            i = f.path.find(marker)
            if i >= 0:
                args.add("--sdk", "bin/cache/flutter_web_sdk" + f.path[i:] + "=" + f.path)
                inputs.append(f)
                break
    for f in web_build:
        args.add("--web-build", f.path)
        inputs.append(f)
    for flag, value in (
        ("--base-href", base_href),
        ("--static-assets-url", static_assets_url),
        ("--pwa-strategy", pwa_strategy),
        ("--renderer", renderer),
    ):
        if value:
            args.add(flag, value)
    if wasm:
        args.add("--wasm")
    if source_maps:
        args.add("--source-maps")
    _run_tool(
        ctx,
        tool,
        "web",
        args,
        inputs,
        transitive,
        tools,
        outputs,
        "FlutterWebBundle",
        "Writing the web bundle of %{label}",
    )
    return output_dir

def implements_android(plugin):
    """Whether a plugin record has an Android implementation.

    It has one when its pubspec has `flutter.plugin.platforms.android` and that entry does not hand
    the platform to another package (`default_package`), as the Flutter tool decides it.

    Args:
        plugin: A plugin record of `FlutterInfo.plugins`.

    Returns:
        True or False.
    """
    android = plugin.platforms.get("android")
    return type(android) == "dict" and "default_package" not in android

def _android_plugins(deps):
    """`<name> <version>` of the plugins among `deps` that have an Android implementation."""
    plugins = []
    for dep in deps:
        if FlutterInfo not in dep:
            continue
        versions = {record.package_name: record.version for record in owned_package_records(dep[DartInfo])}
        for plugin in dep[FlutterInfo].plugins:
            if getattr(plugin, "_depth", 0) == 0 and implements_android(plugin):
                plugins.append("%s %s" % (plugin.name, versions.get(plugin.name, "")))
    return sorted(plugins)

def _flutter_pub_packages_impl(ctx):
    return [
        dart_info_no_package(deps = ctx.attr.deps),
        FlutterPubPackagesInfo(
            android_plugins = _android_plugins(ctx.attr.deps),
            package_graph = ctx.file.package_graph,
        ),
    ]

flutter_pub_packages = rule(
    implementation = _flutter_pub_packages_impl,
    doc = "Every package of a pub lock, for an app's `pub_packages`. A Flutter hub declares one as `@<hub>//packages`.",
    attrs = {
        "deps": attr.label_list(
            doc = "The lock's packages.",
            providers = [DartInfo],
        ),
        "package_graph": attr.label(
            doc = "The lock's package graph (`@<hub>//:package_graph.json`), which the asset tool completes with the project's own package and the packages the lock does not plan.",
            allow_single_file = [".json"],
        ),
    },
)

def bundle_shader_sources(ctx):
    """The app's own shaders, for the dev tool: `{bundle key: [workspace path]}`.

    A shader the pubspec lists is a `.frag` among `pubspec_srcs`; its bundle
    key is its path under the project directory, as the Flutter tool keys it.
    The dev tool watches these and has the app reload a shader that changed.

    Args:
      ctx: The rule context; its rule has `BUNDLE_ATTRS`.

    Returns:
      The bundle-key-to-source-paths map.
    """
    if not ctx.file.pubspec:
        return {}
    project = _dir_short_path(ctx.file.pubspec)
    prefix = project + "/" if project else ""
    return {
        f.short_path[len(prefix):]: [f.short_path] if f.is_source and not f.short_path.startswith("../") else []
        for f in ctx.files.pubspec_srcs
        if f.extension == "frag" and f.short_path.startswith(prefix)
    }
