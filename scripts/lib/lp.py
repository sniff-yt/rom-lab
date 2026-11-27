#!/usr/bin/env python3
"""Tiny reader/writer for Android dynamic partition ("super") metadata.

Handles the liblp on-disk format (metadata v10.x) well enough to:
  info     <super.img>                      list partitions, sizes, free space
  extract  <super.img> <name> <out.img>     copy one logical partition out
  replace  <super.img> <name> <in.img>      write it back (grows/shrinks extents)

Only "linear" extents on block device 0 are supported (what Google's
emulator and GSI-style super images use). The super image must be a raw
(non-sparse) image. All metadata slots (primary + backup) are rewritten.
"""
import hashlib
import struct
import sys

SECTOR = 512
RESERVED = 4096
GEOM_MAGIC = 0x616C4467
HDR_MAGIC = 0x414C5030
TARGET_LINEAR = 0
TARGET_ZERO = 1

GEOM_FMT = "<II32sIII"          # magic, struct_size, checksum, max, slots, block
TABLE_DESC = "<III"             # offset, num_entries, entry_size
PART_FMT = "<36sIIII"            # name, attrs, first_extent, num_extents, group
EXT_FMT = "<QIQI"               # num_sectors, target_type, target_data, target_source
GROUP_FMT = "<36sIQ"            # name, flags, maximum_size
BDEV_FMT = "<QIIQ36sI"          # first_logical_sector, alignment, align_off, size, name, flags


def die(msg):
    sys.stderr.write("lp.py: " + msg + "\n")
    sys.exit(1)


class Super:
    def __init__(self, path):
        self.path = path
        with open(path, "rb") as f:
            f.seek(RESERVED)
            g = f.read(4096)
        magic, ssize, _cs, mmax, slots, lbs = struct.unpack_from(GEOM_FMT, g)
        if magic != GEOM_MAGIC:
            die("%s: no super geometry magic (not a raw super image?)" % path)
        self.geom_size = ssize
        self.metadata_max = mmax
        self.slots = slots
        self.block_size = lbs
        self._read_metadata()

    def slot_offsets(self):
        base = RESERVED + 2 * 4096
        prim = [base + i * self.metadata_max for i in range(self.slots)]
        back = [base + self.slots * self.metadata_max + i * self.metadata_max
                for i in range(self.slots)]
        return prim + back

    def _read_metadata(self):
        with open(self.path, "rb") as f:
            f.seek(self.slot_offsets()[0])
            raw = f.read(self.metadata_max)
        magic, major, minor, hsize = struct.unpack_from("<IHHI", raw, 0)
        if magic != HDR_MAGIC:
            die("bad metadata header magic")
        self.major, self.minor, self.hsize = major, minor, hsize
        self.header = bytearray(raw[:hsize])
        tables_size = struct.unpack_from("<I", raw, 44)[0]
        tables = raw[hsize:hsize + tables_size]
        descs = []
        off = 80
        for _ in range(4):
            descs.append(struct.unpack_from(TABLE_DESC, raw, off))
            off += 12
        self.descs = descs

        def table(i, fmt):
            o, n, es = descs[i]
            return [list(struct.unpack_from(fmt, tables, o + k * es)) for k in range(n)]

        self.parts = table(0, PART_FMT)
        self.extents = table(1, EXT_FMT)
        self.groups = table(2, GROUP_FMT)
        self.bdevs = table(3, BDEV_FMT)
        self.entry_sizes = [d[2] for d in descs]

    # --- helpers -------------------------------------------------------
    @staticmethod
    def _name(b):
        return b.split(b"\0", 1)[0].decode()

    def find(self, name):
        for i, p in enumerate(self.parts):
            if self._name(p[0]) == name:
                return i
        die("partition %r not found (have: %s)" % (
            name, ", ".join(self._name(p[0]) for p in self.parts)))
        return -1

    def part_extents(self, idx):
        p = self.parts[idx]
        return self.extents[p[2]:p[2] + p[3]]

    def part_size(self, idx):
        return sum(e[0] for e in self.part_extents(idx)) * SECTOR

    def used_ranges(self, skip=None):
        r = []
        for i in range(len(self.parts)):
            if i == skip:
                continue
            for e in self.part_extents(i):
                if e[1] == TARGET_LINEAR:
                    r.append((e[2], e[2] + e[0]))
        return sorted(r)

    def free_ranges(self, skip=None):
        bd = self.bdevs[0]
        first, align, size = bd[0], max(bd[1], self.block_size), bd[3]
        align_s = align // SECTOR
        end = size // SECTOR
        out = []
        cur = first
        for a, b in self.used_ranges(skip) + [(end, end)]:
            start = -(-cur // align_s) * align_s
            if a > start:
                out.append((start, a))
            cur = max(cur, b)
        return out

    # --- commands ------------------------------------------------------
    def info(self):
        print("metadata v%d.%d, slots=%d, metadata_max=%d, block=%d" % (
            self.major, self.minor, self.slots, self.metadata_max, self.block_size))
        print("super size: %d" % self.bdevs[0][3])
        for g in self.groups:
            print("group %-28s max=%d" % (self._name(g[0]), g[2]))
        for i, p in enumerate(self.parts):
            exts = self.part_extents(i)
            print("part  %-28s size=%-12d group=%s extents=%s" % (
                self._name(p[0]), self.part_size(i), self._name(self.groups[p[4]][0]),
                [(e[2], e[0]) for e in exts]))
        free = sum(b - a for a, b in self.free_ranges()) * SECTOR
        print("free: %d bytes" % free)

    def extract(self, name, out):
        idx = self.find(name)
        with open(self.path, "rb") as src, open(out, "wb") as dst:
            for e in self.part_extents(idx):
                n = e[0] * SECTOR
                if e[1] == TARGET_ZERO:
                    dst.write(b"\0" * n)
                    continue
                if e[3] != 0:
                    die("extent on block device %d not supported" % e[3])
                src.seek(e[2] * SECTOR)
                while n:
                    chunk = src.read(min(n, 1 << 22))
                    if not chunk:
                        die("short read")
                    dst.write(chunk)
                    n -= len(chunk)

    def replace(self, name, inp):
        import os
        idx = self.find(name)
        size = os.path.getsize(inp)
        if size % SECTOR:
            die("input size %d is not sector aligned" % size)
        need = size // SECTOR
        # Group limit check.
        gi = self.parts[idx][4]
        gmax = self.groups[gi][2]
        if gmax:
            used = sum(self.part_size(i) for i, p in enumerate(self.parts)
                       if p[4] == gi and i != idx)
            if used + size > gmax:
                die("group %s would exceed its max size (%d > %d)" % (
                    self._name(self.groups[gi][0]), used + size, gmax))
        # Reuse the partition's own extents first, then free space.
        new_exts = []
        remaining = need
        for e in self.part_extents(idx):
            if remaining == 0:
                break
            if e[1] != TARGET_LINEAR:
                continue
            take = min(e[0], remaining)
            new_exts.append([take, TARGET_LINEAR, e[2], 0])
            remaining -= take
        if remaining:
            mine = sorted((e[2], e[2] + e[0]) for e in new_exts)
            for a, b in self.free_ranges(skip=idx):
                # carve out ranges already used by our own kept extents
                segs = [(a, b)]
                for ma, mb in mine:
                    nxt = []
                    for sa, sb in segs:
                        if mb <= sa or ma >= sb:
                            nxt.append((sa, sb))
                        else:
                            if sa < ma:
                                nxt.append((sa, ma))
                            if mb < sb:
                                nxt.append((mb, sb))
                    segs = nxt
                for sa, sb in segs:
                    if remaining == 0:
                        break
                    take = min(sb - sa, remaining)
                    new_exts.append([take, TARGET_LINEAR, sa, 0])
                    remaining -= take
                if remaining == 0:
                    break
        if remaining:
            die("not enough free space in super for %s (%d more bytes needed)" % (
                name, remaining * SECTOR))
        # Rebuild extent table with this partition's extents replaced.
        ext_tbl = []
        for i, p in enumerate(self.parts):
            exts = new_exts if i == idx else self.part_extents(i)
            p[2] = len(ext_tbl)
            p[3] = len(exts)
            ext_tbl.extend(list(e) for e in exts)
        self.extents = ext_tbl
        # Write data.
        with open(inp, "rb") as src, open(self.path, "r+b") as dst:
            for e in new_exts:
                n = e[0] * SECTOR
                dst.seek(e[2] * SECTOR)
                while n:
                    chunk = src.read(min(n, 1 << 22))
                    dst.write(chunk)
                    n -= len(chunk)
        self._write_metadata()

    def _write_metadata(self):
        tables = bytearray()
        counts = [(self.parts, PART_FMT), (self.extents, EXT_FMT),
                  (self.groups, GROUP_FMT), (self.bdevs, BDEV_FMT)]
        hdr = bytearray(self.header)
        off = 80
        for (rows, fmt), es in zip(counts, self.entry_sizes):
            start = len(tables)
            for r in rows:
                ent = bytearray(es)
                struct.pack_into(fmt, ent, 0, *r)
                # keep any trailing bytes zero (fields we don't model are zero in practice)
                tables.extend(ent)
            struct.pack_into(TABLE_DESC, hdr, off, start, len(rows), es)
            off += 12
        if self.hsize + len(tables) > self.metadata_max:
            die("metadata too large")
        struct.pack_into("<I", hdr, 44, len(tables))
        hdr[48:80] = hashlib.sha256(tables).digest()
        hdr[12:44] = b"\0" * 32
        hdr[12:44] = hashlib.sha256(bytes(hdr)).digest()
        blob = bytes(hdr) + bytes(tables)
        with open(self.path, "r+b") as f:
            for o in self.slot_offsets():
                f.seek(o)
                f.write(blob)
        self._read_metadata()


def main(argv):
    if len(argv) < 3:
        die(__doc__)
    cmd, path = argv[1], argv[2]
    s = Super(path)
    if cmd == "info":
        s.info()
    elif cmd == "extract" and len(argv) == 5:
        s.extract(argv[3], argv[4])
    elif cmd == "replace" and len(argv) == 5:
        s.replace(argv[3], argv[4])
    elif cmd == "size" and len(argv) == 4:
        print(s.part_size(s.find(argv[3])))
    elif cmd == "free":
        print(sum(b - a for a, b in s.free_ranges()) * SECTOR)
    else:
        die(__doc__)


if __name__ == "__main__":
    main(sys.argv)
