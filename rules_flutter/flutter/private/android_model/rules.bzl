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

RdfApkInfo = provider(
    doc = "An APK of an app built from the pinned Gradle model, as a test runner needs it.",
    fields = {
        "apk": "File: the signed APK.",
        "application_id": "string: the application id the APK installs under.",
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
    args.add_all([f for f in ctx.files.libraries if f != ctx.file.android_jar], before_each = "--lib")
    args.add_all(ctx.files.app_dex, before_each = "--app-dex")
    extra = ctx.files.libraries + ctx.files.app_dex
    outputs = [out]
    groups = {}
    if ctx.file.mapping:
        # With the app's mapping file L8 adds its own part: the whole is what retraces the app.
        mapping = ctx.actions.declare_file(ctx.label.name + "/mapping.txt")
        args.add("--mapping", ctx.file.mapping)
        args.add("--out-mapping", mapping)
        extra.append(ctx.file.mapping)
        outputs.append(mapping)
        groups["mapping"] = depset([mapping])
    if ctx.file.profile:
        # The baseline profile's rules for the desugared library, rewritten as R8 rewrites the app's.
        profile = ctx.actions.declare_file(ctx.label.name + "_baseline-prof.txt")
        args.add("--profile", ctx.file.profile)
        args.add("--out-profile", profile)
        extra.append(ctx.file.profile)
        outputs.append(profile)
        groups["profile"] = depset([profile])
    args.add("--output", out)
    args.add_all(ctx.files.jars)
    _tool(ctx, args, ctx.files.jars + extra + [ctx.file.android_jar, ctx.file.desugared_lib_config], outputs, "RdfL8", "L8 %{label}", worker = bool(ctx.files.app_dex))
    return [DefaultInfo(files = depset([out])), OutputGroupInfo(**groups)]

rdf_l8 = rule(
    implementation = _rdf_l8_impl,
    attrs = {
        "android_jar": attr.label(allow_single_file = True, mandatory = True),
        "app_dex": attr.label_list(allow_files = True, doc = "The app's final dex (R8's output): the desugared library is shrunk to what it uses."),
        "debuggable": attr.bool(default = True),
        "desugared_lib_config": attr.label(allow_single_file = True, mandatory = True),
        "jars": attr.label_list(allow_files = [".jar"]),
        "libraries": attr.label_list(allow_files = [".jar"], doc = "More of the boot classpath (the platform's optional libraries, the lambda stubs)."),
        "mapping": attr.label(allow_single_file = True, doc = "R8's mapping file; L8 takes the map id from it."),
        "profile": attr.label(allow_single_file = True, doc = "The merged baseline profile (text), with `app_dex`."),
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
    if ctx.attr.proto:
        args.add("--proto-format")
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
        "proto": attr.bool(doc = "Link to the proto format: what R8 shrinks resources in and what a bundle carries."),
        "target_sdk_version": attr.string(),
    },
)

# ---------------------------------------------------------------------------------------------------
# A release build: R8 over the whole program, the resources shrunk in the same run, as AGP runs it.

def _rdf_r8_impl(ctx):
    name = ctx.label.name
    dex = ctx.actions.declare_file(name + ".zip")
    java_res = ctx.actions.declare_file(name + "_java_res.jar")
    mapping = ctx.actions.declare_file(name + "/mapping.txt")
    config = ctx.actions.declare_file(name + "/configuration.txt")
    usage = ctx.actions.declare_file(name + "/usage.txt")
    seeds = ctx.actions.declare_file(name + "/seeds.txt")
    profile = ctx.actions.declare_file(name + "/baseline-prof.txt")
    merged_profile = ctx.actions.declare_file(name + "/merged-baseline-prof.txt")
    metadata = ctx.actions.declare_file(name + "/r8.json")
    outputs = [dex, java_res, mapping, config, usage, seeds, profile, merged_profile, metadata]
    program = depset(ctx.files.jars, transitive = [depset(_runtime_jars(ctx.attr.deps))])
    res_jars = depset(ctx.files.java_resource_jars + _runtime_jars(ctx.attr.java_resource_deps))
    args = _tool_args(ctx, "r8")
    args.add("--min-api", ctx.attr.min_sdk)
    if ctx.attr.debuggable:
        args.add("--debuggable")
    if not ctx.attr.minify:
        args.add("--no-minify")
    if not ctx.attr.full_mode:
        args.add("--no-full-mode")
    if not ctx.attr.strict_keep_rules:
        args.add("--legacy-keep-rules")
    args.add_all(program, before_each = "--program")
    args.add_all(ctx.files.rules_jars, before_each = "--rules-jar")
    args.add_all(ctx.files.classpath, before_each = "--classpath")
    args.add_all(ctx.files.libraries, before_each = "--lib")
    args.add_all(ctx.files.configs, before_each = "--config")
    args.add_all(res_jars, before_each = "--java-res")
    args.add_all(ctx.attr.excludes, before_each = "--exclude")
    args.add_all(ctx.attr.pick_firsts, before_each = "--pick-first")
    args.add_all(ctx.attr.merges, before_each = "--merge")
    args.add_all(ctx.files.profiles, before_each = "--profile")
    inputs = [program, res_jars, depset(ctx.files.rules_jars + ctx.files.classpath + ctx.files.libraries + ctx.files.configs + ctx.files.profiles)]
    if ctx.file.desugared_lib_config:
        args.add("--desugared-lib-config", ctx.file.desugared_lib_config)
        inputs.append(depset([ctx.file.desugared_lib_config]))
    groups = {}
    if ctx.files.resources:
        # Resource shrinking: the linked resources (proto format; one per APK the variant gives) go
        # through R8 with the code, and the resource files are read for the keep rules they carry
        # (`tools:keep`).
        log = ctx.actions.declare_file(name + "/resources.txt")
        outputs.append(log)
        for i, linked in enumerate(ctx.files.resources):
            shrunk = ctx.actions.declare_file("%s_shrunk_%d.ap_" % (name, i))
            outputs.append(shrunk)
            args.add("--resources", linked)
            args.add("--out-resources", shrunk)
            groups["resources_%d" % i] = depset([shrunk])
        args.add("--out-resources-log", log)
        args.add_all(ctx.files.resource_files, before_each = "--res-file")
        inputs.append(depset(ctx.files.resources + ctx.files.resource_files))
    args.add("--out-dex", dex)
    args.add("--out-java-res", java_res)
    args.add("--out-mapping", mapping)
    args.add("--out-config", config)
    args.add("--out-usage", usage)
    args.add("--out-seeds", seeds)
    args.add("--out-profile", profile)
    args.add("--out-merged-profile", merged_profile)
    args.add("--out-metadata", metadata)

    # A worker: R8 is minutes of work for a cold JVM and far less for a warm one, and it runs again on
    # every code edit of a release build (inside Gradle it runs in the daemon for the same reason).
    _tool(ctx, args, depset(transitive = inputs), outputs, "RdfR8", "R8 %{label}", worker = True)
    return [
        DefaultInfo(files = depset([dex])),
        OutputGroupInfo(
            java_res = depset([java_res]),
            mapping = depset([mapping]),
            merged_profile = depset([merged_profile]),
            metadata = depset([metadata]),
            profile = depset([profile]),
            reports = depset([config, usage, seeds]),
            **groups
        ),
    ]

rdf_r8 = rule(
    doc = """The whole program through R8, as AGP's R8 task runs it (AGP's own driver, full mode).

    Output groups: `java_res` (the Java resources R8 kept, service files renamed), `resources_<i>`
    (the shrunk resources of the i-th input, proto format), `mapping`, `profile` (the baseline profile rewritten for the
    shrunk program), `reports` (the configuration R8 saw, what it removed and what the rules kept).""",
    implementation = _rdf_r8_impl,
    attrs = {
        "classpath": attr.label_list(allow_files = [".jar"], doc = "Compile-only jars: what the compile classpath has and the runtime classpath does not."),
        "configs": attr.label_list(allow_files = True, doc = "Shrinker rule files, in AGP's order."),
        "debuggable": attr.bool(),
        "deps": attr.label_list(providers = [JavaInfo], doc = "Libraries whose own jars are program input."),
        "desugared_lib_config": attr.label(allow_single_file = True),
        "excludes": attr.string_list(),
        "full_mode": attr.bool(default = True, doc = "android.enableR8.fullMode."),
        "jars": attr.label_list(allow_files = [".jar"], doc = "Program jars."),
        "java_resource_deps": attr.label_list(providers = [JavaInfo]),
        "java_resource_jars": attr.label_list(allow_files = [".jar"]),
        "libraries": attr.label_list(allow_files = [".jar"], doc = "android.jar, the platform's optional libraries, the lambda stubs."),
        "merges": attr.string_list(),
        "min_sdk": attr.int(mandatory = True),
        "minify": attr.bool(default = True, doc = "Rename classes and members (off when the rules say -dontobfuscate is not enough: never set by the model)."),
        "pick_firsts": attr.string_list(),
        "profiles": attr.label_list(allow_files = True, doc = "Baseline profiles (text) of the app and its libraries."),
        "resource_files": attr.label_list(allow_files = True, doc = "The resource source files; their XML is read for keep rules."),
        "resources": attr.label_list(allow_files = True, doc = "The linked resources in proto format, to shrink: one per APK the variant gives."),
        "strict_keep_rules": attr.bool(default = True, doc = "android.r8.strictFullModeForKeepRules."),
        "rules_jars": attr.label_list(allow_files = [".jar"], doc = "Maven jars whose embedded shrinker rules (META-INF/proguard, META-INF/com.android.tools) apply."),
        "tool": attr.label(executable = True, cfg = "exec", mandatory = True),
    },
)

def _rdf_res_finish_impl(ctx):
    out = ctx.actions.declare_file(ctx.label.name + ".ap_")
    binary = ctx.file.src
    if ctx.attr.convert:
        binary = ctx.actions.declare_file(ctx.label.name + "_binary.ap_")
        ctx.actions.run(
            toolchain = None,
            executable = ctx.executable.aapt2,
            arguments = ["convert", "--output-format", "binary", "-o", binary.path, ctx.file.src.path],
            inputs = [ctx.file.src],
            outputs = [binary],
            mnemonic = "RdfAapt2Convert",
            progress_message = "aapt2 convert %{label}",
        )
    ctx.actions.run(
        toolchain = None,
        executable = ctx.executable.aapt2,
        arguments = ["optimize", binary.path, "--shorten-resource-paths", "-o", out.path],
        inputs = [binary],
        outputs = [out],
        mnemonic = "RdfAapt2Optimize",
        progress_message = "aapt2 optimize %{label}",
    )
    return [DefaultInfo(files = depset([out]))]

def _rdf_art_profile_impl(ctx):
    prof = ctx.actions.declare_file(ctx.label.name + "/baseline.prof")
    profm = ctx.actions.declare_file(ctx.label.name + "/baseline.profm")
    args = _tool_args(ctx, "artprofile")
    args.add_all(ctx.files.profiles, before_each = "--profile")
    args.add_all(ctx.files.dex, before_each = "--dex")
    args.add("--out-prof", prof)
    args.add("--out-profm", profm)
    _tool(ctx, args, ctx.files.profiles + ctx.files.dex, [prof, profm], "RdfArtProfile", "Baseline profile %{label}")
    return [
        DefaultInfo(files = depset([prof, profm])),
        OutputGroupInfo(prof = depset([prof]), profm = depset([profm])),
    ]

rdf_art_profile = rule(
    doc = "The baseline profile as the binary files a release APK carries in `assets/dexopt/` (AGP's compileArtProfile, with AGP's profgen).",
    implementation = _rdf_art_profile_impl,
    attrs = {
        "dex": attr.label_list(allow_files = True, doc = "The dex archives, in the order they are packaged."),
        "profiles": attr.label_list(allow_files = True, doc = "Profile rules (text), in the names of the final dex."),
        "tool": attr.label(executable = True, cfg = "exec", mandatory = True),
    },
)

rdf_res_finish = rule(
    doc = "The resources a release APK carries: from the proto format R8 shrank them in to binary (`convert`), then optimized as AGP's optimizeResources does.",
    implementation = _rdf_res_finish_impl,
    attrs = {
        "aapt2": attr.label(executable = True, cfg = "exec", allow_single_file = True, mandatory = True),
        "convert": attr.bool(default = True, doc = "The source is in proto format."),
        "src": attr.label(allow_single_file = True, mandatory = True),
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
    if ctx.attr.final_ids:
        args.add("--final-ids")
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
        "final_ids": attr.bool(doc = "`app` mode: write the fields final (android.nonFinalResIds=false)."),
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
    pairs = []
    for f in ctx.files.srcs:
        if not f.basename.endswith(".so") and not ctx.attr.rename:
            continue
        abi = ctx.attr.abi or f.dirname.split("/")[-1]
        if ctx.attr.abis and abi not in ctx.attr.abis:
            continue
        key = abi + "/" + (ctx.attr.rename or f.basename)
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
        pairs.append((abi, f, out))
    if not ctx.attr.symbols:
        return [DefaultInfo(files = depset(outs))]

    # For an app bundle: what each library loses when it is stripped, as AGP keeps it.
    symbols = ctx.actions.declare_file(ctx.label.name + "_symbols.zip")
    args = _tool_args(ctx, "nativesymbols")
    args.add("--objcopy", ctx.executable.objcopy)
    args.add("--level", ctx.attr.symbols)
    args.add("--out", symbols)
    for abi, f, out in pairs:
        args.add("%s=%s=%s" % (abi, f.path, out.path))
    _tool(
        ctx,
        args,
        depset([f for _, f, _ in pairs] + outs + [ctx.executable.objcopy]),
        [symbols],
        "RdfNativeSymbols",
        "Native debug symbols of %{label}",
    )
    return [DefaultInfo(files = depset(outs)), OutputGroupInfo(symbols = depset([symbols]))]

_SYMBOL_ATTRS = {
    "objcopy": attr.label(executable = True, cfg = "exec", allow_single_file = True, doc = "The NDK's llvm-objcopy; needed with `symbols`."),
    "symbols": attr.string(
        values = ["", "symbol_table", "full"],
        doc = "What an app bundle keeps of the libraries (AGP's `ndk.debugSymbolLevel`), in the output group `symbols`.",
    ),
}

rdf_native_libs = rule(
    implementation = _rdf_native_libs_impl,
    attrs = {
        "abi": attr.string(doc = "The ABI of every file, when the directory does not say."),
        "abis": attr.string_list(doc = "The ABIs to keep; all when empty."),
        "rename": attr.string(doc = "The name the (one) library is packaged under: the AOT library is libapp.so."),
        "srcs": attr.label_list(allow_files = True),
        "strip": attr.label(executable = True, cfg = "exec", allow_single_file = True, mandatory = True),
        "tool": attr.label(executable = True, cfg = "exec", doc = "Needed with `symbols`."),
    } | _SYMBOL_ATTRS,
)

def _rdf_native_dir_impl(ctx):
    out = ctx.actions.declare_file(ctx.label.name + ".zip")
    args = _tool_args(ctx, "nativedir")
    args.add("--abi", ctx.attr.abi)
    args.add("--strip", ctx.executable.strip)
    args.add("--out", out)
    args.add_all(ctx.files.srcs, expand_directories = False)
    if not ctx.attr.symbols:
        _tool(ctx, args, depset(ctx.files.srcs + [ctx.executable.strip]), [out], "RdfNativeDir", "Native libraries of %{label}")
        return [DefaultInfo(files = depset([out]))]
    symbols = ctx.actions.declare_file(ctx.label.name + "_symbols.zip")
    args.add("--objcopy", ctx.executable.objcopy)
    args.add("--level", ctx.attr.symbols)
    args.add("--symbols-out", symbols)
    _tool(
        ctx,
        args,
        depset(ctx.files.srcs + [ctx.executable.strip, ctx.executable.objcopy]),
        [out, symbols],
        "RdfNativeDir",
        "Native libraries of %{label}",
    )
    return [DefaultInfo(files = depset([out])), OutputGroupInfo(symbols = depset([symbols]))]

rdf_native_dir = rule(
    doc = """Directories of native libraries whose names are known only when they are built (the
    libraries of build hooks), as one zip part under `lib/<abi>/`: each checked to be of the ABI,
    and stripped.""",
    implementation = _rdf_native_dir_impl,
    attrs = {
        "abi": attr.string(mandatory = True),
        "srcs": attr.label_list(allow_files = True, doc = "Directories."),
        "strip": attr.label(executable = True, cfg = "exec", allow_single_file = True, mandatory = True),
        "tool": attr.label(executable = True, cfg = "exec", mandatory = True),
    } | _SYMBOL_ATTRS,
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
    if ctx.attr.release:
        args.add("--release")
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
        "release": attr.bool(doc = "Compress as a release build does."),
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
    unsigned = ctx.attr.signing == "none"
    out = ctx.actions.declare_file(ctx.label.name + ("-unsigned.apk" if unsigned else ".apk"))
    res_jars = ctx.files.java_resource_jars + _runtime_jars(ctx.attr.java_resource_deps)
    args = _tool_args(ctx, "pack")
    args.add("--out", out)
    entries = []
    for target, name in ctx.attr.entries.items():
        args.add_all(target.files, before_each = "--entry", format_each = name + "=%s")
        entries.append(target.files)
    for target, name in ctx.attr.stored_entries.items():
        args.add_all(target.files, before_each = "--stored-entry", format_each = name + "=%s")
        entries.append(target.files)
    args.add_all(ctx.files.dex, before_each = "--dex")
    if ctx.attr.dex_store:
        args.add("--dex-store")
    for f in ctx.files.native_libs:
        args.add("--native", "%s=%s" % (f.dirname.split("/")[-1], f.path))
    if ctx.attr.native_compress:
        args.add("--native-compress")
    args.add_all(ctx.files.zips, before_each = "--zip")
    args.add_all(ctx.attr.abis, before_each = "--abi")
    args.add_all(ctx.files.resources, before_each = "--resources")
    args.add_all(res_jars, before_each = "--java-res")
    args.add_all(ctx.attr.excludes, before_each = "--exclude")
    args.add_all(ctx.attr.pick_firsts, before_each = "--pick-first")
    args.add_all(ctx.attr.merges, before_each = "--merge")
    args.add_all(ctx.attr.jni_excludes, before_each = "--jni-exclude")
    args.add_all(ctx.attr.jni_pick_firsts, before_each = "--jni-pick-first")
    if ctx.attr.release:
        args.add("--release")
    inputs = ctx.files.dex + ctx.files.native_libs + ctx.files.zips + ctx.files.resources + res_jars
    if unsigned:
        # A key of the user's never enters the build: the APK is aligned here and signed by
        # `bazel run <name>_sign`, outside the action graph.
        args.add("--unsigned")
    else:
        # The debug key, which is no secret: the same one for every build of these rules.
        args.add("--keystore", ctx.file._debug_keystore)
        args.add("--ks-pass", "android")
        args.add("--key-alias", "androiddebugkey")
        args.add("--key-pass", "android")
        args.add("--min-sdk", ctx.attr.min_sdk)
        v1 = ctx.attr.v1_signing
        if v1 == "true" or (v1 == "" and ctx.attr.min_sdk < 24):
            args.add("--v1")
        if ctx.attr.v2_signing == "false":
            args.add("--no-v2")
        if ctx.attr.v3_signing == "true":
            args.add("--v3")
        inputs.append(ctx.file._debug_keystore)
    _tool(ctx, args, depset(inputs, transitive = entries), [out], "RdfApk", "Packaging and signing %{label}", worker = True)
    providers = [
        DefaultInfo(files = depset([out])),
        OutputGroupInfo(_validation = depset(ctx.files.validations)),
    ]
    if ctx.attr.application_id and not unsigned:
        providers.append(RdfApkInfo(apk = out, application_id = ctx.attr.application_id))
    return providers

rdf_apk = rule(
    implementation = _rdf_apk_impl,
    attrs = {
        "abis": attr.string_list(doc = "The ABIs of this APK: native libraries of other ABIs in `zips` are left out. All when empty."),
        "application_id": attr.string(doc = "The application id, for an APK a test runner installs (the whole app)."),
        "dex": attr.label_list(allow_files = True),
        "dex_store": attr.bool(doc = "Package dex files uncompressed."),
        "entries": attr.label_keyed_string_dict(allow_files = True, doc = "File to its name in the APK."),
        "excludes": attr.string_list(),
        "java_resource_deps": attr.label_list(providers = [JavaInfo]),
        "java_resource_jars": attr.label_list(allow_files = [".jar"]),
        "jni_excludes": attr.string_list(),
        "jni_pick_firsts": attr.string_list(),
        "merges": attr.string_list(),
        "min_sdk": attr.int(mandatory = True),
        "native_compress": attr.bool(doc = "Legacy packaging: native libraries compressed, extracted at install."),
        "native_libs": attr.label_list(allow_files = True),
        "pick_firsts": attr.string_list(),
        "release": attr.bool(doc = "Compress as a release build does."),
        "resources": attr.label_list(allow_files = True),
        "stored_entries": attr.label_keyed_string_dict(allow_files = True, doc = "File to its name in the APK, never compressed."),
        "signing": attr.string(
            default = "debug",
            values = ["debug", "none"],
            doc = "`debug`: signed here with the debug key. `none`: left unsigned; a release key signs outside the build.",
        ),
        "tool": attr.label(executable = True, cfg = "exec", mandatory = True),
        "v1_signing": attr.string(values = ["", "true", "false"], doc = "The signing configuration's enableV1Signing; empty for AGP's default."),
        "v2_signing": attr.string(values = ["", "true", "false"]),
        "v3_signing": attr.string(values = ["", "true", "false"]),
        "validations": attr.label_list(allow_files = True, doc = "Checks that must pass for this APK to build (the pin is not stale)."),
        "zips": attr.label_list(allow_files = True),
        "_debug_keystore": attr.label(allow_single_file = True, default = "//flutter/private/android_model:debug.keystore"),
    },
)

# ---------------------------------------------------------------------------------------------------
# An app bundle: the base module, put together as AGP's module task does, through bundletool.

def _rdf_bundle_impl(ctx):
    unsigned = ctx.attr.signing == "none"
    out = ctx.actions.declare_file(ctx.label.name + ("-unsigned.aab" if unsigned else ".aab"))
    res_jars = ctx.files.java_resource_jars + _runtime_jars(ctx.attr.java_resource_deps)
    args = _tool_args(ctx, "bundle")
    args.add("--out", out)
    args.add("--resources", ctx.file.resources)
    entries = []
    for target, name in ctx.attr.root_entries.items():
        args.add_all(target.files, before_each = "--root-entry", format_each = name + "=%s")
        entries.append(target.files)
    for target, name in ctx.attr.metadata.items():
        args.add_all(target.files, before_each = "--metadata", format_each = name + "=%s")
        entries.append(target.files)
    args.add_all(ctx.files.dex, before_each = "--dex")
    for f in ctx.files.native_libs:
        args.add("--native", "%s=%s" % (f.dirname.split("/")[-1], f.path))
    if not ctx.attr.native_compress:
        args.add("--uncompressed-native-libs")
    args.add_all(ctx.files.zips, before_each = "--zip")
    args.add_all(res_jars, before_each = "--java-res")
    args.add_all(ctx.attr.excludes, before_each = "--exclude")
    args.add_all(ctx.attr.pick_firsts, before_each = "--pick-first")
    args.add_all(ctx.attr.merges, before_each = "--merge")
    args.add_all(ctx.attr.jni_excludes, before_each = "--jni-exclude")
    args.add_all(ctx.attr.jni_pick_firsts, before_each = "--jni-pick-first")
    args.add_all(ctx.attr.no_splits, before_each = "--no-split")
    args.add_all(ctx.attr.uncompressed_globs, before_each = "--uncompressed-glob")
    if not ctx.attr.store_archive:
        args.add("--no-store-archive")
    args.add("--min-sdk", ctx.attr.min_sdk)
    args.add_all(ctx.files.symbols, before_each = "--symbols")
    inputs = ctx.files.dex + ctx.files.native_libs + ctx.files.zips + ctx.files.symbols + res_jars + [ctx.file.resources]
    if unsigned:
        args.add("--unsigned")
    else:
        args.add("--keystore", ctx.file._debug_keystore)
        inputs.append(ctx.file._debug_keystore)
    _tool(ctx, args, depset(inputs, transitive = entries), [out], "RdfBundle", "Bundling %{label}")
    return [
        DefaultInfo(files = depset([out])),
        OutputGroupInfo(_validation = depset(ctx.files.validations)),
    ]

def _rdf_dependency_report_impl(ctx):
    out = ctx.actions.declare_file(ctx.label.name + ".pb")
    args = _tool_args(ctx, "dependencies")
    args.add("--out", out)
    args.add_all(ctx.attr.libraries, before_each = "--library")
    args.add_all(ctx.attr.library_dependencies, before_each = "--library-dependencies")
    args.add_all(ctx.attr.module_dependencies, before_each = "--module-dependency")
    args.add_all(ctx.attr.repositories, before_each = "--repository")
    _tool(ctx, args, depset(), [out], "RdfDependencyReport", "Dependency report of %{label}")
    return [DefaultInfo(files = depset([out]))]

rdf_dependency_report = rule(
    doc = """The dependency report of an app bundle (`dependencies.pb`): the Maven libraries of the app,
    which depends on which and where each came from, as the pin recorded them from AGP's own task.""",
    implementation = _rdf_dependency_report_impl,
    attrs = {
        "libraries": attr.string_list(doc = "`<group:name:version>|<index of its repository, or -1>|<sha256 of its artifact, or empty>`."),
        "library_dependencies": attr.string_list(doc = "`<index>=<index>,...`: a library and the libraries it depends on."),
        "module_dependencies": attr.string_list(doc = "Indices of the libraries the app's projects depend on."),
        "repositories": attr.string_list(doc = "`maven=<url>` or `ivy=<url>`."),
        "tool": attr.label(executable = True, cfg = "exec", mandatory = True),
    },
)

rdf_bundle = rule(
    doc = """An app bundle (.aab) with one module, `base`, built by bundletool (the version AGP uses).

    The module is what AGP's module task makes: the manifest and the resources in proto format, the
    dex files, the native libraries, the assets, and the Java resources under `root/`.""",
    implementation = _rdf_bundle_impl,
    attrs = {
        "dex": attr.label_list(allow_files = True),
        "excludes": attr.string_list(),
        "java_resource_deps": attr.label_list(providers = [JavaInfo]),
        "java_resource_jars": attr.label_list(allow_files = [".jar"]),
        "jni_excludes": attr.string_list(),
        "jni_pick_firsts": attr.string_list(),
        "merges": attr.string_list(),
        "metadata": attr.label_keyed_string_dict(allow_files = True, doc = "File to `<directory>/<name>` under BUNDLE-METADATA."),
        "min_sdk": attr.int(mandatory = True),
        "native_compress": attr.bool(doc = "Legacy packaging: native libraries compressed in the APKs made from the bundle."),
        "native_libs": attr.label_list(allow_files = True),
        "no_splits": attr.string_list(doc = "Dimensions the store must not split the module by: ABI, SCREEN_DENSITY, LANGUAGE."),
        "pick_firsts": attr.string_list(),
        "resources": attr.label(allow_single_file = True, mandatory = True, doc = "The linked resources, proto format."),
        "root_entries": attr.label_keyed_string_dict(allow_files = True, doc = "File to its path under the module's `root/`."),
        "signing": attr.string(default = "debug", values = ["debug", "none"]),
        "store_archive": attr.bool(default = True),
        "symbols": attr.label_list(allow_files = [".zip"], doc = "Native debug symbols (`<abi>/<library>.sym`), under BUNDLE-METADATA."),
        "tool": attr.label(executable = True, cfg = "exec", mandatory = True),
        "uncompressed_globs": attr.string_list(),
        "validations": attr.label_list(allow_files = True),
        "zips": attr.label_list(allow_files = True, doc = "Asset parts (entries under assets/)."),
        "_debug_keystore": attr.label(allow_single_file = True, default = "//flutter/private/android_model:debug.keystore"),
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

    # The plugins of the lock that have an Android side: the pin's against the build's.
    if ctx.attr.check_plugins and ctx.files.plugin_list:
        args.add("--plugin-list", ctx.files.plugin_list[0])
        args.add_all(ctx.attr.plugins, before_each = "--plugin")
    _tool(ctx, args, ctx.files.srcs + ctx.files.plugin_list, [out], "RdfPinCheck", "Checking that %s is current" % ctx.attr.model)
    return [DefaultInfo(files = depset([out]))]

rdf_pin_check = rule(
    implementation = _rdf_pin_check_impl,
    attrs = {
        "hub_prefix": attr.string(doc = "Where the hub links the app's directory; a file under it is named by the rest of its path."),
        "check_plugins": attr.bool(doc = "Whether the pin records its plugins (a pin of an app without Flutter has none to check)."),
        "inputs": attr.string_dict(doc = "Package-relative path to the sha256 the pin recorded."),
        "model": attr.string(mandatory = True),
        "pin_command": attr.string(mandatory = True),
        "plugin_list": attr.label(allow_files = True, doc = "The build's own list, one `<name> <version>` a line (the application's `android_plugins` output group); nothing when the app names no lock."),
        "plugins": attr.string_list(doc = "`<name> <version>` of the plugins with an Android side that the pin was written for."),
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
# An AAR made in this build (a Flutter module, `flutter_android_aar`), taken apart for the app.

def _rdf_aar_parts_impl(ctx):
    manifest = ctx.actions.declare_file(ctx.label.name + "/AndroidManifest.xml")
    classes = ctx.actions.declare_file(ctx.label.name + "/classes.jar")
    part = ctx.actions.declare_file(ctx.label.name + "/part.zip")
    args = _tool_args(ctx, "aarparts")
    args.add("--aar", ctx.file.aar)
    args.add("--manifest", manifest)
    args.add("--classes", classes)
    args.add("--part", part)
    _tool(ctx, args, [ctx.file.aar], [manifest, classes, part], "RdfAarParts", "Taking %{label} apart")
    return [
        DefaultInfo(files = depset([manifest, classes, part])),
        OutputGroupInfo(manifest = depset([manifest]), classes = depset([classes]), part = depset([part])),
    ]

rdf_aar_parts = rule(
    doc = """The parts of an AAR that the build made: `manifest`, `classes` (a jar) and `part` (a zip
    of its native libraries as `lib/<abi>/` and its assets), as output groups.""",
    implementation = _rdf_aar_parts_impl,
    attrs = {
        "aar": attr.label(allow_single_file = [".aar"], mandatory = True),
        "tool": attr.label(executable = True, cfg = "exec", mandatory = True),
    },
)

# ---------------------------------------------------------------------------------------------------
# Small adapters.

def _rdf_output_group_impl(ctx):
    groups = ctx.attr.src[OutputGroupInfo]
    if ctx.attr.optional and not hasattr(groups, ctx.attr.group):
        return [DefaultInfo(files = depset())]
    return [DefaultInfo(files = getattr(groups, ctx.attr.group))]

rdf_output_group = rule(
    doc = "The files of one output group of a target.",
    implementation = _rdf_output_group_impl,
    attrs = {
        "group": attr.string(mandatory = True),
        "optional": attr.bool(doc = "No files, not an error, when the target has no such group."),
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
