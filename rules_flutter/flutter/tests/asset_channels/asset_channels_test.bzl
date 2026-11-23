"""Analysis tests for cross-channel asset key provenance (COV-63).

Own entries are authoritative: a key claimed by two different files in any
two channels fails analysis in the COV-1 shape. The same file reached along
two paths stays legal and is bundled once, and a family reached along two
paths is written once in the bundle config.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//flutter/tests:action_content.bzl", "written_json")

visibility(["//flutter/tests/..."])

def _bundle_config(ctx):
    """The bundle action's written `.asset_bundle_config.json`."""
    env = analysistest.begin(ctx)
    config = written_json(env, ".asset_bundle_config.json")
    return env, config

def _own_pub_conflict_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "channel_data/own.txt")
    asserts.expect_failure(env, "channel_data/other.txt")
    asserts.expect_failure(env, "own_pub_collision")
    asserts.expect_failure(env, "pub_other")
    return analysistest.end(env)

def _own_data_conflict_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "packages/cov63/channel_data/own.txt")
    asserts.expect_failure(env, "channel_data/own.txt")
    asserts.expect_failure(env, "blob.bin")
    asserts.expect_failure(env, "own_lib")
    asserts.expect_failure(env, "blob_glue")
    return analysistest.end(env)

def _same_file_two_channels_test_impl(ctx):
    env, config = _bundle_config(ctx)
    variants = config["assets"]["channel_data/shared.txt"]
    asserts.equals(env, 1, len(variants))
    asserts.equals(env, "channel_data/shared.txt", variants[0]["asset"])
    return analysistest.end(env)

def _same_file_data_test_impl(ctx):
    env, config = _bundle_config(ctx)
    variants = config["assets"]["packages/cov63/channel_data/shared.txt"]
    asserts.equals(env, 1, len(variants))
    asserts.equals(env, "packages/cov63/channel_data/shared.txt", variants[0]["asset"])
    return analysistest.end(env)

def _font_diamond_written_once_test_impl(ctx):
    env, config = _bundle_config(ctx)
    fonts = config["fonts"]
    asserts.equals(env, ["Diamond"], [f["family"] for f in fonts])
    asserts.equals(env, 1, len(fonts[0]["fonts"]))
    asserts.equals(env, "fonts/Diamond.ttf", fonts[0]["fonts"][0]["asset"])
    return analysistest.end(env)

def _font_clash_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "Diamond")
    asserts.expect_failure(env, "font_clash_a")
    asserts.expect_failure(env, "font_clash_b")
    return analysistest.end(env)

_own_pub_conflict_test = analysistest.make(
    _own_pub_conflict_test_impl,
    expect_failure = True,
)

_own_data_conflict_test = analysistest.make(
    _own_data_conflict_test_impl,
    expect_failure = True,
)

_same_file_two_channels_test = analysistest.make(
    _same_file_two_channels_test_impl,
)

_same_file_data_test = analysistest.make(
    _same_file_data_test_impl,
)

_font_diamond_written_once_test = analysistest.make(
    _font_diamond_written_once_test_impl,
)

_font_clash_test = analysistest.make(
    _font_clash_test_impl,
    expect_failure = True,
)

def asset_channels_test_suite(name):
    """Registers the COV-63 analysis tests.

    Args:
        name: Prefix for the generated tests and the suite.
    """
    _own_pub_conflict_test(
        name = name + "_own_pub_conflict",
        target_under_test = ":own_pub_collision",
    )
    _own_data_conflict_test(
        name = name + "_own_data_conflict",
        target_under_test = ":own_data_collision_app",
    )
    _same_file_two_channels_test(
        name = name + "_same_file_two_channels",
        target_under_test = ":shared_channel_bundle",
    )
    _same_file_data_test(
        name = name + "_same_file_data",
        target_under_test = ":shared_data_app",
    )
    _font_diamond_written_once_test(
        name = name + "_font_diamond_written_once",
        target_under_test = ":font_diamond_bundle",
    )
    _font_clash_test(
        name = name + "_font_clash",
        target_under_test = ":font_clash_bundle",
    )
    native.test_suite(
        name = name,
        tests = [
            ":" + name + "_own_pub_conflict",
            ":" + name + "_own_data_conflict",
            ":" + name + "_same_file_two_channels",
            ":" + name + "_same_file_data",
            ":" + name + "_font_diamond_written_once",
            ":" + name + "_font_clash",
        ],
    )
