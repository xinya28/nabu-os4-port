#!/usr/bin/env python3
"""把 pkgscan.py 的清单和待删清单求交集，产出可直接被 bash 消费的 TSV。

    matchpkg.py --json system.pkgs.json --wanted wanted.txt \
                --hits hits.tsv --misses misses.txt

hits.tsv 每行： <目录>\t<包名>\t<字节数>
misses.txt 每行：<包名>            （这份固件里没有的条目）

为什么删包这一步单独用 Python 做：包名和目录名不是一一对应的（同一份 system 里
`MiuiVideo` 目录可能对应 `com.miui.videoplayer`），用 awk/sed 拼字符串在真实固件上
很容易错配，而"错配"在这里的代价是删错 APK。
"""
import argparse
import json
import sys


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--json", required=True)
    ap.add_argument("--wanted", required=True)
    ap.add_argument("--hits", required=True)
    ap.add_argument("--misses", required=True)
    args = ap.parse_args()

    with open(args.json, encoding="utf-8") as fh:
        data = json.load(fh)
    by_pkg = {row["package"]: row for row in data.get("packages", [])}

    wanted = []
    seen = set()
    with open(args.wanted, encoding="utf-8") as fh:
        for line in fh:
            pkg = line.strip()
            if pkg and not pkg.startswith("#") and pkg not in seen:
                seen.add(pkg)
                wanted.append(pkg)

    hits, misses = [], []
    for pkg in wanted:
        row = by_pkg.get(pkg)
        if row is None:
            misses.append(pkg)
            continue
        hits.append((row["dir"], pkg, str(int(row.get("bytes") or 0))))

    with open(args.hits, "w", encoding="utf-8") as fh:
        for d, p, b in hits:
            fh.write(f"{d}\t{p}\t{b}\n")
    with open(args.misses, "w", encoding="utf-8") as fh:
        for p in misses:
            fh.write(p + "\n")

    total = sum(int(b) for _, _, b in hits)
    print(f"matchpkg: 命中 {len(hits)} / 待删 {len(wanted)}，"
          f"可回收 {total / 1024 / 1024:.1f} MiB", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
