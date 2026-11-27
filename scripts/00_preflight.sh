#!/usr/bin/env bash
# shellcheck shell=bash
#
# 00_preflight —— 环境自检与工具安装
#
#   scripts/00_preflight.sh [--install] [--min-free-gb 30] [--json out/preflight.json]
#
# 设计取舍：
#   * 默认只检查、不安装；CI 里用 --install 一把装齐，本地手工跑时先看清缺什么。
#   * 不静默跳过缺失的工具 —— 缺少 mkfs.erofs 而继续跑，最后会得到一个"看起来
#     构建成功、其实 system.img 根本没重新生成"的包，那种失败最难查。
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INSTALL=0
MIN_FREE_GB=30
JSON_OUT="$OUT_ROOT/preflight.json"

while [ $# -gt 0 ]; do
  case "$1" in
    --install)       INSTALL=1; shift ;;
    --min-free-gb)   MIN_FREE_GB="$2"; shift 2 ;;
    --json)          JSON_OUT="$2"; shift 2 ;;
    -h|--help)       sed -n '2,12p' "$0"; exit 0 ;;
    *) die "未知参数 $1" 2 ;;
  esac
done

prepare_dirs
stage_banner "00 preflight"

PAYLOAD_DUMPER_VERSION="${PAYLOAD_DUMPER_VERSION:-2.1.0}"

# 工具 → 提供它的 apt 包
declare -A APT_PKG=(
  [curl]=curl [unzip]=unzip [zip]=zip [python3]=python3
  [simg2img]=android-sdk-libsparse-utils
  [mkfs.erofs]=erofs-utils [dump.erofs]=erofs-utils [fsck.erofs]=erofs-utils
  [zstd]=zstd [xxd]=xxd [file]=file [numfmt]=coreutils
)

REQUIRED=(bash curl unzip zip python3 od sha256sum df file)
IMAGE_TOOLS=(simg2img mkfs.erofs dump.erofs fsck.erofs zstd)
OPTIONAL_TOOLS=(lpunpack img2simg)

missing_req=()
missing_img=()

check() {
  local t="$1"
  have "$t" && { ok "$t  $(command -v "$t")"; return 0; }
  warn "缺少 $t"
  return 1
}

for t in "${REQUIRED[@]}"; do check "$t" || missing_req+=("$t"); done
for t in "${IMAGE_TOOLS[@]}"; do check "$t" || missing_img+=("$t"); done
for t in "${OPTIONAL_TOOLS[@]}"; do
  if have "$t"; then ok "$t  $(command -v "$t")"; else log "$t 未安装（只在处理 tgz/super.img 输入时才需要）"; fi
done

# payload-dumper-go：OTA 包（payload.bin）的唯一可靠解包器
PDG="$TOOLS_DIR/bin/payload-dumper-go"
PDG_STATUS="present"
if [ -x "$PDG" ]; then
  ok "payload-dumper-go $("$PDG" --version 2>/dev/null | head -1 || echo "$PAYLOAD_DUMPER_VERSION")"
elif [ "$INSTALL" = "1" ]; then
  need_cmd curl
  url="https://github.com/ssut/payload-dumper-go/releases/download/${PAYLOAD_DUMPER_VERSION}/payload-dumper-go_${PAYLOAD_DUMPER_VERSION}_linux_amd64.tar.gz"
  info "安装 payload-dumper-go ${PAYLOAD_DUMPER_VERSION}"
  tmp="$(mktemp -d)"
  curl -fL --retry 5 --retry-delay 3 -o "$tmp/pdg.tgz" "$url" || die "payload-dumper-go 下载失败"
  tar -xzf "$tmp/pdg.tgz" -C "$tmp"
  mkdir -p "$TOOLS_DIR/bin"
  find "$tmp" -type f -name 'payload-dumper-go' -exec install -m755 {} "$PDG" \;
  rm -rf "$tmp"
  [ -x "$PDG" ] || die "payload-dumper-go 安装后仍不可执行"
  ok "payload-dumper-go installed"
else
  PDG_STATUS="missing"
  warn "payload-dumper-go 未安装（处理 payload.bin 时需要；加 --install）"
fi

if [ "${#missing_req[@]}" -gt 0 ] || [ "${#missing_img[@]}" -gt 0 ]; then
  if [ "$INSTALL" = "1" ]; then
    pkgs=()
    for t in "${missing_req[@]}" "${missing_img[@]}"; do
      p="${APT_PKG[$t]:-}"
      [ -n "$p" ] && pkgs+=("$p")
    done
    if [ "${#pkgs[@]}" -gt 0 ]; then
      uniq_pkgs="$(printf '%s\n' "${pkgs[@]}" | sort -u | tr '\n' ' ')"
      info "apt-get install: $uniq_pkgs"
      if [ "$(id -u)" -eq 0 ]; then
        apt-get update -qq && apt-get install -y --no-install-recommends $uniq_pkgs
      else
        sudo -n apt-get update -qq && sudo -n apt-get install -y --no-install-recommends $uniq_pkgs
      fi || die "apt-get 安装失败"
      # 装完复查，避免包名拼错但 apt 返回 0
      for t in "${missing_req[@]}" "${missing_img[@]}"; do
        have "$t" || die "安装后仍然缺少 $t"
      done
      ok "依赖安装完成"
    fi
  else
    die "缺少必需工具：${missing_req[*]:-} ${missing_img[*]:-}（加 --install 自动装）"
  fi
fi

require_free "$WORK_ROOT" "$MIN_FREE_GB"

# 拿不到 root 时明确警告：解包将无法保留 uid/gid，重打包出来的 system 会全 root:root
if [ "$(id -u)" -ne 0 ] && ! sudo -n true 2>/dev/null; then
  warn "没有免密 sudo：解包无法保留 uid/gid。产出的 system.img 可能因权限错误无法开机。"
  ROOT_OK=0
else
  ROOT_OK=1
fi

mkdir -p "$(dirname "$JSON_OUT")"
cat > "$JSON_OUT" <<JSON
{
  "generated_at": "$(now_iso)",
  "host": {
    "kernel": "$(uname -r)",
    "arch": "$(uname -m)",
    "cpus": $(nproc 2>/dev/null || echo 1),
    "free_gb": $(free_gb "$WORK_ROOT" || echo 0),
    "root_available": $ROOT_OK
  },
  "tools": {
    "payload_dumper_go": "$PDG_STATUS",
    "simg2img": $(have simg2img && echo true || echo false),
    "mkfs_erofs": $(have mkfs.erofs && echo true || echo false),
    "lpunpack": $(have lpunpack && echo true || echo false)
  },
  "min_free_gb": $MIN_FREE_GB
}
JSON

ok "preflight 通过，报告：$JSON_OUT"
