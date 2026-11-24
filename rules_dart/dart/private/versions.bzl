"""Dart SDK release versions and their SHA-256 checksums per platform, and semver comparison.

The semver helpers sit here, above the generated tables, because this leaf is
loadable from every layer. `update_cross_sdk_versions` keeps everything
before the end of `TOOL_VERSIONS` verbatim.
"""

visibility(["//dart/..."])

# Sentinel prepended to the prerelease segment list. `1` beats `0` so stable
# versions (which carry `(1,)`) sort after their prerelease counterparts.
_STABLE_SENTINEL = (1,)
_PRERELEASE_SENTINEL = (0,)

# Prerelease segments always parse as 3-tuples: (is_string_flag, int_value,
# string_value). Numeric segments are `(0, N, "")`; identifier segments
# are `(1, 0, ID)`. Per semver, numeric < identifier; within each kind,
# natural ordering applies.
_EMPTY_PRE = ()

def parse_semver(version):
    """Parses a semver string into a comparable tuple.

    Follows semver spec: major.minor.patch[-prerelease][+buildmeta].
    A version without prerelease is greater than the same version with one
    (e.g., `1.0.0` > `1.0.0-dev.1`). Build metadata (`+N` / `+sha.123`) is
    stripped before comparison, matching semver precedence rules.

    Both the stable and prerelease paths return a 5-tuple:

        (major, minor, patch, kind_sentinel, prerelease_segments)

    where `kind_sentinel` is `(1,)` for stable versions and `(0,)` for
    prereleases, and `prerelease_segments` is a (possibly empty) tuple of
    3-tuples encoding each prerelease segment. This shape comparison is
    consistent regardless of whether either operand has a prerelease, so
    `semver_gt("1.0.0", "1.0.0-dev.1")` returns cleanly without raising a
    type mismatch.

    Args:
        version: A semver string like `1.9.1`, `2.0.0-dev.1`, or `3.0.0+4`.

    Returns:
        A tuple that can be compared with `>`, `<`, or `==` to other
        `parse_semver` results.
    """
    release, _, pre = version.partition("-")

    # Build metadata is ignored for precedence; strip before parsing.
    release, _, _ = release.partition("+")
    parts = release.split(".")
    nums = tuple([int(p) for p in parts])

    if not pre:
        return nums + (_STABLE_SENTINEL, _EMPTY_PRE)

    pre_segments = []
    for seg in pre.split("."):
        if seg.isdigit():
            pre_segments.append((0, int(seg), ""))
        else:
            pre_segments.append((1, 0, seg))
    return nums + (_PRERELEASE_SENTINEL, tuple(pre_segments))

def semver_gt(a, b):
    """Compares two semver strings.

    Args:
      a: The semver string on the left of the comparison.
      b: The semver string on the right of the comparison.

    Returns:
      True if `a` is a higher version than `b`, with a prerelease ordering below its release.
    """
    return parse_semver(a) > parse_semver(b)

TOOL_VERSIONS = {
    "3.13.5": {
        "macos-arm64": "9dfe7d6f2558816c2a978aff6c80e8a4509c6cb726c0702a616c64d286f60e88",
        "macos-x64": "15aaffcc5c6aebcf5e907f721671a9f03cdc5e0b95affa59a9d8291fb2972421",
        "linux-x64": "ea864bc64df30a6b8bdf30b2e32550f7717d9a890de8f40293aeabb924fe232b",
        "linux-arm64": "19a731647c3ed55058ee46dde00330150e6a8729bb6121b4a31e86084c8a3e6d",
        "windows-x64": "aed8e4a8932ce8fa18ea32f990e43b4a1c9390a4c73777ab6fdf77fc9f4524d1",
    },
}

# SHA256 checksums for cross-compilation gen_snapshot binaries,
# keyed by SDK version and `<exec_platform>_<target_platform>`.
# Refresh with: bazel run //dart/private/tools:update_cross_sdk_versions
CROSS_GEN_SNAPSHOT_VERSIONS = {
    "3.13.5": {
        "linux-arm64_linux-arm": "d514af001cd5fc5a05658a0e96648e637c9f65fd16c0aeaad070b161e6f89e58",
        "linux-arm64_linux-riscv64": "41da7a233b341c1c5087a2e62453f45a1558eae112bf5f31ec0b623a340c5cd4",
        "linux-arm64_linux-x64": "7ded57b21548ef17c050c9761a076f7214819b4d19f9f1538862e9b83875fda4",
        "linux-x64_linux-arm": "8a3c3f8ea44cf2cddd98af66adaaf6af95fca0ec269a649b18ee9a5b00921220",
        "linux-x64_linux-arm64": "ce3ad6675e530e1707242e8c1766a1918d32c454b83abe042f000187dd0c4c91",
        "linux-x64_linux-riscv64": "c40196c9c9767ce8714c3a8dd6a2423f888f5f097d6fb6aef2fb2d6f4a2d52ef",
        "macos-arm64_linux-arm": "4440e7e0e349f2d591364abb339df54011fd583bc5f895aae615bbcf276cda24",
        "macos-arm64_linux-arm64": "f5b730afa92b9fe6ef675ff244f64af951ba406bcf854b40d5fe0f308674a948",
        "macos-arm64_linux-riscv64": "d8f59b845c8b46901a35e75840739d39346d81630824f609d5d419e46f3b23a3",
        "macos-arm64_linux-x64": "00c9bbc2917d386defdfaad362933bcb43046851bcc7a492c03b590cdcb1afbd",
        "macos-x64_linux-arm": "ed39fc64789604ef7810b445c6ed4fa8c9faabbd82c2d81353bd0a21cef2b1ec",
        "macos-x64_linux-arm64": "976c0d4945435200ae8ff15244cad44699f87f195b6e027c09f193a55b2d6a57",
        "macos-x64_linux-riscv64": "44b140dc784992adb7d4c83a53ebf5fdd29ccb0edf290cedf633a6684994527a",
        "macos-x64_linux-x64": "fd036118af52635b4b4ad682fcc3829545a84d1983647a96cc6585b42499ca50",
        "windows-x64_linux-arm": "7c3c75a1bc52a88b71c5ab82b7158ae9ee68168d2d0f0666bd983e3446eb789e",
        "windows-x64_linux-arm64": "3dccaf204481766e2f31ae98137dfb8d4c4133c49a47e2bf6d8febc04c34d2b9",
        "windows-x64_linux-riscv64": "ba3dd42aeb8b0f1e3fe64f23116e45e091d739c25047c3a176e2148bc567de58",
        "windows-x64_linux-x64": "38be0d2905f7222811c25c1d3a44929b6e30383e097f4b839c6a8745463dd00c",
    },
}

# SHA256 checksums for cross-compilation target dartaotruntime binaries,
# keyed by SDK version and `<target_platform>`.
# Refresh with: bazel run //dart/private/tools:update_cross_sdk_versions
CROSS_DARTAOTRUNTIME_VERSIONS = {
    "3.13.5": {
        "linux-arm": "952db10b55516ee28d5c28702b0bd0a0ec7bc19dd0a32358d35bd6a0467273b5",
        "linux-arm64": "f88a85bd246f958f2591fc2c0bdec770d06a0f8eecd9b233f1641b87e5320210",
        "linux-riscv64": "fe571b94cb649f0dcdfe23e9567873b3a6bd7013bf66733b11d871fc0602fe5d",
        "linux-x64": "a123bbc2f6687329b7257fab7f986f20e518b13d2b87761beb2b736c2ef8da7b",
    },
}
