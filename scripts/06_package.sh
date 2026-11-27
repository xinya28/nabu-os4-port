#!/usr/bin/env bash
# shellcheck shell=bash
#
# 06_package —— 组装可刷入的包
#
#   scripts/06_package.sh [--images work/ported] [--out out/package]
#                         [--version v0.1] [--target-firmware DIR]
#                         [--include-target] [--split-mb 1800] [--zip]
#
# 包里有什么、为什么是这些：
#   boot.img            本仓库内核段构建，内含平板驱动
#   system/product/system_ext.img   OS4 精简 + 移植注入后的镜像
#   MANIFEST.json       这份包由什么构建出来（可复现的最小信息集）
#   SHA256SUMS          刷机前先校验，别跳
#   flash.sh / README-FLASH.txt  刷写脚本与说明（fastbootd 直接刷逻辑分区）
#
# 包里**没有** vendor/odm/vendor_dlkm：它们是 nabu 原厂固件，属于厂商二进制，
# 本仓库不分发。flash.sh 会提示你先用原厂固件把 vendor 侧刷回去（或保持不动）。
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

IMAGES="$WORK_ROOT/ported"
OUT="$OUT_ROOT/package"
VERSION=""
TARGET_FW=""
INCLUDE_TARGET=0
SPLIT_MB=1800
DO_ZIP=0

while [ $# -gt 0 ]; do
  case "$1" in
    --images)          IMAGES="$2"; shift 2 ;;
    --out)             OUT="$2"; shift 2 ;;
    --version)         VERSION="$2"; shift 2 ;;
    --target-firmware) TARGET_FW="$2"; shift 2 ;;
    --include-target)  INCLUDE_TARGET=1; shift ;;
    --split-mb)        SPLIT_MB="$2"; shift 2 ;;
    --zip)             DO_ZIP=1; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) die "未知参数 $1" 2 ;;
  esac
done

prepare_dirs
stage_banner "06 package"
need_dir "$IMAGES" "先跑 scripts/04_port.sh"
mkdir -p "$OUT"
rm -f "$OUT"/*.img "$OUT"/*.img.part-* "$OUT"/*.zip "$OUT"/SHA256SUMS 2>/dev/null || true

[ -n "$VERSION" ] || VERSION="$(date -u +%Y%m%d)"
BUILD_ID="${BUILD_ID:-$(date -u +%Y%m%d%H%M)}"

# ── 1. 收集镜像 ────────────────────────────────────────────────────────────
declare -a PACKED=()
for part in $(cfg port/manifest.toml from_source.parts); do
  src="$IMAGES/$part.img"
  if [ -f "$src" ]; then
    cp -f "$src" "$OUT/$part.img"
    PACKED+=("$part")
    ok "$part.img  $(human "$(bytes_of "$src")")"
  else
    warn "缺少 $part.img（源包可能不带此分区）"
  fi
done

# boot：优先用 05 生成的、替换过内核的那一份
BOOT_SRC=""
for cand in "$OUT_ROOT/boot-nabu-os4.img" "$OUT_ROOT/boot.img" "$WORK_ROOT/kbuild/boot.img"; do
  [ -f "$cand" ] && BOOT_SRC="$cand" && break
done
if [ -n "$BOOT_SRC" ]; then
  cp -f "$BOOT_SRC" "$OUT/boot.img"
  PACKED+=("boot")
  ok "boot.img ← $(basename "$BOOT_SRC")"
else
  warn "没有 boot.img：kernel 段还没跑，或用 --boot-in 指定原厂 boot.img"
fi

# 目标固件里的启动类分区：默认不打包（厂商二进制，且刷之前设备上就有）
if [ "$INCLUDE_TARGET" = "1" ] && [ -n "$TARGET_FW" ] && [ -d "$TARGET_FW" ]; then
  for p in vendor_boot dtbo vbmeta vbmeta_system; do
    [ -f "$TARGET_FW/$p.img" ] || continue
    cp -f "$TARGET_FW/$p.img" "$OUT/$p.img"
    PACKED+=("$p")
    ok "$p.img（来自目标固件）"
  done
fi

[ "${#PACKED[@]}" -gt 0 ] || die "没有可打包的镜像" 2

# ── 2. 刷写脚本与说明 ──────────────────────────────────────────────────────
cat > "$OUT/flash.sh" <<'FLASH'
#!/usr/bin/env bash
# 在 fastbootd（不是 bootloader 的 fastboot）下刷入 system 侧。
#
#   ./flash.sh            # 先 dry-run 看命令
#   ./flash.sh --go       # 真的刷
#   ./flash.sh --go --slot a
#
# 前提：bootloader 已解锁；设备在 `adb reboot fastboot` 进入的 fastbootd。
set -euo pipefail
GO=0; SLOT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --go) GO=1; shift ;;
    --slot) SLOT="$2"; shift 2 ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "未知参数 $1" >&2; exit 2 ;;
  esac
done

run() {
  if [ "$GO" = "1" ]; then echo "+ $*"; "$@"; else echo "  $*"; fi
}

echo "== 设备 =="
fastboot devices || { echo "没有设备：先 adb reboot fastboot" >&2; exit 1; }

for p in boot system product system_ext; do
  [ -f "$p.img" ] || continue
  if [ "$p" = "boot" ]; then
    run fastboot flash boot "$p.img"
  else
    # 逻辑分区必须用 fastbootd，bootloader 的 fastboot 会报 "not a physical partition"
    run fastboot flash "$p" "$p.img"
  fi
done

if [ -f vbmeta.img ]; then
  # 移植包的 vbmeta 与原厂不同，必须关闭校验，否则起不来
  run fastboot --disable-verity --disable-verification flash vbmeta vbmeta.img
fi

[ "$GO" = "1" ] || { echo; echo "以上是 dry-run；加 --go 执行。"; exit 0; }
echo
echo "刷写完成。第一次开机较慢（10-20 分钟），不要反复断电。"
FLASH
chmod +x "$OUT/flash.sh"

cat > "$OUT/README-FLASH.txt" <<TXT
nabu-os4-port 刷写说明
======================

包内容
  boot.img               内核（4.14.180 + 平板驱动 + 屏幕状态门控 autosleep）
  system.img             OS4 源机型的 system（精简 + 移植注入后）
  product.img            OS4 源机型的 product
  system_ext.img         OS4 源机型的 system_ext
  MANIFEST.json          构建信息
  SHA256SUMS             校验和

包里没有 vendor / odm / vendor_dlkm / vendor_boot / dtbo / vbmeta*
—— 这些是 nabu 原厂固件，仓库不分发。移植的前提是设备上那份 vendor 侧保持
原厂（或来自你本地的同版本固件）。

刷写前
  1. sha256sum -c SHA256SUMS
  2. 备份：至少备份 boot、vendor_boot、dtbo、vbmeta，以及你的 data（会丢）
  3. 解锁 bootloader；确认当前槽位（fastboot getvar current-slot）

刷写
  adb reboot fastboot        # 进 fastbootd，不是 bootloader
  ./flash.sh                 # 先看 dry-run 的命令
  ./flash.sh --go            # 确认后执行

第一次开机
  - 10-20 分钟属正常；移植包首次启动要做 dex 优化与资源重排
  - 卡在开机动画超过 30 分钟：adb shell 拿 dmesg / logcat（若 adbd 起了）
  - 完全进不去 fastbootd 之外的东西时：fastboot flash boot <原厂 boot.img> 回退

已知限制（详见 docs/PORTING.md）
  - vendor 侧仍是 nabu 原厂（Android 13 / API 33），OS4 是 Android 17；
    跨版本 HAL 接口是本移植最大的风险点
  - 相机、指纹（nabu 没有）、蜂窝相关功能不在首版目标内
  - 触控笔侧键：驱动侧仍在做（见 docs/KERNEL.md）
TXT

# ── 3. 清单与校验和 ────────────────────────────────────────────────────────
MANIFEST="$OUT/MANIFEST.json"
{
  printf '{\n  "package": "nabu-os4-port",\n  "version": "%s",\n  "build_id": "%s",\n  "generated_at": "%s",\n' \
    "$(json_escape "$VERSION")" "$(json_escape "$BUILD_ID")" "$(now_iso)"
  printf '  "target_device": "nabu",\n  "target_model": "Xiaomi Pad 5",\n'
  printf '  "source_parts": "%s",\n' "$(cfg port/manifest.toml from_source.parts)"
  printf '  "flash_tool": "fastbootd",\n  "images": [\n'
  first=1
  for f in "$OUT"/*.img; do
    [ -f "$f" ] || continue
    [ "$first" = "1" ] || printf ',\n'
    first=0
    printf '    {"file": "%s", "bytes": %s, "sha256": "%s"}' \
      "$(basename "$f")" "$(bytes_of "$f")" "$(sha256_of "$f")"
  done
  printf '\n  ]\n}\n'
} > "$MANIFEST"

( cd "$OUT" && sha256sum ./*.img > SHA256SUMS )

# ── 4. 大文件切分（Actions artifact 单文件有上限） ────────────────────────
if [ "$DO_ZIP" = "0" ]; then
  limit=$((SPLIT_MB * 1024 * 1024))
  for f in "$OUT"/*.img; do
    [ -f "$f" ] || continue
    sz="$(bytes_of "$f")"
    if [ "$sz" -gt "$limit" ]; then
      info "$(basename "$f") $(human "$sz") 超过 ${SPLIT_MB}MiB，切分上传"
      ( cd "$OUT" && split -b "${SPLIT_MB}M" -d -a 2 "$(basename "$f")" "$(basename "$f").part-" )
      rm -f "$f"
    fi
  done
  # 原文件已被切掉，SHA256SUMS 必须按"实际存在的文件"重建，
  # 否则 sha256sum -c 会对着已删除的 .img 报缺失，把真正的校验失败淹掉
  ( cd "$OUT" && rm -f SHA256SUMS && sha256sum ./*.img ./*.part-* 2>/dev/null > SHA256SUMS || true )
fi

if [ "$DO_ZIP" = "1" ]; then
  need_cmd zip
  info "打成 zip（store，不做二次压缩：erofs 已经是压缩过的）"
  ( cd "$OUT" && zip -0 -q "../nabu-os4-$VERSION.zip" ./*.img MANIFEST.json SHA256SUMS flash.sh README-FLASH.txt )
  ok "zip: $OUT_ROOT/nabu-os4-$VERSION.zip"
fi

ok "打包完成：$OUT"
( cd "$OUT" && ls -lh | sed 's/^/    /' >&2 )
