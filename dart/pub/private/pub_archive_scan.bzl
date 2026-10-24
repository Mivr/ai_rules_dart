"""Header-first archive scan refusing hard links and escaping symlinks.

A pub archive is pinned by sha256, but that pins the archive bytes, not what
the extracted package ends up holding: `ctx.extract` turns a tar hard-link
entry into a real hard link, so an entry whose target climbs out of the
extraction directory makes a "package file" share bytes with a file elsewhere
on the build host. Editing that host file then changes the build with no lock
or source change. The post-extraction walk (`pub_symlink.bzl`) cannot see
hard links — a hard link is a regular file whose realpath is itself, and
Starlark has no stat (no inode or link count) to tell them apart — so the
decision has to come from the archive's own entry headers, before any
extracted content is trusted (before a BUILD file is written, a pubspec is
read, or a consumer can see the tree).

Every site that unpacks third-party pub content calls `refuse_archive_bytes`
between fetching the archive and extracting it: hosted spokes, git spokes,
merged-cycle members (hosted and git), `pub.package()` repositories, and the
module extension's cycle-planning scratch. The scan refuses every hard-link
entry whatever its target, and every symlink entry whose target is absolute
or climbs out of the package root — the same lexical rule the
post-extraction walk applies (`symlink_escapes_package`), so the two guards
never disagree. The walk itself is kept: dangling links, chain escapes
through in-package links, and materialising in-package links as regular files
all behave as before.

The scan reads `.tar.gz` (RFC 1952 framing around an RFC 1951 deflate stream
carrying a tar archive) and plain `.tar` (`git archive` output), covering the
tar shapes real archives use: ustar names (with `prefix`), GNU long names and
long links (`L`/`K`), and pax extended and global headers (`x`/`g`, honouring
`path=`, `linkpath=` and `size=`). Sizes parse as octal or base-256. Unknown
entry kinds, sparse entries, corrupt headers, and truncated streams fail the
fetch closed: a package the scanner cannot read exactly is not a package the
build trusts. Device entries stay inert (the extractor creates nothing for
them) and entry names stay the extractor's business.

The scan uses Bazel's repository APIs only (`ctx.read` at the call sites;
this file itself only fails): it never shells out to host tools and never
consults `PATH`, so results are identical on Linux, macOS and Windows. The
whole scan is one linear pass over the archive — headers parse from C-speed
slices, file data advances counters without being stored, and only the 32
KiB LZ77 window, one 512-byte header buffer, and small name records are kept
— so the added work stays linear in archive size. Per-byte integrity (gzip
CRC32, tar checksums) is deliberately not re-verified: the lock's sha256
already pins every byte, and checksumming again would double the pass for no
new signal.

`scan_archive_bytes` is pure over the archive bytes (it returns a refusal
struct instead of failing) so unit tests cover every refusal shape without
downloading anything; `classify_archive_entry` and `archive_entry_error`
are pure too. `pub_lock_package.bzl` re-exports the scan and the walk for
rule sets outside `//dart/pub`.
"""

load("//dart/pub/private:pub_symlink.bzl", "symlink_escapes_package")

# `_BYTE_TABLE[i]` is the one-character string with byte value `i`. Starlark
# has no `chr`, so inflated literal symbols (integers) index this table to
# become characters; the reverse direction uses `hash` of a one-character
# string, which is its byte value.
_BYTE_TABLE = (
    "\000\001\002\003\004\005\006\007\010\011\012\013\014\015\016\017" +
    "\020\021\022\023\024\025\026\027\030\031\032\033\034\035\036\037" +
    "\040\041\042\043\044\045\046\047\050\051\052\053\054\055\056\057" +
    "\060\061\062\063\064\065\066\067\070\071\072\073\074\075\076\077" +
    "\100\101\102\103\104\105\106\107\110\111\112\113\114\115\116\117" +
    "\120\121\122\123\124\125\126\127\130\131\132\133\134\135\136\137" +
    "\140\141\142\143\144\145\146\147\150\151\152\153\154\155\156\157" +
    "\160\161\162\163\164\165\166\167\170\171\172\173\174\175\176\177" +
    "\200\201\202\203\204\205\206\207\210\211\212\213\214\215\216\217" +
    "\220\221\222\223\224\225\226\227\230\231\232\233\234\235\236\237" +
    "\240\241\242\243\244\245\246\247\250\251\252\253\254\255\256\257" +
    "\260\261\262\263\264\265\266\267\270\271\272\273\274\275\276\277" +
    "\300\301\302\303\304\305\306\307\310\311\312\313\314\315\316\317" +
    "\320\321\322\323\324\325\326\327\330\331\332\333\334\335\336\337" +
    "\340\341\342\343\344\345\346\347\350\351\352\353\354\355\356\357" +
    "\360\361\362\363\364\365\366\367\370\371\372\373\374\375\376\377"
)

# RFC 1951 caps Huffman codes at 15 bits; the 32 KiB LZ77 window is the
# distance limit. Both are protocol constants, not tunables.
_MAX_CODE_BITS = 15
_WINDOW_SIZE = 32768

# Length and distance base values and extra-bit counts (RFC 1951 3.2.5).
_LENGTH_BASE = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
_LENGTH_EXTRA = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
_DIST_BASE = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
_DIST_EXTRA = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]

# The order the dynamic header stores code-length code lengths in.
_CODE_LENGTH_ORDER = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

# Cap on collected GNU long-name, long-link and pax record data. Real names
# stay far below it; anything past it is hostile, not a package path.
_MAX_COLLECT_BYTES = 1048576

# The tar end-of-archive marker (two 512-byte zero blocks; the walk stops at
# the first and ignores whatever follows it, the way the extractor does).
_ZERO_BLOCK = "\0" * 512

def _new_scan_state(data):
    """Returns the mutable scan state for one archive.

    One dict threads through every helper (Starlark caps parameter lists, so
    the values that travel together ride in one state): the input bytes
    (`d`, `n`, `p`), the bit-reader buffer (`bb`, `bc`), the LZ77 window
    (`win`, `wp`) and inflated byte count (`out`, `member_out`), the tar
    consumer (`tmode`, `tneed`, `tbuf`), the pending and global name records
    (`pname`, `plink`, `ppath`, `plinkpath`, `psize`, `gpath`, `glinkpath`,
    `pax_kind`), and the first refusal (`refusal`, None while clean).

    Args:
      data: Raw archive bytes as an ISO-8859-1 Starlark string.

    Returns:
      The fresh state dict.
    """
    return {
        "d": data,
        "n": len(data),
        "p": 0,
        "bb": 0,
        "bc": 0,
        "win": [""] * _WINDOW_SIZE,
        "wp": 0,
        "out": 0,
        "member_out": 0,
        "tmode": "hdr",
        "tneed": 512,
        "tbuf": [],
        "pname": None,
        "plink": None,
        "ppath": None,
        "plinkpath": None,
        "psize": None,
        "gpath": None,
        "glinkpath": None,
        "pax_kind": "",
        "refusal": None,
    }

def _scan_error(package_name, detail):
    """Builds the fetch-failure diagnostic for an unscannable archive.

    Policy refusals (hard links, escaping symlinks) go through
    `archive_entry_error` instead; this is for archives the scanner cannot
    read exactly — corrupt, truncated, or using entry kinds it does not
    cover — which the build refuses rather than trusts.

    Args:
      package_name: The pub package the archive was fetched for.
      detail: What could not be read.

    Returns:
      The `fail()` message naming the package.
    """
    return 'pub package "%s": cannot scan its archive: %s' % (package_name, detail)

def archive_entry_error(package_name, path, kind, target):
    """Builds the fetch-failure diagnostic for a refused archive entry.

    Names the package, the entry path, the entry kind and the raw target, so
    the failure points at the offending archive entry. The symlink shape
    starts exactly like the post-extraction walk's diagnostic (which names
    the resolved target instead) so one grep matches either guard.

    Args:
      package_name: The pub package the entry was found in.
      path: The entry path relative to the package root, as stored.
      kind: `"hard-link"` or `"symlink"`.
      target: The entry's raw target, as stored.

    Returns:
      The `fail()` message naming the package, path, kind and target.
    """
    if kind == "hard-link":
        return (
            'pub package "%s": hard-link "%s" points at "%s": ' +
            "refusing an archive entry that extracts as a link sharing bytes " +
            "with another file, which the build cannot tell apart from a regular file"
        ) % (package_name, path, target)
    return (
        'pub package "%s": symlink "%s" escapes the package (points at "%s"): ' +
        "refusing to materialise a link that reads undeclared host files"
    ) % (package_name, path, target)

def classify_archive_entry(name, typeflag, link_target):
    """Classifies one tar entry header as refused or benign. Pure.

    Refuses every hard-link entry whatever its target, and every symlink
    entry whose target is absolute or climbs out of the package root (the
    walk's lexical rule, so the guards never disagree). Everything else —
    regular files, directories, long-name, long-link and pax records, inert
    device entries — is benign to this check.

    Args:
      name: The entry path relative to the package root, after long-name
        and pax `path=` resolution.
      typeflag: The entry kind character (`"1"` hard link, `"2"` symlink).
      link_target: The entry's raw target, after long-link and pax
        `linkpath=` resolution.

    Returns:
      A `struct(kind, path, target)` refusal, or None when benign.
    """
    if typeflag == "1":
        return struct(kind = "hard-link", path = name, target = link_target)
    if typeflag == "2" and symlink_escapes_package(name, link_target):
        return struct(kind = "symlink", path = name, target = link_target)
    return None

def _refill_bits(s):
    """Loads one input byte into the bit-reader buffer.

    Args:
      s: The scan state.
    """
    s["bb"] = s["bb"] | (hash(s["d"][s["p"]]) << s["bc"])
    s["p"] = s["p"] + 1
    s["bc"] = s["bc"] + 8

def _take_bits(s, package_name, k):
    """Reads `k` bits, failing closed on a truncated stream.

    Args:
      s: The scan state.
      package_name: The pub package being scanned, for diagnostics.
      k: How many bits to read (at most 13; Huffman decodes one at a time).

    Returns:
      The `k`-bit value.
    """
    for _ in range(5):
        if s["bc"] >= k:
            break
        if s["p"] >= s["n"]:
            fail(_scan_error(package_name, "the deflate stream ends mid-block"))
        _refill_bits(s)
    if s["bc"] < k:
        fail(_scan_error(package_name, "the deflate stream ends mid-block"))
    v = s["bb"] & ((1 << k) - 1)
    s["bb"] = s["bb"] >> k
    s["bc"] = s["bc"] - k
    return v

def _huffman_build(lengths, package_name):
    """Builds a canonical Huffman decoder from code lengths.

    Precomputes, per bit length, the first code and the symbol-table base, so
    decoding walks at most one code's worth of bits. Lengths past the RFC cap
    fail closed rather than decode an invalid table.

    Args:
      lengths: Code length per symbol (0 for no code).
      package_name: The pub package being scanned, for diagnostics.

    Returns:
      A `(first, base, counts, symbols, maxbits)` decoder tuple.
    """
    maxbits = 0
    for l in lengths:
        if l > maxbits:
            maxbits = l
    if maxbits > _MAX_CODE_BITS:
        fail(_scan_error(package_name, "a Huffman table uses codes past 15 bits"))
    counts = [0] * (maxbits + 1)
    for l in lengths:
        if l > 0:
            counts[l] = counts[l] + 1
    first = [0] * (maxbits + 1)
    base = [0] * (maxbits + 1)
    code = 0
    index = 0
    for l in range(1, maxbits + 1):
        code = (code + counts[l - 1]) << 1
        first[l] = code
        base[l] = index
        index = index + counts[l]
    symbols = [0] * index
    pos = [0] * (maxbits + 1)
    for l in range(1, maxbits + 1):
        pos[l] = base[l]
    for sym in range(len(lengths)):
        l = lengths[sym]
        if l > 0:
            symbols[pos[l]] = sym
            pos[l] = pos[l] + 1
    return (first, base, counts, symbols, maxbits)

def _huffman_decode(s, package_name, decoder):
    """Decodes one Huffman symbol, failing closed on an invalid code.

    Args:
      s: The scan state.
      package_name: The pub package being scanned, for diagnostics.
      decoder: A `_huffman_build` decoder tuple.

    Returns:
      The decoded symbol.
    """
    first, base, counts, symbols, maxbits = decoder
    code = 0
    for l in range(1, maxbits + 1):
        code = (code << 1) | _take_bits(s, package_name, 1)
        if code - first[l] < counts[l]:
            return symbols[base[l] + code - first[l]]
    fail(_scan_error(package_name, "the deflate stream holds an invalid Huffman code"))

def _dynamic_code_lengths(s, package_name, hlit, hdist):
    """Reads a dynamic block's literal and distance code lengths.

    Decodes the code-length alphabet (stored in `_CODE_LENGTH_ORDER`) with
    its run-length repeats: 16 repeats the previous length, 17 and 18 repeat
    zero. A repeat with nothing to repeat, or lengths that do not add up,
    fails closed.

    Args:
      s: The scan state.
      package_name: The pub package being scanned, for diagnostics.
      hlit: Literal/length code count (HLIT + 257).
      hdist: Distance code count (HDIST + 1).

    Returns:
      The `(literal lengths, distance lengths)` pair.
    """
    hclen = _take_bits(s, package_name, 4) + 4
    start = [0] * 19
    for i in range(hclen):
        start[_CODE_LENGTH_ORDER[i]] = _take_bits(s, package_name, 3)
    cltab = _huffman_build(start, package_name)
    total = hlit + hdist
    lens = []
    for _ in range(total * 2 + 16):
        if len(lens) >= total:
            break
        sym = _huffman_decode(s, package_name, cltab)
        if sym <= 15:
            lens.append(sym)
        elif sym == 16:
            if not lens:
                fail(_scan_error(package_name, "a dynamic block repeats no length"))
            prev = lens[len(lens) - 1]
            for _ in range(_take_bits(s, package_name, 2) + 3):
                lens.append(prev)
        elif sym == 17:
            for _ in range(_take_bits(s, package_name, 3) + 3):
                lens.append(0)
        else:
            for _ in range(_take_bits(s, package_name, 7) + 11):
                lens.append(0)
    if len(lens) != total:
        fail(_scan_error(package_name, "a dynamic block's code lengths do not add up"))
    return (lens[:hlit], lens[hlit:])

def _tar_consume_byte(s, package_name, c):
    """Feeds one inflated byte to the tar consumer.

    Collects the 512-byte header, then either skips file data by counter or
    collects long-name, long-link and pax record data (bounded by
    `_MAX_COLLECT_BYTES`). Past the end-of-archive marker bytes are ignored:
    the extractor stops there too.

    Args:
      s: The scan state.
      package_name: The pub package being scanned, for diagnostics.
      c: The one-character inflated byte.
    """
    if s["tmode"] == "done":
        return
    if s["tmode"] == "skip":
        s["tneed"] = s["tneed"] - 1
        if s["tneed"] == 0:
            s["tmode"] = "hdr"
            s["tneed"] = 512
        return
    s["tbuf"].append(c)
    if s["tmode"] == "hdr":
        if len(s["tbuf"]) != 512:
            return
        _tar_finish_header(s, package_name, "".join(s["tbuf"]))
        s["tbuf"] = []
        return
    if len(s["tbuf"]) >= s["tneed"]:
        need = s["tneed"]
        _tar_finish_data(s, package_name, "".join(s["tbuf"][:need]))
        s["tbuf"] = []
        pad = (-need) % 512
        if pad == 0:
            s["tmode"] = "hdr"
            s["tneed"] = 512
        else:
            # Record data is 512-padded like file data; the consumer lands
            # exactly on the next header.
            s["tmode"] = "skip"
            s["tneed"] = pad

def _emit_literal(s, package_name, c):
    """Emits one literal byte to the window and the tar consumer.

    Args:
      s: The scan state.
      package_name: The pub package being scanned, for diagnostics.
      c: The one-character byte.
    """
    s["win"][s["wp"]] = c
    s["wp"] = s["wp"] + 1
    if s["wp"] == _WINDOW_SIZE:
        s["wp"] = 0
    s["out"] = s["out"] + 1
    s["member_out"] = s["member_out"] + 1
    _tar_consume_byte(s, package_name, c)

def _match_from(s, dist):
    """Returns the window index `dist` bytes back.

    Args:
      s: The scan state.
      dist: The LZ77 distance (1 to 32 KiB).

    Returns:
      The window index the match copies from first.
    """
    src = s["wp"] - dist
    if src < 0:
        src = src + _WINDOW_SIZE
    return src

def _emit_match_collecting(s, package_name, dist, length):
    """Emits one match byte by byte through the tar consumer.

    Slow path, taken only while the tar consumer collects a header or a
    name record; file data takes the bulk path instead.

    Args:
      s: The scan state.
      package_name: The pub package being scanned, for diagnostics.
      dist: The LZ77 distance.
      length: The match length.
    """
    src = _match_from(s, dist)
    for _ in range(length):
        c = s["win"][src]
        src = src + 1
        if src == _WINDOW_SIZE:
            src = 0
        s["win"][s["wp"]] = c
        s["wp"] = s["wp"] + 1
        if s["wp"] == _WINDOW_SIZE:
            s["wp"] = 0
        s["out"] = s["out"] + 1
        s["member_out"] = s["member_out"] + 1
        _tar_consume_byte(s, package_name, c)

def _emit_match(s, package_name, dist, length):
    """Emits one LZ77 match to the window and the tar consumer.

    File data skips by counter, so a match that fits inside the skip copies
    window bytes in bulk without touching the consumer per byte; anything
    else (headers, name records, or a match straddling a region boundary)
    falls back to the collecting path.

    Args:
      s: The scan state.
      package_name: The pub package being scanned, for diagnostics.
      dist: The LZ77 distance.
      length: The match length.
    """
    if s["tmode"] != "skip" or length > s["tneed"]:
        _emit_match_collecting(s, package_name, dist, length)
        return
    src = _match_from(s, dist)
    for _ in range(length):
        s["win"][s["wp"]] = s["win"][src]
        s["wp"] = s["wp"] + 1
        if s["wp"] == _WINDOW_SIZE:
            s["wp"] = 0
        src = src + 1
        if src == _WINDOW_SIZE:
            src = 0
    s["out"] = s["out"] + length
    s["member_out"] = s["member_out"] + length
    s["tneed"] = s["tneed"] - length
    if s["tneed"] == 0:
        s["tmode"] = "hdr"
        s["tneed"] = 512

def _inflate_huffman_block(s, package_name, lit, dist):
    """Inflates one Huffman-coded block, stopping early on a refusal.

    Every symbol consumes at least one input bit, so bounding the loop by
    the remaining input bits plus one proves termination; a missing
    end-of-block marker fails closed instead of running past it.

    Args:
      s: The scan state.
      package_name: The pub package being scanned, for diagnostics.
      lit: The literal/length decoder.
      dist: The distance decoder.
    """
    for _ in range((s["n"] - s["p"] + s["bc"]) * 8 + 1):
        if s["refusal"] != None:
            return
        sym = _huffman_decode(s, package_name, lit)
        if sym < 256:
            _emit_literal(s, package_name, _BYTE_TABLE[sym])
        elif sym == 256:
            return
        else:
            li = sym - 257
            length = _LENGTH_BASE[li] + _take_bits(s, package_name, _LENGTH_EXTRA[li])
            dsym = _huffman_decode(s, package_name, dist)
            _emit_match(s, package_name, _DIST_BASE[dsym] + _take_bits(s, package_name, _DIST_EXTRA[dsym]), length)
    fail(_scan_error(package_name, "a deflate block never terminates"))

def _inflate_stored(s, package_name):
    """Inflates one stored (uncompressed) block.

    Aligns to a byte boundary, checks LEN against its complement, and emits
    the bytes as literals. Stored blocks carry tar bytes like any other, so
    each byte still passes through the tar consumer.

    Args:
      s: The scan state.
      package_name: The pub package being scanned, for diagnostics.
    """
    s["bb"] = 0
    s["bc"] = 0
    if s["p"] + 4 > s["n"]:
        fail(_scan_error(package_name, "a stored block is truncated"))
    lo = hash(s["d"][s["p"]]) + hash(s["d"][s["p"] + 1]) * 256
    hi = hash(s["d"][s["p"] + 2]) + hash(s["d"][s["p"] + 3]) * 256
    if lo + hi != 65535:
        fail(_scan_error(package_name, "a stored block's length check fails"))
    s["p"] = s["p"] + 4
    if s["p"] + lo > s["n"]:
        fail(_scan_error(package_name, "a stored block is truncated"))
    for _ in range(lo):
        if s["refusal"] != None:
            return
        _emit_literal(s, package_name, s["d"][s["p"]])
        s["p"] = s["p"] + 1

def _inflate_member_blocks(s, package_name):
    """Inflates every deflate block of one gzip member.

    Dispatches stored, fixed and dynamic blocks; a reserved block kind fails
    closed. Returns early once the tar consumer records a refusal. A member
    holds fewer blocks than it holds input bytes, which bounds the loop.

    Args:
      s: The scan state.
      package_name: The pub package being scanned, for diagnostics.
    """
    for _ in range(s["n"] + 2):
        if s["refusal"] != None:
            return
        final = _take_bits(s, package_name, 1)
        kind = _take_bits(s, package_name, 2)
        if kind == 0:
            _inflate_stored(s, package_name)
        elif kind == 1:
            _inflate_huffman_block(s, package_name, _FIXED_LIT, _FIXED_DIST)
        elif kind == 2:
            hlit = _take_bits(s, package_name, 5) + 257
            hdist = _take_bits(s, package_name, 5) + 1
            lit_lens, dist_lens = _dynamic_code_lengths(s, package_name, hlit, hdist)
            _inflate_huffman_block(s, package_name, _huffman_build(lit_lens, package_name), _huffman_build(dist_lens, package_name))
        else:
            fail(_scan_error(package_name, "a deflate block uses the reserved kind"))
        if final:
            return
    fail(_scan_error(package_name, "a gzip member holds no final block"))

def _cut_nul(field):
    """Cuts a tar header field at its first NUL pad byte.

    Args:
      field: The raw fixed-width field string.

    Returns:
      The field up to (not including) the first NUL.
    """
    return field.split("\0")[0]

def _parse_tar_number(field, package_name, what):
    """Parses a tar numeric field: octal, or base-256 when flagged.

    Base-256 (top bit of the first byte set) carries large sizes the octal
    field cannot hold; anything else must be octal digits with NUL or space
    padding, and anything unparsable fails closed.

    Args:
      field: The raw fixed-width field string.
      package_name: The pub package being scanned, for diagnostics.
      what: The field name, for diagnostics.

    Returns:
      The field value.
    """
    if hash(field[0]) >= 128:
        v = hash(field[0]) - 128
        for c in field[1:].elems():
            v = v * 256 + hash(c)
        return v
    text = _cut_nul(field).strip(" ")
    if text == "":
        return 0
    v = 0
    for c in text.elems():
        d = hash(c) - hash("0")
        if d < 0 or d > 7:
            fail(_scan_error(package_name, "an entry's %s is not a number" % what))
        v = v * 8 + d
    return v

def _parse_tar_header(block, package_name):
    """Parses one 512-byte tar header block.

    Joins `prefix` and `name` the way the extractor does, so over-long paths
    classify under their full name. An empty name fails closed.

    Args:
      block: The 512-byte header string.
      package_name: The pub package being scanned, for diagnostics.

    Returns:
      A `struct(name, size, typeflag, linkname)` entry header.
    """
    name = _cut_nul(block[0:100])
    prefix = _cut_nul(block[345:500])
    if prefix != "":
        name = prefix + "/" + name
    if name == "":
        fail(_scan_error(package_name, "an entry has no name"))
    return struct(
        name = name,
        size = _parse_tar_number(block[124:136], package_name, "size"),
        typeflag = block[156:157],
        linkname = _cut_nul(block[157:257]),
    )

def _pending_value(header_value, pending, global_value):
    """Resolves one entry field across its override sources.

    A GNU long-name/long-link record or a pax `path=`/`linkpath=` record set
    for this entry wins; otherwise a pax global record wins; otherwise the
    header field stands.

    Args:
      header_value: The header field.
      pending: This entry's override, or None.
      global_value: The pax global override, or None.

    Returns:
      The effective value.
    """
    if pending != None:
        return pending
    if global_value != None:
        return global_value
    return header_value

def _parse_pax_records(text, package_name):
    """Parses pax record data into its scan-relevant records. Pure.

    Only `path=`, `linkpath=` and `size=` affect the scan; the rest are
    ignored. A malformed record fails closed.

    Args:
      text: The record data string.
      package_name: The pub package being scanned, for diagnostics.

    Returns:
      A `struct(path, linkpath, size)` of overrides (each None when absent).
    """
    path = None
    linkpath = None
    size = None
    for line in text.split("\n"):
        if line == "":
            continue
        _length, sep, record = line.partition(" ")
        if sep == "":
            fail(_scan_error(package_name, "a pax record has no length prefix"))
        name, sep, val = record.partition("=")
        if sep == "":
            fail(_scan_error(package_name, "a pax record has no key"))
        if name == "path":
            path = val
        elif name == "linkpath":
            linkpath = val
        elif name == "size":
            digits = val.strip(" ")
            v = 0
            for c in digits.elems():
                d = hash(c) - hash("0")
                if d < 0 or d > 9:
                    fail(_scan_error(package_name, "a pax size is not a number"))
                v = v * 10 + d
            size = v
    return struct(path = path, linkpath = linkpath, size = size)

def _apply_pax_records(s, kind, text, package_name):
    """Merges parsed pax records into the pending name state.

    Global records (`g`) persist for every later entry; extended records
    (`x`) apply to the next entry only, with `size=` replacing its data
    length. The caller passes the record kind because `pax_kind` is already
    cleared by the time the collected data arrives.

    Args:
      s: The scan state.
      kind: The record kind (`x` or `g`).
      text: The record data string.
      package_name: The pub package being scanned, for diagnostics.
    """
    recs = _parse_pax_records(text, package_name)
    if kind == "g":
        if recs.path != None:
            s["gpath"] = recs.path
        if recs.linkpath != None:
            s["glinkpath"] = recs.linkpath
    else:
        s["ppath"] = recs.path
        s["plinkpath"] = recs.linkpath
        s["psize"] = recs.size

def _tar_data_size(s, header):
    """Returns the data length the tar consumer skips or collects.

    A pax `size=` override replaces the header size for the next entry only.

    Args:
      s: The scan state.
      header: The parsed entry header.

    Returns:
      The data byte count.
    """
    if s["psize"] != None:
        size = s["psize"]
        s["psize"] = None
        return size
    return header.size

def _tar_clear_pending(s):
    """Drops this entry's name records after it is classified.

    Args:
      s: The scan state.
    """
    s["pname"] = None
    s["plink"] = None
    s["ppath"] = None
    s["plinkpath"] = None

def _tar_finish_data(s, package_name, text):
    """Applies collected long-name, long-link and pax record data.

    GNU data is NUL-terminated text for the next entry's name (`L`) or
    target (`K`); pax data merges into the pending records. Which one
    applies rode in `pax_kind`.

    Args:
      s: The scan state.
      package_name: The pub package being scanned, for diagnostics.
      text: The collected data string.
    """
    kind = s["pax_kind"]
    s["pax_kind"] = ""
    if kind == "x" or kind == "g":
        _apply_pax_records(s, kind, text, package_name)
        return
    if kind == "K":
        s["plink"] = _cut_nul(text)
    else:
        s["pname"] = _cut_nul(text)

def _tar_skip_data(s, header):
    """Points the consumer past one entry's data by counter.

    Data is 512-padded, so the skip covers the padding too and the consumer
    lands exactly on the next header.

    Args:
      s: The scan state.
      header: The parsed entry header.
    """
    size = _tar_data_size(s, header)
    skip = size + ((-size) % 512)
    if skip == 0:
        s["tmode"] = "hdr"
        s["tneed"] = 512
    else:
        s["tmode"] = "skip"
        s["tneed"] = skip

def _tar_collect_data(s, package_name, header, kind):
    """Points the consumer at one name record's data for collection.

    Args:
      s: The scan state.
      package_name: The pub package being scanned, for diagnostics.
      header: The parsed entry header.
      kind: The record kind (`L`, `K`, `x` or `g`).
    """
    size = _tar_data_size(s, header)
    if size > _MAX_COLLECT_BYTES:
        fail(_scan_error(package_name, "a name record is too long to scan"))
    s["pax_kind"] = kind
    if size == 0:
        _tar_finish_data(s, package_name, "")
        s["tmode"] = "hdr"
        s["tneed"] = 512
    else:
        s["tmode"] = "data"
        s["tneed"] = size

def _tar_finish_header(s, package_name, block):
    """Classifies one streamed header and arms the consumer for its data.

    Resolves the entry name and target across GNU and pax overrides, refuses
    hard-link entries and escaping symlinks, stores name records for the
    next entry, and points the consumer at the data (skipped by counter for
    files, collected for name records). The zero block ends the archive;
    sparse and unknown kinds fail closed.

    Args:
      s: The scan state.
      package_name: The pub package being scanned, for diagnostics.
      block: The 512-byte header string.
    """
    if block == _ZERO_BLOCK:
        s["tmode"] = "done"
        return
    header = _parse_tar_header(block, package_name)
    kind = header.typeflag
    if kind == "\0":
        kind = "0"
    name = _pending_value(header.name, s["pname"] if s["ppath"] == None else s["ppath"], s["gpath"])
    if kind == "1" or kind == "2":
        target = _pending_value(header.linkname, s["plink"] if s["plinkpath"] == None else s["plinkpath"], s["glinkpath"])
        refusal = classify_archive_entry(name, kind, target)
        _tar_clear_pending(s)
        if refusal != None:
            s["refusal"] = refusal
            s["tmode"] = "done"
        else:
            _tar_skip_data(s, header)
        return
    _tar_clear_pending(s)
    if kind == "L" or kind == "K" or kind == "x" or kind == "g":
        _tar_collect_data(s, package_name, header, kind)
    elif kind == "0" or kind == "5" or kind == "D" or kind == "3" or kind == "4" or kind == "6":
        _tar_skip_data(s, header)
    elif kind == "S":
        fail(_scan_error(package_name, "a sparse entry cannot be scanned"))
    else:
        fail(_scan_error(package_name, "an entry has kind %r, which cannot be scanned" % kind))

def _gzip_member_trailer(s, package_name):
    """Consumes one gzip member's trailer, checking the inflated size.

    The CRC32 is not re-verified (the lock's sha256 pins every byte); the
    ISIZE size check catches truncation, which the tar end marker can miss
    when the stream is cut exactly at a block boundary.

    Args:
      s: The scan state.
      package_name: The pub package being scanned, for diagnostics.
    """
    if s["p"] + 8 > s["n"]:
        fail(_scan_error(package_name, "a gzip member is truncated"))
    isize = hash(s["d"][s["p"] + 4]) + hash(s["d"][s["p"] + 5]) * 256 + hash(s["d"][s["p"] + 6]) * 65536 + hash(s["d"][s["p"] + 7]) * 16777216
    s["p"] = s["p"] + 8
    if s["member_out"] % 4294967296 != isize:
        fail(_scan_error(package_name, "a gzip member's size check fails"))

def _gzip_skip_name(s, package_name):
    """Skips one NUL-terminated gzip header string (name or comment).

    Args:
      s: The scan state.
      package_name: The pub package being scanned, for diagnostics.
    """
    for _ in range(s["n"] - s["p"] + 1):
        if s["p"] >= s["n"]:
            fail(_scan_error(package_name, "a gzip header is truncated"))
        if hash(s["d"][s["p"]]) == 0:
            s["p"] = s["p"] + 1
            return
        s["p"] = s["p"] + 1
    fail(_scan_error(package_name, "a gzip header is truncated"))

def _scan_gzip_member(s, package_name):
    """Scans one gzip member: framing, deflate blocks, trailer.

    Parses the RFC 1952 header (extra field, name, comment and header CRC
    are skipped), inflates every block through the tar consumer, then checks
    the trailer. Stops early once a refusal is recorded.

    Args:
      s: The scan state positioned at the member magic.
      package_name: The pub package being scanned, for diagnostics.
    """
    if s["p"] + 10 > s["n"]:
        fail(_scan_error(package_name, "a gzip member is truncated"))
    if hash(s["d"][s["p"]]) != 31 or hash(s["d"][s["p"] + 1]) != 139 or hash(s["d"][s["p"] + 2]) != 8:
        fail(_scan_error(package_name, "a gzip member has a bad header"))
    flags = hash(s["d"][s["p"] + 3])
    s["p"] = s["p"] + 10
    if flags & 4:
        if s["p"] + 2 > s["n"]:
            fail(_scan_error(package_name, "a gzip header is truncated"))
        xlen = hash(s["d"][s["p"]]) + hash(s["d"][s["p"] + 1]) * 256
        s["p"] = s["p"] + 2
        if s["p"] + xlen > s["n"]:
            fail(_scan_error(package_name, "a gzip header is truncated"))
        s["p"] = s["p"] + xlen
    if flags & 8:
        _gzip_skip_name(s, package_name)
    if flags & 16:
        _gzip_skip_name(s, package_name)
    if flags & 2:
        if s["p"] + 2 > s["n"]:
            fail(_scan_error(package_name, "a gzip header is truncated"))
        s["p"] = s["p"] + 2
    s["bb"] = 0
    s["bc"] = 0
    s["member_out"] = 0
    _inflate_member_blocks(s, package_name)
    if s["refusal"] != None:
        return
    _gzip_member_trailer(s, package_name)

def _scan_plain_tar(data, package_name):
    """Scans an uncompressed tar archive by header offsets. Pure.

    Without a deflate layer every header sits at a computable offset, so the
    walk jumps from header to header and never touches file data — unlike
    the streaming path, which decodes every byte. Name records slice out of
    the input and apply through the same pending state the streamed path
    threads through its scan state.

    Args:
      data: Raw tar bytes as an ISO-8859-1 Starlark string.
      package_name: The pub package being scanned, for diagnostics.

    Returns:
      A `struct(kind, path, target)` refusal, or None when clean.
    """
    pos = 0
    n = len(data)
    pending = {
        "pname": None,
        "plink": None,
        "ppath": None,
        "plinkpath": None,
        "psize": None,
        "gpath": None,
        "glinkpath": None,
    }
    for _ in range(n // 512 + 2):
        if pos + 512 > n:
            fail(_scan_error(package_name, "the tar archive is truncated"))
        block = data[pos:pos + 512]
        if block == _ZERO_BLOCK:
            return None
        header = _parse_tar_header(block, package_name)
        kind = header.typeflag
        if kind == "\0":
            kind = "0"
        if pending["psize"] != None:
            size = pending["psize"]
            pending["psize"] = None
        else:
            size = header.size
        pos = pos + 512
        if kind == "1" or kind == "2":
            refusal = classify_archive_entry(
                _pending_value(header.name, pending["pname"] if pending["ppath"] == None else pending["ppath"], pending["gpath"]),
                kind,
                _pending_value(header.linkname, pending["plink"] if pending["plinkpath"] == None else pending["plinkpath"], pending["glinkpath"]),
            )
            pending["pname"] = None
            pending["plink"] = None
            pending["ppath"] = None
            pending["plinkpath"] = None
            if refusal != None:
                return refusal
        elif kind == "L" or kind == "K" or kind == "x" or kind == "g":
            if pos + size > n:
                fail(_scan_error(package_name, "the tar archive is truncated"))
            if size > _MAX_COLLECT_BYTES:
                fail(_scan_error(package_name, "a name record is too long to scan"))
            text = data[pos:pos + size] if size > 0 else ""
            if kind == "L":
                pending["pname"] = _cut_nul(text)
            elif kind == "K":
                pending["plink"] = _cut_nul(text)
            else:
                recs = _parse_pax_records(text, package_name)
                if kind == "g":
                    if recs.path != None:
                        pending["gpath"] = recs.path
                    if recs.linkpath != None:
                        pending["glinkpath"] = recs.linkpath
                else:
                    pending["ppath"] = recs.path
                    pending["plinkpath"] = recs.linkpath
                    pending["psize"] = recs.size
        elif kind == "0" or kind == "5" or kind == "D" or kind == "3" or kind == "4" or kind == "6":
            pending["pname"] = None
            pending["plink"] = None
            pending["ppath"] = None
            pending["plinkpath"] = None
        elif kind == "S":
            fail(_scan_error(package_name, "a sparse entry cannot be scanned"))
        else:
            fail(_scan_error(package_name, "an entry has kind %r, which cannot be scanned" % kind))
        pos = pos + size + ((-size) % 512)
    fail(_scan_error(package_name, "the tar archive never terminates"))

def scan_archive_bytes(data, package_name):
    """Scans archive bytes for refused entries. Pure over the bytes.

    Sniffs the framing — gzip members (inflated through the tar consumer in
    one linear pass) or a plain tar (walked by header offsets) — and returns
    the first refusal: every hard-link entry whatever its target, and every
    symlink entry whose target is absolute or climbs out of the package
    root. Returns None for a clean archive. Corrupt or unscannable archives
    fail, as do trailing bytes past the last gzip member that are not NUL
    padding.

    Args:
      data: Raw archive bytes as an ISO-8859-1 Starlark string.
      package_name: The pub package the archive was fetched for.

    Returns:
      A `struct(kind, path, target)` refusal, or None when clean.
    """
    if data == "":
        fail(_scan_error(package_name, "the archive is empty"))
    if len(data) >= 2 and hash(data[0]) == 31 and hash(data[1]) == 139:
        s = _new_scan_state(data)
        for _ in range(s["n"] + 2):
            _scan_gzip_member(s, package_name)
            if s["refusal"] != None:
                return s["refusal"]
            for _ in range(s["n"] - s["p"] + 1):
                if s["p"] >= s["n"]:
                    break
                if hash(s["d"][s["p"]]) != 0:
                    break
                s["p"] = s["p"] + 1
            if s["p"] >= s["n"]:
                return None
        fail(_scan_error(package_name, "trailing bytes follow the last gzip member"))
    return _scan_plain_tar(data, package_name)

def refuse_archive_bytes(data, package_name):
    """Fails the fetch when archive bytes hold a refused entry.

    Thin failure wrapper over `scan_archive_bytes` for the fetch call sites:
    hosted spokes, git spokes, merged-cycle members, `pub.package()` repos,
    and the module extension's cycle-planning scratch all call this between
    fetching the archive and extracting it.

    Args:
      data: Raw archive bytes as an ISO-8859-1 Starlark string.
      package_name: The pub package the archive was fetched for.
    """
    refusal = scan_archive_bytes(data, package_name)
    if refusal != None:
        fail(archive_entry_error(package_name, refusal.path, refusal.kind, refusal.target))

# Fixed-block decoders (RFC 1951 section 3.2.6), built once at load: literals
# 0-143 take 8 bits, 144-255 take 9, 256-279 take 7, 280-287 take 8, and every
# distance takes 5.
_FIXED_LIT = _huffman_build([8] * 144 + [9] * 112 + [7] * 24 + [8] * 8, "pub archive scan")
_FIXED_DIST = _huffman_build([5] * 32, "pub archive scan")
