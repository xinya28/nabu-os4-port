#!/usr/bin/env python3
"""扫描解包后的 system/product/system_ext，产出「包名 → 目录」清单。

为什么不用 `aapt`/`apkanalyzer`：CI 上装 Android SDK 要几个 G，而这里只需要
AndroidManifest.xml 里 `manifest/@package` 一个属性。二进制 XML（AXML）是
公开格式，自己解析 200 行就够了，顺便还不依赖 Java。

用法：
    pkgscan.py --root <解包目录> [--json out.json]
    pkgscan.py --list <解包目录>          # 只看 "包名<TAB>目录"

输出：
    {"root": "...", "count": N, "errors": M, "packages": [
        {"package": "com.miui.video", "dir": "system/app/MiuiVideo",
         "apk": "MiuiVideo.apk", "privapp": false, "split": null, "bytes": 123}, ...]}
"""
import argparse
import json
import os
import struct
import sys

RES_XML_TYPE = 0x0003
RES_STRING_POOL_TYPE = 0x0001
RES_XML_START_ELEMENT_TYPE = 0x0102
NO_ENTRY = 0xFFFFFFFF


def _len8(data, p):
    """AXML UTF-8 池里的长度域：1 或 2 字节。"""
    n = data[p]
    if n & 0x80:
        return ((n & 0x7F) << 8) | data[p + 1], p + 2
    return n, p + 1


def read_string_pool(data, base):
    _ctype, hsize, _csize = struct.unpack_from("<HHI", data, base)
    strcount, _stylecount, flags = struct.unpack_from("<III", data, base + 8)
    strstart = struct.unpack_from("<I", data, base + 16)[0]
    utf8 = bool(flags & 0x100)
    offsets = struct.unpack_from("<%dI" % strcount, data, base + hsize)
    out = []
    for off in offsets:
        p = base + strstart + off
        try:
            if utf8:
                _u16len, p = _len8(data, p)          # 先 utf-16 长度
                n, p = _len8(data, p)                # 再 utf-8 字节数
                out.append(data[p:p + n].decode("utf-8", "replace"))
            else:
                n, p = _len8(data, p)
                out.append(data[p:p + n * 2].decode("utf-16-le", "replace"))
        except (IndexError, struct.error):
            out.append("")
    return out


def parse_manifest_element(data, off, strings):
    """从 START_ELEMENT chunk 里取 name / package / split。"""
    try:
        (_t, hsize, _sz, _line, _cmt, _ns, name_idx,
         attr_start, attr_size, attr_count) = struct.unpack_from("<HHIIIIIIHH", data, off)
    except struct.error:
        return None

    name = strings[name_idx] if name_idx < len(strings) else ""
    # 第一个 START_ELEMENT 一定是 manifest
    if name != "manifest":
        return None

    pkg = split = None
    base = off + hsize + attr_start
    if attr_size < 20:
        return None
    for i in range(attr_count):
        p = base + i * attr_size
        try:
            _ans, aname, raw, _tsize, _res0, dtype, tdata = struct.unpack_from(
                "<IIIIHBBI", data, p)
        except struct.error:
            break
        an = strings[aname] if aname < len(strings) else ""
        if raw != NO_ENTRY and raw < len(strings):
            value = strings[raw]
        elif dtype == 0x03 and tdata < len(strings):   # TYPE_STRING
            value = strings[tdata]
        else:
            continue
        if an == "package":
            pkg = value
        elif an == "split":
            split = value
    return pkg, split


def read_manifest(apk_path):
    """直接读 APK 里的 AndroidManifest.xml，不落盘解压。"""
    with open(apk_path, "rb") as fh:
        data = fh.read(64 * 1024)      # manifest 通常在头部附近，64 KiB 足够
    if len(data) < 16:
        return None, None
    magic = data[0:4]
    if magic == b"PK\x03\x04":
        import zipfile
        try:
            with zipfile.ZipFile(apk_path) as zf:
                data = zf.read("AndroidManifest.xml")
        except (KeyError, OSError, Exception):  # noqa: BLE001 - 坏包直接跳过
            return None, None
    elif magic != b"\x03\x00\x08\x00":
        # 无文件头的旧式 AXML 少见，按偏移 0 试一次
        pass

    ctype, hsize, _csize = struct.unpack_from("<HHI", data, 0)
    if ctype != RES_XML_TYPE:
        return None, None
    off = hsize
    strings = []
    while off + 8 <= len(data):
        ctype, csize = struct.unpack_from("<HI", data, off)
        if csize == 0:
            break
        if ctype == RES_STRING_POOL_TYPE:
            strings = read_string_pool(data, off)
        elif ctype == RES_XML_START_ELEMENT_TYPE:
            if strings:
                return parse_manifest_element(data, off, strings)
            return None, None
        off += csize
    return None, None


def scan(root):
    rows = []
    errors = 0
    for dirpath, _dirnames, filenames in os.walk(root):
        apks = [f for f in filenames if f.endswith(".apk")]
        if not apks:
            continue
        rel = os.path.relpath(dirpath, root)
        # 优先取与目录同名的 apk（AOSP 布局），否则按名字排序取第一个
        apks.sort(key=lambda f: (os.path.splitext(f)[0] != os.path.basename(dirpath), f))
        for apk in apks[:1]:
            apk_path = os.path.join(dirpath, apk)
            try:
                pkg, split = read_manifest(apk_path)
            except (OSError, struct.error, ValueError):
                pkg, split = None, None
                errors += 1
            if not pkg:
                errors += 1
                continue
            rows.append({
                "package": pkg,
                "dir": rel,
                "apk": apk,
                "privapp": rel.startswith(("system/priv-app", "product/priv-app",
                                           "system_ext/priv-app", "priv-app")),
                "split": split,
                "bytes": os.path.getsize(apk_path),
            })
    rows.sort(key=lambda r: r["package"])
    return rows, errors


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", required=True)
    ap.add_argument("--json")
    ap.add_argument("--list", action="store_true")
    args = ap.parse_args()

    if not os.path.isdir(args.root):
        print(f"pkgscan: 不是目录 {args.root}", file=sys.stderr)
        return 1

    rows, errors = scan(args.root)

    if args.list:
        for r in rows:
            print(f"{r['package']}\t{r['dir']}")
        return 0

    payload = {"root": os.path.abspath(args.root), "count": len(rows),
               "errors": errors, "packages": rows}
    text = json.dumps(payload, ensure_ascii=False, indent=1)
    if args.json:
        with open(args.json, "w", encoding="utf-8") as fh:
            fh.write(text + "\n")
        print(f"pkgscan: {len(rows)} packages, {errors} unparsed → {args.json}",
              file=sys.stderr)
    else:
        print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
