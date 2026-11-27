#!/usr/bin/env python3
"""极小的 TOML 读取器，给 bash 流水线用。

为什么不用 shell 直接 source 配置：`.toml` 里的字符串、数组、布尔值语法
和 bash 不一样（`a = ["x", "y"]` 直接 source 会炸），而且把配置当代码执行
是隐性的 RCE 面。这里只读、只输出值。

用法：
    cfg.py get  <file.toml> <dotted.key> [default]
    cfg.py env  <file.toml> [prefix]        # 输出 KEY="value" 行，供 eval
    cfg.py list <file.toml> <table> <field> # 打印数组元素/子表某字段
"""
import json
import shlex
import sys
import tomllib


def load(path):
    with open(path, "rb") as fh:
        return tomllib.load(fh)


def dig(data, key):
    cur = data
    for part in key.split("."):
        if isinstance(cur, dict) and part in cur:
            cur = cur[part]
        elif isinstance(cur, list) and part.isdigit() and int(part) < len(cur):
            cur = cur[int(part)]
        else:
            raise KeyError(key)
    return cur


def to_shell(value):
    if isinstance(value, bool):
        return "1" if value else "0"
    if isinstance(value, list):
        return " ".join(str(v) for v in value)
    if isinstance(value, dict):
        return json.dumps(value, ensure_ascii=False, sort_keys=True)
    return str(value)


def cmd_get(argv):
    path, key = argv[0], argv[1]
    default = argv[2] if len(argv) > 2 else ""
    try:
        print(to_shell(dig(load(path), key)))
    except KeyError:
        if default == "":
            sys.exit(0)
        print(default)


def cmd_env(argv):
    path = argv[0]
    prefix = argv[1] if len(argv) > 1 else "CFG_"
    flat = {}

    def walk(node, trail):
        if isinstance(node, dict):
            for k, v in node.items():
                walk(v, trail + [str(k)])
        else:
            flat[prefix + "_".join(trail).replace("-", "_")] = to_shell(node)

    walk(load(path), [])
    for k, v in flat.items():
        print(f"{k}={shlex.quote(v)}")


def cmd_list(argv):
    path, table, field = argv[0], argv[1], argv[2]
    data = load(path)
    rows = dig(data, table)
    if isinstance(rows, dict):
        rows = [rows]
    for row in rows:
        print(to_shell(row.get(field, "")))


def main(argv):
    if not argv:
        print(__doc__)
        return 2
    cmd, rest = argv[0], argv[1:]
    try:
        {"get": cmd_get, "env": cmd_env, "list": cmd_list}[cmd](rest)
    except KeyError as exc:
        print(f"cfg.py: 缺少键 {exc}", file=sys.stderr)
        return 1
    except FileNotFoundError as exc:
        print(f"cfg.py: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
