"""Shared fixtures and assertions for the direct tests of the `dart/ext` macros.

Every `*_library` macro under `//dart/ext` wraps a `dart_library` around one or
more `dart_codegen` targets. A direct test therefore reads two kinds of target
out of one instantiation: the wrapping library, whose providers must carry the
sources and the generated files, and a codegen target, whose action must carry
the generator contract and read the source, the generator binary and the
annotation library. The functions here make both kinds of assertion, so each
per-macro test only states what is specific to its builder: the suffix it
emits and the shim it runs.
"""

load("@rules_testing//lib:truth.bzl", "matching", "subjects")
load("//dart:providers.bzl", "DartInfo", "DartPackageMetadataInfo")
load(":truth_helpers.bzl", "action_of", "expect_default_outputs", "expect_inputs", "package_names", "provider_of")

visibility(["//dart/..."])

PACKAGE = "direct_ext_pkg"
LANGUAGE_VERSION = "3.11"
ANNOTATIONS = "//dart/tests/direct_annotation:annotations"

# The source of `ANNOTATIONS`: a generator reads its package through `deps`.
ANNOTATION_INPUT = "*dart/tests/direct_annotation/lib/annotations.dart"

def source_of(key):
    """Returns the label of the source file the test for `key` instantiates its macro over."""
    return ":lib/ext/%s.dart" % key

def library_builder_targets(name, key):
    """Returns the `analysis_test` targets of a `library_builder_library`-shaped macro.

    Args:
      name: The suite name; the macro's wrapping library is `<name>_subject`.
      key: The test's source key, see `source_of`.

    Returns:
      `dict` of the wrapping `library` and the `generate` codegen target the macro
      declares for the source, named `_<library>_<token>_gen`.
    """
    return {
        "library": ":%s_subject" % name,
        "generate": ":_%s_subject_lib_ext_%s_dart_gen" % (name, key),
    }

def shared_part_targets(name, key):
    """Returns the `analysis_test` targets of a `shared_part_library`-shaped macro.

    Args:
      name: The suite name; the macro's wrapping library is `<name>_subject`.
      key: The test's source key, see `source_of`.

    Returns:
      `dict` of the wrapping `library`, the `part` codegen target that emits the
      builder's shard and the `combined` target that merges it into `.g.dart`.
    """
    stem = "_%s_subject_lib_ext_%s_dart" % (name, key)
    return {
        "library": ":%s_subject" % name,
        "part": ":%s_part" % stem,
        "combined": ":%s_combined" % stem,
    }

def expect_library(env, library, key, generated, annotation = "direct_annotations"):
    """Asserts a macro's wrapping library carries the sources and the generated files.

    Args:
      env: The `analysis_test` environment.
      library: The wrapping `dart_library` target.
      key: The test's source key, see `source_of`.
      generated: `list[str]`: suffixes of the files the macro generates for the
        source, for example `[".freezed.dart"]`.
      annotation: Package name of the `annotation_dep` the macro was given.
    """
    source = "dart/tests/lib/ext/%s.dart" % key
    outputs = [source] + ["dart/tests/lib/ext/%s%s" % (key, suffix) for suffix in generated]
    expect_default_outputs(env, library, outputs)
    info = provider_of(env, library, DartInfo, "DartInfo", {
        "package_name": subjects.str,
        "transitive_srcs": subjects.depset_file,
        "transitive_packages": package_names,
    })
    info.package_name().equals(PACKAGE)
    info.transitive_srcs().contains_at_least(outputs)
    info.transitive_packages().contains_at_least([PACKAGE, annotation])

def expect_generator(env, generator, spec):
    """Asserts one codegen target a macro declared: its providers and its action.

    Args:
      env: The `analysis_test` environment.
      generator: The `dart_codegen` or `dart_sqlcodegen` target the macro declared.
      spec: `struct(source, outputs, shim, mnemonic, inputs)`: the source and the
        outputs, both relative to the package; a glob over the exec path of the
        generator binary the action must run; the action's mnemonic; and globs
        over any further files the action must read.
    """
    metadata = provider_of(env, generator, DartPackageMetadataInfo, "DartPackageMetadataInfo", {
        "package_name": subjects.str,
        "language_version": subjects.str,
    })
    metadata.package_name().equals(PACKAGE)
    metadata.language_version().equals(LANGUAGE_VERSION)
    expect_default_outputs(env, generator, ["dart/tests/" + o for o in spec.outputs])
    action = action_of(env, generator, spec.mnemonic)
    action.contains_flag_values([
        ("--package", PACKAGE),
        ("--root-language-version", LANGUAGE_VERSION),
        ("--input-asset", spec.source),
    ])
    for output in spec.outputs:
        action.argv().contains_predicate(matching.str_endswith(output))
    expect_inputs(action, ["*dart/tests/" + spec.source, spec.shim] + spec.inputs)

def generator_spec(source, outputs, shim, mnemonic = "DartCodegen", inputs = []):
    """Builds the `spec` of `expect_generator`.

    Args:
      source: Source path relative to the package, for example `lib/ext/x.dart`.
      outputs: `list[str]`: output paths relative to the package.
      shim: Glob over the exec path of the generator binary.
      mnemonic: The mnemonic of the action the target registers.
      inputs: `list[str]`: globs over further files the action reads.

    Returns:
      The `struct` `expect_generator` takes.
    """
    return struct(source = source, outputs = outputs, shim = shim, mnemonic = mnemonic, inputs = inputs)

def expect_library_builder(env, targets, key, suffixes, shim):
    """Asserts the library and the one codegen target of a `library_builder_library`-shaped macro.

    Args:
      env: The `analysis_test` environment.
      targets: The struct `analysis_test` built from `library_builder_targets`.
      key: The test's source key, see `source_of`.
      suffixes: `list[str]`: the output suffixes the macro was asked for.
      shim: Glob over the exec path of the shim the macro must run.
    """
    expect_library(env, targets.library, key, suffixes)
    outputs = ["lib/ext/%s%s" % (key, s) for s in suffixes]
    spec = generator_spec("lib/ext/%s.dart" % key, outputs, shim, inputs = [ANNOTATION_INPUT])
    expect_generator(env, targets.generate, spec)

def expect_shared_part(env, targets, key, part_suffix, shim):
    """Asserts the library and the two codegen targets of a `shared_part_library`-shaped macro.

    Args:
      env: The `analysis_test` environment.
      targets: The struct `analysis_test` built from `shared_part_targets`.
      key: The test's source key, see `source_of`.
      part_suffix: The shard suffix the macro was asked for.
      shim: Glob over the exec path of the builder's shim.
    """
    expect_library(env, targets.library, key, [".g.dart"])
    source = "lib/ext/%s.dart" % key
    part = "lib/ext/%s%s" % (key, part_suffix)
    expect_generator(env, targets.part, generator_spec(source, [part], shim, inputs = [ANNOTATION_INPUT]))
    combined = generator_spec(source, ["lib/ext/%s.g.dart" % key], "*combining_shim/bin*", inputs = ["*" + part])
    expect_generator(env, targets.combined, combined)
