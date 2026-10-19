"""Red-path contract for symlinks in pub package archives.

A pub package archive (hosted tarball, `git archive` output, or a
merged-cycle member) must not smuggle symlinks that read undeclared host
files: `pub.from_lock` and every spoke materialise the link as-is, and every
consumer then reads the link's target instead of a declared input. The shared
guard (`//dart/pub/private:pub_symlink.bzl`) rejects any link whose target
is absolute or climbs above the package root, and materialises links that
stay inside as regular files.

These load-time checks pin the guard's decision procedure. The live
fetch-time rejection is verified manually (see BUILD.bazel): point the lock
at a git package whose `lib/` holds an escaping symlink and the fetch fails
naming the package, the link, and the word "symlink".
"""

# buildifier: disable=bzl-visibility
load("@rules_dart//dart/pub/private:pub_symlink.bzl", "is_absolute_symlink_target", "pub_symlink_error", "symlink_escapes_package")

def check_pub_symlink_contract():
    """Fails at load time when the symlink guard misclassifies a link target."""
    if not symlink_escapes_package("lib/secret.dart", "../../evil.txt"):
        fail("symlink_escapes_package must reject a link climbing above the package root")
    if not symlink_escapes_package("a.dart", "../evil.txt"):
        fail("symlink_escapes_package must reject a top-level link climbing out")
    if not symlink_escapes_package("lib/a.dart", "/etc/passwd"):
        fail("symlink_escapes_package must reject an absolute target")
    if not symlink_escapes_package("lib/a.dart", ""):
        fail("symlink_escapes_package must reject an empty (broken) target")
    if symlink_escapes_package("lib/a.dart", "b.dart"):
        fail("symlink_escapes_package must allow a sibling target")
    if symlink_escapes_package("lib/a.dart", "../lib/b.dart"):
        fail("symlink_escapes_package must allow an up-and-back target that stays inside")
    if symlink_escapes_package("lib/sub/a.dart", "../../b.dart"):
        fail("symlink_escapes_package must allow climbing exactly to the package root")
    if not is_absolute_symlink_target("/etc/passwd"):
        fail("is_absolute_symlink_target must recognise POSIX absolute targets")
    if is_absolute_symlink_target("lib/b.dart"):
        fail("is_absolute_symlink_target must allow relative targets")
    err = pub_symlink_error("evil_pkg", "lib/secret.dart", "../../evil.txt")
    if "evil_pkg" not in err or "lib/secret.dart" not in err or "symlink" not in err:
        fail("pub_symlink_error must name the package and the link: %r" % err)
