"""The lean Android build actions that the pinned Gradle model drives.

Every tool is one the pin file names (AGP's own D8 and L8, manifest merger, R class writer, signer and
aapt2, fetched by hash) or comes from the Android SDK (`android.jar`, the NDK's `llvm-strip`). Nothing
here loads `rules_android`.
"""

load("@rules_java//java/common:java_info.bzl", "JavaInfo")

RdfDexInfo = provider(
    doc = "One jar (or one project's jars) dexed in D8's intermediate mode, AGP's first dex step.",
    fields = {
        "archive": "File: a zip of dex files.",
        "globals": "File: the global synthetics D8 kept out of the archive; merged in the second step.",
    },
)

_WORKER = {
    "requires-worker-protocol": "json",
    "supports-workers": "1",
}

def _tool_args(ctx, command):
    args = ctx.actions.args()
    args.add(command)
    return args

def _tool(ctx, args, inputs, outputs, mnemonic, progress, worker = False):
    args.use_param_file("@%s", use_always = True)
    args.set_param_file_format("multiline")
    ctx.actions.run(
        toolchain = None,
        executable = ctx.executable.tool,
        arguments = [args],
        inputs = inputs,
        outputs = outputs,
        mnemonic = mnemonic,
        progress_message = progress,
        execution_requirements = _WORKER if worker else {},
    )

# ---------------------------------------------------------------------------------------------------
# D8, first step: one jar (or one project's jars) to one dex archive, in a persistent worker.

def _runtime_jars(deps):
    jars = []
    for d in deps:
        jars.extend(d[JavaInfo].runtime_output_jars)
    return jars

def _rdf_dex_impl(ctx):
    jars = ctx.files.jars + _runtime_jars(ctx.attr.deps)
    out = ctx.actions.declare_file(ctx.label.name + ".zip")
    globals = ctx.actions.declare_file(ctx.label.name + ".globals")
    classpath = depset(ctx.files.classpath + _runtime_jars(ctx.attr.classpath_deps))
    args = _tool_args(ctx, "dex")
    if not ctx.attr.debuggable:
        args.add("--release")
    if ctx.attr.store:
        args.add("--store")
    args.add("--min-api", ctx.attr.min_sdk)
    inputs = list(jars)
    if ctx.attr.with_platform:
        args.add("--lib", ctx.file.android_jar)
        inputs.append(ctx.file.android_jar)
    if ctx.file.desugared_lib_config:
        args.add("--desugared-lib-config", ctx.file.desugared_lib_config)
        inputs.append(ctx.file.desugared_lib_config)
    args.add_all(classpath, before_each = "--classpath")
    args.add("--output", out)
    args.add("--globals", globals)
    args.add_all(jars)
    _tool(ctx, args, depset(inputs, transitive = [classpath]), [out, globals], "RdfDex", "D8 %{label}", worker = True)
    return [
        DefaultInfo(files = depset([out])),
        RdfDexInfo(archive = out, globals = globals),
    ]

rdf_dex = rule(
    implementation = _rdf_dex_impl,
    attrs = {
        "android_jar": attr.label(allow_single_file = True, mandatory = True),
        "classpath": attr.label_list(allow_files = [".jar"], doc = "What D8 needs to desugar below API 24 or with core library desugaring."),
        "classpath_deps": attr.label_list(providers = [JavaInfo]),
        "debuggable": attr.bool(default = True),
        "deps": attr.label_list(providers = [JavaInfo], doc = "Libraries whose own jars are dexed."),
        "desugared_lib_config": attr.label(allow_single_file = True, doc = "Core library desugaring: the configuration D8 rewrites calls with."),
        "jars": attr.label_list(allow_files = [".jar"]),
        "min_sdk": attr.int(mandatory = True),
        "store": attr.bool(doc = "Write the dex files uncompressed (apps that package dex uncompressed)."),
        "tool": attr.label(executable = True, cfg = "exec", mandatory = True),
        "with_platform": attr.bool(
            default = True,
            doc = "Give D8 android.jar. AGP gives it to a library's dexing only below API 24 or with core library desugaring.",
        ),
    },
)

# ---------------------------------------------------------------------------------------------------
# D8, second step: the archives of one scope merged to the final dex files, with the global synthetics.

def _rdf_dex_merge_impl(ctx):
    out = ctx.actions.declare_file(ctx.label.name + ".zip")
    archives = [d[RdfDexInfo].archive for d in ctx.attr.archives]
    globals = [d[RdfDexInfo].globals for d in ctx.attr.globals]
    args = _tool_args(ctx, "dexmerge")
    if not ctx.attr.debuggable:
        args.add("--release")
    if ctx.attr.store:
        args.add("--store")
    args.add("--min-api", ctx.attr.min_sdk)
    args.add("--lib", ctx.file.android_jar)
    args.add_all(globals, before_each = "--globals")
    args.add("--output", out)
    args.add_all(archives)
    _tool(ctx, args, archives + globals + [ctx.file.android_jar], [out], "RdfDexMerge", "Merging dex %{label}", worker = True)
    return [DefaultInfo(files = depset([out]))]

rdf_dex_merge = rule(
    implementation = _rdf_dex_merge_impl,
    attrs = {
        "android_jar": attr.label(allow_single_file = True, mandatory = True),
        "archives": attr.label_list(providers = [RdfDexInfo]),
        "debuggable": attr.bool(default = True),
        "globals": attr.label_list(providers = [RdfDexInfo], doc = "Archives whose global synthetics are merged in."),
        "min_sdk": attr.int(mandatory = True),
        "store": attr.bool(),
        "tool": attr.label(executable = True, cfg = "exec", mandatory = True),
    },
)

def _rdf_dex_archive_impl(ctx):
    return [DefaultInfo(files = depset([d[RdfDexInfo].archive for d in ctx.attr.srcs]))]

rdf_dex_archive = rule(
    doc = "The dex archives of the first step as they are (a split APK packages them unmerged).",
    implementation = _rdf_dex_archive_impl,
    attrs = {"srcs": attr.label_list(providers = [RdfDexInfo])},
)

# ---------------------------------------------------------------------------------------------------
# L8: the desugared core library itself as dex (what AGP's l8DexDesugarLib task makes).

def _rdf_l8_impl(ctx):
    out = ctx.actions.declare_file(ctx.label.name + ".zip")
    args = _tool_args(ctx, "l8")
    if not ctx.attr.debuggable:
        args.add("--release")
    if ctx.attr.store:
        args.add("--store")
    args.add("--min-api", ctx.attr.min_sdk)
    args.add("--lib", ctx.file.android_jar)
    args.add("--desugared-lib-config", ctx.file.desugared_lib_config)
    args.add("--output", out)
    args.add_all(ctx.files.jars)
    _tool(ctx, args, ctx.files.jars + [ctx.file.android_jar, ctx.file.desugared_lib_config], [out], "RdfL8", "L8 %{label}")
    return [DefaultInfo(files = depset([out]))]

rdf_l8 = rule(
    implementation = _rdf_l8_impl,
    attrs = {
        "android_jar": attr.label(allow_single_file = True, mandatory = True),
        "debuggable": attr.bool(default = True),
        "desugared_lib_config": attr.label(allow_single_file = True, mandatory = True),
        "jars": attr.label_list(allow_files = [".jar"]),
        "min_sdk": attr.int(mandatory = True),
        "store": attr.bool(),
        "tool": attr.label(executable = True, cfg = "exec", mandatory = True),
    },
)

# ---------------------------------------------------------------------------------------------------
# aapt2 compile: the resource files of one library to one archive of compiled files.

def _rdf_res_compile_impl(ctx):
    if not ctx.files.srcs:
        return [DefaultInfo()]
    out = ctx.actions.declare_file(ctx.label.name + ".flata.zip")
    args = _tool_args(ctx, "rescompile")
    if not ctx.attr.crunch:
        args.add("--no-crunch")
    args.add("--aapt2", ctx.executable.aapt2)
    args.add("--out", out)
    args.add_all(ctx.files.srcs)
    ctx.actions.run(
        toolchain = None,
        executable = ctx.executable.tool,
        arguments = [args.use_param_file("@%s", use_always = True).set_param_file_format("multiline")],
        inputs = ctx.files.srcs,
        tools = [ctx.executable.aapt2],
        outputs = [out],
        mnemonic = "RdfResCompile",
        progress_message = "Compiling resources %{label}",
        execution_requirements = _WORKER,
    )
    return [DefaultInfo(files = depset([out]))]

rdf_res_compile = rule(
    doc = """The resource files of one library as one archive of compiled files.

    As in AGP, XML and plain files are compiled by AGP's resource compiler inside the tool; PNGs that
    are crunched go to the aapt2 binary.""",
    implementation = _rdf_res_compile_impl,
    attrs = {
        "aapt2": attr.label(executable = True, cfg = "exec", allow_single_file = True, mandatory = True),
        "crunch": attr.bool(default = True, doc = "AGP crunches the PNGs of AARs always and a project's own by build type."),
        "srcs": attr.label_list(allow_files = True),
        "tool": attr.label(executable = True, cfg = "exec", mandatory = True),
    },
)

# ---------------------------------------------------------------------------------------------------
# aapt2 link: merged manifest plus compiled resources to the resource APK and its symbol list.

def _rdf_aapt2_link_impl(ctx):
    ap = ctx.actions.declare_file(ctx.label.name + ".ap_")
    rtxt = ctx.actions.declare_file(ctx.label.name + "_R.txt")
    args = ctx.actions.args()
    args.add("link")
    args.add("-o", ap)
    args.add("--manifest", ctx.file.manifest)
    args.add("-I", ctx.file.android_jar)
    args.add("--auto-add-overlay")
    args.add("--no-version-vectors")
    args.add("--no-proguard-location-reference")
    if ctx.attr.min_sdk_version:
        args.add("--min-sdk-version", ctx.attr.min_sdk_version)
    if ctx.attr.target_sdk_version:
        args.add("--target-sdk-version", ctx.attr.target_sdk_version)
    args.add_all(ctx.attr.no_compress, before_each = "-0")
    args.add_all(ctx.files.compiled, before_each = "-R")
    args.add("--output-text-symbols", rtxt)
    ctx.actions.run(
        toolchain = None,
        executable = ctx.executable.aapt2,
        arguments = [args],
        inputs = [ctx.file.manifest, ctx.file.android_jar] + ctx.files.compiled,
        outputs = [ap, rtxt],
        mnemonic = "RdfAapt2Link",
        progress_message = "aapt2 link %{label}",
    )
    return [
        DefaultInfo(files = depset([ap])),
        OutputGroupInfo(rtxt = depset([rtxt])),
    ]

rdf_aapt2_link = rule(
    implementation = _rdf_aapt2_link_impl,
    attrs = {
        "aapt2": attr.label(executable = True, cfg = "exec", allow_single_file = True, mandatory = True),
        "android_jar": attr.label(allow_single_file = True, mandatory = True),
        "compiled": attr.label_list(allow_files = True, doc = "Compiled resources, lowest priority first."),
        "manifest": attr.label(allow_single_file = True, mandatory = True),
        "min_sdk_version": attr.string(),
        "no_compress": attr.string_list(),
        "target_sdk_version": attr.string(),
    },
)

# ---------------------------------------------------------------------------------------------------
# Manifest merge with AGP's own merger.

def _rdf_manifest_merge_impl(ctx):
    out = ctx.actions.declare_file(ctx.label.name + "/AndroidManifest.xml")
    args = _tool_args(ctx, "manifest")
    args.add("--main", ctx.file.main)
    args.add_all(ctx.files.overlays, before_each = "--overlay")
    args.add_all(ctx.files.libs, before_each = "--lib")
    args.add("--namespace", ctx.attr.namespace)
    args.add("--type", ctx.attr.merge_type)
    for k, v in ctx.attr.properties.items():
        args.add("--property", "%s=%s" % (k, v))
    for k, v in ctx.attr.placeholders.items():
        args.add("--placeholder", "%s=%s" % (k, v))
    args.add_all(ctx.attr.merger_features, before_each = "--feature")
    args.add("--out", out)
    _tool(ctx, args, [ctx.file.main] + ctx.files.overlays + ctx.files.libs, [out], "RdfManifestMerge", "Merging manifests %{label}")
    return [DefaultInfo(files = depset([out]))]

rdf_manifest_merge = rule(
    implementation = _rdf_manifest_merge_impl,
    attrs = {
        "libs": attr.label_list(allow_files = True, doc = "Library manifests, highest priority first."),
        "main": attr.label(allow_single_file = True, mandatory = True),
        "merge_type": attr.string(default = "APPLICATION", values = ["APPLICATION", "LIBRARY"]),
        "merger_features": attr.string_list(),
        "namespace": attr.string(mandatory = True),
        "overlays": attr.label_list(allow_files = True, doc = "Build type and flavor manifests, highest priority first."),
        "placeholders": attr.string_dict(),
        "properties": attr.string_dict(),
        "tool": attr.label(executable = True, cfg = "exec", mandatory = True),
    },
)

# ---------------------------------------------------------------------------------------------------
# R classes, as AGP writes them: per library from its own symbol list, as bytecode.

def _rdf_symbols_impl(ctx):
    out = ctx.actions.declare_file(ctx.label.name + "/R-def.txt")
    args = _tool_args(ctx, "symbols")
    args.add("--package", ctx.attr.package)
    args.add("--android-jar", ctx.file.android_jar)
    args.add("--out", out)
    args.add_all(ctx.files.srcs)
    _tool(ctx, args, ctx.files.srcs + [ctx.file.android_jar], [out], "RdfSymbols", "Resource symbols %{label}")
    return [DefaultInfo(files = depset([out]))]

rdf_symbols = rule(
    doc = "The symbols one project's own resources declare (AGP's ParseLibraryResourcesTask).",
    implementation = _rdf_symbols_impl,
    attrs = {
        "android_jar": attr.label(allow_single_file = True, mandatory = True),
        "package": attr.string(mandatory = True),
        "srcs": attr.label_list(allow_files = True),
        "tool": attr.label(executable = True, cfg = "exec", mandatory = True),
    },
)

def _rdf_r_jar_impl(ctx):
    out = ctx.actions.declare_file(ctx.label.name + ".jar")
    args = _tool_args(ctx, "rjar")
    args.add("--mode", ctx.attr.mode)
    inputs = []
    if ctx.attr.package:
        args.add("--package", ctx.attr.package)
    if ctx.file.local:
        args.add("--local", ctx.file.local)
        inputs.append(ctx.file.local)
    if ctx.file.rtxt:
        args.add("--rtxt", ctx.file.rtxt)
        inputs.append(ctx.file.rtxt)
    if ctx.file.android_jar:
        args.add("--android-jar", ctx.file.android_jar)
        inputs.append(ctx.file.android_jar)
    symbol_files = []
    for target, package in ctx.attr.deps.items():
        # One symbol file per target; its path is written when the action runs.
        args.add_all(target.files, before_each = "--dep", format_each = package + "=%s")
        symbol_files.append(target.files)
    for package in ctx.attr.empty_packages:
        args.add("--dep", package + "=")
    args.add("--out", out)
    _tool(ctx, args, depset(inputs, transitive = symbol_files), [out], "RdfRJar", "R classes %{label}")
    return [
        DefaultInfo(files = depset([out])),
        JavaInfo(output_jar = out, compile_jar = out, neverlink = ctx.attr.mode != "app"),
    ]

rdf_r_jar = rule(
    doc = """R classes as bytecode, written by AGP's own writer.

    `library`: what one library project compiles against (its own symbols, ids not final).
    `external`: the same for the AARs, in one jar. `app`: the classes the app packages, one per
    library from that library's own symbol list and the app's own, with aapt2's final ids.""",
    implementation = _rdf_r_jar_impl,
    attrs = {
        "android_jar": attr.label(allow_single_file = True),
        "deps": attr.label_keyed_string_dict(allow_files = True, doc = "Symbol file (an AAR's R.txt or a project's R-def.txt) to its package."),
        "empty_packages": attr.string_list(doc = "Packages of libraries without resources: they get an empty R class."),
        "local": attr.label(allow_single_file = True, doc = "The project's own symbols (rdf_symbols)."),
        "mode": attr.string(mandatory = True, values = ["library", "external", "app"]),
        "package": attr.string(),
        "rtxt": attr.label(allow_single_file = True, doc = "aapt2's symbol list with the final ids."),
        "tool": attr.label(executable = True, cfg = "exec", mandatory = True),
    },
)

# ---------------------------------------------------------------------------------------------------
# Native libraries, stripped as AGP's stripDebugSymbols does (the engine's are 390 MB each unstripped).

def _rdf_native_libs_impl(ctx):
    outs = []
    seen = {}
    for f in ctx.files.srcs:
        if not f.basename.endswith(".so"):
            continue
        abi = ctx.attr.abi or f.dirname.split("/")[-1]
        if ctx.attr.abis and abi not in ctx.attr.abis:
            continue
        key = abi + "/" + f.basename
        n = seen.get(key, 0)
        seen[key] = n + 1

        # The same name from two sources: both are kept, and the packager decides (equal content, or
        # the app's `pickFirsts`, or an error).
        out = ctx.actions.declare_file("%s/%s%s" % (ctx.label.name, "dup%d/" % n if n else "", key))
        ctx.actions.run(
            toolchain = None,
            executable = ctx.executable.strip,
            arguments = ["--strip-unneeded", "-o", out.path, f.path],
            inputs = [f],
            outputs = [out],
            mnemonic = "RdfStrip",
            progress_message = "Stripping %s" % f.short_path,
        )
        outs.append(out)
    return [DefaultInfo(files = depset(outs))]

rdf_native_libs = rule(
    implementation = _rdf_native_libs_impl,
    attrs = {
        "abi": attr.string(doc = "The ABI of every file, when the directory does not say."),
        "abis": attr.string_list(doc = "The ABIs to keep; all when empty."),
        "srcs": attr.label_list(allow_files = True),
        "strip": attr.label(executable = True, cfg = "exec", allow_single_file = True, mandatory = True),
    },
)

# ---------------------------------------------------------------------------------------------------
# A zip part: files that go into an APK as they are (assets), compressed once here.

def _package_relative(f):
    path = f.short_path
    if path.startswith("../"):
        path = path.split("/", 2)[2]
    package = f.owner.package
    return path[len(package) + 1:] if package and path.startswith(package + "/") else path

def _rdf_zip_part_impl(ctx):
    out = ctx.actions.declare_file(ctx.label.name + ".zip")
    args = _tool_args(ctx, "zip")
    if ctx.attr.store:
        args.add("--store")
    args.add("--out", out)
    inputs = []
    trees = []
    for target, prefix in ctx.attr.trees.items():
        # A directory is passed as it is; the tool walks it.
        args.add_all(target.files, format_each = prefix + "=%s", expand_directories = False)
        trees.append(target.files)
    for f in ctx.files.srcs:
        rel = _package_relative(f)
        name = None
        for root in ctx.attr.roots:
            if rel.startswith(root + "/"):
                name = ctx.attr.prefix + "/" + rel[len(root) + 1:]
                break
        if name == None:
            fail("%s: %s is under none of the roots %s" % (ctx.label, rel, ctx.attr.roots))
        args.add("%s=%s" % (name, f.path))
        inputs.append(f)
    _tool(ctx, args, depset(inputs, transitive = trees), [out], "RdfZip", "Zipping %{label}", worker = True)
    return [DefaultInfo(files = depset([out]))]

rdf_zip_part = rule(
    implementation = _rdf_zip_part_impl,
    attrs = {
        "prefix": attr.string(default = "assets"),
        "roots": attr.string_list(doc = "Package-relative directories of `srcs`; a file's name in the APK is `prefix` and its path under its root."),
        "srcs": attr.label_list(allow_files = True),
        "store": attr.bool(doc = "No compression (a split that is rewritten on every Dart edit)."),
        "tool": attr.label(executable = True, cfg = "exec", mandatory = True),
        "trees": attr.label_keyed_string_dict(allow_files = True, doc = "Directory to its path in the APK."),
    },
)

# ---------------------------------------------------------------------------------------------------
# Package, align and sign one APK (the whole app, the base, or one split) in one worker request.

def _rdf_apk_impl(ctx):
    out = ctx.actions.declare_file(ctx.label.name + ".apk")
    res_jars = ctx.files.java_resource_jars + _runtime_jars(ctx.attr.java_resource_deps)
    args = _tool_args(ctx, "pack")
    args.add("--out", out)
    entries = []
    for target, name in ctx.attr.entries.items():
        args.add_all(target.files, before_each = "--entry", format_each = name + "=%s")
        entries.append(target.files)
    args.add_all(ctx.files.dex, before_each = "--dex")
    if ctx.attr.dex_store:
        args.add("--dex-store")
    for f in ctx.files.native_libs:
        args.add("--native", "%s=%s" % (f.dirname.split("/")[-1], f.path))
    if ctx.attr.native_compress:
        args.add("--native-compress")
    args.add_all(ctx.files.zips, before_each = "--zip")
    args.add_all(ctx.files.resources, before_each = "--resources")
    args.add_all(res_jars, before_each = "--java-res")
    args.add_all(ctx.attr.excludes, before_each = "--exclude")
    args.add_all(ctx.attr.pick_firsts, before_each = "--pick-first")
    args.add_all(ctx.attr.merges, before_each = "--merge")
    args.add_all(ctx.attr.jni_excludes, before_each = "--jni-exclude")
    args.add_all(ctx.attr.jni_pick_firsts, before_each = "--jni-pick-first")
    args.add("--keystore", ctx.file.keystore)
    args.add("--ks-pass", ctx.attr.keystore_password)
    args.add("--key-alias", ctx.attr.key_alias)
    args.add("--key-pass", ctx.attr.key_password)
    args.add("--min-sdk", ctx.attr.min_sdk)
    if ctx.attr.min_sdk < 24:
        args.add("--v1")
    inputs = ctx.files.dex + ctx.files.native_libs + ctx.files.zips + ctx.files.resources + res_jars + [ctx.file.keystore]
    _tool(ctx, args, depset(inputs, transitive = entries), [out], "RdfApk", "Packaging and signing %{label}", worker = True)
    return [
        DefaultInfo(files = depset([out])),
        OutputGroupInfo(_validation = depset(ctx.files.validations)),
    ]

rdf_apk = rule(
    implementation = _rdf_apk_impl,
    attrs = {
        "dex": attr.label_list(allow_files = True),
        "dex_store": attr.bool(doc = "Package dex files uncompressed."),
        "entries": attr.label_keyed_string_dict(allow_files = True, doc = "File to its name in the APK."),
        "excludes": attr.string_list(),
        "java_resource_deps": attr.label_list(providers = [JavaInfo]),
        "java_resource_jars": attr.label_list(allow_files = [".jar"]),
        "jni_excludes": attr.string_list(),
        "jni_pick_firsts": attr.string_list(),
        "key_alias": attr.string(default = "androiddebugkey"),
        "key_password": attr.string(default = "android"),
        "keystore": attr.label(allow_single_file = True, default = "//flutter/private/android_model:debug.keystore"),
        "keystore_password": attr.string(default = "android"),
        "merges": attr.string_list(),
        "min_sdk": attr.int(mandatory = True),
        "native_compress": attr.bool(doc = "Legacy packaging: native libraries compressed, extracted at install."),
        "native_libs": attr.label_list(allow_files = True),
        "pick_firsts": attr.string_list(),
        "resources": attr.label_list(allow_files = True),
        "tool": attr.label(executable = True, cfg = "exec", mandatory = True),
        "validations": attr.label_list(allow_files = True, doc = "Checks that must pass for this APK to build (the pin is not stale)."),
        "zips": attr.label_list(allow_files = True),
    },
)

# ---------------------------------------------------------------------------------------------------
# The pin is stale when a file it was computed from changed.

def _rdf_pin_check_impl(ctx):
    out = ctx.actions.declare_file(ctx.label.name + ".ok")
    args = _tool_args(ctx, "pincheck")
    args.add("--out", out)
    args.add("--model", ctx.attr.model)
    args.add("--pin", ctx.attr.pin_command)
    by_path = {}
    for f in ctx.files.srcs:
        path = _package_relative(f)
        by_path[path.removeprefix(ctx.attr.hub_prefix) if ctx.attr.hub_prefix else path] = f
    for path, sha in ctx.attr.inputs.items():
        f = by_path.get(path)
        args.add("--input", "%s=%s=%s" % (path, sha, f.path if f else ""))
    _tool(ctx, args, ctx.files.srcs, [out], "RdfPinCheck", "Checking that %s is current" % ctx.attr.model)
    return [DefaultInfo(files = depset([out]))]

rdf_pin_check = rule(
    implementation = _rdf_pin_check_impl,
    attrs = {
        "hub_prefix": attr.string(doc = "Where the hub links the app's directory; a file under it is named by the rest of its path."),
        "inputs": attr.string_dict(doc = "Package-relative path to the sha256 the pin recorded."),
        "model": attr.string(mandatory = True),
        "pin_command": attr.string(mandatory = True),
        "srcs": attr.label_list(allow_files = True),
        "tool": attr.label(executable = True, cfg = "exec", mandatory = True),
    },
)

# ---------------------------------------------------------------------------------------------------
# The escape hatch: one plugin project built by Gradle itself, as one cached action.

def _rdf_gradle_aar_impl(ctx):
    classes = ctx.actions.declare_file(ctx.label.name + "/classes.jar")
    manifest = ctx.actions.declare_file(ctx.label.name + "/AndroidManifest.xml")
    rtxt = ctx.actions.declare_file(ctx.label.name + "/R.txt")
    res = ctx.actions.declare_directory(ctx.label.name + "/res")
    assets = ctx.actions.declare_directory(ctx.label.name + "/assets")
    args = _tool_args(ctx, "gradle-aar")
    args.add("--android", ctx.attr.android_dir)
    args.add("--project", ctx.attr.project)
    args.add("--variant", ctx.attr.variant)
    args.add("--init", ctx.file.init)
    args.add("--classes", classes)
    args.add("--manifest", manifest)
    args.add("--rtxt", rtxt)
    args.add("--res", res.path)
    args.add("--assets", assets.path)
    args.use_param_file("@%s", use_always = True)
    args.set_param_file_format("multiline")
    ctx.actions.run(
        toolchain = None,
        executable = ctx.executable.tool,
        arguments = [args],
        inputs = ctx.files.srcs + [ctx.file.init],
        outputs = [classes, manifest, rtxt, res, assets],
        mnemonic = "RdfGradleAar",
        progress_message = "Gradle builds project %s (gradle_fallback) for %%{label}" % ctx.attr.project,
        # Gradle runs where the app's Android project is, with the machine's Gradle home, JDK and
        # Android SDK: not in a sandbox and not on a remote executor. The declared inputs (the
        # project's sources, the app's Gradle files, the pin) are what the result is cached under.
        execution_requirements = {"local": "1", "no-remote": "1", "no-sandbox": "1"},
        use_default_shell_env = True,
    )
    return [
        DefaultInfo(files = depset([classes])),
        JavaInfo(output_jar = classes, compile_jar = classes),
        OutputGroupInfo(
            assets = depset([assets]),
            manifest = depset([manifest]),
            res = depset([res]),
            rtxt = depset([rtxt]),
        ),
    ]

rdf_gradle_aar = rule(
    doc = """One Gradle project built by Gradle itself: its AAR, unpacked.

    For a plugin project the model cannot express. It needs the stock Android toolchain on the
    machine that builds, and `flutter pub get` done in the app.""",
    implementation = _rdf_gradle_aar_impl,
    attrs = {
        "android_dir": attr.string(mandatory = True, doc = "The app's Gradle root, relative to the workspace."),
        "init": attr.label(allow_single_file = True, mandatory = True),
        "project": attr.string(mandatory = True, doc = "The Gradle path of the project."),
        "srcs": attr.label_list(allow_files = True, doc = "What the result depends on: the project's files, the app's Gradle files, the pin."),
        "tool": attr.label(executable = True, cfg = "exec", mandatory = True),
        "variant": attr.string(mandatory = True),
    },
)

# ---------------------------------------------------------------------------------------------------
# Small adapters.

def _rdf_output_group_impl(ctx):
    return [DefaultInfo(files = getattr(ctx.attr.src[OutputGroupInfo], ctx.attr.group))]

rdf_output_group = rule(
    doc = "The files of one output group of a target.",
    implementation = _rdf_output_group_impl,
    attrs = {
        "group": attr.string(mandatory = True),
        "src": attr.label(mandatory = True),
    },
)

def _rdf_unsupported_impl(ctx):
    fail("\n" + ctx.attr.message)

rdf_unsupported = rule(
    doc = "A target that fails when it is built, with the reason.",
    implementation = _rdf_unsupported_impl,
    attrs = {"message": attr.string(mandatory = True)},
)
