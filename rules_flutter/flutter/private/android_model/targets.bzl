"""Targets generated from the pinned Gradle model.

`android_model_hub_targets` runs in the hub repository's BUILD file: AGP's tools, one import per Maven
artifact and one library per plugin project. `android_model_app` runs in the app's own BUILD file (as
`flutter_android_app` of the hub's `defs.bzl`) and makes the app's library, its resources, the split
APKs and the whole APK.

Nothing here reads a Gradle file. What the model records and the rules do not build is an error that
names the project and the feature (`_problems`).
"""

load("@bazel_skylib//rules:write_file.bzl", "write_file")
load("@rules_java//java:defs.bzl", "java_binary", "java_import", "java_library", "java_plugin")
load("@rules_kotlin//kotlin:core.bzl", "define_kt_toolchain", "kt_kotlinc_options", "kt_ksp_plugin")
load("@rules_kotlin//kotlin:jvm.bzl", "kt_jvm_library")
load("//flutter/private:flutter_android_application.bzl", "flutter_android_bundle")
load(":names.bzl", "artifact_repo", "artifact_target", "project_target")
load(
    ":rules.bzl",
    "rdf_aapt2_link",
    "rdf_apk",
    "rdf_dex",
    "rdf_dex_archive",
    "rdf_dex_merge",
    "rdf_gradle_aar",
    "rdf_l8",
    "rdf_manifest_merge",
    "rdf_native_libs",
    "rdf_output_group",
    "rdf_pin_check",
    "rdf_r_jar",
    "rdf_res_compile",
    "rdf_symbols",
    "rdf_zip_part",
)

_TOOL_SOURCES = ["AndroidTool.java", "Apk.java", "Dexing.java", "GradleAar.java", "PinCheck.java", "Resources.java"]

# ABIs the Dart side can build native code for (FFI libraries, code assets).
_DART_ABIS = ["arm64-v8a", "x86_64"]

# Kotlin compiler arguments that change nothing in the classes (debug information only).
_KOTLIN_ARGS_WITHOUT_EFFECT = ["-Xuse-inline-scopes-numbers"]

# Jars on a Kotlin compile task's plugin classpath that are no compiler plugin of the project's own:
# kapt and KSP (rules_kotlin runs its own) and the libraries they bring.
_KOTLIN_PLUGIN_JARS_HANDLED = [
    "kotlin-annotation-processing-",
    "kotlin-build-tools-",
    "symbol-processing-",
    "kotlin-stdlib-",
    "kotlin-reflect-",
    "kotlinx-",
    "annotations-",
]

# ---------------------------------------------------------------------------------------------------
# Reading the model.

def _app_project(model):
    for k, p in model["projects"].items():
        if p["type"] == "application":
            return k, p
    fail("android_model: the model has no application project")

def _classpath(model, v, which):
    """One classpath in Gradle's order, highest priority first: ("p", project, variant) or ("a", artifact)."""
    out = []
    cp = v.get(which)
    if not cp:
        return out
    for e in model["classpaths"][cp]:
        if e.startswith("project:"):
            path, _, variant = e[len("project:"):].rpartition("@")
            out.append(("p", path, variant))
        elif e.startswith("file:"):
            out.append(("f", e[len("file:"):], None))
        else:
            out.append(("a", e, None))
    return out

def _artifacts(model, v, which):
    return [e[1] for e in _classpath(model, v, which) if e[0] == "a"]

def _projects(model, v, which):
    return [(e[1], e[2]) for e in _classpath(model, v, which) if e[0] == "p"]

def _has_jar(a):
    aar = a.get("aar")
    return (not aar) or aar["classes"] or bool(aar["libs"])

def _has_native(a):
    return bool(a.get("native_libs")) or bool(a.get("aar") and a["aar"]["jni"])

def _artifact_jar(path):
    return "@%s//:jar" % artifact_repo(path)

def _sdk_jar(p):
    return "sdk/platforms/%s/android.jar" % p["compile_sdk"]

def _is_local(p):
    """The project whose sources are in the package that calls `flutter_android_app`: the app."""
    return p["type"] == "application"

def _path(rooted, local, info):
    """A model path as a path relative to the package that builds it; None when it belongs elsewhere.

    The app is built in its own package. Every other project is built in the hub: a plugin of the pub
    cache from its archive (`pub/`), a project of the workspace (a library module of the app, a
    plugin under development) through a link to its directory (`ws/`).
    """
    root, _, rest = rooted.partition(":")
    if local:
        return rest if root == "app" else None
    if root == "pub":
        return "pub/" + rest
    if root == "ws":
        return "ws/" + rest
    if root == "app":
        return "ws/" + (info["app_dir"] + "/" if info["app_dir"] else "") + rest
    return None

def _paths(rooted, local, info):
    return [p for p in [_path(r, local, info) for r in rooted] if p != None]

def _dex_config(_model, v):
    """How an app variant dexes: the minimum API level and whether the core library is desugared."""
    return "m%s%s" % (v["min_sdk"], "d" if v.get("core_library_desugaring") else "")

def _needs_classpath(v):
    # AGP gives D8 the classpath only below API 24, where default and static interface methods are
    # desugared; from 24 on each jar is dexed alone. (With the classpath D8 writes other helper
    # classes than the stock build has.)
    return int(v["min_sdk"]) < 24

def _needs_platform(v):
    # A library (a Maven artifact, a plugin project) is dexed against android.jar only where AGP's
    # dexing transform has it: below API 24 or with core library desugaring. Without it D8 does not
    # see newer platform types (ExecutorService as AutoCloseable since API 34) and writes no helper
    # classes for them. Checked against the stock build's own intermediate dex: equal bytes.
    return int(v["min_sdk"]) < 24 or bool(v.get("core_library_desugaring"))

def _reached(model, v):
    """The (project, variant) pairs an app variant builds, in a stable order."""
    seen = {}
    todo = _projects(model, v, "runtime") + _projects(model, v, "compile")
    for _ in range(10000):
        if not todo:
            break
        key = todo.pop(0)
        if key in seen:
            continue
        seen[key] = True
        q = model["projects"][key[0]]["variants"][key[1]]
        todo += _projects(model, q, "runtime") + _projects(model, q, "compile")
    return seen.keys()

def _hub_input(model, path):
    """Whether a pin input (a path relative to the app) lies in a library project of the app's tree."""
    for p in model["projects"].values():
        if p["type"] != "application" and p["dir"].startswith("app:") and path.startswith(p["dir"][len("app:"):] + "/"):
            return True
    return False

def _crunch(p, build_type):
    for b in p["build_types"]:
        if b["name"] == build_type:
            return bool(b.get("crunch_pngs"))
    return False

def _native_problems(path, p, built_elsewhere):
    """A CMake or ndk-build library the model records; the rules do not run those builds."""
    enb = p.get("external_native_build") or {}
    native = enb.get("cmake") or enb.get("ndk_build")

    # Flutter's own Gradle plugin points every app at an empty CMake project of the SDK.
    if not native or native.startswith("flutter:") or path in built_elsewhere:
        return []
    return ["project %s: native code built by %s (%s). If Bazel builds that library on the Dart side, list the project in `native_built_elsewhere` of `flutter_android_app`" % (path, "CMake" if enb.get("cmake") else "ndk-build", native)]

def _problems(model, path, p, v):
    """What the model records for one project variant and these rules do not build."""
    out = []
    where = "project %s" % path
    for feature in ("dataBinding", "viewBinding", "compose", "renderScript", "mlModelBinding", "prefab", "prefabPublishing"):
        if p["build_features"].get(feature):
            out.append("%s: build feature `%s`" % (where, feature))
    for kind, feature in (("aidl", "AIDL sources"), ("shaders", "shader sources"), ("java_resources", "Java resource directories")):
        if v["sources"].get(kind):
            out.append("%s: %s (%s)" % (where, feature, ", ".join(v["sources"][kind])))
    kotlin = v.get("kotlin") or {}
    for jar in kotlin.get("plugin_jars", []):
        if not [h for h in _KOTLIN_PLUGIN_JARS_HANDLED if jar.startswith(h)]:
            out.append("%s: Kotlin compiler plugin %s" % (where, jar))
    for arg in kotlin.get("free_compiler_args", []):
        if arg not in _KOTLIN_ARGS_WITHOUT_EFFECT and _kotlin_arg(arg) == None:
            out.append("%s: Kotlin compiler argument %s" % (where, arg))
    if v.get("annotation_processor_args") and v["sources"]["kotlin"] and _has_kotlin_plugin(p):
        out.append("%s: annotation processor arguments in a Kotlin project (%s)" % (where, ", ".join(v["annotation_processor_args"].keys())))
    for which in ("runtime", "compile"):
        for e in _classpath(model, v, which):
            if e[0] == "f":
                out.append("%s: file dependency %s" % (where, e[1]))
    return out

def _has_kotlin_plugin(p):
    return bool([c for c in p["gradle_plugins"] if c.startswith("org.jetbrains.kotlin.")])

def _kotlin_arg(arg):
    """A free compiler argument as (kt_kotlinc_options attribute, value), or None when it is unknown."""
    if arg.startswith("-Xjvm-default="):
        return ("x_jvm_default", arg.split("=", 1)[1])
    if arg.startswith("-jvm-default="):
        return ("jvm_default", arg.split("=", 1)[1])
    if arg.startswith("-opt-in=") or arg.startswith("-Xopt-in="):
        return ("x_optin", arg.split("=", 1)[1])
    if arg == "-Xcontext-receivers":
        return ("x_context_receivers", True)
    if arg == "-Xcontext-parameters":
        return ("x_context_parameters", True)
    if arg == "-progressive":
        return ("progressive", True)
    if arg == "-java-parameters":
        return ("java_parameters", True)
    return None

def _fail_on(problems, pin_command):
    problems = {p: True for p in problems}.keys()
    if problems:
        fail("\nandroid_model: the Gradle model has what these rules do not build:\n  - " + "\n  - ".join(problems) +
             "\nA plugin project can be built by Gradle itself instead: list it in `gradle_fallback` of the pin target and run `%s`." % pin_command)

# ---------------------------------------------------------------------------------------------------
# One Android project (the app, a plugin, a library module) as one library.

def _build_config(name, p, v):
    """What AGP's generateBuildConfig writes: the standard fields, then the variant's own."""
    ns = v["namespace"]
    lines = [
        "package %s;" % ns,
        "public final class BuildConfig {",
        "  public static final boolean DEBUG = %s;" % ('Boolean.parseBoolean("true")' if v["debuggable"] else "false"),
    ]
    if p["type"] == "application":
        lines.append('  public static final String APPLICATION_ID = "%s";' % v["application_id"])
    else:
        lines.append('  public static final String LIBRARY_PACKAGE_NAME = "%s";' % ns)
    lines.append('  public static final String BUILD_TYPE = "%s";' % v["build_type"])
    flavors = v["flavors"]
    if flavors:
        lines.append('  public static final String FLAVOR = "%s";' % "".join([f["name"] if i == 0 else f["name"][:1].upper() + f["name"][1:] for i, f in enumerate(flavors)]))
    if len(flavors) > 1:
        for f in flavors:
            lines.append('  public static final String FLAVOR_%s = "%s";' % (f["dimension"], f["name"]))
    if p["type"] == "application":
        lines.append("  public static final int VERSION_CODE = %s;" % (v.get("version_code") or 1))
        lines.append('  public static final String VERSION_NAME = "%s";' % (v.get("version_name") or ""))
    for fname, f in v["build_config_fields"].items():
        lines.append("  public static final %s %s = %s;" % (f["type"], fname, f["value"]))
    lines += ["}", ""]
    write_file(name = name + "_buildconfig", out = name + "_gen/" + ns.replace(".", "/") + "/BuildConfig.java", content = lines)
    return ":" + name + "_buildconfig"

def _kotlinc_options(name, kotlin):
    kwargs = dict(
        jvm_target = kotlin.get("jvm_target") or "17",
        warn = "off",
        # rules_kotlin compiles lambdas to classes; Gradle's default since Kotlin 2.0 is invokedynamic.
        x_lambdas = "indy",
        x_sam_conversions = "indy",
    )
    if kotlin.get("language_version"):
        kwargs["language_version"] = kotlin["language_version"]
    if kotlin.get("api_version"):
        kwargs["api_version"] = kotlin["api_version"]
    optin = list(kotlin.get("opt_in") or [])
    for arg in kotlin.get("free_compiler_args") or []:
        mapped = _kotlin_arg(arg)
        if mapped == None:
            continue
        if mapped[0] == "x_optin":
            optin.append(mapped[1])
        else:
            kwargs[mapped[0]] = mapped[1]
    if optin:
        kwargs["x_optin"] = optin
    kt_kotlinc_options(name = name, **kwargs)

def _processors(name, model, v, hub):
    """kapt, KSP and Java annotation processors of the model as rules_kotlin and rules_java plugins."""
    plugins = []
    arts = model["artifacts"]
    seen = {}
    for which in ("annotation_processors", "kapt_processors"):
        paths = _artifacts(model, v, which)
        deps = [hub + artifact_target(a) for a in paths if _has_jar(arts[a])]
        for a in paths:
            for cls in arts[a].get("processors", []):
                if cls in seen:
                    continue
                seen[cls] = True
                plugin = "%s_ap%d" % (name, len(plugins))
                java_plugin(name = plugin, processor_class = cls, deps = deps, generates_api = True)
                plugins.append(":" + plugin)
    paths = _artifacts(model, v, "ksp_processors")
    deps = [hub + artifact_target(a) for a in paths if _has_jar(arts[a])]
    for a in paths:
        for cls in arts[a].get("ksp_providers", []):
            plugin = "%s_ksp%d" % (name, len(plugins))
            kt_ksp_plugin(name = plugin, processor_class = cls, deps = deps, options = {k: str(val) for k, val in (v.get("ksp_args") or {}).items()})
            plugins.append(":" + plugin)
    return plugins

def _project(name, path, p, v, model, info, hub, label_of, dex_variants, extra_srcs = [], extra_deps = [], exclude = []):
    """One Android project variant: library, compile-time R class, manifest, compiled resources, dex.

    Args:
      name: the target name stem.
      path: the Gradle path of the project.
      p: the project of the model.
      v: its variant.
      model: the model.
      info: what the hub's repository rule found on this host.
      hub: label prefix of the hub's root package.
      label_of: function from (project path, variant) to the label stem of that project's targets.
      dex_variants: the app variants this project is dexed for.
      extra_srcs: generated sources.
      extra_deps: more compile dependencies (the app's R classes).
      exclude: glob patterns of sources to leave out.
    """
    local = _is_local(p)
    src = v["sources"]
    arts = model["artifacts"]
    dirs = []
    for d in _paths(src["kotlin"], local, info) + _paths(src["java"], local, info):
        if d not in dirs:
            dirs.append(d)
    kt = native.glob([d + "/**/*.kt" for d in dirs], exclude = exclude, allow_empty = True)
    jv = native.glob([d + "/**/*.java" for d in dirs], exclude = exclude, allow_empty = True) + extra_srcs
    if p["build_features"].get("buildConfig"):
        jv = jv + [_build_config(name, p, v)]

    sdk_jar = hub + _sdk_jar(p)
    deps = [hub + "android_jar_" + p["compile_sdk"], hub + "ext_r"]
    for e in _classpath(model, v, "compile"):
        if e[0] == "p":
            q = model["projects"][e[1]]
            deps.append(label_of(e[1], e[2]))
            if _res_dirs(q, q["variants"][e[2]]):
                deps.append(label_of(e[1], e[2]) + "_r")
        elif e[0] == "a" and _has_jar(arts[e[1]]):
            deps.append(hub + artifact_target(e[1]))
    deps += extra_deps

    # Resources, and the R class the project's own code compiles against.
    res_srcs = native.glob([d + "/**" for d in _paths(src["res"], local, info)], allow_empty = True)
    if v["res_values"]:
        # resValue of the DSL, and what a generator plugin (google-services) wrote at pin time.
        lines = ['<?xml version="1.0" encoding="utf-8"?>', "<resources>"]
        for rname, r in v["res_values"].items():
            value = r["value"].replace("&", "&amp;").replace("<", "&lt;")
            if r["type"] == "string":
                # As AGP's generator writes a string value: never translatable.
                lines.append('    <string name="%s" translatable="false">%s</string>' % (rname, value))
            else:
                lines.append('    <item name="%s" type="%s">%s</item>' % (rname, r["type"], value))
        lines += ["</resources>", ""]
        write_file(name = name + "_res_values", out = name + "_gen/res/values/gradleResValues.xml", content = lines)
        res_srcs = res_srcs + [":" + name + "_res_values"]
    rdf_res_compile(
        name = name + "_res",
        srcs = res_srcs,
        # A project's own PNGs are crunched by build type.
        crunch = _crunch(p, v["build_type"]),
        aapt2 = hub + "aapt2",
        tool = hub + "tool",
    )
    rdf_symbols(
        name = name + "_symbols",
        srcs = res_srcs,
        package = v["namespace"],
        android_jar = sdk_jar,
        tool = hub + "tool_once",
    )
    if p["type"] != "application" and res_srcs:
        rdf_r_jar(
            name = name + "_r",
            mode = "library",
            package = v["namespace"],
            local = ":" + name + "_symbols",
            android_jar = sdk_jar,
            tool = hub + "tool_once",
        )
        deps.append(":" + name + "_r")

    plugins = _processors(name, model, v, hub)
    kotlin = v.get("kotlin") or {}
    java = p.get("java") or {}
    if kt:
        _kotlinc_options(name + "_kotlinc", kotlin)
        kt_jvm_library(
            name = name,
            srcs = kt + jv,
            deps = deps,
            plugins = plugins,
            kotlinc_opts = ":" + name + "_kotlinc",
            # Gradle's module name is `<group>:<project>_<variant>`. The compiler mangles `internal`
            # names with it, reading every character that cannot be in an identifier as `_`, so the
            # colon (a path separator to the compiler's classpath) can be written that way.
            module_name = (kotlin.get("module_name") or name).replace(":", "_"),
        )
    else:
        javacopts = ["-XepDisableAllChecks", "-Xlint:none", "-nowarn"]
        if java.get("source"):
            javacopts += ["-source", java["source"], "-target", java.get("target") or java["source"]]
        javacopts += [a for a in v.get("javac_args") or [] if not a.startswith("-Xlint") and a != "-Werror"]
        javacopts += ["-A%s=%s" % (k, val) for k, val in (v.get("annotation_processor_args") or {}).items()]
        java_library(
            name = name,
            srcs = jv,
            deps = deps,
            plugins = plugins,
            javacopts = javacopts,
        )

    # Dex: AGP's first step, once per way an app variant dexes.
    done = {}
    for av in dex_variants:
        config = _dex_config(model, av)
        if config in done:
            continue
        done[config] = True
        needs_classpath = _needs_classpath(av)
        rdf_dex(
            name = name + "_dex_" + config,
            deps = [":" + name],
            min_sdk = int(av["min_sdk"]),
            debuggable = av["debuggable"],
            store = av["packaging"].get("dex_use_legacy") == False,
            desugared_lib_config = (hub + "desugar_config") if av.get("core_library_desugaring") else None,
            classpath = [hub + "ext_jars_" + config] if needs_classpath else [],
            classpath_deps = [label_of(q, qv) for q, qv in _projects(model, v, "compile")] if needs_classpath else [],
            # The app's own classes are dexed by a task that always has the platform library.
            with_platform = p["type"] == "application" or _needs_platform(av),
            android_jar = sdk_jar,
            tool = hub + "tool",
        )

    manifests = _paths(src["manifests"], local, info)
    if not manifests:
        fail("android_model: project %s has no manifest in the model" % path)
    if p["type"] == "application":
        native.filegroup(name = name + "_manifest", srcs = manifests[:1])
        native.filegroup(name = name + "_manifest_overlays", srcs = manifests[1:])
    else:
        # As AGP's ProcessLibraryManifest: the library's manifest with its namespace and SDK levels
        # written in, so that the app's merge adds no implicit permission for a missing uses-sdk.
        rdf_manifest_merge(
            name = name + "_manifest",
            main = manifests[0],
            overlays = manifests[1:],
            namespace = v["namespace"],
            merge_type = "LIBRARY",
            properties = {
                "MIN_SDK_VERSION": str(v["min_sdk"]),
                "PACKAGE": v["namespace"],
                "TARGET_SDK_VERSION": str(v["target_sdk"] or v["min_sdk"]),
            },
            placeholders = v["manifest_placeholders"],
            tool = hub + "tool_once",
        )
    native.filegroup(
        name = name + "_native",
        srcs = native.glob([d + "/**/*.so" for d in _paths(src["jni_libs"], local, info)], allow_empty = True),
    )
    native.filegroup(
        name = name + "_assets",
        srcs = native.glob([d + "/**" for d in _paths(src["assets"], local, info)], allow_empty = True),
    )

def _res_dirs(p, v):
    # A project Gradle builds always has a symbol list (its AAR's R.txt, which may be empty).
    return bool(v["sources"]["res"]) or bool(v["res_values"]) or bool(p.get("gradle_fallback"))

def _gradle_project(name, path, variant, model, hub, android_dir, dex_variants, inputs):
    """One project built by Gradle itself (the escape hatch), with the targets `_project` makes."""
    p = model["projects"][path]
    v = p["variants"][variant]
    sdk_jar = hub + _sdk_jar(p)
    rdf_gradle_aar(
        name = name,
        project = path,
        variant = variant,
        android_dir = android_dir,
        init = Label("//flutter/private/android_model/tools:model.init.gradle"),
        srcs = inputs + [hub + project_target(path, variant) + "_files"],
        tool = hub + "tool_once",
    )
    for group in ("manifest", "res", "assets"):
        rdf_output_group(name = "%s_%s%s" % (name, group, "_files" if group != "manifest" else ""), src = ":" + name, group = group)
    rdf_output_group(name = name + "_symbols", src = ":" + name, group = "rtxt")
    rdf_res_compile(name = name + "_res", srcs = [":" + name + "_res_files"], aapt2 = hub + "aapt2", tool = hub + "tool")
    rdf_r_jar(name = name + "_r", mode = "external", deps = {":" + name + "_symbols": v["namespace"]}, tool = hub + "tool_once")
    native.filegroup(name = name + "_native", srcs = [])
    done = {}
    for av in dex_variants:
        config = _dex_config(model, av)
        if config in done:
            continue
        done[config] = True
        rdf_dex(
            name = name + "_dex_" + config,
            deps = [":" + name],
            min_sdk = int(av["min_sdk"]),
            debuggable = av["debuggable"],
            store = av["packaging"].get("dex_use_legacy") == False,
            desugared_lib_config = (hub + "desugar_config") if av.get("core_library_desugaring") else None,
            classpath = [hub + "ext_jars_" + config] if _needs_classpath(av) else [],
            with_platform = _needs_platform(av),
            android_jar = sdk_jar,
            tool = hub + "tool",
        )

# ---------------------------------------------------------------------------------------------------
# The hub: everything that does not depend on the app's own sources.

def android_model_hub_targets(name, model, info):
    """Generates the hub's targets.

    Args:
      name: unused; a macro has a name.
      model: the decoded pin file.
      info: what the hub's repository rule found on this host.
    """
    hub = ":"
    arts = model["artifacts"]
    _, app = _app_project(model)
    variants = app["variants"].values()

    # What the model records and the rules do not build: an error, here, before anything is built.
    problems = []
    for path, p in model["projects"].items():
        if p["type"] == "application" or _is_local(p) or p.get("gradle_fallback"):
            continue
        for v in p["variants"].values():
            problems += _problems(model, path, p, v)
    _fail_on(problems, info["pin_command"])

    # The Android SDK: platforms and the NDK's strip.
    sdks = {p["compile_sdk"]: True for p in model["projects"].values()}
    for s in sdks:
        java_import(name = "android_jar_" + s, jars = ["sdk/platforms/%s/android.jar" % s], neverlink = True)
    native.exports_files(["sdk/platforms/%s/android.jar" % s for s in sdks])
    strip = "sdk/ndk/%s/toolchains/llvm/prebuilt/%s/bin/llvm-strip%s" % (app["ndk_version"], info["ndk_host"], info["exe"])
    native.exports_files([strip])
    native.alias(name = "llvm_strip", actual = strip)

    # AGP's own tools, from the pin, behind one program.
    tool_jars = []
    for name in ("r8", "manifest_merger", "apksig", "r_class_writer", "resource_compiler"):
        for a in model["tool_classpaths"][name]:
            if _artifact_jar(a) not in tool_jars:
                tool_jars.append(_artifact_jar(a))
    java_import(name = "tool_libs", jars = tool_jars)
    java_library(
        name = "tool_lib",
        srcs = [Label("//flutter/private/android_model/tools:" + s) for s in _TOOL_SOURCES],
        javacopts = ["-XepDisableAllChecks", "-Xlint:none", "-nowarn"],
        deps = [":tool_libs"],
    )
    java_binary(
        name = "tool",
        main_class = "rules_flutter.android.AndroidTool",
        jvm_flags = ["-Xshare:auto", "-XX:+UseParallelGC", "-Xss4m"],
        runtime_deps = [":tool_lib"],
    )
    java_binary(
        name = "tool_once",
        main_class = "rules_flutter.android.AndroidTool",
        jvm_flags = ["-Xshare:auto", "-XX:TieredStopAtLevel=1", "-XX:+UseSerialGC"],
        runtime_deps = [":tool_lib"],
    )
    aapt2 = model["tool_classpaths"]["aapt2_" + info["host_os"]][0]
    native.alias(name = "aapt2", actual = "@%s//:x/aapt2%s" % (artifact_repo(aapt2), info["exe"]))

    # Kotlin through rules_kotlin, with ABI jars: a dependant recompiles only when a library's ABI changed.
    define_kt_toolchain(name = "kotlin_toolchain", experimental_use_abi_jars = True)

    # Maven artifacts: an import, a dex archive per way of dexing, compiled resources.
    used = {}
    reached = {}
    configs = {}
    for v in variants:
        for key in _reached(model, v):
            reached[key] = True
        config = _dex_config(model, v)
        configs.setdefault(config, []).append(v)
    for path, p in model["projects"].items():
        for v in p["variants"].values():
            for which in ("runtime", "compile", "annotation_processors", "kapt_processors", "ksp_processors"):
                for a in _artifacts(model, v, which):
                    used[a] = True

    for config, vs in configs.items():
        av = vs[0]
        jars = []
        for v in vs:
            for a in _artifacts(model, v, "runtime"):
                if _has_jar(arts[a]) and _artifact_jar(a) not in jars:
                    jars.append(_artifact_jar(a))
        native.filegroup(name = "ext_jars_" + config, srcs = jars)
        if av.get("core_library_desugaring"):
            # Core library desugaring: the configuration D8 rewrites calls with, and the library itself.
            cld = _artifacts(model, av, "core_library_desugaring")
            cfg = [a for a in cld if "desugar_jdk_libs_configuration" in a]
            if not cfg:
                fail("android_model: core library desugaring without com.android.tools:desugar_jdk_libs_configuration in the model")
            if not native.existing_rule("desugar_config"):
                native.alias(name = "desugar_config", actual = "@%s//:x/META-INF/desugar/d8/desugar.json" % artifact_repo(cfg[0]))
            rdf_l8(
                name = "desugared_lib_dex_" + config,
                jars = [_artifact_jar(a) for a in cld],
                min_sdk = int(av["min_sdk"]),
                debuggable = av["debuggable"],
                store = av["packaging"].get("dex_use_legacy") == False,
                desugared_lib_config = ":desugar_config",
                android_jar = _sdk_jar(app),
                tool = ":tool_once",
            )

    r_deps = {}
    r_empty = []
    for path in used:
        a = arts[path]
        t = artifact_target(path)
        repo = "@" + artifact_repo(path)
        aar = a.get("aar")
        if _has_jar(a):
            java_import(name = t, jars = [repo + "//:jar"])
            for config, vs in configs.items():
                av = vs[0]
                rdf_dex(
                    name = t + "_dex_" + config,
                    jars = [repo + "//:jar"],
                    min_sdk = int(av["min_sdk"]),
                    debuggable = av["debuggable"],
                    store = av["packaging"].get("dex_use_legacy") == False,
                    desugared_lib_config = ":desugar_config" if av.get("core_library_desugaring") else None,
                    classpath = [":ext_jars_" + config] if _needs_classpath(av) else [],
                    with_platform = _needs_platform(av),
                    android_jar = _sdk_jar(app),
                    tool = ":tool",
                )
            native.alias(name = t + "_jar", actual = repo + "//:jar")
        if aar:
            native.alias(name = t + "_manifest", actual = repo + "//:aar/AndroidManifest.xml")
            native.alias(name = t + "_rtxt", actual = repo + "//:aar/R.txt")
            if aar["assets"]:
                native.alias(name = t + "_assets", actual = repo + "//:assets")
            if aar["res"]:
                rdf_res_compile(name = t + "_res", srcs = [repo + "//:res"], aapt2 = ":aapt2", tool = ":tool")
            if aar.get("namespace"):
                if aar["r_txt"]:
                    r_deps[repo + "//:aar/R.txt"] = aar["namespace"]
                elif aar["namespace"] not in r_empty:
                    r_empty.append(aar["namespace"])
        if _has_native(a):
            native.alias(name = t + "_native", actual = repo + "//:native_libs")

    # The pin's input files that lie in library projects of the workspace (see rdf_pin_check).
    native.filegroup(
        name = "pin_inputs",
        srcs = native.glob([_path("app:" + f, False, info) for f in model["inputs"] if _hub_input(model, f)], allow_empty = True),
    )

    # The R classes of the AARs that project code compiles against (ids not final), in one jar.
    rdf_r_jar(
        name = "ext_r",
        mode = "external",
        deps = r_deps,
        empty_packages = r_empty,
        tool = ":tool_once",
    )

    for (path, variant) in reached:
        p = model["projects"][path]
        if _is_local(p):
            continue
        if p.get("gradle_fallback"):
            # Built by Gradle in the app's package (the escape hatch); the hub holds what the
            # result depends on.
            native.filegroup(
                name = project_target(path, variant) + "_files",
                srcs = native.glob([_path(p["dir"], False, info) + "/**"], allow_empty = True),
            )
            continue
        for q, _ in _projects(model, p["variants"][variant], "compile"):
            if model["projects"][q].get("gradle_fallback"):
                fail("android_model: project %s depends on project %s, which Gradle builds (gradle_fallback); list %s in `gradle_fallback` too" % (path, q, path))
        _project(
            project_target(path, variant),
            path,
            p,
            p["variants"][variant],
            model,
            info,
            hub,
            lambda q, qv: ":" + project_target(q, qv),
            variants,
        )

# ---------------------------------------------------------------------------------------------------
# The app.

def _version(v, model, info):
    """versionCode and versionName as stock gives them.

    A Flutter app's Gradle files take both from Flutter (`flutter.versionCode`, `flutter.versionName`),
    which the Flutter tool derives from `version:` of pubspec.yaml on every build. The pin records
    markers there, and the pubspec's current values take their place here, so a version bump needs no
    new pin. Where Gradle sets a value itself, the pinned value stands; a suffix (a flavor's
    `versionNameSuffix`) is kept.
    """
    code = v.get("version_code")
    name = v.get("version_name")
    markers = model.get("pubspec_version_markers") or {}

    # As the Flutter tool: `1.2.3+4` is name 1.2.3 and code 4; without a build number the code is 1,
    # and without a version the name is 1.0.
    build_name, _, build_number = (info.get("pubspec_version") or "").partition("+")
    if code == markers.get("code"):
        code = int(build_number) if build_number.isdigit() else 1
    elif code != None and markers.get("code") and code > 1000000000:
        fail("android_model: the app's Gradle file computes versionCode from flutter.versionCode (the model has %s); set it from the pubspec's build number or as a literal" % code)
    if name != None and markers.get("name") and markers["name"] in name:
        name = name.replace(markers["name"], build_name or "1.0")
    return code, name

def android_model_app(
        name,
        model,
        info,
        hub,
        application = None,
        variant = "debug",
        abis = None,
        native_built_elsewhere = [],
        visibility = None):
    """The Android app of a pinned Gradle model.

    Makes `name` (the split APKs of a debug build: `base`, one per Gradle project, and the Dart
    payload, so that an edit rewrites only its own split), `name_apk` (the same app as one APK, what
    `flutter build apk` gives; built when asked for) and their parts.

    Args:
      name: target name of the split APKs.
      model: the decoded pin file (bound by the hub's `defs.bzl`).
      info: what the hub found on this host (bound by the hub's `defs.bzl`).
      hub: label prefix of the hub's root package (bound by the hub's `defs.bzl`).
      application: the `flutter_application` whose Dart payload the app carries.
      variant: the app variant to build, for example `debug` or `devDebug`. It must be in the pin.
      abis: the ABIs whose native libraries are packaged; the model's `ndk.abiFilters` when None.
      native_built_elsewhere: Gradle paths of projects whose CMake or ndk-build library Bazel builds on
        the Dart side (it then arrives with `application`), so the model's record of it is not an error.
      visibility: visibility of `name` and `name_apk`.
    """
    app_path, p = _app_project(model)
    if variant not in p["variants"]:
        fail("android_model: %s has no variant `%s` of the app (it has %s). Variants are chosen when pinning: set `variants` of the pin target and run `%s`." % (
            info["model_label"],
            variant,
            ", ".join(p["variants"].keys()),
            info["pin_command"],
        ))
    v = p["variants"][variant]
    version_code, version_name = _version(v, model, info)
    v = v | {"version_code": version_code, "version_name": version_name}
    if not v["debuggable"]:
        fail("android_model: variant `%s` is not debuggable. Release builds (R8, resource shrinking, signing configurations, bundles) are not built from the model yet." % variant)
    arts = model["artifacts"]
    sdk_jar = hub + _sdk_jar(p)
    min_sdk = int(v["min_sdk"])
    config = _dex_config(model, v)
    reached = _reached(model, v)

    def label_of(q, qv):
        # In this package: the projects Gradle builds (the escape hatch). Every other is in the hub.
        if model["projects"][q].get("gradle_fallback"):
            return ":%s_%s" % (name, project_target(q, qv))
        return hub + project_target(q, qv)

    problems = _problems(model, app_path, p, v) + _native_problems(app_path, p, native_built_elsewhere)
    if min_sdk < 21:
        problems.append("project %s: minSdk %d (below 21 an app needs a main dex list)" % (app_path, min_sdk))
    for q, qv in reached:
        project = model["projects"][q]
        if not project.get("gradle_fallback"):
            # Everything at once, the libraries' too (the hub would say the same when it loads).
            problems += _problems(model, q, project, project["variants"][qv])
            problems += _native_problems(q, project, native_built_elsewhere)
    _fail_on(problems, info["pin_command"])

    # The pin must describe these files: a build with other Gradle files or another lock fails.
    rdf_pin_check(
        name = name + "_pin_check",
        inputs = model["inputs"],
        # The Gradle files of the workspace's library projects are read where the hub links them.
        srcs = native.glob([f for f in model["inputs"] if not _hub_input(model, f)], allow_empty = True) + [hub + "pin_inputs"],
        hub_prefix = _path("app:", False, info),
        model = info["model_label"],
        pin_command = info["pin_command"],
        tool = hub + "tool_once",
    )

    runtime = _classpath(model, v, "runtime")
    rt_artifacts = [e[1] for e in runtime if e[0] == "a"]
    rt_projects = [(e[1], e[2]) for e in runtime if e[0] == "p"]

    # The projects Gradle itself builds (the escape hatch).
    asset_trees = {}
    for q, qv in reached:
        project = model["projects"][q]
        if project.get("gradle_fallback"):
            # buildifier: disable=print
            print("android_model: project %s is built by Gradle itself (gradle_fallback of %s)" % (q, info["pin_command"]))
            target = label_of(q, qv)[1:]
            _gradle_project(
                target,
                q,
                qv,
                model,
                hub,
                (native.package_name() + "/android").lstrip("/"),
                [v],
                native.glob([f for f in model["inputs"] if not _hub_input(model, f)], allow_empty = True) + [hub + "pin_inputs", info["model_label"]],
            )
            asset_trees[":" + target + "_assets_files"] = "assets"

    # Manifest.
    properties = {
        "MIN_SDK_VERSION": str(v["min_sdk"]),
        "PACKAGE": v["application_id"],
        "TARGET_SDK_VERSION": str(v["target_sdk"]),
    }
    if version_code != None:
        properties["VERSION_CODE"] = str(version_code)
    if version_name != None:
        properties["VERSION_NAME"] = str(version_name)
    if v.get("max_sdk") != None:
        properties["MAX_SDK_VERSION"] = str(v["max_sdk"])

    # The features AGP's ProcessApplicationManifest passes for an application.
    features = ["REMOVE_TOOLS_DECLARATIONS"] + (["DEBUGGABLE"] if v["debuggable"] else [])
    legacy_jni = v["packaging"].get("jni_use_legacy")
    if legacy_jni == None:
        legacy_jni = min_sdk < 23
    if not legacy_jni:
        properties["EXTRACT_NATIVE_LIBS"] = "false"
    rdf_manifest_merge(
        name = name + "_manifest",
        main = ":" + name + "_lib_manifest",
        overlays = [":" + name + "_lib_manifest_overlays"],
        libs = [
            (label_of(e[1], e[2]) if e[0] == "p" else hub + artifact_target(e[1])) + "_manifest"
            for e in runtime
            if e[0] == "p" or (e[0] == "a" and arts[e[1]].get("aar"))
        ],
        properties = properties,
        placeholders = v["manifest_placeholders"],
        namespace = v["namespace"],
        merger_features = features,
        tool = hub + "tool_once",
    )

    # Resources: dependencies first, the app last, so that the app wins.
    compiled = []
    for e in reversed(runtime):
        if e[0] == "p":
            compiled.append(label_of(e[1], e[2]) + "_res")
        elif e[0] == "a" and arts[e[1]].get("aar") and arts[e[1]]["aar"]["res"]:
            compiled.append(hub + artifact_target(e[1]) + "_res")
    compiled.append(":" + name + "_lib_res")
    rdf_aapt2_link(
        name = name + "_res",
        manifest = ":" + name + "_manifest",
        compiled = compiled,
        android_jar = sdk_jar,
        min_sdk_version = str(v["min_sdk"]),
        target_sdk_version = str(v["target_sdk"]),
        aapt2 = hub + "aapt2",
    )
    rdf_output_group(name = name + "_rtxt", src = ":" + name + "_res", group = "rtxt")

    # R classes: one per library from that library's own symbols, and the app's own, with final ids.
    r_deps = {}
    r_empty = []
    for e in runtime:
        if e[0] == "a":
            aar = arts[e[1]].get("aar")
            if aar and aar.get("namespace"):
                if aar["r_txt"]:
                    r_deps[hub + artifact_target(e[1]) + "_rtxt"] = aar["namespace"]
                elif aar["namespace"] not in r_empty:
                    r_empty.append(aar["namespace"])
        elif e[0] == "p":
            q = model["projects"][e[1]]
            qv = q["variants"][e[2]]
            if _res_dirs(q, qv):
                r_deps[label_of(e[1], e[2]) + "_symbols"] = qv["namespace"]
            elif qv["namespace"] not in r_empty:
                r_empty.append(qv["namespace"])
    rdf_r_jar(
        name = name + "_r",
        mode = "app",
        package = v["namespace"],
        rtxt = ":" + name + "_rtxt",
        local = ":" + name + "_lib_symbols",
        deps = r_deps,
        empty_packages = [e for e in r_empty if e not in r_deps.values()],
        tool = hub + "tool_once",
    )
    rdf_dex(
        name = name + "_r_dex",
        deps = [":" + name + "_r"],
        min_sdk = min_sdk,
        debuggable = v["debuggable"],
        store = v["packaging"].get("dex_use_legacy") == False,
        android_jar = sdk_jar,
        tool = hub + "tool",
    )

    # The app's own code. The plugin registrant is the one the Flutter tool wrote when the model was
    # pinned; a copy in the source tree (not checked in by a stock project) is left out.
    generated = []
    for rel, text in (model.get("generated_sources") or {}).items():
        gen = "%s_src_%d" % (name, len(generated))
        write_file(name = gen, out = "%s_gen/%s" % (name, rel), content = text.split("\n"))
        generated.append(":" + gen)
    _project(
        name + "_lib",
        app_path,
        p,
        v,
        model,
        info,
        hub,
        label_of,
        [v],
        extra_srcs = generated,
        extra_deps = [":" + name + "_r"],
        exclude = ["**/" + rel for rel in (model.get("generated_sources") or {}).keys()],
    )

    # Dex, AGP's second step: one merge per scope (Maven libraries, plugin projects, the app).
    ext = [hub + artifact_target(a) + "_dex_" + config for a in rt_artifacts if _has_jar(arts[a])]
    libs = [label_of(q, qv) + "_dex_" + config for q, qv in rt_projects]
    app_dex = ":%s_lib_dex_%s" % (name, config)
    r_dex = ":" + name + "_r_dex"
    merge = dict(
        min_sdk = min_sdk,
        debuggable = v["debuggable"],
        store = v["packaging"].get("dex_use_legacy") == False,
        android_jar = sdk_jar,
        tool = hub + "tool",
    )
    rdf_dex_merge(name = name + "_dex_ext", archives = ext, **merge)
    rdf_dex_merge(name = name + "_dex_libs", archives = libs, **merge)
    rdf_dex_merge(name = name + "_dex_project", archives = [app_dex, r_dex], globals = ext + libs + [app_dex, r_dex], **merge)

    # For the splits: R classes and the global synthetics go with the base; each project's archive is
    # packaged as the first step left it.
    rdf_dex_merge(name = name + "_dex_base", archives = [r_dex], globals = ext + libs + [app_dex, r_dex], **merge)
    desugared = [hub + "desugared_lib_dex_" + config] if v.get("core_library_desugaring") else []

    # The Dart payload and the Dart side's native libraries.
    abis = abis or v["ndk_abi_filters"] or []
    native_srcs = [hub + artifact_target(a) + "_native" for a in rt_artifacts if _has_native(arts[a])]
    native_srcs += [label_of(q, qv) + "_native" for q, qv in rt_projects] + [":" + name + "_lib_native"]
    rdf_native_libs(name = name + "_native", srcs = native_srcs, abis = abis, strip = hub + "llvm_strip")
    native_libs = [":" + name + "_native"]
    dart_zip = []
    dart_zip_stored = []
    if application:
        dart_abis = [a for a in _DART_ABIS if not abis or a in abis] or _DART_ABIS[:1]
        for abi in dart_abis:
            bundle = "%s_bundle_%s" % (name, abi.replace("-", "_"))
            flutter_android_bundle(name = bundle, application = application, android_abi = abi, mobile_install_compatible = False, plugins_from_model = True)
            rdf_output_group(name = bundle + "_native", src = ":" + bundle, group = "native_libs")
            rdf_native_libs(name = bundle + "_native_stripped", srcs = [":" + bundle + "_native"], abi = abi, strip = hub + "llvm_strip")
            native_libs.append(":" + bundle + "_native_stripped")
        first = "%s_bundle_%s" % (name, dart_abis[0].replace("-", "_"))
        rdf_output_group(name = name + "_flutter_assets", src = ":" + first, group = "flutter_assets")
        trees = {":" + name + "_flutter_assets": "assets/flutter_assets"}
        rdf_zip_part(name = name + "_dart", trees = trees, tool = hub + "tool")
        rdf_zip_part(name = name + "_dart_stored", trees = trees, store = True, tool = hub + "tool")
        dart_zip = [":" + name + "_dart"]
        dart_zip_stored = [":" + name + "_dart_stored"]

    # Assets of the app, its library projects and the AARs.
    asset_srcs = [":" + name + "_lib_assets"]
    asset_roots = _paths(v["sources"]["assets"], True, info)
    for e in runtime:
        if e[0] == "p":
            q = model["projects"][e[1]]
            if q.get("gradle_fallback"):
                continue
            asset_srcs.append(label_of(e[1], e[2]) + "_assets")
            asset_roots += _paths(q["variants"][e[2]]["sources"]["assets"], False, info)
        elif e[0] == "a" and arts[e[1]].get("aar") and arts[e[1]]["aar"]["assets"]:
            asset_srcs.append(hub + artifact_target(e[1]) + "_assets")
            if "aar/assets" not in asset_roots:
                asset_roots.append("aar/assets")
    rdf_zip_part(name = name + "_assets", srcs = asset_srcs, roots = asset_roots, trees = asset_trees, tool = hub + "tool")

    # The marker file AGP puts in every APK.
    write_file(
        name = name + "_app_metadata",
        out = name + "_gen/app-metadata.properties",
        content = ["appMetadataVersion=1.1", "androidGradlePluginVersion=" + model["tools"]["agp"], ""],
    )

    packaging = v["packaging"]
    common = dict(
        min_sdk = min_sdk,
        dex_store = packaging.get("dex_use_legacy") == False,
        native_compress = bool(legacy_jni),
        excludes = packaging["excludes"],
        pick_firsts = packaging["pick_firsts"],
        merges = packaging["merges"],
        jni_excludes = packaging["jni_excludes"],
        jni_pick_firsts = packaging["jni_pick_firsts"],
        validations = [":" + name + "_pin_check"],
        tool = hub + "tool",
    )
    ext_jars = [hub + artifact_target(a) + "_jar" for a in rt_artifacts if _has_jar(arts[a])]
    project_libs = [label_of(q, qv) for q, qv in rt_projects]

    # 1. The whole app as one APK, as `flutter build apk` gives.
    rdf_apk(
        name = name + "_apk",
        entries = {":" + name + "_app_metadata": "META-INF/com/android/build/gradle/app-metadata.properties"},
        resources = [":" + name + "_res"],
        dex = [":" + name + "_dex_project", ":" + name + "_dex_libs", ":" + name + "_dex_ext"] + desugared,
        native_libs = native_libs,
        zips = dart_zip + [":" + name + "_assets"],
        java_resource_deps = [":" + name + "_lib"] + project_libs,
        java_resource_jars = ext_jars,
        visibility = visibility,
        **common
    )

    # 2. The same app as split APKs: what an edit changes is its own small file.
    #    base: manifest, resources, R classes, Maven code, native libraries, assets
    #    one split per Gradle project (the app, each plugin): its dex and Java resources
    #    dart: flutter_assets
    rdf_apk(
        name = name + "_base",
        entries = {":" + name + "_app_metadata": "META-INF/com/android/build/gradle/app-metadata.properties"},
        resources = [":" + name + "_res"],
        dex = [":" + name + "_dex_base", ":" + name + "_dex_ext"] + desugared,
        native_libs = native_libs,
        zips = [":" + name + "_assets"],
        java_resource_jars = ext_jars,
        **common
    )
    splits = [":" + name + "_base"]
    parts = {"app": dict(dex = [app_dex], java_resource_deps = [":" + name + "_lib"])}
    for q, qv in rt_projects:
        parts[project_target(q, qv)] = dict(dex = [label_of(q, qv) + "_dex_" + config], java_resource_deps = [label_of(q, qv)])
    if dart_zip_stored:
        parts["dart"] = dict(zips = dart_zip_stored)
    for split, kwargs in parts.items():
        sn = "%s_split_%s" % (name, split)
        write_file(
            name = sn + "_manifest",
            out = sn + "_gen/AndroidManifest.xml",
            content = [
                '<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="%s" split="%s" android:versionCode="%s">' % (v["application_id"], split, version_code or 1),
                '  <application android:hasCode="%s"/>' % ("true" if "dex" in kwargs else "false"),
                "</manifest>",
                "",
            ],
        )
        rdf_aapt2_link(name = sn + "_res", manifest = ":" + sn + "_manifest", android_jar = sdk_jar, aapt2 = hub + "aapt2")
        if "dex" in kwargs:
            rdf_dex_archive(name = sn + "_dex", srcs = kwargs.pop("dex"))
            kwargs["dex"] = [":" + sn + "_dex"]
        rdf_apk(name = sn, resources = [":" + sn + "_res"], **(kwargs | common))
        splits.append(":" + sn)
    native.filegroup(name = name, srcs = splits, visibility = visibility)

    # `bazel run :<name>_install`: sends the splits that changed to the device and starts the app.
    java_binary(
        name = name + "_install",
        main_class = "rules_flutter.android.Install",
        runtime_deps = [Label("//flutter/private/android_model/tools:install_lib")],
        data = splits,
        args = ["--package", v["application_id"], "--split", "base=$(rootpath :%s_base)" % name] +
               [arg for split in parts for arg in ["--split", "%s=$(rootpath :%s_split_%s)" % (split, name, split)]],
        visibility = visibility,
    )
