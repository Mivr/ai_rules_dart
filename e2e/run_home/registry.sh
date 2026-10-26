# Inventory of every runnable entry point `rules_dart` offers, and the HOME
# policy each one must uphold. Sourced by `run_home_test.sh`, which runs every
# row under canary HOME directories and fails on any write into them.
#
# Rule for new entry points: adding a public target that `bazel run` accepts
# (or making a refused target runnable) without adding a row here fails the
# test script's enumeration check, and so fails CI. The row needs the label as
# `bazel run` takes it from this workspace, safe run arguments, the HOME
# policy, and the expected outcome:
#
#   LABEL|ARGS|POLICY|EXPECT[|CHECK]
#
# ARGS are word-split after `bazel run LABEL --`. `{WORKSPACE}` expands to this
# workspace's absolute path (only for tools that cannot take a relative path,
# because `bazel run` executes outside the workspace directory).
#
# POLICY is one of:
#   caller-home  the entry keeps the caller's environment (pub cache and
#                credentials keep working) but the rule-owned launcher around
#                it must write nothing under HOME. User programs (binaries,
#                tests, shims) and the SDK pass-through live here.
#   private      the entry redirects the home variables at a fresh directory
#                that is removed afterwards. Rule-owned tool launchers
#                (format, fix, analysis) live here.
#   n/a          the entry is not runnable: `bazel run` must refuse it.
#
# EXPECT is `exit:N` (exact exit code), `nonzero` (any failure; used for
# platform spawn failures such as executing a kernel directly, whose signal
# differs by host), or `refuse` (`bazel run` must decline with
# "Not executable").
#
# CHECK is optional: `stdout:<fixed-string>` that must appear in the run's
# combined output (used to prove the SDK pass-through still surfaces the
# caller's credentials while writing nothing), or
# `changed-file:<workspace-path>` naming a file the run must rewrite and that
# the script restores afterwards (used so the `fmt` entry really spawns the
# formatter instead of no-oping over an already-formatted input).
RUN_HOME_ENTRIES=(
  # --- test-workspace instances of every public rule ---
  '//:bin_exe|--exit=7|caller-home|exit:7'
  '//:bin_aot|--exit=7|caller-home|nonzero'
  '//:bin_kernel|--exit=7|caller-home|nonzero'
  '//:bin_kernel_launcher|--exit=7|caller-home|exit:7'
  '//:bin_jit|--exit=7|caller-home|nonzero'
  '//:plain_test||caller-home|exit:0'
  '//:fmt|fmt_sample.dart|private|exit:0|changed-file:fmt_sample.dart'
  '//:fix_it|--dry-run|private|exit:0'
  '//:analysis_test||private|exit:0'
  '//:web_js||n/a|refuse'
  '//:web_wasm||n/a|refuse'
  '//:fix_lib||n/a|refuse'
  # --- the SDK pass-through: caller env kept, analytics suppressed ---
  '@rules_dart//dart:dart|--version|caller-home|exit:0'
  '@rules_dart//dart:dart|pub token list|caller-home|exit:0|stdout:pub-cache-token.example.com'
  '@rules_dart//dart:dart|--verbose pub token list|caller-home|exit:0|stdout:pub-cache-token.example.com'
  # --- codegen shims: `--help` parses arguments and exits, no work ---
  '@rules_dart//dart/ext/_shared/combining_shim:bin|--help|caller-home|exit:0'
  '@rules_dart//dart/ext/built_value:shim|--help|caller-home|exit:0'
  '@rules_dart//dart/ext/copy_with_extension_gen:shim|--help|caller-home|exit:0'
  '@rules_dart//dart/ext/drift:shim_analyzer|--help|caller-home|exit:0'
  '@rules_dart//dart/ext/drift:shim_discover|--help|caller-home|exit:0'
  '@rules_dart//dart/ext/drift:shim_drift|--help|caller-home|exit:0'
  '@rules_dart//dart/ext/drift:shim_prep|--help|caller-home|exit:0'
  '@rules_dart//dart/ext/freezed:shim|--help|caller-home|exit:0'
  '@rules_dart//dart/ext/go_router:shim|--help|caller-home|exit:0'
  '@rules_dart//dart/ext/json_serializable:shim|--help|caller-home|exit:0'
  '@rules_dart//dart/ext/mockito:shim|--help|caller-home|exit:0'
  '@rules_dart//dart/ext/stacked:shim_bottomsheet|--help|caller-home|exit:0'
  '@rules_dart//dart/ext/stacked:shim_dialog|--help|caller-home|exit:0'
  '@rules_dart//dart/ext/stacked:shim_form|--help|caller-home|exit:0'
  '@rules_dart//dart/ext/stacked:shim_locator|--help|caller-home|exit:0'
  '@rules_dart//dart/ext/stacked:shim_logger|--help|caller-home|exit:0'
  '@rules_dart//dart/ext/stacked:shim_router|--help|caller-home|exit:0'
  # --- developer tools: safe arguments that stop before any network ---
  # `check_dual_build_collisions` resolves its baseline only inside the
  # rules_dart checkout itself, so from here it exits 255 after the usage
  # check; the row pins that behavior and its HOME cleanliness.
  '@rules_dart//dart/ext/tools:check_dual_build_collisions|{WORKSPACE}/empty_dir|caller-home|exit:255'
  '@rules_dart//dart/private/tools:update_cross_sdk_versions|--versions-bzl=/nonexistent|caller-home|exit:1'
  # --- tool binaries run directly: configless or kernel-shaped ---
  '@rules_dart//dart/private/tools:kernel_launcher||caller-home|exit:1'
  '@rules_dart//dart/private/tools:kernel_link||caller-home|nonzero'
  '@rules_dart//dart/private/tools:kernel_module||caller-home|nonzero'
  '@rules_dart//dart/private/tools:link_hook_runner|--help|caller-home|nonzero'
  '@rules_dart//dart/private/tools:web_compile_runner||caller-home|nonzero'
  '@rules_dart//dart/private:analyzer_summary_tool||caller-home|nonzero'
  '@rules_dart//dart:kernel_link||caller-home|nonzero'
  '@rules_dart//dart:kernel_module||caller-home|nonzero'
  # --- public but not runnable: `bazel run` must refuse each one ---
  '@rules_dart//dart/private:analyzer_sdk_summary_input||n/a|refuse'
  '@rules_dart//dart/private:aspect_modular_kernel||n/a|refuse'
  '@rules_dart//dart/tests/sdk_toolchain_fixture:sdk_root||n/a|refuse'
  '@rules_dart//dart/ext/tools:check_dual_build_collisions_lib||n/a|refuse'
  '@rules_dart//dart/guard:directive_guard||n/a|refuse'
  '@rules_dart//dart/runfiles:runfiles||n/a|refuse'
  '@rules_dart//dart/tests/analyzer_summary_fixture/codegen/dep:dep||n/a|refuse'
  '@rules_dart//dart/tests/analyzer_summary_fixture/flutter:sky_engine||n/a|refuse'
  '@rules_dart//dart/tests/analyzer_summary_fixture/testpkg:testpkg_lib||n/a|refuse'
)
