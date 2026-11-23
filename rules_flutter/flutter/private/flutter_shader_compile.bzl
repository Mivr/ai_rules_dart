"""Flutter shader compilation via impellerc.

Compiles .frag/.glsl shader files to .iplr (Impeller IR) format using the
impellerc offline shader processor. Platform-specific runtime stages are
selected based on the target platform.
"""

# Platform-specific impellerc flags. Flutter's shader compiler targets:
# - iOS: Metal only
# - macOS: SKSL + Metal
# - Android/Linux/Windows: SKSL + GLES + GLES3 + Vulkan
# - Web: SKSL only (with --json)
# - flutter_tester (`flutter test`): SKSL + Vulkan, Impeller's backend there
load("//flutter:providers.bzl", "resolve_exec_dart_vm")

visibility(["//flutter/..."])

SHADER_PLATFORM_FLAGS = {
    "ios": ["--runtime-stage-metal"],
    "macos": ["--sksl", "--runtime-stage-metal"],
    "android": ["--sksl", "--runtime-stage-gles", "--runtime-stage-gles3", "--runtime-stage-vulkan"],
    "linux": ["--sksl", "--runtime-stage-gles", "--runtime-stage-gles3", "--runtime-stage-vulkan"],
    "windows": ["--sksl", "--runtime-stage-gles", "--runtime-stage-gles3", "--runtime-stage-vulkan"],
    "web": ["--sksl"],
    "tester": ["--sksl", "--runtime-stage-vulkan"],
}

def get_shader_platform_flags(target_platform):
    """Get the impellerc flags for a target platform.

    Args:
        target_platform: One of "ios", "macos", "android", "linux", "windows", "web",
            "tester".

    Returns:
        List of impellerc flag strings.
    """
    if target_platform not in SHADER_PLATFORM_FLAGS:
        fail("Unknown target platform '%s' for shader compilation. " % target_platform +
             "Supported platforms: %s" % ", ".join(SHADER_PLATFORM_FLAGS.keys()))
    return SHADER_PLATFORM_FLAGS[target_platform]

def _shader_rel_path(file):
    rel = file.short_path
    if rel.startswith("../"):
        return "external/" + rel[len("../"):]
    return rel

def _find_shader_lib_dir(shader_lib):
    """Finds the shader_lib root directory from any file in the filegroup."""
    for f in shader_lib:
        if "/shader_lib/" in f.path:
            idx = f.path.find("/shader_lib/")
            return f.path[:idx + len("/shader_lib")]
    return None

def _note_shader_include(ctx, seen_rels, rel, inc):
    """Records an include path, failing on conflicting files at one path.

    Returns:
      True when the include was already staged and must be skipped.
    """
    prev = seen_rels.get(rel)
    if prev == None:
        seen_rels[rel] = inc
        return False
    if prev != inc:
        fail("%s: conflicting shader_includes at %s: %s and %s" % (
            ctx.label,
            rel,
            prev.path,
            inc.path,
        ))
    return True

def _stage_shader_self(ctx, output, stage_prefix, shader, stage_root, staged_files):
    """Stages the shader itself beside its includes and returns its staged dir."""
    shader_rel = _shader_rel_path(shader)
    shader_rel_dir = shader_rel.rsplit("/", 1)[0] if "/" in shader_rel else ""
    staged_shader_dir = (stage_root + "/" + shader_rel_dir) if shader_rel_dir else stage_root
    has_shader_dir = False
    for link in staged_files:
        if link.dirname == staged_shader_dir or link.dirname.startswith(staged_shader_dir + "/"):
            has_shader_dir = True
            break
    if not has_shader_dir:
        shader_link = ctx.actions.declare_file(stage_prefix + "/" + shader_rel, sibling = output)
        ctx.actions.symlink(output = shader_link, target_file = shader)
        staged_files.append(shader_link)
    return staged_shader_dir

def _stage_shader_includes(ctx, output, shader, includes):
    """Stages declared include files into a per-action include tree.

    Points `--include` only at the staged locations, never at a workspace
    directory (which in local execution is a directory symlink containing
    undeclared sibling files).

    Returns:
      A `(staged_files, include_dirs)` tuple.
    """
    staged_files = []
    include_dirs = []
    stage_prefix = output.basename + ".includes"
    seen_rels = {}
    stage_root = None
    for inc in includes:
        if inc == None or inc == shader:
            continue
        rel = _shader_rel_path(inc)
        if _note_shader_include(ctx, seen_rels, rel, inc):
            continue
        link = ctx.actions.declare_file(stage_prefix + "/" + rel, sibling = output)
        ctx.actions.symlink(output = link, target_file = inc)
        staged_files.append(link)
        if stage_root == None:
            stage_root = link.path[:len(link.path) - len(rel) - 1]

    if stage_root != None:
        staged_shader_dir = _stage_shader_self(ctx, output, stage_prefix, shader, stage_root, staged_files)
        include_dirs.append(staged_shader_dir)
        for link in staged_files:
            if link.dirname not in include_dirs:
                include_dirs.append(link.dirname)
    return staged_files, include_dirs

def _shader_compile_args(ctx, output, spirv_output, shader, platform_flags, is_web, include_dirs, shader_lib_dir):
    """Builds the impellerc args for one shader compile."""
    args = ctx.actions.args()
    for flag in platform_flags:
        args.add(flag)
    args.add("--iplr")
    if is_web:
        args.add("--json")
    args.add("--sl=" + output.path)
    args.add("--spirv=" + spirv_output.path)
    args.add("--input=" + shader.path)
    args.add("--input-type=frag")
    for inc_dir in include_dirs:
        args.add("--include=" + inc_dir)
    if shader_lib_dir:
        args.add("--include=" + shader_lib_dir)
    return args

def _run_shader_compile(ctx, compile, tools):
    """Runs impellerc directly, or via the retry wrapper where SkSL can fail soft.

    Args:
        ctx: The rule context of the rule implementation that calls this helper.
        compile: struct describing the shader compile: `shader` (the input
            file), `output` (the `.iplr` file), `spirv_output` (the
            intermediate file), `target_platform`, `platform_flags` (the
            impellerc flags for the platform), `args` (the impellerc args
            object), `inputs` (the action input files).
        tools: struct with the executables: `impellerc`, `compile_tool` (the
            retry wrapper, used only where the flags include SkSL beside
            other stages), `require_sksl` (whether an SkSL failure is an
            error instead of a warning).
    """
    retry_possible = "--sksl" in compile.platform_flags and len(compile.platform_flags) > 1
    if not retry_possible:
        ctx.actions.run(
            executable = tools.impellerc,
            arguments = [compile.args],
            inputs = compile.inputs,
            outputs = [compile.output, compile.spirv_output],
            mnemonic = "FlutterShaderCompile",
            progress_message = "Compiling shader %s for %s" % (compile.shader.short_path, compile.target_platform),
            toolchain = None,
        )
        return
    dart_exe, dart_vm_files = resolve_exec_dart_vm(ctx)
    wrapper_args = ctx.actions.args()
    wrapper_args.add("--impellerc", tools.impellerc)
    wrapper_args.add("--shader", compile.shader.short_path)
    if tools.require_sksl:
        wrapper_args.add("--require-sksl")
    wrapper_args.add("--")
    ctx.actions.run(
        executable = dart_exe,
        arguments = [tools.compile_tool.path, wrapper_args, compile.args],
        inputs = depset(
            direct = compile.inputs + [tools.impellerc, tools.compile_tool],
            transitive = [dart_vm_files],
        ),
        outputs = [compile.output, compile.spirv_output],
        mnemonic = "FlutterShaderCompile",
        progress_message = "Compiling shader %s for %s" % (compile.shader.short_path, compile.target_platform),
        toolchain = "@rules_dart//dart:exec_tools_toolchain_type",
    )

def shader_compile_tools(impellerc, shader_lib, compile_tool):
    """The executables behind one `flutter_shader_compile_action` call.

    Args:
        impellerc: The impellerc executable File.
        shader_lib: List of shader_lib include Files.
        compile_tool: The compiled `compile_shader` executable File, which
            retries a shader whose SkSL stage fails without it. Used only
            where the flags include SkSL beside other stages.

    Returns:
        A struct with `impellerc`, `shader_lib` and `compile_tool`.
    """
    return struct(
        impellerc = impellerc,
        shader_lib = shader_lib,
        compile_tool = compile_tool,
    )

def flutter_shader_compile_action(
        ctx,
        job,
        output,
        tools,
        target_platform,
        is_web = False,
        require_sksl = False):
    """Compile a single shader file to .iplr format using impellerc.

    Args:
        ctx: The rule context of the rule implementation that calls this helper.
        job: The shader job struct: `file` (the input .frag/.glsl shader
            File) and `includes` (Files the shader may `#include` — inputs
            the sandbox needs, staged into a per-action include tree so
            workspace directories are never searched directly).
        output: The output .iplr File.
        tools: The executables from `shader_compile_tools`.
        target_platform: Target platform string ("ios", "macos", "android", "linux", "windows", "web").
        is_web: If True, emit JSON format (for web targets).
        require_sksl: Make an SkSL failure an error instead of a warning.
    """
    platform_flags = get_shader_platform_flags(target_platform)
    shader_lib_dir = _find_shader_lib_dir(tools.shader_lib)

    # impellerc requires a --spirv intermediate output alongside --sl when
    # using runtime stages (not platform flags). Declare it as a secondary output.
    spirv_output = ctx.actions.declare_file(output.basename + ".spirv", sibling = output)

    # Stage declared include files into a per-action directory under bazel-out
    # so `--include` points only at the declared files' staged locations and
    # never at a workspace directory (which in local execution is a directory
    # symlink containing undeclared sibling files).
    staged_files, include_dirs = _stage_shader_includes(ctx, output, job.file, job.includes)

    args = _shader_compile_args(
        ctx,
        output,
        spirv_output,
        job.file,
        platform_flags,
        is_web,
        include_dirs,
        shader_lib_dir,
    )

    inputs = [job.file] + tools.shader_lib + list(job.includes) + staged_files
    _run_shader_compile(
        ctx = ctx,
        compile = struct(
            shader = job.file,
            output = output,
            spirv_output = spirv_output,
            target_platform = target_platform,
            platform_flags = platform_flags,
            args = args,
            inputs = inputs,
        ),
        tools = struct(
            impellerc = tools.impellerc,
            compile_tool = tools.compile_tool,
            require_sksl = require_sksl,
        ),
    )
