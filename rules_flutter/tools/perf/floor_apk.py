"""In-place entry replacement inside an APK, for the toolchain floor.

Unchanged entries are copied as raw bytes: nothing is recompressed and
nothing is realigned, so their alignment (and the page alignment of the
stored ``.so`` files) survives. The replaced entry is written after them,
aligned, and the central directory is rewritten without the old entry.
The old entry's bytes stay behind as dead space (a rewrite that closed the
gap would shift, and so realign, every later entry). Any v2 signing block
is dropped: the re-sign adds it back.
"""

import struct
import zipfile
import zlib

PAGE = 16384
_LOCAL = struct.Struct("<4s5H3I2H")
_CENTRAL = struct.Struct("<4s6H3I5H2I")


def _dos_time(info):
    year, month, day, hour, minute, second = info.date_time
    return ((hour << 11) | (minute << 5) | (second // 2),
            ((year - 1980) << 9) | (month << 5) | day)


def _raw_span(data, info):
    """(start, end) of an entry's local header plus data in the file."""
    fields = _LOCAL.unpack_from(data, info.header_offset)
    start = info.header_offset
    end = start + _LOCAL.size + fields[9] + fields[10] + info.compress_size
    if info.flag_bits & 0x08:
        end += 16
    return start, end


def _new_entry(info, payload, offset):
    """Local header + data for the replacement; stored data is aligned."""
    stored = info.compress_type == zipfile.ZIP_STORED
    body = payload if stored else zlib.compress(payload, 6)[2:-4]
    name = info.filename.encode("utf-8")
    pad = 0
    if stored:
        align = PAGE if name.endswith(b".so") else 4
        pad = (-(offset + _LOCAL.size + len(name))) % align
    mtime, mdate = _dos_time(info)
    crc = zlib.crc32(payload) & 0xFFFFFFFF
    header = _LOCAL.pack(b"PK\x03\x04", 20, 0, info.compress_type, mtime,
                         mdate, crc, len(body), len(payload), len(name), pad)
    return (header + name + b"\0" * pad + body, crc, len(body),
            len(payload))


def _central_record(info, offset, new=None):
    crc, csize, usize = info.CRC, info.compress_size, info.file_size
    if new is not None:
        crc, csize, usize = new
    mtime, mdate = _dos_time(info)
    name = info.filename.encode("utf-8")
    return _CENTRAL.pack(
        b"PK\x01\x02", info.create_version, info.extract_version,
        info.flag_bits & ~0x08 if new else info.flag_bits,
        info.compress_type, mtime, mdate, crc, csize, usize, len(name),
        len(info.extra), len(info.comment), 0, info.internal_attr,
        info.external_attr, offset) + name + info.extra + info.comment


def replace_entry(apk, name, payload):
    """Replaces entry ``name`` of ``apk`` with ``payload`` in place."""
    with open(apk, "rb") as fh:
        data = fh.read()
    with zipfile.ZipFile(apk) as archive:
        infos = archive.infolist()
    target = [info for info in infos if info.filename == name]
    if not target:
        raise KeyError("APK has no entry %s" % name)
    kept = [info for info in infos if info.filename != name]
    # Keep the original local entries in place and append the new one.
    out = bytearray(data[:max(_raw_span(data, i)[1] for i in infos)])
    central = [_central_record(i, i.header_offset) for i in kept]
    entry, *sizes = _new_entry(target[0], payload, len(out))
    central.append(_central_record(target[0], len(out), tuple(sizes)))
    out += entry
    directory = b"".join(central)
    eocd = struct.pack("<4s4H2IH", b"PK\x05\x06", 0, 0, len(central),
                       len(central), len(directory), len(out), 0)
    with open(apk, "wb") as fh:
        fh.write(bytes(out) + directory + eocd)


def entry_names(apk):
    """Entry names of an APK/zip, in central directory order."""
    with zipfile.ZipFile(apk) as archive:
        return archive.namelist()
