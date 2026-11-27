#!/usr/bin/env python3
"""安全地改 build.prop。

    propset.py --file <build.prop> --table <nabu.prop> [--overwrite] [--dry-run]

用 Python 而不是 sed 的原因：属性值里可能出现 `|`、`&`、`\\1`（比如自定义
fingerprint），sed 的替换分隔符和反向引用会被这些字符搞坏，而 build.prop 写坏了
是"开机卡 Logo"级别的故障，不值得为了少一个文件去赌转义。

行为：
  * 表里的 key 已存在 → 按 --overwrite 决定替换还是跳过
  * 不存在 → 追加到文件末尾（保持原有顺序不动）
  * 输出被修改的 key，供调用方写报告
"""
import argparse
import os
import sys


def read_table(path):
    rows = []
    with open(path, encoding="utf-8") as fh:
        for raw in fh:
            line = raw.rstrip("\n")
            stripped = line.strip()
            if not stripped or stripped.startswith("#"):
                continue
            if "=" not in line:
                print(f"propset: 跳过无法解析的行: {line!r}", file=sys.stderr)
                continue
            key, _, value = line.partition("=")
            key = key.strip()
            if not key:
                print(f"propset: 空 key: {line!r}", file=sys.stderr)
                continue
            rows.append((key, value.rstrip("\r")))
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--file", required=True)
    ap.add_argument("--table", required=True)
    ap.add_argument("--overwrite", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--report", help="把结果写成 TSV: status<TAB>key<TAB>value")
    args = ap.parse_args()

    table = read_table(args.table)
    existing = {}
    lines = []
    if os.path.exists(args.file):
        with open(args.file, encoding="utf-8", errors="replace") as fh:
            for idx, raw in enumerate(fh):
                line = raw.rstrip("\n")
                lines.append(line)
                if "=" in line and not line.lstrip().startswith("#"):
                    k = line.split("=", 1)[0].strip()
                    existing.setdefault(k, idx)
    else:
        os.makedirs(os.path.dirname(os.path.abspath(args.file)), exist_ok=True)

    report = []
    appended = 0
    for key, value in table:
        new_line = f"{key}={value}"
        if key in existing:
            idx = existing[key]
            old = lines[idx]
            if old.strip() == new_line:
                report.append(("unchanged", key, value))
                continue
            if not args.overwrite:
                report.append(("skipped", key, value))
                continue
            lines[idx] = new_line
            report.append(("replaced", key, value))
        else:
            lines.append(new_line)
            appended += 1
            report.append(("appended", key, value))

    if args.report:
        with open(args.report, "w", encoding="utf-8") as fh:
            for status, key, value in report:
                fh.write(f"{status}\t{key}\t{value}\n")

    if not args.dry_run:
        with open(args.file, "w", encoding="utf-8") as fh:
            fh.write("\n".join(lines).rstrip("\n") + "\n")

    counts = {}
    for status, _, _ in report:
        counts[status] = counts.get(status, 0) + 1
    summary = " ".join(f"{k}={v}" for k, v in sorted(counts.items()))
    print(f"propset: {args.file} {summary}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
