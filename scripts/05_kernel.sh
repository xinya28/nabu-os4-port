#!/usr/bin/env bash
# shellcheck shell=bash
#
# 05_kernel —— 构建/打包内核（含平板驱动整合）
#
#   scripts/05_kernel.sh [--branch nabu-w-oss-bks] [--localversion -perf]
#                        [--no-perf] [--no-autosleep] [--ksu-version 35171]
#                        [--boot-in <原厂 boot.img>] [--image <已有 Image>]
#                        [--download-llvm] [--jobs N]
#
# 两种用法：
#   * 从源码构建（默认）：clone 上游 → 打补丁 → 合配置 → 编译 → 出 AnyKernel zip；
#   * --image 直接给一个已编好的 Image：跳过编译，只做打包/repack（本地迭代用）。
#
# 这一阶段的目的不是"改内核功能"，而是让内核和移植 ROM 的 vendor 模块对得上：
# 4.14.180 + modversions，vermagic 尾部一致，符号 CRC 由同一 base 保证。
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SRC_BRANCH="$(cfg kernel/source.toml source.default_branch)"
LOCALVERSION="-perf"
PERF=1
AUTOSLEEP=1
KSU_VERSION=""
BOOT_IN=""
PREBUILT=""
DOWNLOAD_LLVM=0
JOBS="$(nproc 2>/dev/null || echo 4)"

while [ $# -gt 0 ]; do
  case "$1" in
    --branch)        SRC_BRANCH="$2"; shift 2 ;;
    --localversion)  LOCALVERSION="$2"; shift 2 ;;
    --no-perf)       PERF=0; shift ;;
    --no-autosleep)  AUTOSLEEP=0; shift ;;
    --ksu-version)   KSU_VERSION="$2"; shift 2 ;;
    --boot-in)       BOOT_IN="$2"; shift 2 ;;
    --image)         PREBUILT="$2"; shift 2 ;;
    --download-llvm) DOWNLOAD_LLVM=1; shift ;;
    --jobs)          JOBS="$2"; shift 2 ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) die "未知参数 $1" 2 ;;
  esac
done

prepare_dirs
stage_banner "05 kernel"
need_cmd git

SRC_REPO="$(cfg kernel/source.toml source.repo)"
BUILD_SCRIPT="$(cfg kernel/source.toml source.build_script)"
IMAGE_OUT="$(cfg kernel/source.toml source.image_out)"
CONFIG_REF="$(cfg kernel/source.toml source.config_ref)"
CLANG_VER="$(cfg kernel/source.toml toolchain.clang)"
KERNEL_DIR="$WORK_ROOT/kernel"
BUILD_DIR="$WORK_ROOT/kbuild"
mkdir -p "$BUILD_DIR"

# ── 1. Image：外部提供 或 源码构建 ─────────────────────────────────────────
if [ -n "$PREBUILT" ]; then
  need_file "$PREBUILT"
  info "使用外部 Image：$PREBUILT"
  cp -f "$PREBUILT" "$BUILD_DIR/Image"
else
  need_dir_tree() { [ -f "$KERNEL_DIR/$1" ] || die "内核树缺少 $1"; }
  if [ ! -d "$KERNEL_DIR/.git" ]; then
    info "clone $SRC_REPO ($SRC_BRANCH)"
    rm -rf "$KERNEL_DIR"
    git clone --depth 1 -b "$SRC_BRANCH" "$SRC_REPO" "$KERNEL_DIR" \
      || die "clone 失败（检查网络/分支名）"
  else
    info "复用已有内核树，同步到 origin/$SRC_BRANCH"
    git -C "$KERNEL_DIR" fetch --depth 1 origin "$SRC_BRANCH" \
      && git -C "$KERNEL_DIR" checkout -q FETCH_HEAD \
      || warn "fetch 失败，继续用本地 HEAD"
    git -C "$KERNEL_DIR" reset --hard -q || true
    git -C "$KERNEL_DIR" clean -fdq || true
  fi
  KERNEL_SHA="$(git -C "$KERNEL_DIR" rev-parse --short HEAD)"
  log "内核 HEAD: $KERNEL_SHA $(git -C "$KERNEL_DIR" log -1 --pretty=%s)"

  # ── 2. 补丁 ──────────────────────────────────────────────────────────────
  apply_patch() {
    local p="$1"
    need_file "$p"
    if git -C "$KERNEL_DIR" apply --check "$p" 2>/dev/null; then
      git -C "$KERNEL_DIR" apply --verbose "$p" >/dev/null 2>&1 || die "补丁应用失败：$p"
      ok "patch $(basename "$p")"
    else
      die "补丁无法应用（上游已变或已包含）：$p"
    fi
  }

  if [ "$AUTOSLEEP" = "1" ]; then
    apply_patch "$REPO_ROOT/$(cfg kernel/source.toml patches.autosleep_default)"
    apply_patch "$REPO_ROOT/$(cfg kernel/source.toml patches.autosleep_gate)"
    # 0002 新增 .c 文件；编译项用追加而不是塞进补丁，避免上游重排 Makefile 后失败
    printf '\nobj-$(CONFIG_PM_AUTOSLEEP) += nabu_autosleep_gate.o\n' >> "$KERNEL_DIR/kernel/power/Makefile"
    grep -q 'nabu_autosleep_gate' "$KERNEL_DIR/kernel/power/Makefile" \
      || die "Makefile 追加失败（0002 补丁是否真的生效？）"
  else
    info "跳过 autosleep 补丁（--no-autosleep）"
  fi

  # /proc/kallsyms 默认 0444，任何 App 都能 grep ksu_* 符号来指纹识别 root
  if grep -q 'proc_create("kallsyms", 0444,' "$KERNEL_DIR/kernel/kallsyms.c"; then
    sed -i 's/proc_create("kallsyms", 0444,/proc_create("kallsyms", 0400,/' "$KERNEL_DIR/kernel/kallsyms.c"
    ok "kallsyms 权限 0444 → 0400"
  fi

  # ── 3. 配置 ──────────────────────────────────────────────────────────────
  CFG="$KERNEL_DIR/$CONFIG_REF"
  need_file "$CFG" "内核树里的基线配置"
  cfg_append() {
    local frag="$REPO_ROOT/$1"
    need_file "$frag"
    printf '\n' >> "$CFG"
    cat "$frag" >> "$CFG"
    ok "config += $(basename "$frag")"
  }
  [ "$PERF" = "1" ] && cfg_append "$(cfg kernel/source.toml configs.perf)"
  [ "$AUTOSLEEP" = "1" ] && cfg_append "$(cfg kernel/source.toml configs.suspend)"

  if grep -q '^CONFIG_LOCALVERSION=' "$CFG"; then
    sed -i "s|^CONFIG_LOCALVERSION=.*|CONFIG_LOCALVERSION=\"${LOCALVERSION}\"|" "$CFG"
  else
    printf '\nCONFIG_LOCALVERSION="%s"\n' "$LOCALVERSION" >> "$CFG"
  fi
  log "CONFIG_LOCALVERSION=\"$LOCALVERSION\""

  if [ -n "$KSU_VERSION" ]; then
    sed -i "s|^KSU_VERSION := \$(shell expr.*|KSU_VERSION := ${KSU_VERSION}|" \
      "$KERNEL_DIR/KernelSU/kernel/Kbuild"
    grep -n '^KSU_VERSION :=' "$KERNEL_DIR/KernelSU/kernel/Kbuild" \
      || die "KSU_VERSION 固定失败（Kbuild 结构变了？）"
  fi

  # ── 4. 工具链 ────────────────────────────────────────────────────────────
  # 上游 build-recovery.sh 第 8 行是 `: "${LLVM_BIN:?...}"`，然后自己
  # export PATH="$LLVM_BIN:$PATH"。也就是说：**只把 clang 放进 PATH 不够**，
  # 必须显式给它 LLVM_BIN，否则构建在第一个 make 之前就退出（报错信息还只有
  # 一行 "Provide absolute path to ..."，很容易被当成缺 clang）。
  LLVM_DIR="$TOOLS_DIR/llvm"
  if [ -z "${LLVM_BIN:-}" ] || [ ! -x "${LLVM_BIN:-/nonexistent}/clang" ]; then
    if [ -x "$LLVM_DIR/bin/clang" ]; then
      LLVM_BIN="$LLVM_DIR/bin"
    elif [ "$DOWNLOAD_LLVM" = "1" ] || ! have clang; then
      need_cmd curl
      info "下载 LLVM $CLANG_VER"
      url="https://github.com/llvm/llvm-project/releases/download/llvmorg-${CLANG_VER}/LLVM-${CLANG_VER}-Linux-X64.tar.xz"
      tmp="$(mktemp -d)"
      curl -fL --retry 5 --retry-delay 5 -o "$tmp/llvm.tar.xz" "$url" || die "LLVM 下载失败"
      mkdir -p "$LLVM_DIR"
      tar -xJf "$tmp/llvm.tar.xz" -C "$LLVM_DIR" --strip-components=1 || die "LLVM 解压失败"
      rm -rf "$tmp"
      LLVM_BIN="$LLVM_DIR/bin"
    else
      LLVM_BIN="$(dirname "$(command -v clang)")"
    fi
  fi
  [ -x "$LLVM_BIN/clang" ] || die "找不到 clang：用 --download-llvm，或设置 LLVM_BIN 指向 LLVM $CLANG_VER 的 bin 目录"
  export LLVM_BIN
  export PATH="$LLVM_BIN:$PATH"
  ok "LLVM: $(clang --version | head -1)  ($LLVM_BIN)"
  # 上游会硬性检查这几个工具的版本串里带 20.1.8
  ld.lld --version >/dev/null 2>&1 || die "llvm bin 目录里没有 ld.lld（$LLVM_BIN）"

  # ── 5. 编译 ──────────────────────────────────────────────────────────────
  need_file "$KERNEL_DIR/$BUILD_SCRIPT"
  info "编译（JOBS=$JOBS，OUT=$BUILD_DIR）"
  # 上游 4.14 树在 clang 20 下会撞上新增的 -Werror 诊断，失败一次后放宽重试
  if ! ( cd "$WORK_ROOT" && OUT="$BUILD_DIR" JOBS="$JOBS" bash "kernel/$BUILD_SCRIPT" ); then
    warn "首次编译失败，用 KCFLAGS=-Wno-error=unused-but-set-variable 重试"
    ( cd "$WORK_ROOT" && OUT="$BUILD_DIR" JOBS="$JOBS" \
        KCFLAGS="-Wno-error=unused-but-set-variable" bash "kernel/$BUILD_SCRIPT" ) \
      || die "内核编译失败"
  fi

  SRC_IMG="$BUILD_DIR/$IMAGE_OUT"
  need_file "$SRC_IMG" "内核产物"
  # boot 分区要的是未压缩裸 Image；Image.gz-dtb 尾巴上还挂着 dtb（nabu 用不到，DTB 在 vendor_boot）
  info "从 $(basename "$SRC_IMG") 取出裸 Image"
  python3 - "$SRC_IMG" "$BUILD_DIR/Image" <<'PY'
import sys, zlib
src, dst = sys.argv[1], sys.argv[2]
data = open(src, "rb").read()
d = zlib.decompressobj(31)
img = d.decompress(data) + d.flush()
open(dst, "wb").write(img)
print(f"Image: {len(img)} bytes, appended dtb: {len(d.unused_data)} bytes")
assert img[0x38:0x3c] == b"ARMd", "不是合法的 arm64 Image"
PY
fi

# ── 6. 校验 + 把产物收进 out/ ──────────────────────────────────────────────
need_file "$BUILD_DIR/Image"
# 裸 Image 是产物之一（AnyKernel 只装它；boot.img repack 也用它）
cp -f "$BUILD_DIR/Image" "$OUT_ROOT/Image"

banner="$(strings "$BUILD_DIR/Image" | grep -m1 '^Linux version' || true)"
# vermagic 是独立字符串，不在 "Linux version" 那一行里，
# 形如 "4.14.180-perf-perf SMP preempt mod_unload modversions aarch64"
vermagic="$(strings "$BUILD_DIR/Image" | grep -m1 -E '^4\.14\.[0-9]+[^ ]* (SMP|PREEMPT|preempt)' || true)"
CFGFILE="$BUILD_DIR/.config"
[ -f "$CFGFILE" ] || CFGFILE="$KERNEL_DIR/.config"

log "版本串 : ${banner:-未找到}"
log "vermagic: ${vermagic:-未找到}"

prefix="$(cfg kernel/source.toml modules.required_vermagic_prefix)"
MISSING=()
case "$banner" in
  *"$prefix"*) ok "内核版本串包含 $prefix，与 vendor 模块同 base" ;;
  *) warn "内核版本串不含 $prefix —— vendor 模块可能加载失败"; MISSING+=("$prefix") ;;
esac

{
  echo "generated   : $(now_iso)"
  echo "branch      : $SRC_BRANCH"
  echo "commit      : ${KERNEL_SHA:-unknown}"
  echo "localversion: $LOCALVERSION"
  echo "patches     : autosleep=$AUTOSLEEP perf=$PERF"
  echo "banner      : ${banner:-未找到}"
  echo "vermagic    : ${vermagic:-未找到}"
  echo
  echo "--- vermagic 相关配置（$CFGFILE）---"
  if [ -f "$CFGFILE" ]; then
    for s in CONFIG_SMP CONFIG_PREEMPT CONFIG_MODULE_UNLOAD CONFIG_MODVERSIONS \
             CONFIG_LOCALVERSION CONFIG_MODULE_SIG CONFIG_KSU CONFIG_KPROBES; do
      if grep -qE "^${s}=" "$CFGFILE"; then grep -E "^${s}=" "$CFGFILE"
      elif grep -qE "^# ${s} is not set" "$CFGFILE"; then grep -E "^# ${s} is not set" "$CFGFILE"
      else echo "${s} 未出现在配置里"; fi
    done
  else
    echo "找不到 .config"
  fi
} > "$OUT_ROOT/kernel-info.txt"

# modversions 必须看 .config，不能看版本串：vermagic 里带 modversions 才是真的开了
if [ -f "$CFGFILE" ] && grep -qE '^CONFIG_MODVERSIONS=y' "$CFGFILE"; then
  ok "CONFIG_MODVERSIONS=y（vendor 模块的符号 CRC 校验能对上）"
else
  warn "CONFIG_MODVERSIONS 未开启 —— vendor 模块很可能加载失败（见 docs/KERNEL.md 第 1 节）"
fi
if grep -qE '^CONFIG_MODULE_UNLOAD=y' "$CFGFILE" 2>/dev/null; then
  ok "CONFIG_MODULE_UNLOAD=y（vermagic 里的 mod_unload 对齐）"
fi

# ── 7. 打包 ────────────────────────────────────────────────────────────────
KERNEL_SHA="${KERNEL_SHA:-$(git -C "$KERNEL_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)}"
info "打 AnyKernel3 zip"
OUTDIR="$OUT_ROOT" DEVICE=nabu bash "$REPO_ROOT/kernel/scripts/pack-anykernel.sh" \
  "$BUILD_DIR/Image" "$SRC_BRANCH" "$KERNEL_SHA"

if [ -n "$BOOT_IN" ]; then
  need_file "$BOOT_IN" "原厂 boot.img"
  need_cmd node
  info "替换 boot.img 内核段（ramdisk/header 保持不变）"
  node "$REPO_ROOT/tools/repack_boot.js" "$BOOT_IN" "$BUILD_DIR/Image" "$OUT_ROOT/boot-nabu-os4.img" \
    || die "boot.img repack 失败"
fi

( cd "$OUT_ROOT" && sha256sum Image ./*.zip boot-nabu-os4.img 2>/dev/null > SHA256SUMS.kernel ) || true
ok "内核阶段完成：$OUT_ROOT"
ls -lh "$OUT_ROOT" | sed 's/^/    /' >&2 || true
