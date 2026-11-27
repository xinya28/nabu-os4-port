#!/usr/bin/env bash
# shellcheck shell=bash
#
# 01_fetch —— 取源固件
#
#   scripts/01_fetch.sh --url <URL|本地路径> [--sha256 <hex>] [--name <文件名>]
#
# 为什么 ROM 不在仓库里、也不在脚本里写死：
#   小米 CDN 的直链带签名和时效，写死必然过期；ROM 包整体受版权保护，
#   本仓库只发布"怎么处理它"的配方。URL 由 workflow_dispatch 传入，
#   或者你先在 Actions 的 Release 里放一份，再把 release 资产链接传进来。
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

URL=""
WANT_SHA=""
NAME=""
SRC_ID=""

while [ $# -gt 0 ]; do
  case "$1" in
    --url)    URL="$2"; shift 2 ;;
    --sha256) WANT_SHA="$2"; shift 2 ;;
    --name)   NAME="$2"; shift 2 ;;
    --source) SRC_ID="$2"; shift 2 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) die "未知参数 $1" 2 ;;
  esac
done

[ -n "$URL" ] || die "必须给 --url" 2

prepare_dirs
stage_banner "01 fetch"
ROM_DIR="$WORK_ROOT/rom"
mkdir -p "$ROM_DIR"

if [ -z "$NAME" ]; then
  NAME="$(basename "${URL%%\?*}")"
  # 允许 URL 末尾带查询串或路径为空
  [ -n "$NAME" ] && [ "$NAME" != "/" ] || NAME="source-rom.bin"
fi

DEST="$ROM_DIR/$NAME"
info "源: $URL"
info "目标: $DEST"

fetch "$URL" "$DEST"

ACTUAL_SHA="$(sha256_of "$DEST")"
SIZE="$(bytes_of "$DEST")"

if [ -n "$WANT_SHA" ]; then
  if [ "${ACTUAL_SHA,,}" != "${WANT_SHA,,}" ]; then
    die "sha256 不匹配
      期望: $WANT_SHA
      实际: $ACTUAL_SHA
      文件: $DEST" 2
  fi
  ok "sha256 校验通过"
else
  warn "未提供 --sha256，只记录不校验：$ACTUAL_SHA（建议下次带上，ROM 下载被截断很常见）"
fi

cat > "$ROM_DIR/fetch.json" <<JSON
{
  "url": "$(json_escape "$URL")",
  "file": "$(json_escape "$DEST")",
  "name": "$(json_escape "$NAME")",
  "bytes": $SIZE,
  "sha256": "$ACTUAL_SHA",
  "source_id": "$(json_escape "$SRC_ID")",
  "fetched_at": "$(now_iso)"
}
JSON

ok "已获取 $(human "$SIZE")  $ACTUAL_SHA"
printf '%s\n' "$DEST"
