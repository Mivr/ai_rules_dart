"""Parameter objects for the modular kernel functions in `dart_kernel.bzl`.

`kernel_module_action()` once took twenty parameters, `library_kernel_info()`
seventeen and `modular_executable_kernel()` fourteen: every flag the compile
takes, threaded one by one from each caller. Values that travel together are
one struct here instead, built by a constructor each call site names. A compile
setting added here is a field on one constructor, not a parameter on three
functions and every caller of each.
"""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("//dart/private:common.bzl", "STABLE_SCHEME")

visibility(["//dart/..."])

VM_PRODUCT_ATTR = {
    "_vm_product": attr.label(
        doc = "The `//dart/private:vm_product` build setting: the `dart.vm.product` value library modules compile with. `dart_test` transitions it to `False`.",
        default = Label("//dart/private:vm_product"),
        providers = [BuildSettingInfo],
    ),
}

def library_vm_product(ctx):
    """The `dart.vm.product` value a library module compiles with.

    Args:
      ctx: A rule or aspect context carrying `VM_PRODUCT_ATTR`.

    Returns:
      `True` unless a `dart_test` configuration set the flag to `False`.
    """
    return ctx.attr._vm_product[BuildSettingInfo].value

def kernel_compile_settings(
        target = "vm",
        platform_dill = None,
        scheme = STABLE_SCHEME,
        extra_frontend_flags = [],
        product = True):
    """The frontend settings every kernel compile of a build shares.

    The same struct reaches `kernel_module_action()`,
    `modular_executable_kernel()` and `library_kernel_info()`, so a setting
    stated for one compile cannot be forgotten for another.

    Args:
      target: The front end's target name (`"vm"` by default; `"flutter"`
        for Flutter modules).
      platform_dill: The platform `.dill` File to compile against; defaults to
        the tools' `platform_dill` when None. Which `dart:` libraries a module
        may import is what this kernel holds.
      scheme: The multi-root URI scheme (`STABLE_SCHEME` by default).
      extra_frontend_flags: Extra flags for the module compiler:
        `--track-widget-creation`, `--enable-experiment=<name>`.
      product: The value of `-Ddart.vm.product` for a `vm` target: `True`
        for kernel binaries, `False` for tests (as under `dart test`).

    Returns:
      A struct with those fields.
    """
    return struct(
        product = product,
        target = target,
        platform_dill = platform_dill,
        scheme = scheme,
        extra_frontend_flags = extra_frontend_flags,
    )

def kernel_link_options(use_base_dill = False, platform_dill = None):
    """How `modular_executable_kernel()` links its output.

    Args:
      use_base_dill: When True, links the output as a delta against any shared
        base dill the dependencies provide.
      platform_dill: Optional platform `.dill` File the link prepends, so the
        output is a whole program a front end can load with `--from-dill`.

    Returns:
      A struct with those fields.
    """
    return struct(use_base_dill = use_base_dill, platform_dill = platform_dill)

def kernel_module_inputs(
        sources,
        packages,
        dep_kmods,
        extra_inputs = None):
    """What a module compile reads: its own sources and its closure.

    Args:
      sources: `struct(uri, file)` for each source the module compiles. The
        URI is the one the source is compiled under.
      packages: The `DartPackageInfo` records the module's package config
        names: either the deduplicated list (an executable's entry or a
        fixture) or an `(own_records, transitive)` pair (a library module,
        whose config the module compiler writes).
      dep_kmods: Postorder depset of the outline directories of the modules
        it compiles against.
      extra_inputs: A depset of files the compile may read beyond `sources`,
        such as the closure's cross-package sources, which an entry module
        compiles from source when it reaches one. None for a library.

    Returns:
      A struct with those fields.
    """
    return struct(
        sources = sources,
        packages = packages,
        dep_kmods = dep_kmods,
        extra_inputs = extra_inputs,
    )

def kernel_module_options(
        defines,
        droppable,
        check_imports = False,
        target_label = None,
        own_packages = (),
        direct_packages = (),
        define_file = None,
        native_assets = None,
        refused_libraries = ()):
    """How a module compile treats its sources.

    Args:
      defines: The `-D` declarations every compile of this module takes: the
        environment of the executable whose closure this is (the
        `executable_dart_defines` setting; an entry module takes the
        executable's own `defines`), then the `//dart:extra_dart_defines`
        flag. A value may hold a comma.
      droppable: Whether the module may leave out the own libraries that do
        not compile for the target, and those that import them. A library's
        module may. An entry module may not: leaving out one of the test's
        own files would silently run a test without it, so any error fails
        its action.
      check_imports: Whether to run the strict-layering import check during
        the module compile.
      target_label: The Bazel target label for diagnostics when checking
        imports.
      own_packages: Package names this target owns.
      direct_packages: Package names this target's direct dependencies provide.
      define_file: A File of `-DKEY=VALUE` lines whose defines go before
        `defines` (a Flutter app's `dart_defines`), or None.
      native_assets: The native-assets mapping (`native_assets.yaml`) an
        executable's entry module embeds, or None. Only an entry (`droppable`
        False) takes one.
      refused_libraries: The `dart:` libraries (`//dart:refused_dart_libraries`) the
        import check refuses in the module's own sources.

    Returns:
      A struct with those fields.
    """
    return struct(
        defines = defines,
        define_file = define_file,
        native_assets = native_assets,
        droppable = droppable,
        check_imports = check_imports,
        target_label = target_label,
        own_packages = own_packages,
        direct_packages = direct_packages,
        refused_libraries = refused_libraries,
    )

def kernel_module_outputs(output, koutline = None, unused_inputs = False):
    """What a module compile produces.

    Args:
      output: The module's directory File to produce. It holds one kernel per
        component of the module's sources, and an `index.json` that lists
        them.
      koutline: Optional directory File to receive the module's outline, the
        sources it left out and an `index.json`, which dependant modules
        compile against.
      unused_inputs: Whether the compile writes its unused-inputs list — the
        declared inputs no compile of this action read — and takes it as the
        action's `unused_inputs_list`, so Bazel skips the action when only an
        unread input changed. True only where one evaluation registers the
        action: an executable's entry, or a `dart_library`'s own module. The
        aspect's fallback compile leaves it False: several evaluations
        register that action, and a file each declared itself would keep their
        keys from matching. False registers the historical action with no
        list.

    Returns:
      A struct with those fields.
    """
    return struct(
        output = output,
        koutline = koutline,
        unused_inputs = unused_inputs,
    )

def library_kernel_sources(
        package_name,
        lib_root,
        own_srcs,
        own_record = None,
        own_records = None):
    """The library whose module `library_kernel_info()` compiles.

    Args:
      package_name: The package the library declares.
      lib_root: The package's `lib_root`.
      own_srcs: The library's own `.dart` files.
      own_record: The library's own `DartPackageInfo`, or None for a facade.
      own_records: The library's own `DartPackageInfo` records, one per owned
        package. Defaults to `[own_record]` (or empty when it is None), which
        is what every one-package library passes; a merged multi-package
        library passes one record per member, and its module compiles all of
        their sources together, against a package config naming every member.

    Returns:
      A struct with those fields.
    """
    return struct(
        package_name = package_name,
        lib_root = lib_root,
        own_srcs = own_srcs,
        own_record = own_record,
        own_records = own_records,
    )

def library_kernel_options(
        opaque,
        rule_deps = None,
        unused_inputs = False,
        non_standalone = False):
    """How `library_kernel_info()` reaches the module's dependencies.

    Args:
      opaque: None when the library can compile a module; otherwise why it
        cannot (a string, see `library_module_inputs`'s `opaque_reason`),
        such as sources that arrive as one directory (`srcs_dir`), whose
        files are not known here.
      rule_deps: Optional list of dependency targets (defaults to
        `ctx.attr.deps`).
      unused_inputs: Whether `kernel_module_action` writes an unused-inputs
        list. True when the caller registers the action once (the
        `dart_library` rule compiles its own module); False in the aspect's
        fallback compile, where several evaluations register it.
      non_standalone: True when the target carries the `no-dart-analyze` tag.
        The aspect computes this from its host; the rule passes nothing.

    Returns:
      A struct with those fields.
    """
    return struct(
        opaque = opaque,
        rule_deps = rule_deps,
        unused_inputs = unused_inputs,
        non_standalone = non_standalone,
    )
