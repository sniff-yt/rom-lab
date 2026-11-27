#!/usr/bin/env python3
"""List partitions of a GPT disk image: prints "<name> <offset_bytes> <size_bytes>".

Usage: gpt.py list <disk.img>        (exit 1 if the file is not a GPT disk)
       gpt.py find <disk.img> <name> (prints "<offset_bytes> <size_bytes>")
"""
import struct
import sys

SECTOR = 512


def parts(path):
    with open(path, "rb") as f:
        f.seek(SECTOR)
        hdr = f.read(92)
        if hdr[:8] != b"EFI PART":
            return None
        entries_lba, num, esize = struct.unpack_from("<QII", hdr, 72)
        f.seek(entries_lba * SECTOR)
        raw = f.read(num * esize)
    out = []
    for i in range(num):
        e = raw[i * esize:(i + 1) * esize]
        if e[:16] == b"\0" * 16:
            continue
        first, last = struct.unpack_from("<QQ", e, 32)
        name = e[56:128].decode("utf-16-le").split("\0", 1)[0]
        out.append((name, first * SECTOR, (last - first + 1) * SECTOR))
    return out


def main(a):
    if len(a) < 3:
        sys.exit(__doc__)
    p = parts(a[2])
    if p is None:
        sys.exit(1)
    if a[1] == "list":
        for n, o, s in p:
            print(n, o, s)
    elif a[1] == "find" and len(a) == 4:
        for n, o, s in p:
            if n == a[3]:
                print(o, s)
                return
        sys.exit("gpt.py: partition %s not found" % a[3])
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv)
