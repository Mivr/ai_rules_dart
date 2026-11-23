"""Shared `flutter_assets/` tree build action.

Leaf module for the action both `flutter_asset_bundle` and the shared asset
bundling step in `//flutter/private:common.bzl` register. Kept apart from the
rule so the rule can load the shader helpers from `common.bzl` without a
load cycle.
"""

load("//flutter/private:asset_uri.bzl", "decode_asset_key")
load("//flutter/private:asset_variant.bzl", "parent_dir_dpr", "variant_dir_dpr")

visibility(["//flutter/..."])

def detect_dpr(path):
    """Detect device-pixel-ratio from the file's immediate parent directory.

    Mirrors flutter_tools 3.47.7 (`asset.dart:935-947`, `:1626`): only the
    file's own parent directory counts, and any `<number>x` name is a
    variant (see `variant_dir_dpr`). `assets/2x/sub/a.png` therefore stays
    its own asset: its parent `sub` is not a variant.

    Args:
        path: Asset path string (e.g. "assets/2.0x/icon.png").

    Returns:
        (base_path, dpr) tuple.  base_path has the DPR dir removed (e.g.
        "assets/icon.png").  dpr is a float or None if not a variant.
    """
    parts = path.split("/")
    if len(parts) < 2:
        return path, None
    dpr = variant_dir_dpr(parts[len(parts) - 2])
    if dpr == None:
        return path, None
    return "/".join(parts[:len(parts) - 2] + parts[len(parts) - 1:]), dpr

def _collapse_empty_segments(key):
    """Drop the empty segments of one encoded bundle key.

    Mirrors how flutter_tools reads an entry whose URI keeps an empty
    segment: it keys the manifest by the raw path (`entryUri.path`) but
    opens the collapsed file (the OS resolves `f//fm.png` to `f/fm.png`).
    `a//b.png` collapses to `a/b.png`; a key without empty segments is
    unchanged.

    Args:
        key: The encoded bundle key.

    Returns:
        The key with every empty `/`-separated piece removed.
    """
    return "/".join([part for part in key.split("/") if part != ""])

def _raw_manifest_variants(raw_key, assets):
    """The manifest variants of one raw (`//`-keeping) bundle key.

    Mirrors one flutter_tools manifest entry for an entry whose URI keeps
    an empty segment (`asset.dart:905-975`, `1217-1270`): the raw key
    itself, the collapsed path (its file is what the spoke read, so it
    exists whenever the raw key was emitted), then the collapsed
    directory's variant files present in the bundle, each with the dpr of
    its own parent directory.

    Args:
        raw_key: The encoded bundle key keeping an empty segment.
        assets: Every encoded bundle key, for the variant scan.

    Returns:
        The variant dict list for the raw key's manifest entry.
    """
    collapsed = _collapse_empty_segments(raw_key)
    raw_variant = {"asset": decode_asset_key(raw_key)}
    raw_dpr = parent_dir_dpr(raw_key)
    if raw_dpr != None:
        raw_variant["dpr"] = raw_dpr
    collapsed_variant = {"asset": decode_asset_key(collapsed)}
    collapsed_dpr = parent_dir_dpr(collapsed)
    if collapsed_dpr != None:
        collapsed_variant["dpr"] = collapsed_dpr
    variants = [raw_variant, collapsed_variant]
    for path in sorted(assets):
        if path == raw_key or path == collapsed or "" in path.split("/"):
            continue
        base, _stripped = detect_dpr(path)
        if base != collapsed:
            continue
        variant = {"asset": decode_asset_key(path)}
        variant_dpr = parent_dir_dpr(path)
        if variant_dpr != None:
            variant["dpr"] = variant_dpr
        variants.append(variant)
    return variants

def _dedupe_bundle_keys(assets):
    """One copy of each encoded bundle key, in sorted order.

    The same file reaches the bundle once per declaring entry (two entries
    declaring `a/b.png` both carry `a/2.0x/b.png`), while the copies map
    already collapses to one file per key. Grouping a repeated key twice
    would list its variant twice; flutter_tools keeps one
    manifest entry per declaration key instead (`asset.dart:905-930`), so a
    repeat contributes nothing.

    Args:
        assets: The encoded bundle keys, possibly with repeats.

    Returns:
        The sorted keys with repeats removed.
    """
    seen = {}
    for path in assets:
        seen[path] = True
    return sorted(seen.keys())

def _collapsed_claims(assets):
    """The raw (`//`-keeping) claimant of each collapsed bundle key.

    One raw key per collapsed path: `build_asset_manifest` lets a
    collapsed file (or its variants) without its own declaration ride its
    claimant's entry instead of gaining a key that would name a file the
    entry did not declare.

    Args:
        assets: Every encoded bundle key.

    Returns:
        dict mapping each collapsed path to its raw claimant key.
    """
    collapsed_of = {}
    for path in sorted(assets):
        if "" in path.split("/"):
            collapsed = _collapse_empty_segments(path)
            if collapsed not in collapsed_of:
                collapsed_of[collapsed] = path
    return collapsed_of

def build_asset_manifest(assets):
    """Build the asset manifest structure from a list of encoded asset keys.

    Mirrors `_createAssetManifest` (flutter_tools 3.47.7 `asset.dart:905-930`):
    the input lists the encoded bundle keys (what the copied files are named,
    `bundle_builder.dart:182`), while every manifest key and variant path is
    `Uri.decodeFull` of its key. Variant grouping still reads the encoded
    keys, as flutter_tools groups by `entryUri.path`. Font assets never reach
    here; FontManifest keeps the encoded `assetUri.path`
    (`flutter_manifest.dart:480`).

    A key keeping an empty segment groups flutter_tools' entry under its
    raw key (see `_raw_manifest_variants`): the raw key, the collapsed
    path, and the collapsed directory's variants, each with its own dpr.
    The collapsed files ride that entry alone and never gain their own key,
    so no key names a file the entry did not declare. Every other key
    groups exactly as before. Each variant carries the dpr parsed from its
    own parent directory. A repeated key groups once: the copies map holds
    one file per key, so a file reached through two declarations still
    contributes one variant (see `_dedupe_bundle_keys`).

    Args:
        assets: list of encoded asset keys relative to the bundle root.
            Repeats collapse to one entry each.

    Returns:
        dict mapping decoded logical key -> list of variant dicts with
        decoded `asset` paths.
    """
    manifest = {}

    # One copy per key: the same file arrives once per declaring entry, but
    # the copies map files it once, so grouping a repeat would list its
    # variant twice.
    assets = _dedupe_bundle_keys(assets)

    # Bundle keys claimed by a raw entry, by collapsed path: a collapsed
    # file (or its variants) without its own declaration rides the raw
    # key's entry instead of gaining one.
    key_set = {path: True for path in assets}
    collapsed_of = _collapsed_claims(assets)

    # Group by base path, sorted by the encoded key as flutter_tools sorts by
    # `entryUri.path`; only the emitted keys and variants are decoded.
    for path in sorted(assets):
        if "" in path.split("/"):
            manifest[decode_asset_key(path)] = _raw_manifest_variants(path, assets)
            continue
        base, dpr = detect_dpr(path)
        if base in collapsed_of and base not in key_set:
            continue
        decoded_base = decode_asset_key(base)
        if decoded_base not in manifest:
            manifest[decoded_base] = []
        entry = {"asset": decode_asset_key(path)}
        if dpr != None:
            entry["dpr"] = dpr
        manifest[decoded_base].append(entry)

    # Ensure the main (1x) variant is first in each list.
    for decoded_base in manifest:
        variants = manifest[decoded_base]
        main_idx = None
        for i, v in enumerate(variants):
            if v["asset"] == decoded_base:
                main_idx = i
                break
        if main_idx != None and main_idx != 0:
            main = variants.pop(main_idx)
            variants.insert(0, main)

    return manifest

def make_bundle_content(assets = [], fonts = [], notices = "", license_files = [], extra_asset_copies = {}):
    """What goes into a `flutter_assets/` bundle.

    Args:
        assets: list of asset entry structs (`struct(key, file, label)`) to
            include in the bundle, each keyed once by the target that listed
            it — relative to its Bazel package, or `packages/<name>/...` for
            a library. The bundle keys every file by its carried `key`.
        fonts: list of font declaration dicts (FontManifest.json schema).
        notices: License text string to compress into NOTICES.Z.
        license_files: list of File objects containing license text to include in NOTICES.Z.
        extra_asset_copies: dict mapping custom dest path → File for assets that
            need a specific destination path (e.g. "fonts/MaterialIcons-Regular.otf").

    Returns:
        A struct with `assets`, `fonts`, `notices`, `license_files` and
        `extra_asset_copies`.
    """
    return struct(
        assets = assets,
        fonts = fonts,
        notices = notices,
        license_files = license_files,
        extra_asset_copies = extra_asset_copies,
    )

def kernel_dills_of(compiled):
    """The kernel dills a bundle or tree-shake struct names: `kernel_dills`, else the single `kernel_dill`.

    Args:
      compiled: A struct with `kernel_dills` (a list, possibly empty) and `kernel_dill` (a File or None).

    Returns:
      A new list of the kernel dill Files, empty when there are none.
    """
    if compiled.kernel_dills:
        return list(compiled.kernel_dills)
    return [compiled.kernel_dill] if compiled.kernel_dill != None else []

def make_tree_shake(
        dart = None,
        flutter_sdk_files = None,
        const_finder = None,
        font_subset = None,
        kernel_dill = None,
        kernel_dills = [],
        tree_shake_key = ""):
    """The icon tree-shaking toolchain and kernels for a bundle action.

    Every field is None or empty when tree shaking is off; the action then
    registers a plain bundle with no icon step.

    Args:
        dart: The `dart` executable File from the Flutter SDK (only required when icon tree shaking is enabled).
        flutter_sdk_files: SDK files needed to run dart (for action inputs when icon tree shaking is enabled).
        const_finder: File for const_finder.dart.snapshot (enables icon tree shaking).
        font_subset: File for font-subset binary (enables icon tree shaking).
        kernel_dill: File for the compiled kernel .dill (needed for icon tree shaking).
        kernel_dills: Optional list of compiled kernel .dill Files when icon tree
            shaking unions code points across multiple shipped builds.
        tree_shake_key: Optional configuration fingerprint for the shipped
            programs whose icons are tree-shaken.

    Returns:
        A struct with `dart`, `flutter_sdk_files`, `const_finder`,
        `font_subset`, `kernel_dill`, `kernel_dills` and `tree_shake_key`.
    """
    return struct(
        dart = dart,
        flutter_sdk_files = flutter_sdk_files,
        const_finder = const_finder,
        font_subset = font_subset,
        kernel_dill = kernel_dill,
        kernel_dills = kernel_dills,
        tree_shake_key = tree_shake_key,
    )

def _add_collapsed_copies(asset_paths, copies):
    """Copy each `//`-keeping key's file under its collapsed key, if free.

    An entry keeping an empty segment also bundles its collapsed file:
    the manifest lists the collapsed variant (see
    `build_asset_manifest`), so the copy must exist under the collapsed
    key too, holding the same file flutter_tools read. The collapsed key
    joins `copies` only, never `asset_paths`, so it gains no manifest key
    of its own; a key another entry already claimed keeps its file.

    Args:
        asset_paths: The manifest bundle keys, in copy order.
        copies: The dest-key-to-file map, extended in place.
    """
    for dest in asset_paths:
        if "" in dest.split("/"):
            collapsed = _collapse_empty_segments(dest)
            if collapsed not in copies:
                copies[collapsed] = copies[dest]

def _const_finder_action(ctx, shaking, all_kernel_dills):
    """Run `const_finder` on kernel dills to extract used icon code points.

    Args:
        ctx: Rule context providing `_const_finder_tool` and `actions`.
        shaking: The `make_tree_shake` struct holding tools and SDK files.
        all_kernel_dills: List of kernel dill `File`s to scan for const icons.

    Returns:
        The declared JSON `File` containing the extracted code points map.
    """
    if shaking.tree_shake_key:
        code_points_name = "%s.%x.icon_code_points.json" % (
            ctx.label.name,
            hash(shaking.tree_shake_key) & 0xffffffff,
        )
    else:
        code_points_name = ctx.label.name + ".icon_code_points.json"
    code_points_file = ctx.actions.declare_file(code_points_name)
    args = ctx.actions.args()
    args.add("--output", code_points_file)
    args.add("--dart", shaking.dart)
    args.add("--const-finder", shaking.const_finder)
    args.add_all(all_kernel_dills, before_each = "--kernel-file")

    transitive_inputs = []
    if shaking.flutter_sdk_files:
        transitive_inputs.append(shaking.flutter_sdk_files)

    tool = getattr(ctx.executable, "_const_finder_tool", None)
    if tool == None:
        fail("%s: _const_finder_tool is required on rule attrs for icon tree shaking" % ctx.label)

    ctx.actions.run(
        executable = tool,
        arguments = [args],
        inputs = depset(
            direct = [shaking.dart, shaking.const_finder] + all_kernel_dills,
            transitive = transitive_inputs,
        ),
        outputs = [code_points_file],
        mnemonic = "FlutterConstFinder",
        progress_message = "Finding const icons for %s" % ctx.label,
        toolchain = None,
    )
    return code_points_file

def _build_bundle_copies(content):
    """Build asset paths and copy map relative to the output directory.

    Args:
        content: What goes into the bundle, from `make_bundle_content`.

    Returns:
        A `(asset_paths, copies, extra_files)` tuple.
    """
    asset_paths = []
    copies = {}
    for entry in content.assets:
        if entry.key not in copies:
            asset_paths.append(entry.key)
        copies[entry.key] = entry.file.path

    extra_files = []
    for dest_path, f in content.extra_asset_copies.items():
        if dest_path not in copies:
            asset_paths.append(dest_path)
        copies[dest_path] = f.path
        extra_files.append(f)

    _add_collapsed_copies(asset_paths, copies)
    return asset_paths, copies, extra_files

def flutter_asset_bundle_action(ctx, content, shaking, output_dir):
    """Create an action that generates the flutter_assets/ tree artifact.

    Args:
        ctx: The rule context of the rule implementation that calls this helper.
        content: What goes into the bundle, from `make_bundle_content`.
        shaking: The icon tree-shaking toolchain and kernels, from
            `make_tree_shake` (all empty when tree shaking is off).
        output_dir: The already-declared directory (tree artifact) File to
            write the bundle into. Declared by the caller rather than here
            because an application has to know where its assets will land
            *before* this action runs — the path is baked into the app as
            `rules_flutter.build_info.assetsDir`, which the dev tool matches
            against the tree it watches and rebuilds. Declaring an output and
            registering the action that fills it are separate steps in
            Starlark, so hoisting the declaration introduces no cycle even
            though icon tree shaking makes this action depend on the kernel.

    Returns:
        The `output_dir` it was given, so callers can chain.
    """
    if output_dir == None:
        fail("flutter_asset_bundle_action: `output_dir` is required — declare it with ctx.actions.declare_directory().")
    tool = ctx.executable._asset_bundle_tool

    asset_paths, copies, extra_files = _build_bundle_copies(content)

    # Build manifest structure.
    manifest = build_asset_manifest(asset_paths)

    # Write the config JSON.
    config = {
        "assets": manifest,
        "fonts": content.fonts,
        "copies": copies,
        "notices": content.notices,
        "license_files": [f.path for f in content.license_files],
    }

    # Icon tree shaking config.
    all_kernel_dills = kernel_dills_of(shaking)
    extra_inputs = []
    if shaking.const_finder and shaking.font_subset and all_kernel_dills:
        icon_code_points = _const_finder_action(ctx, shaking, all_kernel_dills)
        icon_cfg = {
            "font_subset": shaking.font_subset.path,
            "code_points": icon_code_points.path,
        }
        if shaking.tree_shake_key:
            icon_cfg["key"] = "%x" % (hash(shaking.tree_shake_key) & 0xffffffff)
        config["icon_tree_shaking"] = icon_cfg
        extra_inputs.extend([shaking.font_subset, icon_code_points])

    config_content = json.encode(config)
    config_name = (
        "%s.%x.asset_bundle_config.json" % (ctx.label.name, hash(config_content) & 0xffffffff) if shaking.tree_shake_key else ctx.label.name + ".asset_bundle_config.json"
    )
    config_file = ctx.actions.declare_file(config_name)
    ctx.actions.write(config_file, config_content)

    ctx.actions.run(
        executable = tool,
        arguments = [
            "--config",
            config_file.path,
            "--output-dir",
            output_dir.path,
        ],
        inputs = depset(
            direct = [config_file] + [entry.file for entry in content.assets] + extra_files + content.license_files +
                     extra_inputs,
        ),
        outputs = [output_dir],
        mnemonic = "FlutterAssetBundle",
        progress_message = "Bundling Flutter assets %s" % ctx.label,
        toolchain = None,
    )

    return output_dir
