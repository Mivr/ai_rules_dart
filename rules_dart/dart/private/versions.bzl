"""Dart SDK release versions and their SHA-256 checksums per platform, and semver comparison.

The semver helpers sit here, above the generated tables, because this leaf is
loadable from every layer (`dart/ext/registry.bzl` version-bounds its curated
entries with `parse_semver`). `update_cross_sdk_versions` keeps everything
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
    "3.12.2": {
        "macos-arm64": "cd8753928e77b6b665bd70dce0e64b4ec6d2e2fde141d6409bb716c8ac1f1c0a",
        "macos-x64": "38199f56fe22f2235e76799191d5b9516e360369c61b6ba4411398d5d5920bab",
        "linux-x64": "28e47b44cf075f36771046c068bb0d174201cf9c7608744aed1cc23204299c2d",
        "linux-arm64": "f82c83ece7d168047550dfd4a664e4071ac7c488bddb72dc43102c22d7e0b518",
        "windows-x64": "77fd96c823ed09a85e58209a2c5f16b0fc02e5ed4f3e3d46fddf4be763d498d6",
    },
    "3.11.5": {
        "macos-arm64": "3fd03deb3b0c7897a9896c3f5f3dda4a9fe63c43b14364ee928ec6db348be0ac",
        "macos-x64": "94de6a18049c354026f5422446b311cfc96b51db6d316eeb7ca46ff14c0b8aaa",
        "linux-x64": "57f3ab5ac24883060b1ff12bcdac472ed76563ec7364e88f8a6d41e4f0db075f",
        "linux-arm64": "50e9aba58f8717943854778a73074e63a80c42054355d35e2732a0cc0824a2fb",
        "windows-x64": "044b9c58f45c7e8b67467395eaad469f67cd8797a73fbd1d2bb8a89a53b2dcba",
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
    "3.12.2": {
        "linux-arm64_linux-arm": "510ce53c7dc6b0950a90fefc3d5f820e0f9649c7fa8f096ab78fb675fd3e573f",
        "linux-arm64_linux-riscv64": "8c08a6971e3fdba70b12329f89062cb69c9238cc9ae41cf155f739a35ad694ee",
        "linux-arm64_linux-x64": "1c284ac1a28018a8cfd460a7c483e1059f0e8d4b54f2cb79d3a182d4d423d2af",
        "linux-x64_linux-arm": "07b6023c99d7a7d8a9a7f8b0f37966c1a0a25d415f9f9c507b52062a7b713a0d",
        "linux-x64_linux-arm64": "803480376baae5cc5d6ae269cd1b4c87103e7a5976fc9336493ca89ac65668d2",
        "linux-x64_linux-riscv64": "aa539cb6cb7bc86274470d08447ea3f4014526be1ead60e057f38dcd0ebd879e",
        "macos-arm64_linux-arm": "c96967e16d6b131079dc63eef2731185de9864dc966978ff9472011035160eb1",
        "macos-arm64_linux-arm64": "08427d5a0d68a052a527b6a0172726f0aeb1d4b3dfc86e42df9f4f573db67dc9",
        "macos-arm64_linux-riscv64": "549692c82e0fffdfadb24181f43deef847adc7ac544acb34bc5c56f4469388d8",
        "macos-arm64_linux-x64": "823b4358cc870badaa415aee7f3334247491bf9d610cb69968e4f9927fbb7091",
        "macos-x64_linux-arm": "24ea6b59d99d2527ab44b45858c26fbdc27a2c61026be702b9c522ee63406412",
        "macos-x64_linux-arm64": "cc2a9f4cfc552ec7c1aa012ccfc9540eb158a8ad2426cc6c1df823878625b33e",
        "macos-x64_linux-riscv64": "3147ef200dc2309985b750a0854346ae0d4b88c5eafb94fb8935a7804340e16e",
        "macos-x64_linux-x64": "ebed2c1555a4c7d0520fa2da55608bc5421de04aac0ccf71a282af7a4e73e720",
        "windows-x64_linux-arm": "a6fdd980ed9c84ec8dc8277ed26923b70ce2d04ea4c6601c3a0cc6a1804d46e4",
        "windows-x64_linux-arm64": "ed4f82541b565e55bde1e3eab991df5da0b74a9f3d76ffb3e8c9351b22ce0ad9",
        "windows-x64_linux-riscv64": "f010bad4d360f284205d59371073bd224727c9950b8db336c4e806c948504028",
        "windows-x64_linux-x64": "d6a1fed00b3966488d3fbea1b97685cf8b92d4200565fcf6e8631db6f9fe9c13",
    },
    "3.11.5": {
        "linux-arm64_linux-arm": "64beaf431d5233921bd63febb7c4efc135908dd7a6d19c34f407849cc8ba31f8",
        "linux-arm64_linux-riscv64": "731ed19f759dd1d6fa546d829d296cae57d0e6bad3be47d34ce6280c946f4f54",
        "linux-arm64_linux-x64": "e4ef429f27bb2fdaad5a92371ad3cafaefef0325fc8eb4f038880d67049d3b1d",
        "linux-x64_linux-arm": "d90dc6d42eac24d74aa4bcdd048bee018c95a894bad25b6592338fed14109c59",
        "linux-x64_linux-arm64": "98ffbaaad2c22f7eb30cd5a00960c330241c98c198026fedb261588d829fb0b1",
        "linux-x64_linux-riscv64": "38bfa145667c68a5630daa9b198ac98fafec753f5c4cbedb51bfb40cad0dde86",
        "macos-arm64_linux-arm": "56e50b58baf1dff2057b0a29abe9b8df9142a092585d8ee601aeb16395e818f0",
        "macos-arm64_linux-arm64": "87bfc8fe4d939d5f9c6e001710bbecfa734f9e6108ca8ba9f7233faa116c7dc0",
        "macos-arm64_linux-riscv64": "6b5fda6e642a92708cd8999e4e6d8fc6dbd5be17396dd99b8f8075da7b8aca7b",
        "macos-arm64_linux-x64": "9c7d0d00618732331ce6cec2c9469b665adf1ca66796e8ca502f8c1953aee18e",
        "macos-x64_linux-arm": "edb495e464ee610ab1ccd1caf927da88f5824b1231aa64838a961920180681c3",
        "macos-x64_linux-arm64": "61da238ffedca99e45e0bb37de45eb32e38eb4cbec14b2d92aeaa2a0e46faff7",
        "macos-x64_linux-riscv64": "9da1defceb02accde68b5502291faac43a8474486b676d3bad07e9b76c3163aa",
        "macos-x64_linux-x64": "c98f38e63f0e0f16064959162292f97136672fbccbbb0a8edd63411b9d1746dd",
        "windows-x64_linux-arm": "0f65577dcdf4415e4853835506e2815e856a6cc5d70b918ecc4feb1702d1ad8b",
        "windows-x64_linux-arm64": "639a58ed595f90aa71661c7bb094356f75f48c50485c810ff2d2f7bc818f74cd",
        "windows-x64_linux-riscv64": "58ea3f508cb8bc166f143a5f1251f4c195b1b74cb43498467449ded20203cd27",
        "windows-x64_linux-x64": "edc4de9ea83fafe2fe742df0e02a5a10e96c33909d203ce6b2e38b45f8e88d13",
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
    "3.12.2": {
        "linux-arm": "1a2cfb3b35ee3b310325558394060c8b354734b6af748276ded774b435dea939",
        "linux-arm64": "1151399ef2277c866016f0cb9369022c899875480ee9a774af2a01a216f6c9bd",
        "linux-riscv64": "d884dc09413557b25a9279439cd70d22a086c7ecf8ad21590f7d98c11da10491",
        "linux-x64": "297f6b68adf22140d0bfc92cf974dc0e22bd54be6e15d730b911ad5b661d6a89",
    },
    "3.11.5": {
        "linux-arm": "b0b66ed425b0c8a11d4f983510724ff6657136e3575542819869bc5f628162ad",
        "linux-arm64": "97db522e811911c8fa2ff2e464702a4caec8d14fea191cd36642e87e5c4591e2",
        "linux-riscv64": "50984c55201ad3fda922b0600607ea235b472613915e3bcdfdb05e93ce793ea4",
        "linux-x64": "0c731859f537027455e456719dd745f3aeaa3e28a38926c3b6e81d6569532ee4",
    },
}
