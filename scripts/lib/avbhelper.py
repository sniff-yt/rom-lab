#!/usr/bin/env python3
"""Small AVB helpers built on the vendored avbtool.py (same folder).

  footer-env   <img>                 shell vars describing the AVB footer (or AVB_FOOTER=0)
  footer-props <img>                 one "key:value" per line from the footer's prop descriptors
  resign-vbmeta <orig_vbmeta> <new_part_img> <key.pem> <out> [partition]
        Rebuild a top-level vbmeta image: keeps every descriptor of the
        original, but points the chain descriptor (or hashtree/hash
        descriptor) for <partition> (default "system") at the new image,
        then signs the result with <key.pem>.
  digest <vbmeta> <new_part_img> [partition]
        Prints "<total_size> <sha256>" over the top-level vbmeta plus any
        chained vbmeta (what goes into androidboot.vbmeta.size/digest).
"""
import hashlib
import os
import shlex
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import avbtool  # noqa: E402  (vendored, pinned copy)


def die(msg):
    sys.stderr.write("avbhelper: %s\n" % msg)
    sys.exit(1)


def parse(path):
    avb = avbtool.Avb()
    img = avbtool.ImageHandler(path, read_only=True)
    try:
        footer, header, descs, _ = avb._parse_image(img)  # pylint: disable=protected-access
    except avbtool.AvbError as e:
        return None, None, None, str(e)
    return footer, header, descs, None


def vbmeta_blob(path):
    footer, header, _, err = parse(path)
    if err:
        die("%s: %s" % (path, err))
    size = header.SIZE + header.authentication_data_block_size + header.auxiliary_data_block_size
    off = footer.vbmeta_offset if footer else 0
    with open(path, "rb") as f:
        f.seek(off)
        return f.read(size)


def footer_env(path):
    footer, header, descs, err = parse(path)
    if err or footer is None:
        print("AVB_FOOTER=0")
        return
    alg = avbtool.lookup_algorithm_by_type(header.algorithm_type)[0]
    out = {
        "AVB_FOOTER": "1",
        "AVB_ORIG_SIZE": str(footer.original_image_size),
        "AVB_ALGORITHM": alg,
        "AVB_ROLLBACK": str(header.rollback_index),
        "AVB_FLAGS": str(header.flags),
        "AVB_KIND": "none",
        "AVB_PARTITION": "system",
        "AVB_HASH_ALG": "sha256",
    }
    for d in descs:
        if isinstance(d, avbtool.AvbHashtreeDescriptor):
            out["AVB_KIND"] = "hashtree"
            out["AVB_PARTITION"] = d.partition_name
            out["AVB_HASH_ALG"] = d.hash_algorithm
            out["AVB_FEC"] = "1" if d.fec_num_roots else "0"
        elif isinstance(d, avbtool.AvbHashDescriptor):
            out["AVB_KIND"] = "hash"
            out["AVB_PARTITION"] = d.partition_name
            out["AVB_HASH_ALG"] = d.hash_algorithm
    for k, v in out.items():
        print("%s=%s" % (k, shlex.quote(v)))


def footer_props(path):
    _, _, descs, err = parse(path)
    if err or descs is None:
        return
    for d in descs:
        if isinstance(d, avbtool.AvbPropertyDescriptor):
            print("%s:%s" % (d.key, d.value.decode("utf-8", "replace")))


def resign_vbmeta(orig, new_img, key, out, part="system"):
    _, header, descs, err = parse(orig)
    if err:
        die("%s: %s" % (orig, err))
    _, _, new_descs, err = parse(new_img)
    if err:
        die("%s: %s" % (new_img, err))
    pub = avbtool.RSAPublicKey(key).encode()
    replaced = False
    result = []
    for d in descs:
        name = getattr(d, "partition_name", None)
        if name == part and isinstance(d, avbtool.AvbChainPartitionDescriptor):
            d.public_key = pub
            replaced = True
        elif name == part and isinstance(d, (avbtool.AvbHashtreeDescriptor, avbtool.AvbHashDescriptor)):
            match = [n for n in new_descs if type(n) is type(d) and n.partition_name == part]
            if not match:
                die("new image has no %s descriptor for %s" % (type(d).__name__, part))
            d = match[0]
            replaced = True
        result.append(d)
    if not replaced:
        die("original vbmeta has no descriptor for partition %s" % part)
    avb = avbtool.Avb()
    alg = "SHA256_RSA4096"
    blob = avb._generate_vbmeta_blob(  # pylint: disable=protected-access
        alg, key, None, result, None, None,
        header.rollback_index, header.flags, header.rollback_index_location,
        None, None, None, None, None, None, None, None,
        None, None, header.required_libavb_version_minor)
    with open(out, "wb") as f:
        f.write(blob)


def digest(vbmeta, new_img, part="system"):
    _, _, descs, err = parse(vbmeta)
    if err:
        die("%s: %s" % (vbmeta, err))
    blobs = [vbmeta_blob(vbmeta)]
    for d in descs:
        if isinstance(d, avbtool.AvbChainPartitionDescriptor):
            if d.partition_name != part:
                die("chained partition %s not supported" % d.partition_name)
            blobs.append(vbmeta_blob(new_img))
    h = hashlib.sha256()
    for b in blobs:
        h.update(b)
    print(sum(len(b) for b in blobs), h.hexdigest())


def main(a):
    if len(a) < 3:
        die(__doc__)
    cmd = a[1]
    if cmd == "footer-env":
        footer_env(a[2])
    elif cmd == "footer-props":
        footer_props(a[2])
    elif cmd == "resign-vbmeta" and len(a) in (6, 7):
        resign_vbmeta(*a[2:])
    elif cmd == "digest" and len(a) in (4, 5):
        digest(*a[2:])
    else:
        die(__doc__)


if __name__ == "__main__":
    main(sys.argv)
