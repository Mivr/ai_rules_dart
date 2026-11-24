"""One URI normalizer for every Flutter asset path (RT35-flutter:01).

flutter_tools 3.47.7 reads every `flutter:` entry that names a file as a
URI: string-form assets and shaders via `Uri.parse(entry)`, map-form
(`path:`) assets and shaders via `Uri(pathSegments: path.split('/'))`
(`flutter_manifest.dart:826-890`, `AssetsEntry.parseFromYamlSafe`), font
files via `Uri.parse(fontFile['asset'])` (`flutter_manifest.dart:421`). It
finds the file from the decoded `pathSegments` (`asset.dart:1185`,
`1402-1428`) and keys the bundle by the percent-encoded path:
`Uri(pathSegments: ['packages', name, ...segments]).path` for a package
(`asset.dart:1425-1428`), the entry's URI path for the app
(`asset.dart:617`). The key is also the file name inside flutter_assets
(`bundle_builder.dart:182`, `build_system/targets/assets.dart:126`), and
the engine percent-encodes the key it asks for, so the bundle must carry
the encoded spelling.

rules_flutter used to keep the raw entry text as both file name and key, so
`./a.png` failed the spoke fetch with an unhelpful target-name error while
flutter_tools bundles it as `a.png`, and `a b.png` bundled under the key
`a b.png` while flutter_tools (and hence the engine) uses `a%20b.png`.

This module mirrors both readings. A string-form entry reads like
`Uri.parse`: split on `/` (a raw backslash separates first), decode valid
`%XX` escapes as UTF-8, dot-resolve `.` / `x/..` on the decoded segments
the way Dart does (so an escaped `%2E` counts as `.`), then re-encode each
segment leaving RFC 3986 unreserved characters, sub-delims, `:` and `@`
literal and emitting every other UTF-8 byte as uppercase `%XX` (a lone `%`
becomes `%25`). A map-form entry reads like `Uri(pathSegments:
path.split('/'))`: every byte stays literal (a backslash never separates, a
`%XX` never decodes, so `%2E` is data rather than `.`), while dot segments
still resolve and empty segments stay; the literal bytes then re-encode
the same way. A map-form `?` or `#` stays refused as not supported, as on
the base. A raw backslash in string form reads as a path separator exactly
as `Uri.parse` reads it (before dot resolution and before
percent-decoding, so `assets/../x.png` with backslash separators is
`x.png`); a `%5C` escape stays a literal backslash byte and is still
refused, as on the base, as is a literal backslash from a map-form entry
(no Bazel target can name it). An empty segment stays in the key (`assets/e//em.png` keys with
`//`) while the decoded file collapses it (`assets/e/em.png`), as
flutter_tools keys `entryUri.path` but reads `path.fromUri`. Anything
that cannot bundle as flutter_tools would — a query, a fragment, a scheme,
a leading `/`, a `..` that leaves the
package, an escape decoding to `/` or to bytes that are not UTF-8, or a
byte no Bazel target can name (`:`, a backslash, a control character) — is
a refusal carrying the reason; the caller fails naming the package, its
pubspec.yaml and the entry. The label always names the decoded
(collapsed) file; only the bundle key keeps the `//` spelling. Entries whose first segment is `packages`
normalize like every other entry (`packages/d/./a.png` bundles as
`packages/d/a.png`, with dot segments resolved and escapes keyed as
flutter_tools keys them); a reference into another package normalizes to
itself, so the declaring package's walk still refuses it as missing, as on
the base.

Bazel 9.3 Starlark indexes strings by byte and offers no `chr`/`ord`, so
the normalizer works one byte at a time over a 256-byte table (`_BYTES`,
written with octal escapes, the only escapes the lexer takes past 0x7F):
escape bytes parse with a hex lookup, decoded bytes rebuild with table
slices, and UTF-8 validity is checked on the byte values with integer
arithmetic.
"""

visibility(["//flutter/..."])

# Every byte value 0-255 at its own index, so `_BYTES.find(unit)` reads a
# byte and `_BYTES[v:v + 1]` writes one. Octal escapes are the only way to
# spell bytes past 0x7F in a .bzl literal.
_BYTES = "\000\001\002\003\004\005\006\007\010\011\012\013\014\015\016\017" + "\020\021\022\023\024\025\026\027\030\031\032\033\034\035\036\037" + "\040\041\042\043\044\045\046\047\050\051\052\053\054\055\056\057" + "\060\061\062\063\064\065\066\067\070\071\072\073\074\075\076\077" + "\100\101\102\103\104\105\106\107\110\111\112\113\114\115\116\117" + "\120\121\122\123\124\125\126\127\130\131\132\133\134\135\136\137" + "\140\141\142\143\144\145\146\147\150\151\152\153\154\155\156\157" + "\160\161\162\163\164\165\166\167\170\171\172\173\174\175\176\177" + "\200\201\202\203\204\205\206\207\210\211\212\213\214\215\216\217" + "\220\221\222\223\224\225\226\227\230\231\232\233\234\235\236\237" + "\240\241\242\243\244\245\246\247\250\251\252\253\254\255\256\257" + "\260\261\262\263\264\265\266\267\270\271\272\273\274\275\276\277" + "\300\301\302\303\304\305\306\307\310\311\312\313\314\315\316\317" + "\320\321\322\323\324\325\326\327\330\331\332\333\334\335\336\337" + "\340\341\342\343\344\345\346\347\350\351\352\353\354\355\356\357" + "\360\361\362\363\364\365\366\367\370\371\372\373\374\375\376\377"

# Hex digits for `%XX` output (uppercase, as Dart emits) and input lookup.
_HEX_DIGITS = "0123456789ABCDEF"
_HEX_LOOKUP = "0123456789abcdefABCDEF"

# Bytes Dart's path-segment encoder leaves literal: RFC 3986 unreserved
# (`A-Z a-z 0-9 - . _ ~`), sub-delims (`! $ & ' ( ) * + , ; =`), `:` and `@`.
_LITERAL_SEGMENT_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~!$&'()*+,;=:@"

def _refusal(reason):
    """The `normalize_asset_uri` result for an entry spelling we cannot bundle.

    Args:
        reason: Why the spelling is not supported, naming the offending part.

    Returns:
        The failure struct (`ok = False`); callers fail with it.
    """
    return struct(ok = False, segments = [], decoded = "", key = "", is_dir = False, reason = reason)

def _hex_byte(text, i):
    """The byte value of the two hex digits at `text[i:i + 2]`, or -1.

    `int(_, 16)` would fail the build on bad digits instead of answering,
    so the value is read with a lookup. The caller guarantees `i + 2` is in
    range.

    Args:
        text: The string holding the digits.
        i: Index of the first digit.

    Returns:
        The byte value, or -1 when either character is not a hex digit.
    """
    hi = _HEX_LOOKUP.find(text[i])
    lo = _HEX_LOOKUP.find(text[i + 1])
    if hi < 0 or lo < 0:
        return -1
    if hi >= 16:
        hi -= 6
    if lo >= 16:
        lo -= 6
    return hi * 16 + lo

def _decode_segment(raw):
    """Decode one raw `/`-separated piece to its bytes and text.

    Valid `%XX` escapes become their byte (UTF-8 validity is checked
    later, over the whole segment, so a raw lead byte plus an escaped
    continuation validate together); anything else, including a lone `%`,
    stays literal.

    Args:
        raw: The segment as written in the entry.

    Returns:
        `struct(ok, values, text, reason)`: the byte values, the decoded
        text rebuilt byte-exact with table slices, or the refusal reason.
    """
    values = []
    chars = []
    i = 0
    n = len(raw)
    for _ in range(n + 1):
        if i >= n:
            break
        if raw[i] == "%" and i + 3 <= n and _hex_byte(raw, i + 1) >= 0:
            v = _hex_byte(raw, i + 1)
            values.append(v)
            chars.append(_BYTES[v:v + 1])
            i += 3
        elif raw[i] == "%":
            values.append(37)
            chars.append("%")
            i += 1
        else:
            v = _BYTES.find(raw[i])
            if v < 0:
                return struct(ok = False, values = [], text = "", reason = "it holds a byte outside 0-255")
            values.append(v)
            chars.append(raw[i])
            i += 1
    return struct(ok = True, values = values, text = "".join(chars), reason = "")

def _literal_segment(raw):
    """Read one raw `/`-separated piece literally, for map-form entries.

    Mirrors `Uri(pathSegments: path.split('/'))`: no byte is special, so
    `%XX` never decodes, `?` and `#` stay data (both are still refused by
    the caller, as on the base), and a backslash stays a backslash byte
    (refused below, since no Bazel target can name it).

    Args:
        raw: The segment as written in the entry.

    Returns:
        `struct(ok, values, text, reason)`: the byte values, the unchanged
        text, or the refusal reason.
    """
    values = []
    for unit in raw.elems():
        v = _BYTES.find(unit)
        if v < 0:
            return struct(ok = False, values = [], text = "", reason = "it holds a byte outside 0-255")
        values.append(v)
    return struct(ok = True, values = values, text = raw, reason = "")

def _lead_window(lead):
    """The continuation window a UTF-8 lead byte opens, strictly.

    Mirrors what `Uri.parse` accepts (it fails the parse with
    `FormatException` on anything else): overlong `C0`/`C1`, surrogate
    `ED A0`-`ED BF`, out-of-range `F4 90`-`F5 FF`, stray continuations and
    `FE`/`FF` are all refused.

    Args:
        lead: The lead byte value (>= 0x80; ASCII never reaches here).

    Returns:
        `struct(ok, need, lo, hi)`: `need` continuations, each within
        `lo..hi`; `ok = False` for a byte that opens no valid sequence.
    """
    if lead < 0xC2:
        return struct(ok = False, need = 0, lo = 0, hi = 0)
    if lead < 0xE0:
        return struct(ok = True, need = 1, lo = 0x80, hi = 0xBF)
    if lead == 0xE0:
        return struct(ok = True, need = 2, lo = 0xA0, hi = 0xBF)
    if lead < 0xED:
        return struct(ok = True, need = 2, lo = 0x80, hi = 0xBF)
    if lead == 0xED:
        return struct(ok = True, need = 2, lo = 0x80, hi = 0x9F)
    if lead < 0xF0:
        return struct(ok = True, need = 2, lo = 0x80, hi = 0xBF)
    if lead == 0xF0:
        return struct(ok = True, need = 3, lo = 0x90, hi = 0xBF)
    if lead < 0xF4:
        return struct(ok = True, need = 3, lo = 0x80, hi = 0xBF)
    if lead == 0xF4:
        return struct(ok = True, need = 3, lo = 0x80, hi = 0x8F)
    return struct(ok = False, need = 0, lo = 0, hi = 0)

def _ascii_byte_refusal(v, need):
    """The refusal reason for one ASCII byte, or "" when it bundles.

    Args:
        v: The byte value (below 0x80).
        need: Continuations still owed to an open sequence, if any.

    Returns:
        "" when the byte bundles, else why the spelling is not supported.
    """
    if need:
        return "an escape is cut off mid-sequence and is not valid UTF-8"
    if v == 0x2F:
        return "an escape decodes to `/`"
    if v == 0x5C:
        return "it holds a backslash"
    if v == 0x3A:
        return "it holds a `:`"
    if v < 0x20 or v == 0x7F:
        return "it holds a control character"
    return ""

def _step_multibyte(v, need, lo, hi):
    """Fold one non-ASCII byte into the open UTF-8 sequence, if any.

    Args:
        v: The byte value (0x80 or above).
        need: Continuations still owed to an open sequence, if any.
        lo: The low end of the continuation window the lead opened.
        hi: The high end of the continuation window the lead opened.

    Returns:
        `struct(refusal, need, lo, hi)`: the refusal reason ("" when the
        byte fits) and the updated sequence state.
    """
    if need:
        if v < lo or v > hi:
            return struct(refusal = "an escape is not valid UTF-8", need = 0, lo = 0, hi = 0)
        return struct(refusal = "", need = need - 1, lo = 0x80, hi = 0xBF)
    window = _lead_window(v)
    if not window.ok:
        return struct(refusal = "an escape is not valid UTF-8", need = 0, lo = 0, hi = 0)
    return struct(refusal = "", need = window.need, lo = window.lo, hi = window.hi)

def _check_segment_bytes(values):
    """The refusal reason for decoded segment bytes, or "" when bundlable.

    Checks UTF-8 strictly (see `_lead_window`) and refuses every byte no
    bundle key can carry: an escape decoding to `/` (a raw `/` never
    reaches here, it is the splitter), a backslash, a colon (no Bazel
    target can name either), and control characters.

    Args:
        values: The decoded byte values of one segment.

    Returns:
        "" when the bytes bundle, else why the spelling is not supported.
    """
    need = 0
    lo = 0
    hi = 0
    for v in values:
        if v < 0x80:
            refusal = _ascii_byte_refusal(v, need)
            if refusal:
                return refusal
        else:
            step = _step_multibyte(v, need, lo, hi)
            if step.refusal:
                return step.refusal
            need = step.need
            lo = step.lo
            hi = step.hi
    if need:
        return "an escape is cut off mid-sequence and is not valid UTF-8"
    return ""

def _resolve_segments(texts):
    """Dot-resolve decoded segment texts the way Dart does.

    Removes `.` segments and resolves `x/..` pairs; a `..` with nothing
    left to pop escapes the package and is refused, as is a resolution to
    no segments at all (`.`, `./`, `a/..` name no file).

    Args:
        texts: The decoded segment texts, in order.

    Returns:
        `struct(ok, segments, reason)`: the resolved segments or the
        refusal reason.
    """
    out = []
    for text in texts:
        if text == ".":
            continue
        if text == "..":
            if not out:
                return struct(ok = False, segments = [], reason = "a `..` segment escapes the package")
            out.pop(len(out) - 1)
            continue
        out.append(text)
    if not out:
        return struct(ok = False, segments = [], reason = "it names no file")
    return struct(ok = True, segments = out, reason = "")

def _encode_segment(text, first):
    """Percent-encode one decoded segment exactly like Dart's `Uri(pathSegments:)`.

    Bytes in `_LITERAL_SEGMENT_CHARS` stay literal; every other byte of the
    UTF-8 text becomes `%XX` in uppercase hex. A `:` stays literal except in
    the first segment, where Dart encodes it (`Uri(pathSegments:
    ['a:b']).path` is `a%3Ab`) so the key never reads as a scheme.

    Args:
        text: The decoded segment text.
        first: Whether this is the key's first segment.

    Returns:
        The encoded segment.
    """
    chars = []
    for unit in text.elems():
        if unit in _LITERAL_SEGMENT_CHARS and not (first and unit == ":"):
            chars.append(unit)
        else:
            v = _BYTES.find(unit)
            chars.append("%" + _HEX_DIGITS[v // 16] + _HEX_DIGITS[v % 16])
    return "".join(chars)

def normalize_asset_uri(entry, is_map = False):
    """Normalize one asset entry the way flutter_tools 3.47.7 reads it.

    A string-form entry mirrors `Uri.parse(entry)`; a map-form (`path:`)
    entry mirrors `Uri(pathSegments: entry.split('/'))`
    (`flutter_manifest.dart:826-890` for assets and shaders in either form,
    `flutter_manifest.dart:421` for font files, which are always
    string-form). Either reading then derives the bundle key
    (`asset.dart:1425-1428` for a package, `asset.dart:617` for the app):
    `decoded` is what the segments read as (the file to fetch, which the
    Bazel label names), `key` is the percent-encoded bundle key. A trailing
    `/` still marks a directory entry on both. An entry whose first segment
    is `packages` normalizes like any other entry: `Uri.parse` resolves its
    dot segments (`flutter_manifest.dart:826-841` feeds every entry through
    it) and re-encodes the key uppercase, so `packages/d/./a.png` bundles
    as `packages/d/a.png` and `packages/d/caf%c3%a9.png` as
    `packages/d/caf%C3%A9.png`. A reference into another package
    normalizes to itself when plain, keeping today's behaviour; a spelling
    no engine build reads (a query among them) is refused like any
    other entry.

    Args:
        entry: The entry text as written in pubspec.yaml (or a BUILD-listed
            relative path, which is already decoded — use `encode_asset_key`
            for those instead, so a literal `%` in a file name is not
            decoded).
        is_map: Whether the entry came from a map-form (`path:`) item. The
            parser threads the shape; never guess it from the text. String
            entries keep exactly the old reading.

    Returns:
        `struct(ok, segments, decoded, key, is_dir, reason)`: the decoded
        segments, the `/`-joined decoded path, the encoded key, whether the
        entry is a directory, or the reason the spelling is not supported.
    """
    if entry == "":
        return _refusal("it is null or empty")
    if "?" in entry:
        return _refusal("it has a query part")
    if "#" in entry:
        return _refusal("it has a fragment part")

    if is_map:
        # Map form reads like `Uri(pathSegments: entry.split('/'))`: every
        # byte is literal, so a backslash never separates and a `%XX` never
        # decodes. A literal backslash is refused below, since no Bazel
        # target can name it.
        if entry.startswith("/"):
            return _refusal("it is an absolute path")
        slashed = entry
    else:
        # A raw `\` is a path separator, exactly as `Uri.parse` reads it: split
        # first, dot-resolve and percent-decode after. A `%5C` escape still
        # decodes to a backslash byte and is refused below, as on the base.
        slashed = entry.replace("\\", "/")
        if slashed.startswith("/"):
            return _refusal("it is an absolute path")
    is_dir = slashed.endswith("/")
    body = slashed[:len(slashed) - 1] if is_dir else slashed
    texts = []
    for raw in body.split("/"):
        seg = _literal_segment(raw) if is_map else _decode_segment(raw)
        if not seg.ok:
            return _refusal(seg.reason)
        bad = _check_segment_bytes(seg.values)
        if bad:
            return _refusal(bad)
        texts.append(seg.text)
    resolved = _resolve_segments(texts)
    if not resolved.ok:
        return _refusal(resolved.reason)

    # An empty segment stays in the key (flutter_tools keys `entryUri.path`,
    # so `assets/e//em.png` manifests with `//`) while the decoded file
    # collapses it (flutter_tools reads `path.fromUri`, which opens
    # `assets/e/em.png`, and `path.join` lands the copy collapsed). The
    # label names the collapsed file, so the spoke check and link plan see
    # a Bazel-nameable path.
    key = "/".join([_encode_segment(text, i == 0) for i, text in enumerate(resolved.segments)])
    collapsed = [text for text in resolved.segments if text != ""]
    if not collapsed:
        return _refusal("it names no file")
    decoded = "/".join(collapsed)
    if is_dir:
        return struct(
            ok = True,
            segments = collapsed,
            decoded = decoded + "/",
            key = key + "/",
            is_dir = True,
            reason = "",
        )
    return struct(ok = True, segments = collapsed, decoded = decoded, key = key, is_dir = False, reason = "")

def encode_asset_key(decoded):
    """Percent-encode an already-decoded path for a bundle key.

    For filesystem truth (a walked file, a `short_path`-relative key),
    where decoding would corrupt a literal `%` in a file name: encodes each
    `/`-separated piece like Dart's `Uri(pathSegments:)` (see
    `_encode_segment`). Total: unlike `normalize_asset_uri` it never
    refuses, so callers must already know the path bundles.

    Args:
        decoded: The decoded `/`-joined path.

    Returns:
        The encoded bundle key.
    """
    return "/".join([_encode_segment(piece, i == 0) for i, piece in enumerate(decoded.split("/"))])

def decode_asset_key(key):
    """Decode an encoded bundle key for an AssetManifest entry.

    Mirrors `Uri.decodeFull` over the encoded key (flutter_tools 3.47.7
    `asset.dart:923-929`, `_createAssetManifest`): every `%XX` escape
    becomes its bytes — so `%25` is `%`, and escapes of reserved characters
    decode too — while literal `/` separators stay. The inverse of
    `encode_asset_key` on encoder output; a lone `%` stays literal, as in
    `_decode_segment`. Total: unlike `normalize_asset_uri` it never
    refuses, so callers must already know the key bundles.

    Args:
        key: The encoded bundle key (what the copied file is named).

    Returns:
        The decoded manifest key: the manifest entry and variant path.
    """
    return "/".join([_decode_segment(piece).text for piece in key.split("/")])

def pub_bundle_key(prefix, path):
    """The bundle key for one contribution path under `prefix`.

    Normalizes `path` (idempotent on spoke-emitted keys) and prefixes it,
    so no key assembly reads a raw path: `packages/<pkg>/` for pub
    contributions, `""` for the app. Fails on a spelling that is not
    supported, which can only arrive from a hand-built provider, never
    from the spoke.

    Args:
        prefix: `"packages/<name>/"`, or `""` for non-package contributions.
        path: The contribution's asset path (raw or already normalized).

    Returns:
        The bundle key.
    """
    norm = normalize_asset_uri(path)
    if not norm.ok:
        fail("asset path {path} uses a spelling that is not supported: {reason}".format(path = repr(path), reason = norm.reason))
    return prefix + norm.key

def spoke_asset_uri_error(package_name, entry, reason):
    """The fetch failure for an entry spelling rules_flutter cannot bundle.

    Returns the message instead of failing so unit tests can assert it; the
    caller `fail()`s with it. Names the package, its pubspec.yaml and the
    entry, and says the spelling is not supported, so a refusal never comes
    out as a bundle under a key flutter_tools would not use.

    Args:
        package_name: The pub package the entry comes from.
        entry: The entry text as written in pubspec.yaml.
        reason: Why the spelling is not supported (a `normalize_asset_uri`
            refusal reason).

    Returns:
        The error string; the caller `fail()`s with it.
    """
    return (
        "flutter.pub spoke for \"{pkg}\": pubspec.yaml entry {entry} uses " +
        "a spelling that is not supported: {reason}"
    ).format(pkg = package_name, entry = repr(entry), reason = reason)

def normalize_spoke_assets(package_name, parsed_assets):
    """Normalize parsed `flutter.assets` entries or fail the spoke fetch.

    Decodes each entry for file resolution (the label names the decoded
    file) and keys it encoded (the bundle key). Directory entries keep
    their trailing `/` on both spellings; `flavors` / `platforms` travel
    untouched. Each entry carries its pubspec shape (`is_map`), so a
    map-form entry reads like `Uri(pathSegments: path.split('/'))` while a
    string entry keeps the `Uri.parse` reading.

    Args:
        package_name: The pub package the entries come from, for refusals.
        parsed_assets: `struct(path, is_map, flavors, platforms)` entries from
            `parse_flutter_assets_block().assets`.

    Returns:
        `struct(path, key, flavors, platforms)` entries with the decoded
        path and the encoded key; fails the fetch on the first spelling
        that is not supported.
    """
    out = []
    for entry in parsed_assets:
        norm = normalize_asset_uri(entry.path, entry.is_map)
        if not norm.ok:
            fail(spoke_asset_uri_error(package_name, entry.path, norm.reason))
        out.append(struct(path = norm.decoded, key = norm.key, flavors = entry.flavors, platforms = entry.platforms))
    return out

def normalize_spoke_fonts(package_name, parsed_fonts):
    """Normalize parsed `flutter.fonts` file assets or fail the spoke fetch.

    Args:
        package_name: The pub package the entries come from, for refusals.
        parsed_fonts: `struct(family, fonts)` entries from
            `parse_flutter_assets_block().fonts`, each font a
            `struct(asset, weight, style)`.

    Returns:
        `struct(family, fonts)` entries with each font a `struct(asset,
        key, weight, style)`: the decoded file and the encoded bundle key;
        fails the fetch on the first spelling that is not supported.
    """
    out = []
    for entry in parsed_fonts:
        fonts = []
        for font in entry.fonts:
            norm = normalize_asset_uri(font.asset)
            if not norm.ok:
                fail(spoke_asset_uri_error(package_name, font.asset, norm.reason))
            fonts.append(struct(asset = norm.decoded, key = norm.key, weight = font.weight, style = font.style))
        out.append(struct(family = entry.family, fonts = fonts))
    return out

def normalize_spoke_shaders(package_name, parsed_shaders):
    """Normalize parsed `flutter.shaders` entries or fail the spoke fetch.

    Args:
        package_name: The pub package the entries come from, for refusals.
        parsed_shaders: `struct(path, is_map)` entries from
            `parse_flutter_assets_block().shaders`.

    Returns:
        `struct(path, key)` entries with the decoded file and the encoded
        bundle key; fails the fetch on the first spelling that is not
        supported.
    """
    out = []
    for entry in parsed_shaders:
        norm = normalize_asset_uri(entry.path, entry.is_map)
        if not norm.ok:
            fail(spoke_asset_uri_error(package_name, entry.path, norm.reason))
        out.append(struct(path = norm.decoded, key = norm.key))
    return out

def normalize_spoke_asset_block(package_name, asset_block):
    """Normalize a parsed `flutter` block once, for linking and expansion.

    The path-package link plan resolves declared entries against the source
    tree, and the expansion resolves them against the spoke listing: both
    must read the decoded files, never the raw entry text, or an escaped
    entry (`enc%20c.png`) links and expands nothing while the file
    (`enc c.png`) sits there. Normalizing here — and never again downstream —
    also means no entry text is decoded twice: a `%25` names the `%` file
    once (`pct%25.png` finds `pct%.png`, keyed `pct%25.png`).

    Args:
        package_name: The pub package the entries come from, for refusals.
        asset_block: The `parse_flutter_assets_block()` result to normalize.

    Returns:
        A struct `(fonts, assets, shaders)` of the `normalize_spoke_*`
        results; fails the fetch on the first spelling that is not
        supported.
    """
    return struct(
        fonts = normalize_spoke_fonts(package_name, asset_block.fonts),
        assets = normalize_spoke_assets(package_name, asset_block.assets),
        shaders = normalize_spoke_shaders(package_name, asset_block.shaders),
    )
