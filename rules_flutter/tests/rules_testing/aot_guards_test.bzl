"""Tests for the `extra_gen_snapshot_options` guards and sizing-flag classification.

`flutter_aot_gen_snapshot_flags` is the one place the AOT rules turn
`extra_gen_snapshot_options` into the gen_snapshot command line. These tests
pin the parts `aot_flags_test` leaves open:

- a non-flag entry such as `strip` fails with the `--flag` diagnostic, not the
  allow-list one;
- a split-token value holding a line break fails with the single-line
  diagnostic, not the integer one (`--old_gen_heap_size` and `64\\n` are two
  entries, so only the value check can refuse it);
- a sizing flag takes a plain unsigned integer, in `=` or split-token form,
  and any other value fails with the integer diagnostic;
- `--strip` is dropped, `--no-strip` reports `strip = False`, and a positive
  `--dwarf-stack-traces` beside `split_debug_info` is emitted exactly once.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("@rules_testing//lib:analysis_test.bzl", "analysis_test")
load("@rules_testing//lib:truth.bzl", "matching")
load("@rules_testing//lib:util.bzl", "TestingAspectInfo")
load("//flutter:defs.bzl", "flutter_aot_target")
load("//flutter:utils.bzl", "HOST_COMPATIBLE", "flutter_aot_gen_snapshot_flags")

visibility(["//tests/..."])

_PACKAGE = "aot_flags_fixture"
_MAIN = "lib/guards_main.dart"

def _flags(options, obfuscate = False, split_debug_info = False, strip = True):
    """Runs `flutter_aot_gen_snapshot_flags` against a fake rule context."""
    ctx = struct(
        label = Label("//tests/rules_testing:aot_guards_fake"),
        attr = struct(
            extra_gen_snapshot_options = options,
            obfuscate = obfuscate,
            split_debug_info = split_debug_info,
        ),
        actions = struct(declare_file = lambda name: struct(path = "bazel-out/" + name)),
    )
    flags, _outputs, _debug_info, _map, final_strip = flutter_aot_gen_snapshot_flags(ctx, strip)
    return struct(flags = flags, strip = final_strip)

def _sizing_flags_kept_test_impl(ctx):
    """A sizing flag keeps its canonical spelling in `=` and split-token form."""
    env = unittest.begin(ctx)
    for value in ["0", "64", "2147483648"]:
        want = ["--old-gen-heap-size=" + value]
        asserts.equals(env, want, _flags(["--old_gen_heap_size=" + value]).flags)
        asserts.equals(env, want, _flags(["--old_gen_heap_size", value]).flags)
    return unittest.end(env)

def _strip_entries_test_impl(ctx):
    """`--strip` is dropped (the action carries it); `--no-strip` turns stripping off."""
    env = unittest.begin(ctx)
    dropped = _flags(["--strip"])
    asserts.equals(env, [], dropped.flags)
    asserts.equals(env, True, dropped.strip)
    no_strip = _flags(["--no-strip"])
    asserts.equals(env, ["--no-strip"], no_strip.flags)
    asserts.equals(env, False, no_strip.strip)
    return unittest.end(env)

def _dwarf_kept_once_test_impl(ctx):
    """A positive `--dwarf-stack-traces` is kept, and `split_debug_info` does not add a second."""
    env = unittest.begin(ctx)
    plain = _flags(["--dwarf-stack-traces"])
    asserts.equals(env, ["--dwarf-stack-traces"], plain.flags)
    split = _flags(["--dwarf-stack-traces"], split_debug_info = True)
    asserts.equals(env, 1, len([f for f in split.flags if f == "--dwarf-stack-traces"]))
    asserts.equals(env, 1, len([f for f in _flags([], split_debug_info = True).flags if f == "--dwarf-stack-traces"]))
    return unittest.end(env)

_sizing_flags_kept_test = unittest.make(_sizing_flags_kept_test_impl)
_strip_entries_test = unittest.make(_strip_entries_test_impl)
_dwarf_kept_once_test = unittest.make(_dwarf_kept_once_test_impl)

def _expect_failure_matching(env, target, pattern):
    env.expect.that_target(target).failures().contains_predicate(matching.str_matches(pattern))

def _non_flag_entry_impl(env, target):
    """A bare word fails with the `--flag` diagnostic."""
    _expect_failure_matching(env, target, "*entries must be gen_snapshot `--flag`s*")

def _split_value_line_break_impl(env, target):
    """A split-token value with a line break fails with the single-line diagnostic."""
    _expect_failure_matching(env, target, "*contains a line break: argv-bound strings must be single-line*")

def _bad_sizing_value_impl(env, target):
    """A malformed sizing value fails with the integer diagnostic."""
    _expect_failure_matching(env, target, "*plain integer value*")

def _dwarf_argv_impl(env, target):
    """The final AOT argv holds one `--dwarf-stack-traces`."""
    actions = [a for a in target[TestingAspectInfo].actions if a.mnemonic in ("FlutterAotElf", "FlutterAotMacho")]
    env.expect.that_int(len(actions)).equals(1)
    argv = actions[0].argv if actions else []
    env.expect.that_int(len([a for a in argv if a == "--dwarf-stack-traces"])).equals(1)

def _fixture(name, options, **kwargs):
    flutter_aot_target(
        name = name,
        package_name = _PACKAGE,
        main = _MAIN,
        srcs = [_MAIN],
        extra_gen_snapshot_options = options,
        tags = ["manual"],
        target_compatible_with = HOST_COMPATIBLE,
        **kwargs
    )

def _failure_test(name, fixture, impl):
    analysis_test(
        name = name,
        target = ":" + fixture,
        impl = impl,
        expect_failure = True,
        attr_values = {"size": "small"},
    )

def aot_guards_test_suite(name):
    """Defines the gen_snapshot guard tests.

    Args:
        name: The test suite name.
    """
    units = {
        name + "_sizing_flags_kept": _sizing_flags_kept_test,
        name + "_strip_entries": _strip_entries_test,
        name + "_dwarf_kept_once": _dwarf_kept_once_test,
    }
    for unit_name, unit_rule in units.items():
        unit_rule(name = unit_name, size = "small")
    native.test_suite(name = name + "_units", tests = [":" + n for n in units])

    _fixture("_guards_non_flag_target", ["strip"])
    _failure_test(name + "_non_flag", "_guards_non_flag_target", _non_flag_entry_impl)

    _fixture("_guards_line_break_target", ["--old_gen_heap_size", "64\n"])
    _failure_test(name + "_split_line_break", "_guards_line_break_target", _split_value_line_break_impl)

    for case, options in {
        "empty": ["--old_gen_heap_size="],
        "bare": ["--old_gen_heap_size"],
        "letter": ["--old_gen_heap_size", "64a"],
        "space": ["--old_gen_heap_size=1 2"],
        "plus": ["--old_gen_heap_size=+1"],
        "minus": ["--old_gen_heap_size=-1"],
        "fraction": ["--old_gen_heap_size=1.0"],
    }.items():
        _fixture("_guards_size_%s_target" % case, options)
        _failure_test(name + "_bad_size_" + case, "_guards_size_%s_target" % case, _bad_sizing_value_impl)

    _fixture("_guards_dwarf_target", ["--dwarf-stack-traces"], split_debug_info = True)
    analysis_test(
        name = name + "_dwarf_argv",
        target = ":_guards_dwarf_target",
        impl = _dwarf_argv_impl,
        attr_values = {"size": "small"},
    )
