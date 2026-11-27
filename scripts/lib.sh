#!/usr/bin/env bash
# shellcheck shell=bash
#
# 公共函数库 —— 所有 stage 脚本都 source 这个文件。
# 约定：
#   * 每个 stage 都是"读上一步的产物目录 + 写自己的产物目录"，互相不覆盖；
#   * 失败一律非 0 退出，CI 靠退出码判断，不靠 grep 日志；
#   * 任何需要 root 的操作都显式用 sudo，并说明为什么需要。
#
# 环境变量：
#   WORK_ROOT  中间产物（默认 <repo>/work）     —— 可丢弃
#   OUT_ROOT   最终产物（默认 <repo>/out）      —— 会被上传/发布
#   TOOLS_DIR  下载的预编译工具（默认 <repo>/.tools）

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_ROOT="${WORK_ROOT:-$REPO_ROOT/work}"
OUT_ROOT="${OUT_ROOT:-$REPO_ROOT/out}"
TOOLS_DIR="${TOOLS_DIR:-$REPO_ROOT/.tools}"
LOG_TAG="${LOG_TAG:-nabu-os4}"

# ── 日志 ───────────────────────────────────────────────────────────────────
if [ -t 2 ] && [ "${NO_COLOR:-}" = "" ]; then
  _C_RESET=$'\033[0m'; _C_BLUE=$'\033[34m'; _C_YELLOW=$'\033[33m'
  _C_RED=$'\033[31m';  _C_GREEN=$'\033[32m'; _C_DIM=$'\033[2m'
else
  _C_RESET=""; _C_BLUE=""; _C_YELLOW=""; _C_RED=""; _C_GREEN=""; _C_DIM=""
fi

log()  { printf '%s %s[%s]%s %s\n' "$(date -u +%H:%M:%SZ)" "$_C_DIM" "$LOG_TAG" "$_C_RESET" "$*" >&2; }
info() { printf '%s==>%s %s\n' "$_C_BLUE" "$_C_RESET" "$*" >&2; }
ok()   { printf '%s ok %s %s\n' "$_C_GREEN" "$_C_RESET" "$*" >&2; }
warn() { printf '%swarn%s %s\n' "$_C_YELLOW" "$_C_RESET" "$*" >&2; }
die()  { local msg="$1" code="${2:-1}"; printf '%serr %s %s\n' "$_C_RED" "$_C_RESET" "$msg" >&2; exit "$code"; }

# ── 断言 ───────────────────────────────────────────────────────────────────
have() { command -v "$1" >/dev/null 2>&1; }

need_cmd() {
  have "$1" || die "缺少命令 '$1'${2:+ —— $2}"
}

need_file() {
  [ -f "$1" ] || die "缺少文件 '$1'${2:+ —— $2}"
}

need_dir() {
  [ -d "$1" ] || die "缺少目录 '$1'${2:+ —— $2}"
}

# ── 通用工具 ───────────────────────────────────────────────────────────────
sha256_of() { sha256sum "$1" | cut -d' ' -f1; }

bytes_of() {
  # 可移植的字节数（GNU stat 与 BSD stat 参数不同，这里只支持 Linux/CI）
  stat -c %s "$1"
}

human() {
  numfmt --to=iec-i --suffix=B "$1" 2>/dev/null || echo "${1}B"
}

# 剩余可用空间（GB，整数）
free_gb() {
  local path="$1"
  df -BG --output=avail "$path" 2>/dev/null | tail -1 | tr -dc '0-9'
}

require_free() {
  local path="$1" need_gb="$2" why="${3:-解包/重打包需要}"
  local got
  got="$(free_gb "$path")"
  [ -n "$got" ] || return 0
  if [ "$got" -lt "$need_gb" ]; then
    die "磁盘空间不足：$path 只剩 ${got}G，需要 ${need_gb}G（$why）。CI 上先跑「Free disk space」步骤，或换更大的 runner。"
  fi
  log "disk: ${got}G free at $path (need ${need_gb}G)"
}

# 读 config/*.toml： cfg config/target/nabu.toml device.codename
cfg() {
  local file="$1" key="$2" default="${3-}"
  python3 "$REPO_ROOT/tools/cfg.py" get "$REPO_ROOT/$file" "$key" "$default"
}

# 行内注释剥离：  "# foo" 保留，"x  # y" → "x"
strip_comment() { sed -e 's/[[:space:]]*#.*$//' -e 's/[[:space:]]*$//' <<<"$1"; }

# ── 下载 ───────────────────────────────────────────────────────────────────
# fetch <url> <dest>
#   * 断点续传 + 重试，CI 上 5GB 的包一次断掉很正常
#   * 支持 file:// 和本地绝对路径，方便先手动下好再跑流水线
fetch() {
  local url="$1" dest="$2"
  mkdir -p "$(dirname "$dest")"
  if [ -f "$dest" ] && [ -s "$dest" ]; then
    log "reuse existing $(basename "$dest") ($(human "$(bytes_of "$dest")"))"
    return 0
  fi
  case "$url" in
    file://*|/*)
      local src="${url#file://}"
      need_file "$src"
      cp -f "$src" "$dest"
      ;;
    *)
      need_cmd curl
      log "download $url"
      curl -fL --retry 5 --retry-delay 5 --connect-timeout 30 \
           --retry-all-errors -C - -o "$dest" "$url" \
        || die "下载失败：$url"
      ;;
  esac
  [ -s "$dest" ] || die "下载得到空文件：$dest"
}

# ── 镜像格式 ───────────────────────────────────────────────────────────────
# sparse 镜像头 magic 0xED26FF3A
is_sparse() {
  local magic
  magic="$(od -An -tx4 -N4 "$1" | tr -d ' \n')"
  [ "$magic" = "ed26ff3a" ]
}

# detect_fs <img> → erofs | ext4 | f2fs | sparse | unknown
#
# 偏移量容易记错，这里写清楚（都是字节，读出来的都是磁盘上的原始字节序）：
#   EROFS superblock  magic 0xE0F5E1E2 @1024 → 字节 e2 e1 f5 e0
#   F2FS  superblock  magic 0xF2F52010 @1024 → 字节 10 20 f5 f2
#   ext4  superblock  magic 0xEF53     @1080 → 字节 53 ef
# 之前把 erofs magic 当偏移 0 来读是个 bug：真机上所有 erofs 镜像都会被判成 unknown。
detect_fs() {
  local img="$1" m1024 m1080
  if is_sparse "$img"; then echo "sparse"; return; fi

  m1024="$(od -An -tx1 -j1024 -N4 "$img" 2>/dev/null | tr -d ' \n')"
  case "$m1024" in
    e2e1f5e0) echo "erofs"; return ;;
    1020f5f2) echo "f2fs";  return ;;
  esac

  m1080="$(od -An -tx2 -j1080 -N2 "$img" 2>/dev/null | tr -d ' \n')"
  case "$m1080" in
    ef53|53ef) echo "ext4"; return ;;
  esac

  # 兜底：交给 file(1)，它对镜像格式的识别比手写 magic 更全
  case "$(file -b "$img" 2>/dev/null)" in
    *EROFS*) echo "erofs" ;;
    *ext2*|*ext3*|*ext4*) echo "ext4" ;;
    *F2FS*) echo "f2fs" ;;
    *) echo "unknown" ;;
  esac
}

unsparse() {
  local src="$1" dst="$2"
  need_cmd simg2img "apt-get install android-sdk-libsparse-utils"
  simg2img "$src" "$dst"
}

# ── 镜像挂载/解包 ──────────────────────────────────────────────────────────
# 需要 root 的原因：保留 uid/gid/mode（fsck.erofs 和 cp -a 都以 euid 决定是否保留）。
# 这里不做 SELinux label 保留 —— 见 docs/DEBLOAT.md「为什么用 file_contexts 而不是 xattr」。
as_root() {
  if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo -n "$@"; fi
}

# extract_image <img> <fs> <destdir>
extract_image() {
  local img="$1" fs="$2" dest="$3"
  rm -rf "$dest"; mkdir -p "$dest"
  case "$fs" in
    erofs)
      if as_root fsck.erofs --extract="$dest" "$img" >/dev/null 2>&1; then
        log "erofs extracted (fsck.erofs): $(du -sh "$dest" | cut -f1)"
      else
        warn "fsck.erofs 失败，改用 mount 回退"
        mount_image "$img" "$dest"
      fi ;;
    ext4|f2fs)
      mount_image "$img" "$dest" ;;
    *)
      die "不支持的镜像格式 '$fs'（$img）" ;;
  esac
}

mount_image() {
  local img="$1" dest="$2" mnt
  mnt="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "as_root umount '$mnt' 2>/dev/null || true; rmdir '$mnt' 2>/dev/null || true" RETURN
  as_root mount -o loop,ro "$img" "$mnt" || die "mount 失败：$img（容器/CI 里可能需要 --privileged）"
  as_root cp -a "$mnt/." "$dest/"
  as_root umount "$mnt"
  rmdir "$mnt" 2>/dev/null || true
}

# ── 时间/JSON ──────────────────────────────────────────────────────────────
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

json_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

# ── 目录准备 ───────────────────────────────────────────────────────────────
prepare_dirs() {
  mkdir -p "$WORK_ROOT" "$OUT_ROOT" "$TOOLS_DIR/bin"
}

stage_banner() {
  local name="$1"
  info "── $name ─────────────────────────────────────────────"
}
