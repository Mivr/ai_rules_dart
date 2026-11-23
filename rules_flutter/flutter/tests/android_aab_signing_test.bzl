"""Analysis and build tests for release-keystore signing in `flutter_android_aab`.

The `.aab` file rule (`flutter_android_aab_file`) signs with `jarsigner` from
`@bazel_tools//tools/jdk:toolchain_type` when a keystore is given, by attribute
or by the `//flutter:android_release_*` flags, and leaves the bundle unsigned
otherwise. Analysis tests check both a stub JDK toolchain (proving the tool
comes exclusively from the toolchain) and Bazel's default hermetic JDK, plus
attribute-over-flag precedence and fail-closed errors; a small `build_test`
executes `jarsigner` end-to-end on a generated keystore and `.aab` archive.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("@bazel_skylib//rules:build_test.bzl", "build_test")
load("@bazel_skylib//rules:write_file.bzl", "write_file")
load("//flutter/private:flutter_android_aab.bzl", "flutter_android_aab_file")
load("//flutter/private:flutter_android_apk_overlay.bzl", "release_execution_requirements")
load("//flutter/tests:test_suite.bzl", "small_unittest_suite")

visibility(["//flutter/tests/..."])

_STORE_PASS = "aab-test-store-pass"
_KEY_PASS = "aab-test-key-pass"
_JDK_TYPE = "@bazel_tools//tools/jdk:toolchain_type"
_EXTRA_TOOLCHAINS = [str(Label("//flutter/tests:_aab_signing_stub_jdk_toolchain"))]

def _stub_jdk_impl(ctx):
    """Provides a stub JDK compilation toolchain whose `java_runtime` holds `bin/jarsigner`."""
    jarsigner = ctx.actions.declare_file(ctx.label.name + "/bin/jarsigner")
    ctx.actions.write(output = jarsigner, content = "#!/bin/sh\nexit 0\n", is_executable = True)
    runtime = struct(files = depset([jarsigner]), java_home = "stub_java_home")
    return [platform_common.ToolchainInfo(java = struct(java_runtime = runtime))]

_stub_jdk = rule(
    implementation = _stub_jdk_impl,
    doc = "Stub `@bazel_tools//tools/jdk:toolchain_type` implementation for `analysistest`.",
)

def _jdk_bin(ctx, tool_name):
    """Finds `<tool_name>` inside the active JDK toolchain's `java_runtime`."""
    runtime = ctx.toolchains[_JDK_TYPE].java.java_runtime
    for f in runtime.files.to_list():
        if f.path.endswith(("/bin/" + tool_name, "/bin/" + tool_name + ".exe")):
            return f, runtime.files
    fail("%s: JDK toolchain ships no bin/%s" % (ctx.label, tool_name))

def _genkey(ctx, keytool, jdk_files, out, store_type, key_pass = None):
    """Runs `keytool -genkeypair` from the JDK toolchain to emit `out`."""
    args = [
        "-genkeypair",
        "-keystore",
        out.path,
        "-storetype",
        store_type,
        "-storepass",
        _STORE_PASS,
        "-alias",
        "upload",
        "-keyalg",
        "RSA",
        "-keysize",
        "2048",
        "-validity",
        "1",
        "-dname",
        "CN=AabSignTest",
    ]
    if key_pass != None:
        args.extend(["-keypass", key_pass])
    ctx.actions.run(
        executable = keytool,
        toolchain = _JDK_TYPE,
        arguments = args,
        inputs = jdk_files,
        outputs = [out],
        mnemonic = "TestAabKeytool",
    )

def _exec_aab_inputs_impl(ctx):
    """Generates JKS and PKCS#12 keystores and a minimal `.aab` zip via the JDK toolchain."""
    keytool, jdk_files = _jdk_bin(ctx, "keytool")
    jar_tool, _ = _jdk_bin(ctx, "jar")
    entry = ctx.actions.declare_file(ctx.label.name + "_in/BundleConfig.pb")
    ctx.actions.write(output = entry, content = "")
    _genkey(ctx, keytool, jdk_files, ctx.outputs.keystore, "JKS", _KEY_PASS)
    _genkey(ctx, keytool, jdk_files, ctx.outputs.p12_keystore, "PKCS12")
    ctx.actions.run(
        executable = jar_tool,
        toolchain = _JDK_TYPE,
        arguments = ["cfM", ctx.outputs.unsigned_aab.path, "-C", entry.dirname, entry.basename],
        inputs = depset([entry], transitive = [jdk_files]),
        outputs = [ctx.outputs.unsigned_aab],
        mnemonic = "TestAabJar",
    )
    outs = [ctx.outputs.keystore, ctx.outputs.p12_keystore, ctx.outputs.unsigned_aab]
    return [DefaultInfo(files = depset(outs))]

_exec_aab_inputs = rule(
    implementation = _exec_aab_inputs_impl,
    toolchains = [_JDK_TYPE],
    outputs = {
        "keystore": "%{name}.jks",
        "p12_keystore": "%{name}.p12",
        "unsigned_aab": "%{name}_unsigned.aab",
    },
    doc = "Generates real JKS/PKCS#12 keystores and an `.aab` archive so `build_test` runs `jarsigner`.",
)

def _flags(keystore = None, keystore_password_file = None, key_alias = None):
    """Returns `config_settings` with the stub JDK plus any `//flutter:android_release_*` flags."""
    settings = {"//command_line_option:extra_toolchains": _EXTRA_TOOLCHAINS}
    pairs = [
        ("keystore", keystore),
        ("keystore_password_file", keystore_password_file),
        ("key_alias", key_alias),
    ]
    for flag, value in pairs:
        if value != None:
            settings[str(Label("//flutter:android_release_" + flag))] = value
    return settings

def _sign_actions(env):
    """Returns the `AabJarsign` actions registered by the target under test."""
    return [a for a in analysistest.target_actions(env) if a.mnemonic == "AabJarsign"]

def _arg_after(argv, flag):
    """Returns the element immediately following `flag` in `argv`, or None."""
    for i, item in enumerate(argv):
        if item == flag and i + 1 < len(argv):
            return argv[i + 1]
    return None

def _assert_no_password_leak(env):
    """Asserts neither password string reaches `argv` or `env` of any target action."""
    for action in analysistest.target_actions(env):
        for arg in action.argv:
            asserts.false(env, _STORE_PASS in arg, "store password on %s argv: %s" % (action.mnemonic, action.argv))
            asserts.false(env, _KEY_PASS in arg, "key password on %s argv: %s" % (action.mnemonic, action.argv))
            asserts.false(env, arg in ("-storepass", "-keypass"), "literal password flag in %s" % action.argv)
        for value in action.env.values():
            asserts.false(env, _STORE_PASS in value, "store password in %s env" % action.mnemonic)
            asserts.false(env, _KEY_PASS in value, "key password in %s env" % action.mnemonic)

def _signed_test_impl(ctx):
    """A keystore registers one `jarsigner` action from the JDK toolchain with file-based passwords."""
    env = analysistest.begin(ctx)
    actions = _sign_actions(env)
    asserts.equals(env, 1, len(actions), "expected one AabJarsign action")
    if not actions:
        return analysistest.end(env)
    action = actions[0]
    argv = action.argv
    inputs = [f.path for f in action.inputs.to_list()]
    outputs = [f.path for f in action.outputs.to_list()]
    asserts.true(env, argv[0].endswith("stub_jdk/bin/jarsigner"), "tool not from JDK toolchain: %s" % argv)
    asserts.true(env, argv[0] in inputs, "jarsigner executable must be an action input")
    asserts.true(env, _arg_after(argv, "-keystore") in inputs, "-keystore must be an action input")
    asserts.true(env, _arg_after(argv, "-storepass:file") in inputs, "-storepass:file must be an action input")
    asserts.equals(env, outputs, [_arg_after(argv, "-signedjar")])
    asserts.true(env, argv[-2].endswith("_signed_aab_unsigned.aab") and argv[-2] in inputs, "unsigned aab missing")
    asserts.equals(env, "release-alias", argv[-1])
    asserts.false(env, "-keypass:file" in argv, "no key_password_file was given: %s" % argv)
    _assert_no_password_leak(env)
    return analysistest.end(env)

def _key_pass_test_impl(ctx):
    """`key_password_file` adds `-keypass:file` as a declared input without leaking password text."""
    env = analysistest.begin(ctx)
    action = _sign_actions(env)[0]
    inputs = [f.path for f in action.inputs.to_list()]
    key_pass = _arg_after(action.argv, "-keypass:file")
    asserts.true(env, key_pass != None and key_pass.endswith("_key_pass.txt"), "got %s" % action.argv)
    asserts.true(env, key_pass in inputs, "-keypass:file must be an action input")
    _assert_no_password_leak(env)
    return analysistest.end(env)

def _real_jdk_test_impl(ctx):
    """With no toolchain override, `AabJarsign` resolves `jarsigner` from Bazel's hermetic JDK."""
    env = analysistest.begin(ctx)
    actions = _sign_actions(env)
    asserts.equals(env, 1, len(actions), "expected one AabJarsign action")
    if not actions:
        return analysistest.end(env)
    tool = actions[0].argv[0]
    inputs = [f.path for f in actions[0].inputs.to_list()]
    asserts.true(env, tool.startswith("external/"), "expected external Bazel JDK, got %s" % tool)
    asserts.true(env, tool.endswith(("/bin/jarsigner", "/bin/jarsigner.exe")), "unexpected tool %s" % tool)
    asserts.false(env, "local_jdk" in tool, "must not resolve host local_jdk: %s" % tool)
    asserts.true(env, tool in inputs, "JDK jarsigner must be in action inputs")
    return analysistest.end(env)

def _unsigned_test_impl(ctx):
    """Without a keystore the bundle stays unsigned: no signing action, never debug-signed."""
    env = analysistest.begin(ctx)
    asserts.equals(env, 0, len(_sign_actions(env)), "an unsigned bundle registers no signing action")
    for action in analysistest.target_actions(env):
        asserts.equals(env, None, action.argv, "unsigned bundle must only symlink, got %s" % action.mnemonic)
    return analysistest.end(env)

def _precedence_test_impl(ctx):
    """Checks which keystore, password file, and alias won between attributes and flags."""
    env = analysistest.begin(ctx)
    argv = _sign_actions(env)[0].argv
    keystore = _arg_after(argv, "-keystore")
    store_pass = _arg_after(argv, "-storepass:file")
    asserts.true(env, keystore != None and keystore.endswith(ctx.attr.expected_keystore), "got %s" % argv)
    asserts.true(env, store_pass != None and store_pass.endswith(ctx.attr.expected_pass), "got %s" % argv)
    asserts.equals(env, ctx.attr.expected_alias, argv[-1])
    return analysistest.end(env)

def _expect_failure_test_impl(ctx):
    """Asserts analysis failed with each expected substring in the diagnostic."""
    env = analysistest.begin(ctx)
    for expected in ctx.attr.expected_substrings:
        asserts.expect_failure(env, expected)
    return analysistest.end(env)

def _release_requirements_test_impl(ctx):
    """Release signing marks its action `no-remote`; unsigned keeps empty requirements."""
    env = unittest.begin(ctx)
    asserts.equals(env, {"no-remote": "1"}, release_execution_requirements(struct(keystore = "k")))
    asserts.equals(env, {}, release_execution_requirements(None))
    return unittest.end(env)

_PRECEDENCE_ATTRS = {
    "expected_keystore": attr.string(doc = "Expected suffix of `-keystore`.", mandatory = True),
    "expected_pass": attr.string(doc = "Expected suffix of `-storepass:file`.", mandatory = True),
    "expected_alias": attr.string(doc = "Expected trailing key alias argument.", mandatory = True),
}

_FAILURE_ATTRS = {
    "expected_substrings": attr.string_list(doc = "Substrings the failure message must contain.", mandatory = True),
}

_ALL_RELEASE_FLAGS = _flags(
    keystore = str(Label("//flutter/tests:android_aab_signing_test_flag_keystore")),
    keystore_password_file = str(Label("//flutter/tests:android_aab_signing_test_flag_store_pass")),
    key_alias = "flag-alias",
)

_signed_test = analysistest.make(_signed_test_impl, config_settings = _flags(), doc = "Checks signed AAB action.")
_key_pass_test = analysistest.make(_key_pass_test_impl, config_settings = _flags(), doc = "Checks -keypass:file.")
_real_jdk_test = analysistest.make(_real_jdk_test_impl, doc = "Checks default Bazel JDK toolchain resolution.")
_unsigned_test = analysistest.make(_unsigned_test_impl, config_settings = _flags(), doc = "Checks unsigned AAB.")
_precedence_with_flags_test = analysistest.make(
    _precedence_test_impl,
    attrs = _PRECEDENCE_ATTRS,
    config_settings = _ALL_RELEASE_FLAGS,
    doc = "Checks attribute-versus-flag precedence when all release flags are set.",
)
_expect_failure_test = analysistest.make(
    _expect_failure_test_impl,
    expect_failure = True,
    attrs = _FAILURE_ATTRS,
    config_settings = _flags(),
    doc = "Checks fail-closed attribute validation.",
)
_empty_flag_keystore_test = analysistest.make(
    _expect_failure_test_impl,
    expect_failure = True,
    attrs = _FAILURE_ATTRS,
    config_settings = _flags(keystore = str(Label("//flutter/tests:android_aab_signing_test_empty_files"))),
    doc = "Checks empty keystore flag fails closed.",
)
_two_flag_keystore_test = analysistest.make(
    _expect_failure_test_impl,
    expect_failure = True,
    attrs = _FAILURE_ATTRS,
    config_settings = _flags(keystore = str(Label("//flutter/tests:android_aab_signing_test_two_files"))),
    doc = "Checks multi-file keystore flag fails closed.",
)
_two_flag_pass_test = analysistest.make(
    _expect_failure_test_impl,
    expect_failure = True,
    attrs = _FAILURE_ATTRS,
    config_settings = _flags(
        keystore = str(Label("//flutter/tests:android_aab_signing_test_flag_keystore")),
        keystore_password_file = str(Label("//flutter/tests:android_aab_signing_test_two_files")),
        key_alias = "flag-alias",
    ),
    doc = "Checks multi-file keystore_password_file flag fails closed.",
)
_release_requirements_test = unittest.make(_release_requirements_test_impl)

def _file(name, out, line):
    """Declares a `manual` single-file target ending with a trailing newline."""
    write_file(name = name, out = out, content = [line, ""], tags = ["manual"])

def _signing(keystore = None, keystore_password_file = None, key_alias = "", key_password_file = None):
    """Groups release-signing attribute values into a parameter struct."""
    return struct(
        keystore = keystore,
        keystore_password_file = keystore_password_file,
        key_alias = key_alias,
        key_password_file = key_password_file,
    )

def _aab_target(name, kind, signing = None):
    """Declares an unsigned `.aab` fixture paired with a `flutter_android_aab_file` target."""
    spec = signing if signing != None else _signing()
    _file(name + "_" + kind + "_aab_unsigned", name + "_" + kind + "_aab_unsigned.aab", "fake bundle")
    flutter_android_aab_file(
        name = name + "_" + kind + "_aab",
        unsigned_aab = ":" + name + "_" + kind + "_aab_unsigned",
        keystore = spec.keystore,
        keystore_password_file = spec.keystore_password_file,
        key_alias = spec.key_alias,
        key_password_file = spec.key_password_file,
        tags = ["manual"],
    )

def _setup_fixtures(name):
    """Declares stub JDK, keystores, password files, and AAB targets under test."""
    _stub_jdk(name = "_aab_signing_stub_jdk", tags = ["manual"])
    native.toolchain(
        name = "_aab_signing_stub_jdk_toolchain",
        toolchain = ":_aab_signing_stub_jdk",
        toolchain_type = _JDK_TYPE,
    )
    _file(name + "_keystore", name + "_keystore.p12", "fake keystore")
    _file(name + "_flag_keystore", name + "_flag_keystore.p12", "fake flag keystore")
    _file(name + "_store_pass", name + "_store_pass.txt", _STORE_PASS)
    _file(name + "_flag_store_pass", name + "_flag_store_pass.txt", "aab-flag-store-pass")
    _file(name + "_key_pass", name + "_key_pass.txt", _KEY_PASS)
    _file(name + "_pair_a", name + "_pair_a.bin", "a")
    _file(name + "_pair_b", name + "_pair_b.bin", "b")
    native.filegroup(name = name + "_empty_files", srcs = [], tags = ["manual"])
    native.filegroup(
        name = name + "_two_files",
        srcs = [":" + name + "_pair_a", ":" + name + "_pair_b"],
        tags = ["manual"],
    )
    ks = ":" + name + "_keystore"
    sp = ":" + name + "_store_pass"
    kp = ":" + name + "_key_pass"
    two = ":" + name + "_two_files"
    _aab_target(name, "signed", _signing(ks, sp, "release-alias"))
    _aab_target(name, "key_pass", _signing(ks, sp, "release-alias", kp))
    _aab_target(name, "unsigned")
    _aab_target(name, "attr", _signing(ks, sp, "attr-alias"))
    _aab_target(name, "partial_attr", _signing(keystore = ks))
    _aab_target(name, "flag_only")
    _aab_target(name, "no_pass", _signing(keystore = ks, key_alias = "a"))
    _aab_target(name, "no_alias", _signing(keystore = ks, keystore_password_file = sp))
    _aab_target(name, "empty_ks", _signing(":" + name + "_empty_files", sp, "release-alias"))
    _aab_target(name, "two_ks", _signing(two, sp, "release-alias"))
    _aab_target(name, "two_pass", _signing(ks, two, "release-alias"))
    _aab_target(name, "two_key_pass", _signing(ks, sp, "release-alias", two))
    _exec_aab_inputs(name = name + "_exec_in", tags = ["manual"])
    flutter_android_aab_file(
        name = name + "_exec_signed_aab",
        unsigned_aab = ":" + name + "_exec_in_unsigned.aab",
        keystore = ":" + name + "_exec_in.jks",
        keystore_password_file = sp,
        key_alias = "upload",
        key_password_file = kp,
        tags = ["manual"],
    )
    flutter_android_aab_file(
        name = name + "_exec_p12_signed_aab",
        unsigned_aab = ":" + name + "_exec_in_unsigned.aab",
        keystore = ":" + name + "_exec_in.p12",
        keystore_password_file = sp,
        key_alias = "upload",
        tags = ["manual"],
    )

def _register_failure_tests(name):
    """Registers the fail-closed analysis tests and returns their target labels."""
    attr_cases = [
        ("missing_pass_fails", "no_pass", ["keystore_password_file"]),
        ("missing_alias_fails", "no_alias", ["key_alias"]),
        ("empty_attr_keystore_fails", "empty_ks", ["`keystore`", "0 files"]),
        ("two_attr_keystore_fails", "two_ks", ["`keystore`", "2 files"]),
        ("two_attr_pass_fails", "two_pass", ["keystore_password_file", "2 files"]),
        ("two_attr_key_pass_fails", "two_key_pass", ["key_password_file", "2 files"]),
    ]
    labels = []
    for suffix, kind, substrings in attr_cases:
        test_name = name + "_" + suffix
        _expect_failure_test(
            name = test_name,
            size = "small",
            target_under_test = ":" + name + "_" + kind + "_aab",
            expected_substrings = substrings,
        )
        labels.append(":" + test_name)
    flag_cases = [
        ("empty_flag_keystore_fails", _empty_flag_keystore_test, ["android_release_keystore", "0 files"]),
        ("two_flag_keystore_fails", _two_flag_keystore_test, ["android_release_keystore", "2 files"]),
        ("two_flag_store_pass_fails", _two_flag_pass_test, ["android_release_keystore_password_file", "2 files"]),
    ]
    for suffix, rule_fn, substrings in flag_cases:
        test_name = name + "_" + suffix
        rule_fn(
            name = test_name,
            size = "small",
            target_under_test = ":" + name + "_flag_only_aab",
            expected_substrings = substrings,
        )
        labels.append(":" + test_name)
    return labels

def android_aab_signing_test_suite(name):
    """Registers the `flutter_android_aab` signing analysis, unit, and execution tests.

    Args:
      name: Suite name; fixtures and tests derive from it.
    """
    _setup_fixtures(name)
    _signed_test(name = name + "_signed_test", size = "small", target_under_test = ":" + name + "_signed_aab")
    _key_pass_test(name = name + "_key_pass_test", size = "small", target_under_test = ":" + name + "_key_pass_aab")
    _real_jdk_test(name = name + "_real_jdk_test", size = "small", target_under_test = ":" + name + "_signed_aab")
    _unsigned_test(name = name + "_unsigned_test", size = "small", target_under_test = ":" + name + "_unsigned_aab")
    _precedence_with_flags_test(
        name = name + "_attr_beats_flag_test",
        size = "small",
        target_under_test = ":" + name + "_attr_aab",
        expected_keystore = name + "_keystore.p12",
        expected_pass = name + "_store_pass.txt",
        expected_alias = "attr-alias",
    )
    _precedence_with_flags_test(
        name = name + "_partial_attr_flag_fallback_test",
        size = "small",
        target_under_test = ":" + name + "_partial_attr_aab",
        expected_keystore = name + "_keystore.p12",
        expected_pass = name + "_flag_store_pass.txt",
        expected_alias = "flag-alias",
    )
    _precedence_with_flags_test(
        name = name + "_flag_only_test",
        size = "small",
        target_under_test = ":" + name + "_flag_only_aab",
        expected_keystore = name + "_flag_keystore.p12",
        expected_pass = name + "_flag_store_pass.txt",
        expected_alias = "flag-alias",
    )
    small_unittest_suite(name + "_unit", _release_requirements_test)
    build_test(
        name = name + "_exec_test",
        size = "small",
        targets = [":" + name + "_exec_signed_aab", ":" + name + "_exec_p12_signed_aab"],
    )
    failure_labels = _register_failure_tests(name)
    native.test_suite(
        name = name,
        tests = [
            ":" + name + "_signed_test",
            ":" + name + "_key_pass_test",
            ":" + name + "_real_jdk_test",
            ":" + name + "_unsigned_test",
            ":" + name + "_attr_beats_flag_test",
            ":" + name + "_partial_attr_flag_fallback_test",
            ":" + name + "_flag_only_test",
            ":" + name + "_unit",
            ":" + name + "_exec_test",
        ] + failure_labels,
    )
