"""Parameter objects for the modular kernel functions in `dart_kernel.bzl`.

`kernel_module_action()` once took twenty parameters, `library_kernel_info()`
seventeen and `modular_executable_kernel()` fourteen: every flag the compile
takes, threaded one by one from each caller. Values that travel together are
one struct here instead, built by a constructor each call site names. A compile
setting added here is a field on one constructor, not a parameter on three
functions and every caller of each.
"""

load("//dart/private:common.bzl", "STABLE_SCHEME")

def kernel_compile_settings(
        target = "vm",
        platform_dill = None,
        libraries_json = None,
        libraries_platform = None,
        extra_libraries = [],
        scheme = STABLE_SCHEME,
        extra_frontend_flags = []):
    """The frontend settings every kernel compile of a build shares.

    The same struct reaches `kernel_module_action()`,
    `modular_executable_kernel()` and `library_kernel_info()`, so a setting
    stated for one compile cannot be forgotten for another.

    Args:
      target: The `kernel_worker --target` name (`"vm"` by default;
        `"flutter"` for Flutter modules).
      platform_dill: The platform `.dill` File to compile against; defaults to
        the tools' `platform_dill` when None.
      libraries_json: The `libraries.json` File the planner reads available
        `dart:` libraries from; defaults to the tools' `libraries_json` when
        None.
      libraries_platform: Optional platform key in `libraries.json` (in
        addition to `"vm"`) whose libraries are available on the target.
      extra_libraries: Extra bare `dart:` library names (e.g.
        `["ui", "nativewrappers"]`) available in `platform_dill` even when
        absent from `libraries.json`.
      scheme: The multi-root URI scheme (`STABLE_SCHEME` by default).
      extra_frontend_flags: Extra flags forwarded to `kernel_worker`.

    Returns:
      A struct with those fields.
    """
    return struct(
        target = target,
        platform_dill = platform_dill,
        libraries_json = libraries_json,
        libraries_platform = libraries_platform,
        extra_libraries = extra_libraries,
        scheme = scheme,
        extra_frontend_flags = extra_frontend_flags,
    )

def kernel_module_inputs(
        sources,
        packages,
        dep_kmods,
        extra_inputs = None,
        closure_excluded = None):
    """What a module compile reads: its own sources and its closure.

    Args:
      sources: `struct(uri, file)` for each source the module compiles. The
        URI is the one the source is compiled under.
      packages: The `DartPackageInfo` records the module's package config
        names.
      dep_kmods: Postorder depset of the module directories it links against.
      extra_inputs: A depset of files the compile may read beyond `sources`,
        such as the closure's sources, which an entry module compiles from
        when it reaches an excluded file. None for a library.
      closure_excluded: A depset of the `.vm_excluded.txt` sidecars of the
        module's upstream modules. None when there are none.

    Returns:
      A struct with those fields.
    """
    return struct(
        sources = sources,
        packages = packages,
        dep_kmods = dep_kmods,
        extra_inputs = extra_inputs,
        closure_excluded = closure_excluded,
    )

def kernel_module_options(defines, exclude_non_sources, droppable):
    """How a module compile treats its sources.

    Args:
      defines: The `-D` declarations every compile of this module takes. The
        `//dart:extra_dart_defines` flag, the same for the whole build. When
        one contains a comma, the compile runs the toolchain's patched worker
        snapshot; otherwise the pristine snapshot runs.
      exclude_non_sources: Whether to emit only the listed sources, and not
        the libraries reached through them. Both kinds pass True, so a module
        holds its own libraries and an entry holds its own sources, and
        neither embeds the SDK platform or a dependency library.
      droppable: Whether `kernel_module` may retry once without the own
        sources that fail for the VM. A library's module may, and one that
        still fails fails the action. An entry module may not: dropping one of
        the test's own files would silently run a test without it.

    Returns:
      A struct with those fields.
    """
    return struct(
        defines = defines,
        exclude_non_sources = exclude_non_sources,
        droppable = droppable,
    )

def kernel_module_outputs(output, koutline = None, unused_inputs = False):
    """What a module compile produces.

    Args:
      output: The module's directory File to produce. It holds one kernel per
        component of the module's sources, and an `index.json` that lists
        them.
      koutline: Optional directory File to receive stripped `.dill` outlines
        and `index.json` for downstream `--input-kmod` compilation.
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
      opaque: True when the sources arrive as one directory (`srcs_dir`),
        whose files are not known here.
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

def modular_kernel_mode(enabled, kernel_mode):
    """Whether modular compilation is switched on for an executable.

    Args:
      enabled: The `//dart:modular_kernel` flag.
      kernel_mode: Whether the executable is a kernel (`dart_test` always is).

    Returns:
      A struct with those fields.
    """
    return struct(
        enabled = enabled,
        kernel_mode = kernel_mode,
    )

def modular_kernel_conditions(
        mode,
        dep_modular,
        packages_consistent,
        has_code_assets,
        has_own_defines,
        has_compile_flags,
        has_duplicate_source,
        same_sdk):
    """Every fact that decides whether an executable compiles modularly.

    Each `False` (each `True` of the `has_*` facts) is a reason the executable
    falls back to whole-program compilation, which is always correct, only
    slower.

    Args:
      mode: The struct from `modular_kernel_mode()`.
      dep_modular: Whether every dependency's closure is modular.
      packages_consistent: `kernel_packages_consistent` over the executable's
        closure.
      has_code_assets: Whether native code assets are embedded in the kernel.
        The embedding runs the front end over the whole program at once.
      has_own_defines: Whether the executable's own `defines` attribute is
        set. Modules compile with the `//dart:extra_dart_defines` flag, which
        is the same for the whole build, so the flag's `-D`s are shared by
        every module. Only a target's own `defines` cannot be shared, so only
        they fall back.
      has_compile_flags: Whether `dart_compile_flags` are set. They reach
        `dart compile`, which the modular path does not run.
      has_duplicate_source: Whether `duplicated_source` found a repeat.
      same_sdk: Whether the exec and target SDKs report the same version. A
        kernel compiled by one is loaded by the other, and the VM accepts only
        its own kernel format.

    Returns:
      A struct with those fields.
    """
    return struct(
        mode = mode,
        dep_modular = dep_modular,
        packages_consistent = packages_consistent,
        has_code_assets = has_code_assets,
        has_own_defines = has_own_defines,
        has_compile_flags = has_compile_flags,
        has_duplicate_source = has_duplicate_source,
        same_sdk = same_sdk,
    )
