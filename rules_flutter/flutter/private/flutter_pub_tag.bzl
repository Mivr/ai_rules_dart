"""The `flutter.pub` tag class.

Kept out of `flutter/extensions.bzl` so that file stays the extension's
wiring. Later `flutter.pub` attributes are added here.
"""

visibility(["//flutter/..."])

def _is_product_deps_identity(text):
    """Whether `text` is a valid identity half of a product-dep key.

    Args:
        text: The candidate identity.

    Returns:
        True for non-empty lowercase letters, digits, `.`, `_` and `-`.
    """
    if not text:
        return False
    for i in range(len(text)):
        char = text[i]
        if not (
            ("a" <= char and char <= "z") or
            ("0" <= char and char <= "9") or
            char == "." or char == "_" or char == "-"
        ):
            return False
    return True

def _is_product_deps_product(text):
    """Whether `text` is a valid product half of a product-dep key.

    Args:
        text: The candidate product name.

    Returns:
        True for non-empty letters, digits, `.`, `_`, `+` and `-`.
    """
    if not text:
        return False
    for i in range(len(text)):
        char = text[i]
        if not (
            ("a" <= char and char <= "z") or
            ("A" <= char and char <= "Z") or
            ("0" <= char and char <= "9") or
            char == "." or char == "_" or char == "+" or char == "-"
        ):
            return False
    return True

def validate_swift_package_product_deps(hub_name, product_deps):
    """Refuse a malformed `swift_package_product_deps` key.

    Every key is `<identity>:<product>`, exactly one `:`, with an identity
    matching `[a-z0-9._-]+` and a product matching `[A-Za-z0-9._+-]+`. A
    bad key is refused before any repository is created, naming the hub,
    the attribute, the key and the required form.

    Args:
        hub_name: The `flutter.pub` hub name, for the message.
        product_deps: The tag's `swift_package_product_deps` dict.

    Returns:
        None; fails on the first bad key.
    """
    for key in product_deps:
        colon = key.find(":")
        valid = (
            colon >= 0 and
            key.find(":", colon + 1) < 0 and
            _is_product_deps_identity(key[:colon]) and
            _is_product_deps_product(key[colon + 1:])
        )
        if not valid:
            fail((
                'flutter.pub(name = "{hub}"): swift_package_product_deps ' +
                "key {key} is not a valid \"<identity>:<product>\" key: " +
                "expected exactly one `:`, a non-empty identity matching " +
                "`[a-z0-9._-]+` and a non-empty product matching " +
                "`[A-Za-z0-9._+-]+`."
            ).format(hub = hub_name, key = repr(key)))

flutter_pub_tag = tag_class(
    attrs = {
        "name": attr.string(
            doc = "Repository name for the resolved packages hub.",
            mandatory = True,
        ),
        "lock": attr.label(
            doc = "The pubspec.lock file to parse.",
            mandatory = True,
            allow_single_file = True,
        ),
        "ignore_hooks": attr.string_list(
            doc = "Pub package names whose `hook/build.dart` is knowingly " +
                  "irrelevant to this build (its native code is never reached). " +
                  "Suppresses the unreplaced-hook error for them. This is a " +
                  "declaration you make deliberately; it is never a default.",
            default = [],
        ),
        "cycle_breaks": attr.string_list_dict(
            doc = "Package name -> dependency names whose pubspec edge is " +
                  "explicitly left out of that package's spoke `deps`. " +
                  "`flutter.pub` merges pub dependency cycles into a single " +
                  "multi-package spoke repository automatically, so " +
                  "`cycle_breaks` is no longer needed for cycles (for example " +
                  "`dio` <-> `dio_web_adapter` or `test` <-> `test_api`). It " +
                  "remains only as an optional edge-dropping override when " +
                  "explicitly desired: edges dropped here are removed before " +
                  "cycle planning so broken cycles stay separate spokes. " +
                  "Dropping an edge is safe only when the dependency is " +
                  "reached through a conditional import for a platform this " +
                  "build does not target. Every key and listed dependency " +
                  "must name a package in the lock, and each listed " +
                  "dependency must be one the key's own pubspec declares; " +
                  "anything else fails evaluation or the spoke fetch. A key " +
                  "naming a Flutter SDK package (`flutter`, `flutter_test`, " +
                  "...) fails evaluation, though a listed dependency may " +
                  "name one. Empty " +
                  "by default and never given a built-in default.",
            default = {},
        ),
        "android_maven_deps": attr.string_dict(
            doc = "`group:artifact` -> Bazel label additions to the built-in " +
                  "mapping from a plugin's `android/build.gradle*` runtime " +
                  "dependencies to `@rules_android_maven` labels. A plugin dep " +
                  "found in neither table fails the spoke fetch; mapping it " +
                  "here is the fix for external artifacts. The label must " +
                  "resolve in the workspace's `rules_android_maven` install.",
            default = {},
        ),
        "android_maven_ignore": attr.string_list(
            doc = "`group:artifact` coordinates that need no Bazel label and " +
                  "must not fail the spoke fetch as unknown. This is a " +
                  "declaration you make deliberately; it is never a default.",
            default = [],
        ),
        "swift_package_resolved": attr.label(
            doc = "Label of the Xcode `Package.resolved` file pinning the " +
                  "app's SwiftPM dependencies " +
                  "(`ios/.../xcshareddata/swiftpm/Package.resolved`). Each " +
                  "pin becomes a `<hub>__swiftpm-<identity>` spoke holding " +
                  "the pinned sources and a BUILD file translated from its " +
                  "`Package.swift`. Unset (the default) means no SwiftPM " +
                  "spokes. See the README section \"iOS native (SwiftPM) " +
                  "dependencies\".",
            allow_single_file = True,
        ),
        "swift_package_sha256": attr.string_dict(
            doc = "SwiftPM package identity -> SHA-256 hex digest of the " +
                  "pinned source archive (the `github.com/<owner>/<repo>/archive/" +
                  "`revision`.tar.gz` the pin resolves to). Every pin needs " +
                  "an entry: a pin without one fails its spoke fetch before " +
                  "any download, and computing the digest with " +
                  "`sha256sum` over the downloaded archive is the fix.",
            default = {},
        ),
        "swift_package_build_files": attr.string_keyed_label_dict(
            doc = "SwiftPM package identity -> label of a hand-written BUILD " +
                  "file replacing the generated one for that package. Each " +
                  "label resolves in the module that writes this tag (like " +
                  "`lock` and `swift_package_resolved`), so `//third_party:" +
                  "pkg.BUILD` in the root MODULE.bazel names the root " +
                  "module's file. The override skips the manifest " +
                  "translation only: the pinned archive still downloads, so " +
                  "the identity keeps needing its `swift_package_sha256` " +
                  "entry. It is the escape hatch for packages whose " +
                  "manifest uses constructs with no Bazel translation. " +
                  "Empty by default.",
            allow_files = True,
            default = {},
        ),
        "ios_plugin_defines": attr.string_list_dict(
            doc = "Flutter plugin name -> preprocessor defines for that plugin's Apple " +
                  "libraries, the Bazel analogue of a Podfile `post_install` " +
                  "GCC_PREPROCESSOR_DEFINITIONS edit (for example " +
                  "`{\"permission_handler_apple\": [\"PERMISSION_CAMERA=1\"]}`). `NAME` " +
                  "reaches C-family and Swift sources; `NAME=VALUE` reaches C-family " +
                  "sources only, because Swift conditions carry no value. A key naming no " +
                  "Apple plugin in the lock, or naming a Flutter SDK package, fails " +
                  "the extension evaluation.",
            default = {},
        ),
        "ios_plugin_deps": attr.string_keyed_label_dict(
            doc = "Flutter plugin name -> label of one target holding every native " +
                  "dependency the plugin's Apple code needs. Replaces reading the " +
                  "plugin's lock entry, podspec or `Package.swift` dependency list; " +
                  "the plugin's own sources still build. A key naming no locked " +
                  "package, or naming a Flutter SDK package, fails the extension " +
                  "evaluation. Empty by default.",
            default = {},
        ),
        "ios_pod_deps": attr.string_keyed_label_dict(
            doc = "CocoaPods pod name -> label of the Bazel target that " +
                  "provides it. It applies to every plugin in CocoaPods " +
                  "mode, and in SwiftPM mode to plugins without a " +
                  "`Package.swift`. A key may name a subspec " +
                  "(`\"Firebase/Auth\"`), which wins over its root pod " +
                  "(`\"Firebase\"`). The mapping wins over binary pods, the " +
                  "built-in pod-to-SwiftPM table and every version check: " +
                  "you take the version decision. A pod that resolves " +
                  "nowhere fails the fetch of the plugin that needs it, " +
                  "naming the plugin, the pod and this attribute. Labels " +
                  "resolve in the module that writes this tag.",
            default = {},
        ),
        "ios_pod_ignore": attr.string_list(
            doc = "Pod names (root or `Root/Subspec`) that need no Bazel " +
                  "target and must not fail the fetch. This is a " +
                  "declaration you make deliberately; it is never a " +
                  "default. `Flutter` and `FlutterMacOS` are always " +
                  "skipped because the rules link the engine themselves.",
            default = [],
        ),
        "swift_package_product_deps": attr.string_keyed_label_dict(
            doc = "`<identity>:<product>` -> label of the Bazel target that " +
                  "provides that SwiftPM product. A plugin's `Package.swift` " +
                  "dependency on the product resolves to the label instead " +
                  "of a `<hub>__swiftpm-<identity>` spoke, so the package " +
                  "needs no pin, checksum or translatable manifest. Labels " +
                  "resolve in the module that writes this tag. Empty by " +
                  "default.",
            default = {},
        ),
        "ios_podfile_lock": attr.label(
            doc = "Label of the app's CocoaPods `Podfile.lock` (for " +
                  "example `//app/ios:Podfile.lock`). Setting it puts the " +
                  "hub in CocoaPods mode: every Apple plugin's native " +
                  "dependencies are the pods its entry in this lock lists " +
                  "(CocoaPods' own resolution of every podspec, Ruby logic, " +
                  "`ENV` and `$` globals included), and every pod version " +
                  "comes from this lock. A plugin with no entry that ships " +
                  "a `Package.swift` falls back to its SwiftPM product " +
                  "dependencies, as Flutter's mixed mode does. " +
                  "rules_flutter never runs `pod`: your `pod install` " +
                  "writes this file. Unset (the default) means SwiftPM mode.",
            allow_single_file = True,
        ),
    },
    doc = "Resolves a `pubspec.lock` into one spoke repository per package " +
          "plus a hub alias. Requires a `flutter.toolchain` for the Flutter " +
          "SDK packages in the lock.",
)
