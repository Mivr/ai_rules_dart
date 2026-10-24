"""Analysis tests: every codegen action stages under a digest-named pkg-roots root."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//dart:defs.bzl", "dart_aggregate_codegen", "dart_codegen", "dart_library", "dart_sqlcodegen")
load(":pkg_roots_digest_test.bzl", "pkg_roots_digest_suite")

def _stage_segments(input_paths):
    """Returns the path components that name a `<name>.pkg_roots.<digest>` stage."""
    segments = []
    for p in input_paths:
        for part in p.split("/"):
            if ".pkg_roots." in part:
                segments.append(part)
    return segments

def _stage_root_test_impl(ctx):
    env = analysistest.begin(ctx)
    matching = [
        a
        for a in analysistest.target_actions(env)
        if a.mnemonic == ctx.attr.mnemonic
    ]
    asserts.equals(env, 1, len(matching), "expected exactly one %s action" % ctx.attr.mnemonic)
    action = matching[0]
    target_name = analysistest.target_under_test(env).label.name
    input_paths = [f.path for f in action.inputs.to_list()]

    # The declared set stages under one digest-named directory, whatever runs
    # the generator: worker binary, user binary, or script. A changed declared
    # set stages under a directory no earlier build wrote to, so the action
    # can never resolve a `package:` URI through a stale staged link.
    segments = _stage_segments(input_paths)
    asserts.true(
        env,
        len(segments) > 0,
        "expected a <name>.pkg_roots.<digest> stage in %s inputs" % ctx.attr.mnemonic,
    )
    prefix = target_name + ".pkg_roots."
    digests = {}
    for segment in segments:
        asserts.true(
            env,
            segment.startswith(prefix),
            "stage %s must start with %s" % (segment, prefix),
        )
        digest = segment[len(prefix):]
        asserts.equals(env, 16, len(digest), "stage digest in %s must be 16 hex chars" % segment)
        int(digest, 16)  # aborts the test unless every char is hex
        digests[digest] = True
    asserts.equals(
        env,
        1,
        len(digests.keys()),
        "expected one stage directory per %s action, got %s" % (ctx.attr.mnemonic, digests.keys()),
    )

    # No generator kind takes prune flags: user binaries and scripts never
    # parsed the shim contract, and the digest-named stage needs no pruning.
    for arg in action.argv:
        asserts.false(
            env,
            arg.startswith("--pkg-roots"),
            "no generator takes pkg-roots flags in %s argv: %s" % (ctx.attr.mnemonic, action.argv),
        )
    return analysistest.end(env)

_stage_root_test = analysistest.make(
    _stage_root_test_impl,
    attrs = {
        "mnemonic": attr.string(mandatory = True),
    },
)

def _dummy_dart_source_impl(ctx):
    out = ctx.actions.declare_file("lib/" + ctx.label.name + ".dart")
    ctx.actions.write(output = out, content = "// dummy\n")
    return [DefaultInfo(files = depset([out]))]

_dummy_dart_source = rule(
    implementation = _dummy_dart_source_impl,
    attrs = {},
)

def _dummy_staged_file_impl(ctx):
    out = ctx.actions.declare_file(ctx.attr.out_path)
    ctx.actions.write(output = out, content = ctx.attr.content)
    return [DefaultInfo(files = depset([out]))]

_dummy_staged_file = rule(
    implementation = _dummy_staged_file_impl,
    attrs = {
        "out_path": attr.string(mandatory = True),
        "content": attr.string(default = "{}\n"),
    },
)

def codegen_stale_roots_suite(name):
    """Declares fixtures with deps plus stage-root analysis tests for all three codegen rules.

    Args:
      name: Name of the generated `test_suite`; fixture names derive from it.
    """
    _dummy_dart_source(
        name = name + "_src",
        tags = ["manual"],
    )

    _dummy_staged_file(
        name = name + "_dep_file",
        out_path = "lib/dep_helper.json",
        tags = ["manual"],
    )
    dart_library(
        name = name + "_dep_lib",
        srcs = [],
        package_name = "stale_roots_dep",
        resources = [":" + name + "_dep_file"],
        tags = ["manual"],
    )

    dart_codegen(
        name = name + "_bin_fixture",
        src = ":" + name + "_src",
        generator_bin = "//dart/private/tools:noop",
        output_suffixes = [".g.dart"],
        package_name = "stale_roots_pkg",
        deps = [":" + name + "_dep_lib"],
        tags = ["manual"],
    )
    _stage_root_test(
        name = name + "_bin_test",
        size = "small",
        mnemonic = "DartCodegen",
        target_under_test = ":" + name + "_bin_fixture",
    )

    # A worker generator built on the builder shim stages under the same
    # digest-named root; the guarantee is per rule call site, not per kind.
    dart_codegen(
        name = name + "_shim_fixture",
        src = ":" + name + "_src",
        generator_bin = "//dart/ext/json_serializable:shim",
        output_suffixes = [".shim.g.dart"],
        package_name = "stale_roots_pkg",
        deps = [":" + name + "_dep_lib"],
        tags = ["manual"],
    )
    _stage_root_test(
        name = name + "_shim_test",
        size = "small",
        mnemonic = "DartCodegen",
        target_under_test = ":" + name + "_shim_fixture",
    )

    dart_codegen(
        name = name + "_script_fixture",
        src = ":" + name + "_src",
        generator = "//dart/private/tools:noop.dart",
        output_suffixes = [".script.g.dart"],
        package_name = "stale_roots_pkg",
        deps = [":" + name + "_dep_lib"],
        tags = ["manual"],
    )
    _stage_root_test(
        name = name + "_script_test",
        size = "small",
        mnemonic = "DartCodegen",
        target_under_test = ":" + name + "_script_fixture",
    )

    dart_aggregate_codegen(
        name = name + "_agg_bin_fixture",
        srcs = [":" + name + "_src"],
        generator_bin = "//dart/private/tools:noop",
        outputs = ["lib/" + name + "_agg.g.dart"],
        package_name = "stale_roots_pkg",
        deps = [":" + name + "_dep_lib"],
        tags = ["manual"],
    )
    _stage_root_test(
        name = name + "_agg_bin_test",
        size = "small",
        mnemonic = "DartAggregateCodegen",
        target_under_test = ":" + name + "_agg_bin_fixture",
    )

    # The stage wiring is per rule call site, so it needs a shim-closure
    # generator here too. Any builder-shim binary exercises it at analysis
    # time; the rule never runs it under `analysistest`.
    dart_aggregate_codegen(
        name = name + "_agg_shim_fixture",
        srcs = [":" + name + "_src"],
        generator_bin = "//dart/ext/json_serializable:shim",
        outputs = ["lib/" + name + "_agg_shim.g.dart"],
        package_name = "stale_roots_pkg",
        deps = [":" + name + "_dep_lib"],
        tags = ["manual"],
    )
    _stage_root_test(
        name = name + "_agg_shim_test",
        size = "small",
        mnemonic = "DartAggregateCodegen",
        target_under_test = ":" + name + "_agg_shim_fixture",
    )

    dart_aggregate_codegen(
        name = name + "_agg_script_fixture",
        srcs = [":" + name + "_src"],
        generator_script = "//dart/private/tools:noop.dart",
        outputs = ["lib/" + name + "_agg_script.g.dart"],
        package_name = "stale_roots_pkg",
        deps = [":" + name + "_dep_lib"],
        tags = ["manual"],
    )
    _stage_root_test(
        name = name + "_agg_script_test",
        size = "small",
        mnemonic = "DartAggregateCodegen",
        target_under_test = ":" + name + "_agg_script_fixture",
    )

    dart_sqlcodegen(
        name = name + "_sql_fixture",
        src = ":" + name + "_src",
        generator_bin = "//dart/private/tools:noop",
        output_suffixes = [".drift.dart"],
        package_name = "stale_roots_pkg",
        deps = [":" + name + "_dep_lib"],
        tags = ["manual"],
    )
    _stage_root_test(
        name = name + "_sql_test",
        size = "small",
        mnemonic = "DartSqlCodegen",
        target_under_test = ":" + name + "_sql_fixture",
    )

    dart_sqlcodegen(
        name = name + "_sql_shim_fixture",
        src = ":" + name + "_src",
        generator_bin = "//dart/ext/drift:shim_prep",
        output_suffixes = [".shim.drift.dart"],
        package_name = "stale_roots_pkg",
        deps = [":" + name + "_dep_lib"],
        tags = ["manual"],
    )
    _stage_root_test(
        name = name + "_sql_shim_test",
        size = "small",
        mnemonic = "DartSqlCodegen",
        target_under_test = ":" + name + "_sql_shim_fixture",
    )

    native.test_suite(
        name = name,
        tests = [
            ":" + name + "_bin_test",
            ":" + name + "_shim_test",
            ":" + name + "_script_test",
            ":" + name + "_agg_bin_test",
            ":" + name + "_agg_shim_test",
            ":" + name + "_agg_script_test",
            ":" + name + "_sql_test",
            ":" + name + "_sql_shim_test",
        ] + pkg_roots_digest_suite(name + "_digest"),
    )
