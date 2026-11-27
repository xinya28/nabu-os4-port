#!/usr/bin/env bash
# shellcheck shell=bash
#
# 07_verify —— 出厂前自检
#
#   scripts/07_verify.sh [--package out/package] [--ported work/ported]
#
# 这里检查的是"能被机器判定的事实"，不检查"能不能开机"——后者只能靠真机。
# 每一项失败都对应一个明确后果，见各检查项注释。
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PKG="$OUT_ROOT/package"
PORTED="$WORK_ROOT/ported"

while [ $# -gt 0 ]; do
  case "$1" in
    --package) PKG="$2"; shift 2 ;;
    --ported)  PORTED="$2"; shift 2 ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) die "未知参数 $1" 2 ;;
  esac
done

stage_banner "07 verify"
declare -a FAILS=()
declare -a NOTES=()

fail() { FAILS+=("$1"); warn "FAIL: $1"; }
note() { NOTES+=("$1"); log "note: $1"; }

# ── 1. 校验和 ──────────────────────────────────────────────────────────────
if [ -f "$PKG/SHA256SUMS" ]; then
  if ( cd "$PKG" && sha256sum -c SHA256SUMS >/dev/null 2>&1 ); then
    ok "SHA256SUMS 全部匹配"
  else
    fail "SHA256SUMS 校验失败（包被截断或文件被改过）"
  fi
else
  fail "缺少 SHA256SUMS"
fi

# ── 2. 镜像完整性 ──────────────────────────────────────────────────────────
shopt -s nullglob
imgs=("$PKG"/*.img)
[ "${#imgs[@]}" -gt 0 ] || fail "包里没有任何 .img"

for f in "${imgs[@]}"; do
  name="$(basename "$f")"
  size="$(bytes_of "$f")"
  if [ "$size" -lt 1048576 ]; then
    fail "$name 只有 $(human "$size")，不像有效镜像"
    continue
  fi
  fs="$(detect_fs "$f")"
  case "$name" in
    boot.img)
      # boot 必须是 Android boot image，且 page0 之后是 arm64 Image
      if [ "$(head -c8 "$f")" = "ANDROID!" ]; then
        hdr_ver="$(od -An -tu4 -j40 -N4 "$f" | tr -d ' ')"
        [ "$hdr_ver" = "3" ] || note "boot.img header v$hdr_ver（预期 v3）"
        ksz="$(od -An -tu4 -j8 -N4 "$f" | tr -d ' ')"
        magic="$(dd if="$f" bs=1 skip=$((4096 + 56)) count=4 status=none)"
        # 内核大小必须落在第 1 页起的范围内，否则 ramdisk 偏移算错
        if [ "$ksz" -le 0 ] || [ "$ksz" -gt 67108864 ]; then
          fail "boot.img 内核大小异常：$ksz"
        fi
        [ "$magic" = "ARMd" ] && ok "boot.img：header v$hdr_ver，arm64 Image OK（$(human "$ksz")）" \
                              || fail "boot.img 第 1 页偏移 56 处不是 ARMd（内核段有问题）"
      else
        fail "boot.img 不是 Android boot image"
      fi ;;
    *)
      case "$fs" in
        erofs)
          if dump.erofs -S "$f" >/dev/null 2>&1; then
            ok "$name：erofs 可解析（$(human "$size")）"
          else
            fail "$name：erofs 无法解析"
          fi ;;
        ext4)
          if fsck.ext4 -fn "$f" >/dev/null 2>&1; then
            ok "$name：ext4 干净（$(human "$size")）"
          else
            note "$name：ext4 检查有输出（可能是未清理的 ext4，不等于坏了）"
          fi ;;
        unknown) fail "$name：无法识别文件系统" ;;
        *) note "$name：格式 $fs，未做深度校验" ;;
      esac ;;
  esac
done

# ── 3. 移植层报告一致性 ────────────────────────────────────────────────────
if [ -f "$PORTED/port-manifest.json" ]; then
  if grep -q '"problems": \[\]' "$PORTED/port-manifest.json"; then
    ok "移植层报告：无阻塞问题"
  else
    fail "移植层报告里有阻塞问题（见 $PORTED/port-report.md）"
  fi
else
  note "没有 port-manifest.json（只跑了精简、没跑移植层？）"
fi

if [ -f "$PORTED/debloat-summary.json" ]; then
  # 精简后每个分区的 after_bytes 必须大于 0，否则说明重打包产出是空文件
  if grep -q '"after_bytes": 0' "$PORTED/debloat-summary.json" 2>/dev/null \
     || { [ -f "$WORK_ROOT/debloated/debloat-summary.json" ] && grep -q '"after_bytes": 0' "$WORK_ROOT/debloated/debloat-summary.json"; }; then
    fail "精简汇总里有 after_bytes=0 的分区（重打包失败但被吞掉了）"
  else
    ok "精简汇总：无空分区"
  fi
fi

# ── 4. MANIFEST ────────────────────────────────────────────────────────────
if [ -f "$PKG/MANIFEST.json" ]; then
  for key in '"package"' '"version"' '"images"'; do
    grep -q "$key" "$PKG/MANIFEST.json" || fail "MANIFEST.json 缺少 $key"
  done
  ok "MANIFEST.json 结构完整"
else
  fail "缺少 MANIFEST.json"
fi

# ── 5. 汇总 ────────────────────────────────────────────────────────────────
REPORT="$OUT_ROOT/verify-report.txt"
{
  echo "verify report $(now_iso)"
  echo "package: $PKG"
  echo
  echo "FAILS (${#FAILS[@]}):"
  for x in "${FAILS[@]:-}"; do [ -n "$x" ] && echo "  - $x"; done
  echo
  echo "NOTES (${#NOTES[@]}):"
  for x in "${NOTES[@]:-}"; do [ -n "$x" ] && echo "  - $x"; done
} > "$REPORT"

if [ "${#FAILS[@]}" -gt 0 ]; then
  die "自检失败 ${#FAILS[@]} 项，见 $REPORT" 5
fi

ok "自检通过（$REPORT）"
echo
echo "提醒：以上只是镜像级自检。能不能开机、触控/笔/显示是否正常，"
echo "      只有刷到真机上才知道；第一次务必用 fastboot boot 临时启动验证。"
