"""Shared helper for compiling C++ desktop runners using cc_common."""

load("@rules_cc//cc/common:cc_common.bzl", "cc_common")

visibility(["//flutter/..."])

def make_runner_engine(library_file, import_library = None, header_files = [], include_dir = None):
    """The engine files a desktop runner compiles and links against.

    Args:
        library_file: The engine .so or .dll File.
        import_library: Windows-only: the .dll.lib import library File.
        header_files: Header Files from the engine (for inputs).
        include_dir: Directory string for engine headers (-I path).

    Returns:
        A struct with `library_file`, `import_library`, `header_files`
        and `include_dir`.
    """
    return struct(
        library_file = library_file,
        import_library = import_library,
        header_files = header_files,
        include_dir = include_dir,
    )

def make_runner_flags(compile_flags = [], link_flags = [], defines = []):
    """The extra compiler, linker and preprocessor flags for a desktop runner.

    Args:
        compile_flags: Additional compiler flags.
        link_flags: Additional linker flags (e.g., -Wl,-rpath).
        defines: Local defines (e.g., GTK_APP_ID, NDEBUG).

    Returns:
        A struct with `compile_flags`, `link_flags` and `defines`.
    """
    return struct(
        compile_flags = compile_flags,
        link_flags = link_flags,
        defines = defines,
    )

def make_runner_extras(additional_srcs = [], system_libraries = [], system_include_dirs = [], additional_inputs = []):
    """The per-platform extras beyond the runner's own sources and the engine.

    Args:
        additional_srcs: Additional source files to compile (e.g., native registrant).
        system_libraries: Additional shared library Files to link against (e.g.
            GTK3 from the Chromium sysroot). Passed as explicit inputs rather
            than `-L<dir> -l<name>` so that no directory outside the cc
            toolchain's own sysroot ever joins the `-l` search path.
        system_include_dirs: System include directories passed to cc_common.compile(system_includes=...).
        additional_inputs: Additional input files (e.g., sysroot files).

    Returns:
        A struct with `additional_srcs`, `system_libraries`,
        `system_include_dirs` and `additional_inputs`.
    """
    return struct(
        additional_srcs = additional_srcs,
        system_libraries = system_libraries,
        system_include_dirs = system_include_dirs,
        additional_inputs = additional_inputs,
    )

def compile_and_link_runner(ctx, name, srcs, engine, flags, extras):
    """Compile C++ sources and link into an executable using cc_common.

    Uses Bazel's hermetic CC toolchain for both compilation and linking.

    Args:
        ctx: Rule context (must have _cc_toolchain attr and cpp fragment).
        name: Base name for intermediate artifacts and the output binary.
        srcs: List of C++ source Files.
        engine: The engine files, from `make_runner_engine`.
        flags: The extra compiler/linker/preprocessor flags, from `make_runner_flags`.
        extras: The per-platform extras, from `make_runner_extras`.

    Returns:
        The executable File produced by cc_common.link().
    """
    cc_toolchain = ctx.attr._cc_toolchain[cc_common.CcToolchainInfo]
    feature_configuration = cc_common.configure_features(
        ctx = ctx,
        cc_toolchain = cc_toolchain,
    )

    all_srcs = srcs + extras.additional_srcs

    includes = []
    if engine.include_dir:
        includes.append(engine.include_dir)

    # Separate -I flags into includes (relative) for cc_common.
    include_dirs = []
    other_flags = []
    for flag in flags.compile_flags:
        if flag.startswith("-I"):
            include_dirs.append(flag[2:])
        else:
            other_flags.append(flag)

    all_additional_inputs = list(engine.header_files) + list(extras.additional_inputs)

    (_compilation_context, compilation_outputs) = cc_common.compile(
        actions = ctx.actions,
        feature_configuration = feature_configuration,
        cc_toolchain = cc_toolchain,
        name = name,
        srcs = all_srcs,
        includes = includes + include_dirs,
        system_includes = extras.system_include_dirs,
        local_defines = flags.defines,
        user_compile_flags = other_flags,
        additional_inputs = all_additional_inputs,
    )

    # Build a linking context for the engine shared library (and any system
    # libraries) so the toolchain's linker knows how to find and link against
    # them. Bazel stages each one into a private `_solib_*` directory holding
    # only these libraries, so the search path it adds cannot shadow anything
    # the cc toolchain resolves for itself.
    libs_to_link = [cc_common.create_library_to_link(
        actions = ctx.actions,
        feature_configuration = feature_configuration,
        cc_toolchain = cc_toolchain,
        dynamic_library = engine.library_file,
        interface_library = engine.import_library,
    )] + [
        cc_common.create_library_to_link(
            actions = ctx.actions,
            feature_configuration = feature_configuration,
            cc_toolchain = cc_toolchain,
            dynamic_library = lib,
        )
        for lib in extras.system_libraries
    ]
    engine_linker_input = cc_common.create_linker_input(
        owner = ctx.label,
        libraries = depset(libs_to_link),
    )
    engine_linking_context = cc_common.create_linking_context(
        linker_inputs = depset([engine_linker_input]),
    )

    # Link step: produces the executable using the hermetic CC toolchain.
    linking_outputs = cc_common.link(
        actions = ctx.actions,
        feature_configuration = feature_configuration,
        cc_toolchain = cc_toolchain,
        name = name,
        compilation_outputs = compilation_outputs,
        linking_contexts = [engine_linking_context],
        user_link_flags = flags.link_flags,
        output_type = "executable",
        additional_inputs = depset(extras.additional_inputs),
    )

    return linking_outputs.executable
