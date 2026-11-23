"""Analysis test for the kernel info of a source-less library.

A `dart_library` with no `srcs` compiles nothing, so `flutter_kernel_module_aspect`
forwards its dependencies' closure through `DartKernelInfo` values that carry no
module of their own (`kmod == None`) but keep every dependency's `owned`
`(label, short_path)` entries. Those entries feed the duplicate-source check of
every library above it, so dropping them, or giving the header a module, must
fail here.
"""

load("@rules_testing//lib:analysis_test.bzl", "analysis_test")
load("@rules_testing//lib:test_suite.bzl", "test_suite")
load("//flutter:utils.bzl", "FlutterKernelModuleInfo", "flutter_kernel_module_aspect")

visibility(["//tests/..."])

def _owned_paths(info):
    """The `short_path` of every owned entry of a `DartKernelInfo`."""
    return [path for (_label, path) in info.owned.to_list()]

def _owned_labels(info):
    """The label string of every owned entry of a `DartKernelInfo`."""
    return [label for (label, _path) in info.owned.to_list()]

def _header_only_info_impl(env, target):
    """Both kernel infos of a source-less target hold no module and the dependency's owned entry."""
    info = target[FlutterKernelModuleInfo]
    for kernel_info in [info.kernel_info, info.product_kernel_info]:
        env.expect.that_bool(kernel_info.kmod == None).equals(True)
        env.expect.that_bool(kernel_info.koutline == None).equals(True)
        env.expect.that_bool(kernel_info.modular).equals(True)
        paths = _owned_paths(kernel_info)
        env.expect.that_int(len([p for p in paths if p.endswith("header_only_fixture/lib/leaf.dart")])).equals(1)
        labels = _owned_labels(kernel_info)
        env.expect.that_bool(any([label.endswith(":leaf") for label in labels])).equals(True)
        env.expect.that_bool(any([label.endswith(":header") for label in labels])).equals(False)

def _header_only_info_test(name):
    analysis_test(
        name = name,
        target = "//tests/rules_testing/header_only_fixture:header",
        attrs = {"target": {"aspects": [flutter_kernel_module_aspect]}},
        attr_values = {"size": "small"},
        impl = _header_only_info_impl,
    )

def header_only_kernel_info_test_suite(name):
    """Defines the header-only kernel info analysis test.

    Args:
        name: The test suite name.
    """
    test_suite(name = name, tests = [_header_only_info_test])
