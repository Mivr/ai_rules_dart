"""Spike T17a (S9): Bazel targets for the pods of one source, from the pinned CocoaPods model. Not for merge.

One library per pod, named as the pod: `objc_library` for C-family sources, `swift_library` for Swift,
`mixed_language_library` for both in one module. Resource bundles, binary frameworks and privacy
manifests are their own targets and travel as dependencies of the library. `<pod>.framework` wraps the
library as a dynamic framework (the debug link shape of W8-9).

Every value comes from the model. What the model holds that this file does not build is put on the
target as a tag `rdf-unsupported=<what>`, so `bazel query 'attr(tags, "rdf-unsupported", //...)'` lists it.
"""

load("@rules_apple//apple:apple.bzl", "apple_dynamic_framework_import", "apple_dynamic_xcframework_import", "apple_static_framework_import", "apple_static_xcframework_import")
load("@rules_apple//apple:ios.bzl", "ios_framework")
load("@rules_apple//apple:resources.bzl", "apple_bundle_import", "apple_resource_bundle", "apple_resource_group")
load("@rules_cc//cc:objc_import.bzl", "objc_import")
load("@rules_cc//cc:objc_library.bzl", "objc_library")
load("@rules_swift//mixed_language:mixed_language_library.bzl", "mixed_language_library")
load("@rules_swift//swift:swift.bzl", "swift_interop_hint", "swift_library")

_CLANG = ["m", "mm", "c", "cc", "cpp", "cxx", "s", "S"]

# Settings a pod author sets that change nothing in a Bazel build: Xcode-only switches, warnings,
# paths to Swift's runtime that Flutter's old plugin template wrote, and architecture filters.
_NO_EFFECT = [
    "ALWAYS_SEARCH_USER_PATHS",
    "CLANG_CXX_LIBRARY",
    "CLANG_UNDEFINED_BEHAVIOR_SANITIZER_NULLABILITY",
    "COMBINE_HIDPI_IMAGES",
    "DEFINES_MODULE",
    "LD_RUNPATH_SEARCH_PATHS",
    "LIBRARY_SEARCH_PATHS",
    "USE_HEADERMAP",
]

# The language modes of the Swift compiler, as Xcode's Swift specification lists them
# (`SupportedLanguageVersions` of Swift.xcspec: 4.0, 4.2, 5.0, 6.0).
_SWIFT_LANGUAGE_MODES = ["4", "4.2", "5", "6"]

def _swift_language_mode(version):
    """The `-swift-version` Xcode passes for a pod's `SWIFT_VERSION`; None when Xcode would refuse it.

    CocoaPods writes the version the podspec names (5.9, 5.2), and the model keeps it. Xcode's build
    system passes it on only when it is a language mode of the compiler, without trailing zeros
    (5.0 is 5); any other version is cut to its major (5.9 is 5), and refused when that is no mode.
    """
    parts = version.split(".")
    for part in parts:
        if not part.isdigit():
            return None
    for _ in range(len(parts)):
        if len(parts) > 1 and int(parts[-1]) == 0:
            parts = parts[:-1]
    trimmed = ".".join(parts)
    if trimmed in _SWIFT_LANGUAGE_MODES:
        return trimmed
    if parts[0] in _SWIFT_LANGUAGE_MODES:
        return parts[0]
    return None

def _ext(path):
    base = path.rsplit("/", 1)[-1]
    return base.rsplit(".", 1)[-1] if "." in base else ""

def _files(root, paths):
    """Labels of model paths; a path that ends in `/` is a directory (a bundle, an asset catalog)."""
    out = []
    for path in paths:
        if path.endswith("/"):
            out.extend(native.glob([root + "/" + path + "**"], allow_empty = True))
        else:
            out.append(root + "/" + path)
    return out

def _exec_root(label):
    return native.package_relative_label(label).workspace_root

def _path(word, model, name, unsupported):
    """A search path of the pod author, with CocoaPods' variables replaced; None when it names another."""
    for var in ("${PODS_TARGET_SRCROOT}", "$(PODS_TARGET_SRCROOT)"):
        word = word.replace(var, _exec_root(model["labels"][name]) + "/" + model["roots"][name])
    for var in ("${PODS_ROOT}/", "$(PODS_ROOT)/"):
        if word.startswith(var):
            pod, _, rest = word[len(var):].partition("/")
            if pod not in model["roots"]:
                unsupported.append("path " + word)
                return None
            word = _exec_root(model["labels"][pod]) + "/" + model["roots"][pod] + ("/" + rest if rest else "")
    if "$(" in word or "${" in word:
        unsupported.append("path " + word)
        return None
    return word

def _pod(name, pod, model):
    root = model["roots"][name]
    here = _exec_root(model["labels"][name])
    build = pod["build"]
    module = build["module_name"]
    unsupported = []

    swift_srcs = [root + "/" + s for s in pod["sources"] if _ext(s) == "swift"]
    non_arc = {s: True for s in pod["non_arc_sources"] if _ext(s) in ("m", "mm")}
    clang_srcs = [root + "/" + s for s in pod["sources"] if _ext(s) in _CLANG and s not in non_arc]
    other = [s for s in pod["sources"] if _ext(s) != "swift" and _ext(s) not in _CLANG]
    if other:
        unsupported.append("sources " + " ".join(sorted({_ext(s): True for s in other})))
    headers = [root + "/" + h for h in pod["headers"]["all"]]

    # Compiler flags: Xcode's own, CocoaPods' (COCOAPODS=1, its header stores), then the pod author's.
    # Xcode's, from its log of the stock build: `-fmodule-name=<Module>` for every file of a pod, so
    # that the pod's own headers are read as text and not as the module others import; and linker
    # directives for the modules a file imports, which Bazel's toolchain turns off. Pods count on
    # them: AppAuth uses the Security framework and names only SafariServices. A pod that does not
    # want them says so itself (FirebaseCore: `-fno-autolink` in OTHER_CFLAGS), further down.
    clang_copts = ["-fautolink", "-fmodule-name=" + module, "-DCOCOAPODS=1", "-I%s/hdr/%s/private" % (here, name), "-I%s/hdr/%s/private/%s" % (here, name, name)]
    swift_copts = ["-DCOCOAPODS"]
    cxxopts = []
    conlyopts = []
    for key, words in pod["flags"]["pod"].items():
        if key == "GCC_PREPROCESSOR_DEFINITIONS":
            clang_copts.extend(["-D" + w for w in words])
        elif key in ("HEADER_SEARCH_PATHS", "USER_HEADER_SEARCH_PATHS"):
            flag = "-I" if key == "HEADER_SEARCH_PATHS" else "-iquote"
            clang_copts.extend([flag + p for p in [_path(w, model, name, unsupported) for w in words] if p])
        elif key in ("OTHER_CFLAGS", "WARNING_CFLAGS"):
            clang_copts.extend(words)
        elif key == "CLANG_CXX_LANGUAGE_STANDARD":
            cxxopts.append("-std=" + words[0])
        elif key == "GCC_C_LANGUAGE_STANDARD":
            conlyopts.append("-std=" + words[0])
        elif key == "OTHER_SWIFT_FLAGS":
            swift_copts.extend(words)
        elif key == "SWIFT_ACTIVE_COMPILATION_CONDITIONS":
            swift_copts.extend(["-D" + w for w in words])
        elif key not in _NO_EFFECT and not key.startswith("CLANG_WARN_") and "[" not in key:
            unsupported.append("setting " + key)
    for key, words in pod["flags"]["target"].items():
        # Set on the pod's target in the Pods project: a Podfile's post_install writes here.
        if key == "GCC_PREPROCESSOR_DEFINITIONS":
            clang_copts.extend(["-D" + w for w in words])
        elif key == "OTHER_CFLAGS":
            clang_copts.extend(words)
        elif key == "OTHER_SWIFT_FLAGS":
            swift_copts.extend(words)
        elif key == "SWIFT_ACTIVE_COMPILATION_CONDITIONS":
            swift_copts.extend(["-D" + w for w in words])
    groups = pod["compiler_flags_by_file"]
    if len(groups) == 1 and len(groups.values()[0]) == len(clang_srcs) + len(non_arc):
        clang_copts.extend(groups.keys()[0].split(" "))
    elif groups:
        unsupported.append("compiler flags that differ per file")
    if swift_srcs and build.get("swift_version"):
        mode = _swift_language_mode(build["swift_version"])
        if mode:
            swift_copts.extend(["-swift-version", mode])
        else:
            unsupported.append("swift version " + build["swift_version"])

    # What dependents see: the public header store, and the author's settings for whoever uses the pod.
    includes = ["hdr/%s/public" % name, "hdr/%s/public/%s" % (name, name)]
    defines = []
    for key, words in pod["flags"]["user"].items():
        if key == "GCC_PREPROCESSOR_DEFINITIONS":
            defines.extend(words)
        elif key == "HEADER_SEARCH_PATHS":
            for word in words:
                prefix = "${PODS_ROOT}/%s/" % name
                if word.startswith(prefix):
                    includes.append(root + "/" + word[len(prefix):])
                else:
                    unsupported.append("path " + word)
        elif key not in _NO_EFFECT:
            unsupported.append("user setting " + key)

    # Resources. A bundle of the podspec is a bundle target; a privacy manifest is a file inside one.
    resources = []
    for bundle, info in pod["resource_bundles"].items():
        # A ready-made bundle inside the podspec's bundle stays a directory of its own.
        nested = []
        for path in [f for f in info["files"] if f.endswith(".bundle/")]:
            target = "%s.bundle.%s.%s" % (name, bundle, path.rstrip("/").rsplit("/", 1)[-1])
            apple_bundle_import(name = target, bundle_imports = _files(root, [path]))
            nested.append(":" + target)
        apple_resource_bundle(
            name = "%s.bundle.%s" % (name, bundle),
            bundle_name = bundle,
            resources = _files(root, [f for f in info["files"] if not f.endswith(".bundle/")]) + nested,
        )
        resources.append(":%s.bundle.%s" % (name, bundle))
    loose = [r for r in pod["resources"] if not r.endswith(".bundle/")]
    if loose:
        apple_resource_group(name = name + ".resources", resources = _files(root, loose))
        resources.append(":" + name + ".resources")
    for path in [r for r in pod["resources"] if r.endswith(".bundle/")]:
        target = "%s.import.%s" % (name, path.rstrip("/").rsplit("/", 1)[-1])
        apple_bundle_import(name = target, bundle_imports = _files(root, [path]))
        resources.append(":" + target)

    # Binary frameworks and libraries, by the linkage CocoaPods read from the binaries.
    deps = [model["labels"][d] for d in pod["dependencies"]]
    if "Flutter" in pod["dependencies"]:
        # The engine's module map, which its import does not hand to Objective-C (see the hub).
        deps.append(model["labels"]["Flutter"] + ".modules")
    vendored = pod["vendored"]
    framework_modules = []
    for xc in vendored["xcframeworks"]:
        target = "%s.xcframework.%s" % (name, xc["path"].rsplit("/", 1)[-1].removesuffix(".xcframework"))
        linkages = {s["linkage"]: True for s in xc["slices"]}
        rule = apple_dynamic_xcframework_import if "dynamic" in linkages else apple_static_xcframework_import
        if len(linkages) != 1:
            unsupported.append("xcframework with static and dynamic slices")
        rule(name = target, xcframework_imports = _files(root, [xc["path"] + "/"]))
        deps.append(":" + target)
        framework_modules.extend(native.glob([root + "/" + xc["path"] + "/*/*.framework/Modules/*.modulemap"], allow_empty = True))
    for kind, rule in (("static_frameworks", apple_static_framework_import), ("dynamic_frameworks", apple_dynamic_framework_import)):
        for path in vendored[kind]:
            target = "%s.framework.%s" % (name, path.rsplit("/", 1)[-1].removesuffix(".framework"))
            rule(name = target, framework_imports = _files(root, [path + "/"]))
            deps.append(":" + target)
            framework_modules.extend(native.glob([root + "/" + path + "/Modules/*.modulemap"], allow_empty = True))
    if framework_modules:
        # rules_apple's imports hand an Objective-C dependent the framework's headers and its search
        # path, and the module map only to Swift. Without the file among its inputs `@import GoogleMaps;`
        # finds no module. It travels as a header of a library that is no module itself.
        swift_interop_hint(name = name + ".modules.hint", suppressed = True)
        objc_library(name = name + ".modules", hdrs = framework_modules, aspect_hints = [":" + name + ".modules.hint"])
        deps.append(":" + name + ".modules")
    if vendored["static_libraries"]:
        objc_import(name = name + ".archives", archives = [root + "/" + a for a in vendored["static_libraries"]])
        deps.append(":" + name + ".archives")
    if vendored["dynamic_libraries"]:
        unsupported.append("vendored dynamic libraries")

    features = pod["features"]
    if features["script_phases"]:
        unsupported.append("script phases")
    if features["on_demand_resources"]:
        unsupported.append("on demand resources")
    if pod.get("prefix_header_file"):
        unsupported.append("prefix header file")

    public = native.glob(["hdr/%s/public/**" % name], allow_empty = True)
    private = native.glob(["hdr/%s/private/**" % name], allow_empty = True)

    # CocoaPods' prefix header (it imports UIKit for Objective-C) goes in front of every C-family file.
    if pod.get("generated_prefix_header"):
        private.append("gen/%s-prefix.h" % name)
        clang_copts.extend(["-include", "%s/gen/%s-prefix.h" % (here, name)])

    # The module of a pod without Swift is defined once: by the pod's own module map, or by the one
    # CocoaPods generated, which the repository rule put beside the public headers. Swift dependents
    # get that file by name, Objective-C dependents find it on the include path.
    module_map = root + "/" + pod["module_map"] if pod.get("module_map") else None
    if not module_map:
        generated = native.glob(["hdr/%s/public/%s/module.modulemap" % (name, module)], allow_empty = True)
        module_map = generated[0] if generated else None
    swift_interop_hint(name = name + ".hint", module_name = module, module_map = module_map)

    # A pod with Swift: rules_swift writes the module map that names the generated header, and shows it
    # to Objective-C dependents only with this feature. Xcode puts the same into the pod's framework,
    # and other pods import it (`@import GTMAppAuth;` in GoogleSignIn).
    swift_features = ["swift.propagate_generated_module_map"]
    tags = ["rdf-unsupported=" + u for u in unsupported]
    link = dict(
        sdk_frameworks = pod["frameworks"],
        weak_sdk_frameworks = pod["weak_frameworks"],
        sdk_dylibs = pod["libraries"],
    )
    system = ["-Wl,-framework," + f for f in pod["frameworks"]] + ["-Wl,-weak_framework," + f for f in pod["weak_frameworks"]] + ["-l" + lib for lib in pod["libraries"]]

    if swift_srcs and (clang_srcs or non_arc or public):
        # The macro hands its extra arguments to the Swift half too, so language standards go to
        # the C-family half as plain options; a module with C and C++ standards both cannot.
        if cxxopts and conlyopts:
            unsupported.append("C and C++ standards in a module with Swift")
        umbrella = native.glob(["hdr/%s/umbrella/*.h" % name], allow_empty = True)
        mixed_language_library(
            name = name,
            swift_srcs = swift_srcs,
            clang_srcs = clang_srcs + headers + private,
            non_arc_srcs = [root + "/" + s for s in non_arc],
            hdrs = public,
            includes = includes,
            clang_copts = clang_copts + cxxopts + conlyopts,
            clang_defines = defines,
            umbrella_header = umbrella[0] if umbrella else None,
            swift_copts = swift_copts,
            module_name = module,
            module_map = module_map,
            enable_modules = True,
            alwayslink = True,
            data = resources,
            deps = deps,
            features = swift_features,
            tags = tags + ["rdf-unsupported=" + u for u in unsupported if u.startswith("C and C++")],
            **link
        )
    elif swift_srcs:
        swift_library(
            name = name,
            srcs = swift_srcs,
            module_name = module,
            copts = swift_copts,
            generates_header = True,
            generated_header_name = module + "-Swift.h",
            alwayslink = True,
            linkopts = system,
            data = resources,
            deps = deps,
            features = swift_features,
            tags = tags,
        )
    else:
        objc_library(
            name = name,
            srcs = clang_srcs + headers + private,
            non_arc_srcs = [root + "/" + s for s in non_arc],
            hdrs = public,
            includes = includes,
            copts = clang_copts,
            cxxopts = cxxopts,
            conlyopts = conlyopts,
            defines = defines,
            # The pod's own module map names the module; rules_cc takes one or the other.
            module_name = None if module_map else module,
            module_map = module_map,
            enable_modules = True,
            alwayslink = True,
            aspect_hints = [":" + name + ".hint"],
            data = resources,
            deps = deps,
            tags = tags,
            **link
        )

    # Debug link shape: the pod as its own dynamic framework, linked against its dependencies' frameworks.
    if build["should_build"]:
        ios_framework(
            name = name + ".framework",
            bundle_name = module,
            bundle_id = "org.cocoapods." + _bundle_id(module),
            families = ["iphone", "ipad"],
            infoplists = ["@rules_flutter//flutter/private/apple_model:framework-Info.plist"],
            minimum_os_version = model["min_os"],
            deps = [":" + name],
            frameworks = [model["labels"][d] + ".framework" for d in pod["dependencies"] if model["built"].get(d)],
            tags = ["manual"],
        )

def _bundle_id(module):
    return "".join([c if c.isalnum() else "-" for c in module.elems()])

def _framework_module_maps_impl(ctx):
    return [DefaultInfo(files = depset([f for f in ctx.files.frameworks if f.dirname.endswith(".framework/Modules") and f.extension == "modulemap"]))]

framework_module_maps = rule(
    doc = "The module maps among the files of frameworks or XCFrameworks that another repository holds.",
    implementation = _framework_module_maps_impl,
    attrs = {"frameworks": attr.label_list(allow_files = True, mandatory = True)},
)

def pod_targets(name, model):
    """Declares the targets of every pod of one source repository.

    Args:
        name: Unused; a macro has a name.
        model: `MODEL` of the repository's `model.bzl`.
    """
    for pod_name, pod in model["pods"].items():
        _pod(pod_name, pod, model)
