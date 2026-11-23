"""Unit tests for the statement model's template-aware literal scan.

`gradle_segments` keeps a `${...}` body inside its literal span, so a
quoted literal nested in that body must be skipped without re-entering the
scanner. These tests pin the reported `firebase_messaging` statement, the
brace and nested-interpolation shapes a template body can carry, and the
Maven reader's classification of the reported line.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//flutter/private:gradle_deps.bzl", "maven_labels_for_gradle")
load(
    "//flutter/private:gradle_model.bzl",
    "gradle_has_word",
    "gradle_segments",
)
load("//flutter/tests:test_suite.bzl", "small_unittest_suite")

visibility(["//flutter/tests/..."])

# Verbatim `android/build.gradle:65` from firebase_messaging 15.2.1: a
# quoted literal inside a `${...}` body whose own arguments are quoted.
_FIREBASE_MESSAGING_BOM = 'implementation platform("com.google.firebase:firebase-bom:${getRootProjectExtOrCoreProperty("FirebaseSDKVersion", firebaseCoreProject)}")'
_FIREBASE_MESSAGING_BOM_LITERAL = '"com.google.firebase:firebase-bom:${getRootProjectExtOrCoreProperty("FirebaseSDKVersion", firebaseCoreProject)}"'

def _span_texts(spans):
    """The text of each span, in order."""
    return [s.text for s in spans]

def _firebase_messaging_bom_test_impl(ctx):
    """A quoted literal in a template body scans as one literal span."""
    env = unittest.begin(ctx)

    spans = gradle_segments(_FIREBASE_MESSAGING_BOM, "groovy")
    asserts.equals(
        env,
        ["implementation platform(", _FIREBASE_MESSAGING_BOM_LITERAL, ")"],
        _span_texts(spans),
    )
    asserts.equals(env, [True, False, True], [s.code for s in spans])
    asserts.equals(env, _FIREBASE_MESSAGING_BOM, "".join(_span_texts(spans)))
    asserts.true(env, gradle_has_word(_FIREBASE_MESSAGING_BOM, "groovy", "platform"))
    asserts.false(
        env,
        gradle_has_word(_FIREBASE_MESSAGING_BOM, "groovy", "getRootProjectExtOrCoreProperty"),
    )

    return unittest.end(env)

firebase_messaging_bom_test = unittest.make(_firebase_messaging_bom_test_impl)

def _template_literal_brace_test_impl(ctx):
    """A brace inside a quoted literal in a template body keeps its depth."""
    env = unittest.begin(ctx)

    for statement, literal in [
        ('implementation api("${f("}")}")', '"${f("}")}"'),
        ("implementation api(\"${'}'}\")", "\"${'}'}\""),
    ]:
        spans = gradle_segments(statement, "groovy")
        asserts.equals(env, ["implementation api(", literal, ")"], _span_texts(spans), statement)
        asserts.equals(env, [True, False, True], [s.code for s in spans], statement)
        asserts.equals(env, statement, "".join(_span_texts(spans)), statement)

    return unittest.end(env)

template_literal_brace_test = unittest.make(_template_literal_brace_test_impl)

def _template_nested_interpolation_test_impl(ctx):
    """Nested interpolation stays inside the outer literal as one span."""
    env = unittest.begin(ctx)

    statement = 'implementation api("${"${x}"}")'
    spans = gradle_segments(statement, "groovy")
    asserts.equals(env, ["implementation api(", '"${"${x}"}"', ")"], _span_texts(spans))
    asserts.equals(env, [True, False, True], [s.code for s in spans])
    asserts.equals(env, statement, "".join(_span_texts(spans)))

    return unittest.end(env)

template_nested_interpolation_test = unittest.make(_template_nested_interpolation_test_impl)

def _template_literal_forms_test_impl(ctx):
    """Triple-quoted and dollar-slashy literals in a template body stay literal."""
    env = unittest.begin(ctx)

    for statement, literal in [
        ('implementation api("${"""a}b"""}")', '"${"""a}b"""}"'),
        ('implementation api("${$/a}b/$}")', '"${$/a}b/$}"'),
    ]:
        spans = gradle_segments(statement, "groovy")
        asserts.equals(env, ["implementation api(", literal, ")"], _span_texts(spans), statement)
        asserts.equals(env, [True, False, True], [s.code for s in spans], statement)

    return unittest.end(env)

template_literal_forms_test = unittest.make(_template_literal_forms_test_impl)

def _maven_labels_template_literal_test_impl(ctx):
    """The reported line reduces to its coordinate instead of crashing."""
    env = unittest.begin(ctx)

    asserts.equals(env, 3, len(gradle_segments(_FIREBASE_MESSAGING_BOM, "groovy")))
    content = "dependencies {\n    " + _FIREBASE_MESSAGING_BOM + "\n}\n"
    result = maven_labels_for_gradle(content, {}, [])
    asserts.equals(env, [], result.labels)
    asserts.equals(env, ["com.google.firebase:firebase-bom"], result.unknown)
    asserts.equals(env, [], result.unreadable)

    return unittest.end(env)

maven_labels_template_literal_test = unittest.make(
    _maven_labels_template_literal_test_impl,
)

def gradle_model_test_suite(name):
    """Register the statement-model template tests."""
    small_unittest_suite(
        name,
        firebase_messaging_bom_test,
        template_literal_brace_test,
        template_nested_interpolation_test,
        template_literal_forms_test,
        maven_labels_template_literal_test,
    )
