#!/usr/bin/env bash
# shellcheck shell=bash
#
# 自检：不碰真机、不碰 ROM，验证"流水线自身的正确性"。
#
#   scripts/selftest.sh
#
# 覆盖：
#   1. 所有脚本 bash -n 语法检查；
#   2. 所有 Python 工具可编译；
#   3. 配置文件能被 cfg.py 正确读取（键名写错会在这里炸，而不是在 30 分钟后）；
#   4. propset.py 的替换/追加/跳过语义；
#   5. matchpkg.py 的交集计算；
#   6. mkfs.erofs → detect_fs → dump.erofs 的往返（需要 erofs-utils）；
#   7. 每个 stage 的 --help 不崩（能抓到 source 顺序之类的低级错误）。
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

stage_banner "selftest"
FAILED=0
step() { printf '\n%s== %s ==%s\n' "$_C_BLUE" "$1" "$_C_RESET" >&2; }
check() { if "$@"; then ok "pass"; else FAILED=$((FAILED + 1)); warn "FAIL"; fi; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 1. bash 语法
step "bash -n"
for f in "$REPO_ROOT"/scripts/*.sh "$REPO_ROOT"/kernel/scripts/*.sh; do
  [ -f "$f" ] || continue
  if bash -n "$f" 2>"$TMP/err"; then
    ok "$(basename "$f")"
  else
    FAILED=$((FAILED + 1))
    warn "$(basename "$f") 语法错误:"; sed 's/^/    /' "$TMP/err" >&2
  fi
done

# 2. python 可编译
step "python compile"
for f in "$REPO_ROOT"/tools/*.py; do
  if python3 -m py_compile "$f" 2>"$TMP/err"; then
    ok "$(basename "$f")"
  else
    FAILED=$((FAILED + 1)); warn "$(basename "$f") 编译失败:"; sed 's/^/    /' "$TMP/err" >&2
  fi
done

# 3. 配置读取
step "config keys"
check_config() {
  local file="$1" key="$2" want="$3"
  local got
  got="$(python3 "$REPO_ROOT/tools/cfg.py" get "$REPO_ROOT/$file" "$key" "__MISSING__")"
  if [ "$got" = "__MISSING__" ] || [ -z "$got" ]; then
    warn "  $file: $key 读不到"; return 1
  fi
  if [ -n "$want" ] && [ "$got" != "$want" ]; then
    warn "  $file: $key = '$got'，期望 '$want'"; return 1
  fi
  log "  $file: $key = $got"
}
check check_config config/target/nabu.toml device.codename nabu
check check_config config/target/nabu.toml boot.header_version 3
check check_config config/target/nabu.toml partitions.take "system product system_ext"
check check_config config/profiles.toml profile.balanced.tiers "safe balanced"
check check_config port/manifest.toml from_source.parts "system product system_ext"
check check_config kernel/source.toml source.default_branch nabu-w-oss-bks
check check_config kernel/source.toml modules.required_vermagic_prefix 4.14.180

# 4. propset 语义
step "propset"
cat > "$TMP/build.prop" <<'EOF'
ro.product.device=pad8
ro.build.characteristics=tablet
ro.existing=keepme
EOF
python3 "$REPO_ROOT/tools/propset.py" --file "$TMP/build.prop" \
  --table "$REPO_ROOT/port/props/nabu.prop" --overwrite --report "$TMP/p.tsv" 2>/dev/null
check grep -q '^ro.product.device=nabu$' "$TMP/build.prop"
check grep -q '^ro.existing=keepme$' "$TMP/build.prop"
check grep -q '^ro.vndk.version=33$' "$TMP/build.prop"
check grep -q $'^replaced\tro.product.device' "$TMP/p.tsv"

# 不 overwrite 时不能改已有值
cp "$TMP/build.prop" "$TMP/bp2"
printf 'ro.product.device=pad8\n' > "$TMP/bp2"
python3 "$REPO_ROOT/tools/propset.py" --file "$TMP/bp2" --table "$REPO_ROOT/port/props/nabu.prop" 2>/dev/null
check grep -q '^ro.product.device=pad8$' "$TMP/bp2"

# 5. matchpkg
step "matchpkg"
cat > "$TMP/pkgs.json" <<'EOF'
{"packages": [
  {"package": "com.miui.video", "dir": "app/MiuiVideo", "bytes": 100},
  {"package": "com.miui.notes", "dir": "app/MiuiNotes", "bytes": 50}
]}
EOF
printf 'com.miui.video\ncom.not.here\n' > "$TMP/wanted.txt"
python3 "$REPO_ROOT/tools/matchpkg.py" --json "$TMP/pkgs.json" --wanted "$TMP/wanted.txt" \
  --hits "$TMP/hits.tsv" --misses "$TMP/misses.txt" 2>/dev/null
check grep -q $'^app/MiuiVideo\tcom.miui.video\t100$' "$TMP/hits.tsv"
check grep -q '^com.not.here$' "$TMP/misses.txt"

# 6. erofs 往返
step "erofs roundtrip"
if have mkfs.erofs && have dump.erofs; then
  mkdir -p "$TMP/root/app/Foo" "$TMP/root/etc"
  printf 'x' > "$TMP/root/app/Foo/Foo.apk"
  printf 'ro.a=b\n' > "$TMP/root/build.prop"
  if as_root mkfs.erofs -b 4096 --mount-point=/ "$TMP/test.img" "$TMP/root" >/dev/null 2>&1 \
     || mkfs.erofs -b 4096 --mount-point=/ "$TMP/test.img" "$TMP/root" >/dev/null 2>&1; then
    check grep -qx erofs <<<"$(detect_fs "$TMP/test.img")"
    check dump.erofs --stat "$TMP/test.img"
  else
    warn "mkfs.erofs 跑不起来，跳过（本机缺 erofs-utils？）"
  fi
else
  warn "没有 erofs-utils，跳过往返测试（CI 上会装）"
fi

# 7. 各 stage --help
step "stage --help"
for f in "$REPO_ROOT"/scripts/0*.sh "$REPO_ROOT/scripts/pipeline.sh"; do
  [ -f "$f" ] || continue
  if bash "$f" --help >/dev/null 2>&1; then ok "$(basename "$f")"; else
    FAILED=$((FAILED + 1)); warn "$(basename "$f") --help 失败"
  fi
done

echo
if [ "$FAILED" -gt 0 ]; then
  die "自检失败 $FAILED 项" 7
fi
ok "自检全部通过"
