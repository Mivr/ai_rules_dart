"""Spike T17a (S9): repositories from a pinned CocoaPods model (`apple_model.json`). Not for merge.

    apple_model = use_extension("@rules_flutter//flutter/private/apple_model:extension.bzl", "apple_model")
    apple_model.pin(model = "//:apple_model.json")
    use_repo(apple_model, "apple_model")

The pin file is written by CocoaPods (`tools/pin.rb`, in a Ruby container) and read here with
`json.decode`. No podspec, Podfile or Podfile.lock is read by the rules. One repository is made per
distinct source (an archive by sha256, a git commit, or a pub archive by the hash pub recorded), holding
every pod that comes from it, and one hub per pin with an alias per pod and one target per aggregate
target of the Podfile (`Pods-Runner`).
"""

load("@bazel_tools//tools/build_defs/repo:git_worker.bzl", "git_repo")

SCHEMA = 1

_BUILD_FILES = ["BUILD", "BUILD.bazel", "WORKSPACE", "WORKSPACE.bazel", "MODULE.bazel", "REPO.bazel"]

_INFO_PLIST = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundlePackageType</key>
  <string>%s</string>
  <key>CFBundleShortVersionString</key>
  <string>%s</string>
  <key>CFBundleSignature</key>
  <string>????</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>NSPrincipalClass</key>
  <string></string>%s
</dict>
</plist>
"""

_FRAMEWORK_KEYS = """
  <key>CFBundleName</key>
  <string>$(PRODUCT_NAME)</string>"""

_BUNDLE_KEYS = """
  <key>CFBundleIdentifier</key>
  <string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
  <key>CFBundleName</key>
  <string>%s</string>"""

def _clean(text):
    return "".join([c if c.isalnum() else "_" for c in text.elems()])

def _pod_source_impl(ctx):
    fetch = json.decode(ctx.attr.fetch)
    spec = json.decode(ctx.attr.spec)
    if fetch["kind"] == "git":
        # Only a source with git submodules comes here: CocoaPods clones it the same way.
        git_repo(ctx, ctx.path("src"))
        ctx.delete("src/.git")
        top = "src"
    else:
        ctx.download_and_extract(
            url = fetch["url"],
            sha256 = fetch["sha256"],
            output = "src",
            type = fetch.get("type", ""),
            strip_prefix = fetch.get("strip_prefix", ""),
        )
        top = "src"
        if fetch.get("flatten"):
            # cocoapods-downloader: an archive that holds one directory is that directory.
            children = ctx.path("src").readdir()
            if len(children) == 1 and children[0].is_dir:
                top = "src/" + children[0].basename

    # Build files of the pod's own repository would cut its tree into packages.
    found = ctx.execute(["find", "src", "-type", "f", "("] + " -o ".join(["-name " + n for n in _BUILD_FILES]).split(" ") + [")", "-delete"])
    if found.return_code:
        fail("apple_model: cannot remove build files of %s: %s" % (ctx.name, found.stderr))

    # `r` is the directory CocoaPods calls the pod's root, whatever the archive called it.
    ctx.symlink(top, "r")

    for name, pod in spec["pods"].items():
        root = spec["roots"][name]
        command = pod["features"].get("prepare_command")
        if command:
            # The podspec's own script, as CocoaPods runs it after the download and before it reads files.
            done = ctx.execute(["bash", "-c", command], working_directory = root, timeout = 600)
            if done.return_code:
                fail("apple_model: prepare_command of pod %s failed:\n%s\n%s" % (name, done.stdout, done.stderr))

        # CocoaPods' header stores: Headers/Public/<pod>/... and Headers/Private/<pod>/...
        module = pod["build"]["module_name"]
        for mapped, path in pod["headers"]["mapped"].items():
            ctx.symlink(root + "/" + path, "hdr/%s/private/%s" % (name, mapped))

        # `hdr/<pod>/public/<Module>` is what `<Module>.framework/Headers` holds when Xcode builds the
        # pod: every public header by its name, or by its path under `header_mappings_dir`.
        framework_headers = "hdr/%s/public/%s" % (name, module)
        header_dir = (pod.get("header_dir") or "").strip("./")
        for mapped, path in pod["headers"]["public"].items():
            ctx.symlink(root + "/" + path, "hdr/%s/public/%s" % (name, mapped))
            served = mapped.removeprefix(name + "/")
            if header_dir:
                served = served.removeprefix(header_dir + "/")
            if not pod.get("header_mappings_dir"):
                served = served.rsplit("/", 1)[-1]
            if not ctx.path(framework_headers + "/" + served).exists:
                ctx.symlink(root + "/" + path, framework_headers + "/" + served)
        if pod.get("generated_prefix_header"):
            ctx.file("gen/%s-prefix.h" % name, pod["generated_prefix_header"])

        # The Info.plist CocoaPods generates for the pod's framework and for each of its resource
        # bundles (Target Support Files/<pod>/<pod>-Info.plist, ResourceBundle-<bundle>-<pod>-Info.plist):
        # a fixed text with the pod's version in it. rules_apple adds the identifier, the name and
        # the executable; Xcode's variables are written out.
        ctx.file("gen/%s-Info.plist" % name, _INFO_PLIST % ("FMWK", pod["version"], _FRAMEWORK_KEYS))
        for bundle in pod["resource_bundles"]:
            ctx.file("gen/%s.%s-Info.plist" % (name, bundle), _INFO_PLIST % ("BNDL", pod["version"], _BUNDLE_KEYS % bundle))
        umbrella = "%s-umbrella.h" % name
        if pod.get("generated_umbrella_header") and pod["headers"]["public"]:
            ctx.file("hdr/%s/umbrella/%s" % (name, umbrella), pod["generated_umbrella_header"])

        # The module other pods import (`@import FirebaseCore;`). Xcode finds it as a framework: the
        # module map and the umbrella header CocoaPods generated, beside the public headers. Here the
        # same two files go beside the same headers, and the directory above is on the include path
        # of every dependent, where clang looks for `<Module>/module.modulemap`. Only the word
        # `framework` goes: the directory is not laid out as one. A pod with Swift gets its module
        # map from rules_swift (it has to name the generated header), a pod with a module map of its
        # own keeps that.
        module_map = pod.get("generated_module_map")
        has_swift = len([s for s in pod["sources"] if s.endswith(".swift")]) > 0
        if module_map and pod.get("generated_umbrella_header") and not has_swift and not pod.get("module_map"):
            if not module_map.startswith("framework module %s {" % module) or ('umbrella header "%s"' % umbrella) not in module_map:
                fail("apple_model: the module map CocoaPods generated for pod %s is not the one these rules know:\n%s" % (name, module_map))
            ctx.file(framework_headers + "/module.modulemap", module_map.removeprefix("framework "))
            ctx.file(framework_headers + "/" + umbrella, pod["generated_umbrella_header"])

    ctx.file("model.bzl", "MODEL = json.decode(%s)\n" % repr(ctx.attr.spec))
    ctx.file("BUILD.bazel", """# Generated by rules_flutter from the pinned CocoaPods model.
load("@rules_flutter//flutter/private/apple_model:targets.bzl", "pod_targets")
load(":model.bzl", "MODEL")

package(default_visibility = ["//visibility:public"])

pod_targets(name = "pods", model = MODEL)
""")

pod_source = repository_rule(
    doc = "One source of the pin (an archive, a git commit or a pub archive) and the targets of its pods.",
    implementation = _pod_source_impl,
    attrs = {
        "commit": attr.string(),
        "fetch": attr.string(mandatory = True),
        "init_submodules": attr.bool(),
        "recursive_init_submodules": attr.bool(),
        "remote": attr.string(),
        "shallow_since": attr.string(),
        "spec": attr.string(mandatory = True),
        "verbose": attr.bool(),
    },
)

def _hub_impl(ctx):
    hub = json.decode(ctx.attr.hub)
    lines = [
        "# Generated by rules_flutter from the pinned CocoaPods model.",
        'load("@rules_apple//apple:apple.bzl", "apple_dynamic_xcframework_import")',
        'load("@rules_cc//cc:objc_library.bzl", "objc_library")',
        'load("@rules_flutter//flutter/private/apple_model:targets.bzl", "aggregate_library", "framework_module_maps")',
        'load("@rules_swift//swift:swift.bzl", "swift_interop_hint")',
        "",
        'package(default_visibility = ["//visibility:public"])',
        "",
        "# The engine stands for the `Flutter` pod: its podspec is a placeholder the Flutter tool writes.",
        "# The import gives an Objective-C dependent the framework's headers and search path, and the",
        "# module map only to Swift. `Flutter.modules` puts the module map among the inputs of every pod",
        "# that depends on `Flutter`; without it `@import Flutter;` finds no module.",
        'apple_dynamic_xcframework_import(name = "Flutter", xcframework_imports = ["@flutter_ios_engine//:Flutter_xcframework_debug"])',
        'framework_module_maps(name = "Flutter.modules.files", frameworks = ["@flutter_ios_engine//:Flutter_xcframework_debug"])',
        'swift_interop_hint(name = "Flutter.modules.hint", suppressed = True)',
        'objc_library(name = "Flutter.modules", hdrs = [":Flutter.modules.files"], aspect_hints = [":Flutter.modules.hint"])',
        "",
    ]
    for name, label in sorted(hub["labels"].items()):
        if name != "Flutter":
            lines.append("alias(name = %s, actual = %s)" % (repr(name), repr(label)))
        if hub["built"][name]:
            lines.append("alias(name = %s, actual = %s)" % (repr(name + ".framework"), repr(label + ".framework")))
    for name, pods in sorted(hub["aggregates"].items()):
        # What pods tell their user to define (nanopb's PB_FIELD_32BIT=1) goes where CocoaPods puts
        # it: on the aggregate target, for the app's own code, not on every pod that depends on them.
        defines = []
        for pod in pods:
            defines.extend([d for d in hub["user_defines"].get(pod, []) if d not in defines])
        lines.append("aggregate_library(name = %s, defines = %s, deps = %s)" % (repr(name), repr(defines), repr([hub["labels"][p] for p in pods])))
    ctx.file("BUILD.bazel", "\n".join(lines) + "\n")
    ctx.file("defs.bzl", "PODS = %s\nFRAMEWORK_PODS = %s\nDYNAMIC_FRAMEWORK_PODS = %s\nAGGREGATES = %s\n" % (
        repr(sorted(hub["labels"])),
        repr(sorted([p for p, built in hub["built"].items() if built])),
        repr(sorted([p for p, built in hub["built"].items() if built and hub["dynamic"][p]])),
        repr(hub["aggregates"]),
    ))

_hub = repository_rule(implementation = _hub_impl, attrs = {"hub": attr.string(mandatory = True)})

def _fetch_of(model, pod):
    """How Bazel fetches what CocoaPods downloaded for this pod: (key, fetch, pod root in the repository, git attrs)."""
    source = pod["source"]
    if "path" in source:
        for package, pub in model["pub_packages"].items():
            if source["path"] == pub["dir"] or source["path"].startswith(pub["dir"] + "/"):
                if pub["source"] != "hosted":
                    fail("apple_model: plugin %s is not a hosted pub package; the spike fetches only hosted ones" % package)
                sub = source["path"][len(pub["dir"]):]
                return ("pub_" + package, {"kind": "http", "url": pub["archive"], "sha256": pub["sha256"], "type": "tar.gz"}, "r" + sub, {})
        fail("apple_model: pod at %s is not in a pub package" % source["path"])
    if "http" in source:
        fetch = {"kind": "http", "url": source["http"], "sha256": source["sha256"], "type": {"tgz": "tar.gz", "tbz": "tar.bz2", "txz": "tar.xz"}.get(source["type"], source["type"]), "flatten": source["flatten"]}
        return (source["http"], fetch, "r", {})
    if "archive" in source:
        return (source["archive"], {"kind": "http", "url": source["archive"], "sha256": source["sha256"], "type": "tar.gz", "strip_prefix": source["strip_prefix"]}, "r", {})
    if "commit" in source:
        git = {"remote": source["git"], "commit": source["commit"], "recursive_init_submodules": bool(source.get("submodules"))}
        return ("%s@%s+submodules" % (source["git"], source["commit"]), {"kind": "git"}, "r", git)
    fail("apple_model: pod source %s is not one the spike fetches" % source)

def _apple_model_impl(mctx):
    for mod in mctx.modules:
        for tag in mod.tags.pin:
            model = json.decode(mctx.read(tag.model))
            if model.get("schema") != SCHEMA:
                fail("apple_model: %s has schema %s and these rules read schema %s. Pin again." % (tag.model, model.get("schema"), SCHEMA))
            groups = {}
            labels = {}
            roots = {}
            built = {name: bool(pod["build"]["should_build"]) for name, pod in model["pods"].items()}

            # What CocoaPods links as a dynamic framework; a pod that declares `static_framework`
            # (most plugins) it links into the app binary.
            dynamic = {name: pod["build"]["linkage"] == "dynamic" for name, pod in model["pods"].items()}

            # One deployment target for every pod of the app, the user target's: Flutter's podhelper
            # makes pods below it inherit it, and one value means one compile of each library.
            min_os = [t["platform"]["deployment_target"] for t in model["aggregate_targets"].values() if t["user_targets"]][0]
            for name, pod in model["pods"].items():
                if pod["source"].get("path", "").startswith("app:"):
                    labels[name] = "@%s//:%s" % (tag.name, name)
                    continue
                key, fetch, root, git = _fetch_of(model, pod)
                repo = "%s__%s" % (tag.name, _clean(key.removeprefix("https://").removesuffix(".tar.gz").removesuffix(".git")))
                groups.setdefault(repo, struct(fetch = fetch, git = git, pods = {})).pods[name] = pod
                labels[name] = "@%s//:%s" % (repo, name)
                roots[name] = root
            for repo, group in groups.items():
                pod_source(
                    name = repo,
                    fetch = json.encode(group.fetch),
                    spec = json.encode({"pods": group.pods, "labels": labels, "roots": roots, "built": built, "min_os": min_os, "project": model.get("pods_project", {}).get("build_settings", {})}),
                    **group.git
                )
            aggregates = {name: target["pods"]["*"] if "*" in target["pods"] else target["pods"]["Debug"] for name, target in model["aggregate_targets"].items()}
            user_defines = {name: pod["flags"]["user"].get("GCC_PREPROCESSOR_DEFINITIONS", []) for name, pod in model["pods"].items()}
            _hub(name = tag.name, hub = json.encode({"labels": labels, "aggregates": aggregates, "built": built, "dynamic": dynamic, "user_defines": user_defines}))
    return mctx.extension_metadata(reproducible = True)

apple_model = module_extension(
    implementation = _apple_model_impl,
    tag_classes = {"pin": tag_class(attrs = {
        "model": attr.label(mandatory = True, doc = "The pin file CocoaPods wrote."),
        "name": attr.string(default = "apple_model"),
    })},
)
