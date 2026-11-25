"""Unit tests for the addresses a Maven artifact of the Android pin is fetched from."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//flutter/private/android_model:maven.bzl", "maven_urls", "unavailable")
load("//flutter/tests:test_suite.bzl", "small_unittest_suite")

visibility(["//flutter/tests/..."])

_CENTRAL = "https://repo.maven.apache.org/maven2/"
_MIRROR = "https://maven-central.storage-download.googleapis.com/maven2/"
_JAR = "org/jspecify/jspecify/1.0.0/jspecify-1.0.0.jar"

def _central_then_mirror_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, [_CENTRAL + _JAR, _MIRROR + _JAR], maven_urls([_CENTRAL + _JAR]))
    asserts.equals(
        env,
        ["https://repo1.maven.org/maven2/" + _JAR, _MIRROR + _JAR],
        maven_urls(["https://repo1.maven.org/maven2/" + _JAR]),
    )
    return unittest.end(env)

def _other_repositories_are_kept_test_impl(ctx):
    env = unittest.begin(ctx)
    google = "https://dl.google.com/dl/android/maven2/androidx/core/core/1.13.1/core-1.13.1.aar"
    engine = "https://storage.googleapis.com/download.flutter.io/io/flutter/flutter_embedding_debug/1.0.0/a.jar"
    plugin = "https://example.com/m2/" + _JAR
    asserts.equals(env, [google, engine, plugin], maven_urls([google, engine, plugin]))
    asserts.equals(env, [], maven_urls([]))
    return unittest.end(env)

def _each_name_of_a_file_has_its_mirror_beside_it_test_impl(ctx):
    # A refusal of the first name by Central must not make every other name wait for it: Bazel goes
    # down the list in order, so each Central address is followed by its mirror.
    env = unittest.begin(ctx)
    other = "org/jspecify/jspecify/1.0.0/jspecify.jar"
    asserts.equals(
        env,
        [_CENTRAL + _JAR, _MIRROR + _JAR, _CENTRAL + other, _MIRROR + other],
        maven_urls([_CENTRAL + _JAR, _CENTRAL + other]),
    )
    return unittest.end(env)

def _a_mirror_the_pin_already_names_is_not_repeated_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, [_MIRROR + _JAR], maven_urls([_MIRROR + _JAR]))
    asserts.equals(
        env,
        [_CENTRAL + _JAR, _MIRROR + _JAR],
        maven_urls([_CENTRAL + _JAR, _MIRROR + _JAR]),
    )
    return unittest.end(env)

def _the_error_names_the_artifact_the_addresses_and_what_to_do_test_impl(ctx):
    env = unittest.begin(ctx)
    message = unavailable(
        "org.jspecify:jspecify:1.0.0",
        "jspecify-1.0.0.jar",
        "a" * 64,
        [_CENTRAL + _JAR, _MIRROR + _JAR],
    )
    for expected in [
        "org.jspecify:jspecify:1.0.0",
        "jspecify-1.0.0.jar",
        "a" * 64,
        "  " + _CENTRAL + _JAR + "\n  " + _MIRROR + _JAR,
        "--downloader_config",
        "--distdir",
    ]:
        asserts.true(env, expected in message, "%s is not in the error:\n%s" % (expected, message))
    return unittest.end(env)

_t0_test = unittest.make(_central_then_mirror_test_impl)
_t1_test = unittest.make(_other_repositories_are_kept_test_impl)
_t2_test = unittest.make(_each_name_of_a_file_has_its_mirror_beside_it_test_impl)
_t3_test = unittest.make(_a_mirror_the_pin_already_names_is_not_repeated_test_impl)
_t4_test = unittest.make(_the_error_names_the_artifact_the_addresses_and_what_to_do_test_impl)

def maven_urls_test_suite(name):
    small_unittest_suite(name, _t0_test, _t1_test, _t2_test, _t3_test, _t4_test)
