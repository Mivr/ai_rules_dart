"""Installability check of the toolchain floor's replaced package.

The floor number only counts when the package it produced passes the
platform's own structural check: iOS, the code signature verifies and the
bundle's ``Info.plist`` and executable are present; Android, the APK passes
the signature verifier and the alignment check, and ``AndroidManifest.xml``
and the Dart payload entries are present. The tools run through an
injected runner ``runner(argv) -> (returncode, stderr)``.
"""

import os
import plistlib
import re

from floor_apk import entry_names


def _ios_problems(spec, tools, runner):
    problems = []
    code, err = runner([tools["codesign"], "--verify", "--strict",
                        spec.package])
    if code != 0:
        problems.append("codesign verify failed: %s" % err.strip()[:200])
    plist = os.path.join(spec.package, "Info.plist")
    if not os.path.isfile(plist):
        return problems + ["Info.plist missing"]
    with open(plist, "rb") as fh:
        executable = plistlib.load(fh).get("CFBundleExecutable")
    if not executable or not os.path.isfile(
            os.path.join(spec.package, executable)):
        problems.append("bundle executable %r missing" % (executable,))
    return problems


def _zipalign_argv(zipalign, package, runner):
    """The 4-byte alignment check; ``-P 16`` only where zipalign knows it.

    ``-P`` exists from build-tools 35. The version in the path decides;
    without one, a probe with ``-P`` that zipalign rejects as an invalid
    option falls back to the plain check.
    """
    plain = [zipalign, "-c", "4", package]
    match = re.search(r"build-tools/(\d+)[./]", zipalign)
    if match:
        return plain[:2] + ["-P", "16"] + plain[2:] if int(
            match.group(1)) >= 35 else plain
    probe = plain[:2] + ["-P", "16"] + plain[2:]
    code, err = runner(probe)
    return plain if code != 0 and "invalid option" in err else probe


def _android_problems(spec, tools, runner):
    problems = []
    code, err = runner([tools["apksigner"], "verify", spec.package])
    if code != 0:
        problems.append("apksigner verify failed: %s" % err.strip()[:200])
    code, err = runner(_zipalign_argv(tools["zipalign"], spec.package,
                                      runner))
    if code != 0:
        problems.append("zipalign check failed: %s" % err.strip()[:200])
    names = entry_names(spec.package)
    if "AndroidManifest.xml" not in names:
        problems.append("AndroidManifest.xml missing")
    payload = [n for n in names
               if n.endswith("kernel_blob.bin" if spec.mode == "debug"
                             else "/libapp.so")]
    if not payload:
        problems.append("Dart payload entry missing")
    return problems


def check_package(spec, tools, runner):
    """Returns (ok, reason): reason is ``ok`` or the joined problems."""
    check = _ios_problems if spec.platform == "ios" else _android_problems
    problems = check(spec, tools, runner)
    return (not problems, "; ".join(problems) if problems else "ok")
