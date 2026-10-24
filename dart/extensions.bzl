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
load("//dart/private:toolchains_repo.bzl", "PLATFORMS")
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

def _host_platform_key(os):
    """Maps the fetch host to the SDK repository's platform key.

    `dart_register_toolchains` names SDK repositories `<base>_<platform>`
    with keys like `linux-x64`; the scanner compiles and runs on the fetch
    host, so it comes from the host's SDK.

    Args:
      os: The host `os` struct (`module_ctx.os`).

    Returns:
      The platform key (e.g. `"linux-x64"`), failing closed on a host with
      no SDK repository.
    """
    name = os.name.lower()
    arch = os.arch.lower()
    if name.startswith("linux"):
        os_part = "linux"
    elif name.startswith("mac") or name.startswith("darwin"):
        os_part = "macos"
    elif name.startswith("windows"):
        os_part = "windows"
    else:
        fail("the pub archive scanner needs a Linux, macOS or Windows fetch host, got os %r" % os.name)
    if arch == "amd64" or arch == "x86_64":
        arch_part = "x64"
    elif arch == "aarch64" or arch == "arm64":
        arch_part = "arm64"
    else:
        fail("the pub archive scanner needs an x64 or arm64 fetch host, got arch %r" % os.arch)
    platform = os_part + "-" + arch_part
    if platform not in PLATFORMS:
        fail("the pub archive scanner needs a host SDK repository, and there is none for fetch host %r" % platform)
    return platform

def _sdk_repos_owner(module_ctx):
    """Finds the module owning the SDK repositories' canonical names.

    Extension-created repositories are named `<owner>++dart+<repo>` for a
    dependency and `+dart+<repo>` for the main module. The owner is the
    first non-root module carrying this extension's toolchain tags — in
    practice this module itself, under whatever local name the consumer
    gave it — and empty when only the main module tags, i.e. this module
    is the main module.

    Args:
      module_ctx: The `dart` module extension context.

    Returns:
      The owner's local module name, or `""` for the main module.
    """
    for mod in module_ctx.modules:
        if not mod.is_root and mod.tags.toolchain:
            return mod.name
    return ""

def _create_pub_scanner(module_ctx, registrations, selections):
    """Creates the one shared scanner repository from the default SDK.

    Runs beside `dart_register_toolchains`: the scanner compiles from the
    default toolchain's host SDK (the `dart` registration when present, else
    the first remaining registration), so the SDK the scan runs from is the
    SDK the build runs on. The scanner source travels as text, so editing it
    or changing the toolchain recompiles the repository. The source label is
    relative to this file, so it reads this module's file under any local
    name; the SDK owner keeps the canonical SDK labels working as a
    dependency too.

    Args:
      module_ctx: The `dart` module extension context.
      registrations: The toolchain requests by registration name.
      selections: The selected SDK version by registration name.
    """
    if not registrations:
        fail("the `dart` module extension needs at least one `dart.toolchain` tag: without a toolchain there is no SDK to build the pub archive scanner from")
    base = _DEFAULT_NAME if _DEFAULT_NAME in registrations else sorted(registrations.keys())[0]
    platform = _host_platform_key(module_ctx.os)
    pub_scanner_repo(
        name = "dart_pub_scanner",
        scanner_src = module_ctx.read(Label("//dart/pub/private:pub_scan.dart")),
        dart_version = selections[base],
        sdk_repo = base + "_" + platform,
        sdk_repo_owner = _sdk_repos_owner(module_ctx),
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
