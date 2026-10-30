"""The `dart_code_asset` rule.

Binds a native dynamic library to the Dart code-asset id that the owning
package's `@Native`/`@ffi.DefaultAsset` bindings use. The library comes either
from a Bazel-built `cc_shared_library` (`shared_library`) or from a pinned
prebuilt file the consumer supplies (`prebuilt`); the latter compiles nothing
and resolves no C/C++ toolchain. This is the seam between Bazel's native build
and Dart's code-asset resolution: `dart_test` / `dart_binary` consume
`DartCodeAssetInfo` via their `code_assets` attribute and synthesise the
`native_assets.yaml` that `gen_kernel --native-assets` embeds into the kernel.

Two-tier usage: a native-asset-owning package can ship a target exposing
`DartCodeAssetInfo` itself; otherwise rules_dart provides one under
`//dart/ext/<package>` (see `//dart/ext/sqlite3`).

`DartCodeAssetInfo` deliberately carries only what upstream's `CodeAsset`
carries — id, link mode, and the library. Bundling concerns (where the file
lands inside an application, what it is renamed to) belong to the consumer;
rules_flutter layers those on top of this provider rather than rules_dart
guessing at them.
"""

load("@rules_cc//cc/common:cc_shared_library_info.bzl", "CcSharedLibraryInfo")
load("//dart:providers.bzl", "CODE_ASSET_LINK_MODES", "DartCodeAssetInfo")

_CcToolchainCheckInfo = provider(
    doc = "Records the C/C++ toolchain resolved for a `dart_code_asset`'s `shared_library`.",
    fields = {
        "toolchain_label": "Label of the resolved `cc_toolchain` target, or `None`.",
    },
)

def _cc_toolchain_check_aspect_impl(_target, ctx):
    tc_info = ctx.toolchains["@bazel_tools//tools/cpp:toolchain_type"]
    if tc_info == None or getattr(tc_info, "cc", None) == None:
        return [_CcToolchainCheckInfo(toolchain_label = None)]
    return [
        _CcToolchainCheckInfo(
            toolchain_label = getattr(tc_info.cc, "_toolchain_label", None),
        ),
    ]

_cc_toolchain_check_aspect = aspect(
    implementation = _cc_toolchain_check_aspect_impl,
    toolchains = [
        config_common.toolchain_type("@bazel_tools//tools/cpp:toolchain_type", mandatory = False),
    ],
    doc = "Records the C++ toolchain resolved for a code asset's `shared_library`, so the rule can refuse an unregistered host toolchain with an actionable error.",
)

def check_registered_cc_toolchain(target_label, shared_library_label, cc_toolchain_label, is_windows = False):
    """Returns an actionable error if `shared_library` resolved to an unregistered/probed host C toolchain.

    Args:
      target_label: Label of the `dart_code_asset` target.
      shared_library_label: Label of its `shared_library` target.
      cc_toolchain_label: Label (or string) of the resolved `cc_toolchain`, or `None`.
      is_windows: Whether the target platform is Windows.

    Returns:
      An error message string, or `None` if a registered C/C++ toolchain is active.
    """
    if cc_toolchain_label == None:
        return (
            "dart_code_asset %s: building `shared_library` %s requires a C/C++ toolchain " +
            "registered by the consuming module (for example `hermetic_cc_toolchain` in " +
            "MODULE.bazel), but no `@bazel_tools//tools/cpp:toolchain_type` toolchain was resolved."
        ) % (target_label, shared_library_label)
    label_str = str(cc_toolchain_label)
    if not is_windows and "local_config_cc" in label_str:
        return (
            "dart_code_asset %s: `shared_library` %s resolved to the host-probed C/C++ " +
            "toolchain (%s). `rules_dart` does not register a C/C++ toolchain for its " +
            "consumers or fall back to `@local_config_cc`. Register a hermetic C/C++ " +
            "toolchain in your `MODULE.bazel` (for example `bazel_dep(name = " +
            "\"hermetic_cc_toolchain\", ...)` and `register_toolchains(\"@zig_sdk//toolchain:...\")`), " +
            "or set `code_assets_from_deps = False` on a pure-Dart `dart_binary` / `dart_test` " +
            "that does not load native code assets at runtime."
        ) % (target_label, shared_library_label, label_str)
    return None

def _extract_dynamic_library(ctx, library_target):
    """Pull the dynamic-library File out of a `cc_shared_library` target.

    `cc_shared_library` advertises its produced shared library through
    `CcSharedLibraryInfo.linker_input.libraries[*].dynamic_library`. Reading it
    there rather than filtering `DefaultInfo.files` by extension avoids having
    to exclude the Windows import library (`.lib`) and `.pdb`.
    """
    info = library_target[CcSharedLibraryInfo]
    libraries = info.linker_input.libraries
    if not libraries:
        fail("dart_code_asset %s: `shared_library` %s has no libraries in its CcSharedLibraryInfo." %
             (ctx.label, library_target.label))
    for lib in libraries:
        if lib.dynamic_library != None:
            return lib.dynamic_library
    fail("dart_code_asset %s: `shared_library` %s has no dynamic_library File on its CcSharedLibraryInfo." %
         (ctx.label, library_target.label))

def _check_exclusive_libraries(ctx):
    """Rejects setting both ways to supply a bundled library.

    `prebuilt` is the alternative to `shared_library`, so a target may name at
    most one of them, whichever link mode it declares.
    """
    if ctx.attr.prebuilt != None and ctx.attr.shared_library != None:
        fail(("dart_code_asset %s: `prebuilt` and `shared_library` are mutually " +
              "exclusive; set only one of them.") % ctx.label)

def _check_prebuilt_link_mode(ctx):
    """Rejects `prebuilt` with a link mode that does not consume a library file."""
    if ctx.attr.prebuilt != None and ctx.attr.link_mode != "dynamic_loading_bundle":
        fail(("dart_code_asset %s: `prebuilt` is only valid with " +
              "link_mode = \"dynamic_loading_bundle\".") % ctx.label)

def _dart_code_asset_impl(ctx):
    link_mode = ctx.attr.link_mode

    _check_exclusive_libraries(ctx)

    if link_mode == "static":
        fail(("dart_code_asset %s: link_mode = \"static\" is reserved by the " +
              "Dart SDK but implemented by neither the Dart VM nor the " +
              "Flutter engine. Track upstream support at " +
              "https://github.com/dart-lang/sdk/issues/49418. Use " +
              "`dynamic_loading_bundle` until that lands.") % ctx.label)

    if link_mode not in CODE_ASSET_LINK_MODES:
        fail("dart_code_asset %s: invalid link_mode %r. Expected one of: %s." %
             (ctx.label, link_mode, ", ".join(CODE_ASSET_LINK_MODES)))

    _check_prebuilt_link_mode(ctx)

    dynamic_library = None
    system_uri = ""

    if link_mode == "dynamic_loading_bundle":
        if ctx.attr.shared_library == None and ctx.attr.prebuilt == None:
            fail(("dart_code_asset %s: link_mode = \"dynamic_loading_bundle\" " +
                  "requires `shared_library = <cc_shared_library>` or " +
                  "`prebuilt = <file>`.") % ctx.label)
        if ctx.attr.system_uri:
            fail(("dart_code_asset %s: `system_uri` is only valid with " +
                  "link_mode = \"dynamic_loading_system\".") % ctx.label)
        if ctx.attr.prebuilt != None:
            dynamic_library = ctx.file.prebuilt
        else:
            is_windows = ctx.target_platform_has_constraint(
                ctx.attr._os_windows[platform_common.ConstraintValueInfo],
            )
            tc_check = ctx.attr.shared_library[_CcToolchainCheckInfo]
            tc_err = check_registered_cc_toolchain(
                ctx.label,
                ctx.attr.shared_library.label,
                tc_check.toolchain_label,
                is_windows = is_windows,
            )
            if tc_err != None:
                fail(tc_err)
            dynamic_library = _extract_dynamic_library(ctx, ctx.attr.shared_library)
    elif link_mode == "dynamic_loading_system":
        if not ctx.attr.system_uri:
            fail(("dart_code_asset %s: link_mode = \"dynamic_loading_system\" " +
                  "requires `system_uri = \"<uri>\"`.") % ctx.label)
        if ctx.attr.shared_library != None:
            fail(("dart_code_asset %s: `shared_library` is only valid with " +
                  "link_mode = \"dynamic_loading_bundle\".") % ctx.label)
        system_uri = ctx.attr.system_uri
    else:  # dynamic_loading_executable / dynamic_loading_process
        if ctx.attr.shared_library != None:
            fail(("dart_code_asset %s: `shared_library` is only valid with " +
                  "link_mode = \"dynamic_loading_bundle\".") % ctx.label)
        if ctx.attr.system_uri:
            fail(("dart_code_asset %s: `system_uri` is only valid with " +
                  "link_mode = \"dynamic_loading_system\".") % ctx.label)

    files = depset([dynamic_library] if dynamic_library != None else [])
    return [
        DefaultInfo(files = files),
        DartCodeAssetInfo(
            asset_id = ctx.attr.asset_id,
            link_mode = link_mode,
            dynamic_library = dynamic_library,
            system_uri = system_uri,
        ),
    ]

dart_code_asset = rule(
    implementation = _dart_code_asset_impl,
    attrs = {
        "asset_id": attr.string(
            mandatory = True,
            doc = "The code-asset id the owning package's `@Native`/`@ffi.DefaultAsset` declares (e.g. `package:sqlite3/src/ffi/libsqlite3.g.dart`).",
        ),
        "link_mode": attr.string(
            default = "dynamic_loading_bundle",
            doc = """How the runtime loads this asset. One of `dynamic_loading_bundle` (a \
library shipped alongside the app, built by `shared_library` or supplied by `prebuilt`), \
`dynamic_loading_system` (a library already present on the target system, named by \
`system_uri`), `dynamic_loading_executable`, or `dynamic_loading_process`. The reserved \
`static` mode fails fast — neither the Dart VM nor the Flutter engine implements it.

May be a `select()`: an ext package that bundles on one platform and uses the system library on \
another expresses that here, and consumers see a single target.""",
            values = list(CODE_ASSET_LINK_MODES) + ["static"],
        ),
        "shared_library": attr.label(
            providers = [CcSharedLibraryInfo],
            aspects = [_cc_toolchain_check_aspect],
            doc = """A `cc_shared_library` target whose dynamic library backs this code asset, \
built by Bazel and checked against a registered C/C++ toolchain. One of the two ways to supply a \
`dynamic_loading_bundle` library; required when `prebuilt` is unset, and forbidden for the other \
link modes. Mutually exclusive with `prebuilt`.""",
        ),
        "prebuilt": attr.label(
            allow_single_file = [".so", ".dylib", ".dll"],
            doc = """A prebuilt dynamic library (`.so`, `.dylib` or `.dll`) that backs this code \
asset when the package ships a pinned binary instead of building one. Valid only with \
`link_mode = \"dynamic_loading_bundle\"`, and mutually exclusive with `shared_library`. This rule \
downloads nothing and verifies no digest: the label's producer — a download rule or module \
extension — must pin the file's version and sha256.""",
        ),
        "system_uri": attr.string(
            doc = "System library URI, e.g. `libsqlite3.so.0`. Required for `dynamic_loading_system`; forbidden for the other link modes.",
        ),
        "_os_windows": attr.label(
            doc = "Platform constraint probed at analysis time to detect Windows, whose unregistered host C toolchain needs a dedicated error. Defaults to `@platforms//os:windows`.",
            default = "@platforms//os:windows",
        ),
    },
    provides = [DartCodeAssetInfo],
    doc = "Binds a native dynamic library — a Bazel-built `cc_shared_library` or a pinned prebuilt file — to a Dart code-asset id, for use in `dart_test`/`dart_binary` `code_assets`.",
)
