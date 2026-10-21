"""Unit tests for `split_compile_flags`: which stage each `dart_compile_flags` entry reaches.

The front end consumes a few flags, and `gen_kernel` must receive them, since
`dart compile` on a kernel input cannot apply them. Each other flag goes to
`dart compile`. These tests pin the split for each spelling.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//dart/private:dart_compile.bzl", "has_comma_define_flag", "split_compile_flags")
load(":small_suite.bzl", "small_unittest_suite")

def _split(flags):
    return split_compile_flags(flags)

def _front_end_one_flag_forms_test_impl(ctx):
    # Each front-end flag already in one-flag form passes through unchanged.
    env = unittest.begin(ctx)
    flags = [
        "--enable-experiment=macros",
        "-DGREETING=hello",
        "--enable-asserts",
    ]
    result = _split(flags)
    asserts.equals(env, None, result.error)
    asserts.equals(env, flags, result.front_end)
    asserts.equals(env, [], result.backend)
    return unittest.end(env)

def _front_end_two_flag_forms_test_impl(ctx):
    # The two-flag forms are joined, so `gen_kernel` gets the one-flag form.
    env = unittest.begin(ctx)
    result = _split([
        "--enable-experiment",
        "macros",
        "-D",
        "GREETING=hello",
        "--define",
        "MODE=fast",
    ])
    asserts.equals(env, None, result.error)
    asserts.equals(
        env,
        ["--enable-experiment=macros", "-DGREETING=hello", "-DMODE=fast"],
        result.front_end,
    )
    asserts.equals(env, [], result.backend)
    return unittest.end(env)

def _define_equals_form_test_impl(ctx):
    # `--define=KEY=VALUE` is the one-flag form of a define.
    env = unittest.begin(ctx)
    result = _split(["--define=GREETING=hello"])
    asserts.equals(env, ["-DGREETING=hello"], result.front_end)
    asserts.equals(env, [], result.backend)
    return unittest.end(env)

def _backend_flags_test_impl(ctx):
    # Anything else keeps its place and order, and reaches `dart compile`.
    env = unittest.begin(ctx)
    flags = [
        "--extra-gen-snapshot-options=--optimization_level=3",
        "--target-os=linux",
        "--verbosity=error",
    ]
    result = _split(flags)
    asserts.equals(env, [], result.front_end)
    asserts.equals(env, flags, result.backend)
    return unittest.end(env)

def _mixed_order_test_impl(ctx):
    # Front-end and back-end flags interleave; each list keeps its own order.
    env = unittest.begin(ctx)
    result = _split([
        "--verbosity=error",
        "-DA=1",
        "--enable-experiment",
        "macros",
        "--target-os=linux",
        "--enable-asserts",
    ])
    asserts.equals(env, None, result.error)
    asserts.equals(
        env,
        ["-DA=1", "--enable-experiment=macros", "--enable-asserts"],
        result.front_end,
    )
    asserts.equals(env, ["--verbosity=error", "--target-os=linux"], result.backend)
    return unittest.end(env)

def _value_flag_without_value_test_impl(ctx):
    # A value flag at the end has no value to take; the caller fails with the message.
    env = unittest.begin(ctx)
    result = _split(["--enable-experiment"])
    asserts.true(env, result.error != None, "a trailing --enable-experiment must be an error")
    asserts.true(env, "--enable-experiment" in result.error, "the error should name the flag: %s" % result.error)
    return unittest.end(env)

_front_end_one_flag_forms_test = unittest.make(_front_end_one_flag_forms_test_impl)
_front_end_two_flag_forms_test = unittest.make(_front_end_two_flag_forms_test_impl)
_define_equals_form_test = unittest.make(_define_equals_form_test_impl)
_backend_flags_test = unittest.make(_backend_flags_test_impl)
_mixed_order_test = unittest.make(_mixed_order_test_impl)
_value_flag_without_value_test = unittest.make(_value_flag_without_value_test_impl)

def _comma_define_flag_test_impl(ctx):
    # Only a comma in a -D/--define value needs the patched snapshot; a comma
    # in any other flag never reaches the front end's define splitting.
    env = unittest.begin(ctx)
    asserts.true(env, has_comma_define_flag(["-DFOO=a,b"]), "comma -D detected")
    asserts.true(env, has_comma_define_flag(["--define=FOO=a,b"]), "comma --define= detected")
    asserts.true(env, has_comma_define_flag(["--enable-asserts", "-DFOO=a,b"]), "comma among others detected")
    asserts.false(env, has_comma_define_flag([]), "no flags is clean")
    asserts.false(env, has_comma_define_flag(["-DFOO=a", "--define=BAR="]), "comma-free defines are clean")
    asserts.false(env, has_comma_define_flag(["-D"]), "a bare -D names no value")
    asserts.false(
        env,
        has_comma_define_flag(["--extra-gen-snapshot-options=--foo=a,b"]),
        "a comma outside a define needs no patch",
    )
    return unittest.end(env)

_comma_define_flag_test = unittest.make(_comma_define_flag_test_impl)

def compile_flags_test_suite(name):
    """Declares the `split_compile_flags` unit tests.

    Args:
      name: Name of the generated `test_suite`.
    """
    small_unittest_suite(
        name,
        _front_end_one_flag_forms_test,
        _front_end_two_flag_forms_test,
        _define_equals_form_test,
        _backend_flags_test,
        _mixed_order_test,
        _value_flag_without_value_test,
        _comma_define_flag_test,
    )
