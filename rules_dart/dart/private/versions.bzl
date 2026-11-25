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
    "3.14.1": {
        "macos-arm64": "b670699f921bf307c3f2754b56349863ee9b2878661bcd446b50b90296e11311",
        "macos-x64": "3d440c968d4c1bb21c6d57eb1e3e364cea687899daef46b7cc99f07d328caaae",
        "linux-x64": "759bed01e0aeb50e1a0b0a19474ba5c80c6087ce1d37b3214e475c81a44430e8",
        "linux-arm64": "c6e5581d478ac43ecf7d7028798b1bd10aef509f5e351184c755ec7eeeb1bea9",
        "windows-x64": "fb2550f71e3408f2a69ff6ee29573f341991a927f8bc9ad0601dd3c9b19945c8",
    },
    "3.14.0": {
        "macos-arm64": "84ce7e50f18a724d6a29b33af5c4a16b160e9fb64622e12d575b3c9e3420509b",
        "macos-x64": "91fff6ade4d81e02a4b568a6f5bfa037756fbfa1cc911c998e006b166547c05f",
        "linux-x64": "90f7fd75fe21e16437778df882f280910d9bbd4809c90024f21de82435dded1d",
        "linux-arm64": "2bb9a19418ced8d9f5cc9e7faa2dcbbc7dc93882b287b8cd8db859efa191c888",
        "windows-x64": "9364024364325137b0db4cbfd36b178dd76ade7ec2f496846fc1e7e5bea6a681",
    },
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
    "3.14.1": {
        "linux-arm64_linux-arm": "da372f7d4091b3363f13fdf20205ace55fba4fc10d99d92e0dead8f39da16de8",
        "linux-arm64_linux-riscv64": "226564dafc1151354171e8378d510b4b81abb6d55842a18d799cc50cc6ad320d",
        "linux-arm64_linux-x64": "6892d89852c30ba63f6b03580603817a590d7e982e52371ec7c2f931971228e5",
        "linux-x64_linux-arm": "337846ae8118ff4d05f8871f1fb582f472c0e7ba1f5e0cd59066ce8b01b01b34",
        "linux-x64_linux-arm64": "2916b009305a7a3a60acb9c6a36dc27071eeaa7a47797ebbaa69442f52715219",
        "linux-x64_linux-riscv64": "14005575483ca5811fbc4f5e21c6861771dff7365e993cf90916af2760c638b1",
        "macos-arm64_linux-arm": "867897ac14b16e6dc89aa65a9bfaf5e0ab85a61981bbfaca0103ed06f1de2f9f",
        "macos-arm64_linux-arm64": "1c7b4013028e385f1a2fe8b39750b341cf021868a452994b94e6886fb21d744f",
        "macos-arm64_linux-riscv64": "84025f8b977b4c5e144506d75798e937a0e053efb24eba0fce110b12bb1c1ecc",
        "macos-arm64_linux-x64": "37f3d6bd79ebf5829cdac95a80bac4210352752d37ea33593456e51167a9aca5",
        "macos-x64_linux-arm": "e6e006fec0215be75936ca65be36aacd8e537299efe7fd3c925e1a55ea9f6ddd",
        "macos-x64_linux-arm64": "75a16982b288c84c1694d1a7a32be5620c349ec4b5aba71625553a529e773af3",
        "macos-x64_linux-riscv64": "947fc674d573519a0f1c08ce495f7bf67253d409e64856904d189495966d857f",
        "macos-x64_linux-x64": "5535a45e1f724b7a10a6fe6ad0145aaea935316d561774c9cb3127c5339a6768",
        "windows-x64_linux-arm": "d826ddf93461def60c404bd16a36555336a8078986c1af5e7274bf24bfe86876",
        "windows-x64_linux-arm64": "6eeb4ea3c44249c99eeacff224507d900d1ba2b04a07ac0a81416fe863e09375",
        "windows-x64_linux-riscv64": "6a2bcba6156aadc4a559af9a8d2ef1532a985d0693208bb3cf97d5066aa69e6f",
        "windows-x64_linux-x64": "59f67aaa70808c9df2e1d223001f4342ea2441d342a0323f4c17c24d1f3245b1",
    },
    "3.14.0": {
        "linux-arm64_linux-arm": "f2cf6c4c4c8296a1fa80470542a6dc771b8a28e64bb1139f0a4bfc01f6d57153",
        "linux-arm64_linux-riscv64": "ac2742fbdf32ec2f39be71938f9f8a8d35bad7d488bef9b1e962d47ee7cb33a8",
        "linux-arm64_linux-x64": "3c54bc85d52f65e87b702ea00a2a80ca306049321a02b96991f442dd42599ffa",
        "linux-x64_linux-arm": "b186a32df97c25dc240d71d520f4ddb8d656eaaa2544a54a8de693e647b8e20a",
        "linux-x64_linux-arm64": "9200d51fc8abd2f6516293d594c9e87850e579966d9be9023f645be6c45e407c",
        "linux-x64_linux-riscv64": "e458747bbd22e6013ee638fc4f8e40eecf46239e670178f9be251ef88fad43d2",
        "macos-arm64_linux-arm": "66ae4c8d1b180e55a8dc4f62ee5f4a5ae1d0dc91676a110fb453d0c008ca23e9",
        "macos-arm64_linux-arm64": "46f697ea3580623d5e1efc595ff81132425d68d0ba4139c6b643c9c105ba7c41",
        "macos-arm64_linux-riscv64": "6113fc9ed55bc84bbd7edeacddeb6f882e108c3cefbc9bd039e26af35eac3ad3",
        "macos-arm64_linux-x64": "e0cea0d77ec8b72d5fd5995f5939945f06a77d749c34b7b8b349ada305b08801",
        "macos-x64_linux-arm": "18ee005e8a03d258e688627cc4f0dd74482cf2d3bd89ad7c3b14745137b86a43",
        "macos-x64_linux-arm64": "736bba06ccccb8294384ec7e2e820798a4c0b3abab9667dc7c9fd18f857b133e",
        "macos-x64_linux-riscv64": "da16f74edcc0449bfcd159e660d0d48edac0450a0c92ee9c0904e59b3ef88a11",
        "macos-x64_linux-x64": "7d29c51a2fb8534324f51120b8d988a4806353bd09de114f6ef050a3080d47be",
        "windows-x64_linux-arm": "20ba77922cddd1387ea208be07014032a6041ea5e0eb760d55132c978be55e69",
        "windows-x64_linux-arm64": "5235d7eb8be8124c2f4d7913ef46b83ff0c8e157757c2118afd6055b0f8fae85",
        "windows-x64_linux-riscv64": "886436bf1cf5cd92dce8ffe89ebf2c0f476c704c2be69771cb27d9efab8a322d",
        "windows-x64_linux-x64": "ea35080d6dea8a079ccdde30e86c3d6536747147e69fba778f52faf681e743f3",
    },
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
    "3.14.1": {
        "linux-arm": "23bf32f07994a6edfa6f7862cd2181e657d67385e2cfcb5b0a9936e11269d0c9",
        "linux-arm64": "8e5309510570275424eafccf3e5686626eeee475649a7c31844e1b391e9d4579",
        "linux-riscv64": "11d7913fd402d1306fbac7a4fac1481d7dd6d4ee33c9be14bb477b3f0a27cb6b",
        "linux-x64": "39597552b13d642c5b8661dd16b2f2cef4ca54492d125a69df9ef20a9a7bc2db",
    },
    "3.14.0": {
        "linux-arm": "bf41783424c8bc5755b98a74425d51446d6cc19eaafac40a945351d1a0ca780a",
        "linux-arm64": "4c0e6f09c2ea7601d5d410bf1192ddace65d95fd40613ba980a265d4e5bc6f92",
        "linux-riscv64": "50991a1d6fbe2db4eba0a1893b6a307156bbdebcaef2bbd727e6f324abdd6e68",
        "linux-x64": "c97004ecd074ebabc2eb09e69cb9f35f7345eb5a168ca2bec21815668da4f82a",
    },
    "3.13.5": {
        "linux-arm": "952db10b55516ee28d5c28702b0bd0a0ec7bc19dd0a32358d35bd6a0467273b5",
        "linux-arm64": "f88a85bd246f958f2591fc2c0bdec770d06a0f8eecd9b233f1641b87e5320210",
        "linux-riscv64": "fe571b94cb649f0dcdfe23e9567873b3a6bd7013bf66733b11d871fc0602fe5d",
        "linux-x64": "a123bbc2f6687329b7257fab7f986f20e518b13d2b87761beb2b736c2ef8da7b",
    },
}
