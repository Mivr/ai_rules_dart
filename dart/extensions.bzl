"""Extensions for bzlmod.

Installs a Dart toolchain.
Every module can define a toolchain version under the default name, "dart".
The root module's request wins when present, even if it is older than a
dependency's request (rules_dart's included); otherwise the highest requested
version is selected. A root pin older than a dependency's request prints a
NOTE naming both versions.

Additionally, the root module can define arbitrarily many more toolchain versions under different
names (the latest version will be picked for each name) and can register them as it sees fit,
effectively overriding the default named toolchain due to toolchain resolution precedence.
"""

load("//dart/private:toolchain_selection.bzl", "select_toolchain_version", "toolchain_name_override_error")
load("//dart/pub:pub_scanner.bzl", "pub_scanner_repo")
load(":repositories.bzl", "dart_register_toolchains")

_DEFAULT_NAME = "dart"

dart_toolchain = tag_class(
    doc = "Requests a Dart SDK toolchain: the SDK version to install and the base name of the generated repositories. Every module may request a version under the default name; only the root module may register additional names. A root request wins when present, even when older; otherwise the highest requested version is selected.",
    attrs = {
        "name": attr.string(doc = """\
Base name for generated repositories, allowing more than one Dart toolchain to be registered.
Overriding the default is only permitted in the root module.
""", default = _DEFAULT_NAME),
        "dart_version": attr.string(doc = """\
Explicit version of the Dart SDK. A version requested by the root module takes
precedence over versions requested by dependencies (rules_dart's included), even
when the root's version is older; without a root request, the highest requested
version is selected.""", mandatory = True),
    },
)

def _create_pub_scanner(module_ctx, registrations, selections):
    """Creates the one shared scanner repository from the default SDK.

    Runs beside `dart_register_toolchains`: the scanner compiles from the
    default toolchain's host SDK, so the SDK the scan runs from is the SDK
    the build runs on. The repository implementation resolves that SDK
    through this module's own repo mapping (`@dart_<platform>`, imported in
    this module's `MODULE.bazel`), so neither the module order in the
    consumer graph nor version overrides can break the address. The scanner
    source travels as text, so editing it or changing the toolchain
    recompiles the repository. The source label is relative to this file, so
    it reads this module's file under any local name.

    Args:
      module_ctx: The `dart` module extension context.
      registrations: The toolchain requests by registration name.
      selections: The selected SDK version by registration name.
    """
    if _DEFAULT_NAME not in registrations:
        fail("the `dart` module extension needs a `dart.toolchain` tag under the default name: without the default toolchain there is no host SDK to build the pub archive scanner from")
    pub_scanner_repo(
        name = "dart_pub_scanner",
        scanner_src = module_ctx.read(Label("//dart/pub/private:pub_scan.dart")),
        dart_version = selections[_DEFAULT_NAME],
    )

def _toolchain_extension(module_ctx):
    registrations = {}
    for mod in module_ctx.modules:
        for toolchain in mod.tags.toolchain:
            err = toolchain_name_override_error(toolchain.name, mod.is_root, _DEFAULT_NAME)
            if err != None:
                fail(err)
            if toolchain.name not in registrations.keys():
                registrations[toolchain.name] = []
            registrations[toolchain.name].append(struct(
                version = toolchain.dart_version,
                is_root = mod.is_root,
            ))
    selections = {}
    for name, requests in registrations.items():
        selection = select_toolchain_version(name, requests)
        if selection.note:
            # buildifier: disable=print
            print("NOTE: " + selection.note)
        selections[name] = selection.version

        dart_register_toolchains(
            name = name,
            dart_version = selection.version,
        )
    _create_pub_scanner(module_ctx, registrations, selections)
    return module_ctx.extension_metadata(
        reproducible = True,
    )

dart = module_extension(
    implementation = _toolchain_extension,
    tag_classes = {"toolchain": dart_toolchain},
    os_dependent = False,
    arch_dependent = False,
    doc = """Installs a Dart SDK toolchain. Multiple modules may request different versions. The root module's request wins when present (even if older than a dependency's); otherwise the highest requested version is selected.""",
)
