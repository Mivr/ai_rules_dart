"""Red-path contract for symlinks in pub package archives.

A pub package archive (hosted tarball, `git archive` output, or a
merged-cycle member) must not smuggle symlinks that read undeclared host
files: `pub.from_lock` and every spoke materialise the link as-is, and every
consumer then reads the link's target instead of a declared input. The shared
guard (`//dart/pub/private:pub_symlink.bzl`) rejects any link whose target
is absolute or climbs above the package root, and materialises links that
stay inside as regular files.

These load-time checks pin the guards' decision procedures: the
post-extraction walk's lexical rule and the header scan's per-entry
classification, which refuses hostile entries before extraction. The live
fetch-time rejection is verified manually (see BUILD.bazel): point the lock
at a git package whose `lib/` holds an escaping symlink and the fetch fails
naming the package, the link, and the word "symlink".
"""

# buildifier: disable=bzl-visibility
load("@rules_dart//dart/pub/private:pub_symlink.bzl", "is_absolute_symlink_target", "pub_symlink_error", "symlink_escapes_package")

# buildifier: disable=bzl-visibility
load("@rules_dart//dart/pub/private:pub_archive_scan.bzl", "archive_entry_error", "classify_archive_entry")

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
    # The header scan shares the walk's lexical rule: every hard-link entry
    # is refused whatever its target, symlinks only when they escape.
    r = classify_archive_entry("lib/evil.dart", "1", "lib/ok.dart")
    if r == None or r.kind != "hard-link" or r.path != "lib/evil.dart" or r.target != "lib/ok.dart":
        fail("classify_archive_entry must refuse even an in-package hard-link")
    r = classify_archive_entry("lib/evil.dart", "2", "/etc/passwd")
    if r == None or r.kind != "symlink":
        fail("classify_archive_entry must refuse an absolute symlink target")
    r = classify_archive_entry("lib/evil.dart", "2", "../../outside.txt")
    if r == None or r.kind != "symlink":
        fail("classify_archive_entry must refuse an escaping symlink target")
    if classify_archive_entry("lib/ok.dart", "0", "") != None:
        fail("classify_archive_entry must allow a regular file")
    if classify_archive_entry("lib/inner.dart", "2", "ok.dart") != None:
        fail("classify_archive_entry must allow an in-package symlink")
    herr = archive_entry_error("evil_hard_out", "lib/evil.dart", "hard-link", "../../outside.txt")
    if "evil_hard_out" not in herr or "lib/evil.dart" not in herr or "hard-link" not in herr or "../../outside.txt" not in herr:
        fail("archive_entry_error must name the package, path, kind and target: %r" % herr)
    serr = archive_entry_error("evil_esc", "lib/evil.dart", "symlink", "../../outside.txt")
    if not serr.startswith('pub package "evil_esc": symlink "lib/evil.dart" escapes the package'):
        fail("archive_entry_error symlink shape must share the walk diagnostic's prefix: %r" % serr)
