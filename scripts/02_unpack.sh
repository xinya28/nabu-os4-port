#!/usr/bin/env bash
# shellcheck shell=bash
#
# 02_unpack —— 把源固件拆成裸分区镜像
#
#   scripts/02_unpack.sh --input <zip|tgz|img|dir> [--out work/images] [--keep system,product,system_ext]
#
# 支持三种输入形态：
#   1. OTA zip（内含 payload.bin）      ← 首选，payload 里每个逻辑分区是独立条目
#   2. 小米 fastboot tgz（内含 super.img）← 需要 lpunpack 才能拆逻辑分区
#   3. 已拆好的镜像目录 / 单个 .img
#
# 输出：work/images/*.img + work/images/index.json（含 fs、大小、sha256）
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INPUT=""
OUTDIR="$WORK_ROOT/images"
KEEP_LIST=""
ONLY=""

while [ $# -gt 0 ]; do
  case "$1" in
    --input) INPUT="$2"; shift 2 ;;
    --out)   OUTDIR="$2"; shift 2 ;;
    --keep)  KEEP_LIST="$2"; shift 2 ;;
    --only)  ONLY="$2"; shift 2 ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) die "未知参数 $1" 2 ;;
  esac
done

[ -n "$INPUT" ] || die "必须给 --input" 2
prepare_dirs
stage_banner "02 unpack"

rm -rf "$OUTDIR"; mkdir -p "$OUTDIR"
PDG="$TOOLS_DIR/bin/payload-dumper-go"
SCRATCH="$WORK_ROOT/scratch"
rm -rf "$SCRATCH"; mkdir -p "$SCRATCH"

# ── 1. 把输入里的东西倒进 SCRATCH ──────────────────────────────────────────
collect_from_dir() {
  local src="$1"
  log "扫描目录 $src"
  find "$src" -maxdepth 3 -type f \( -name '*.img' -o -name 'payload.bin' \) -print0 \
    | while IFS= read -r -d '' f; do cp -f "$f" "$SCRATCH/"; done
}

case "$INPUT" in
  *.zip)
    need_cmd unzip
    info "zip：先看有没有 payload.bin（OTA 包）"
    if unzip -l "$INPUT" | grep -qE 'payload\.bin$'; then
      unzip -o -j "$INPUT" 'payload.bin' -d "$SCRATCH" >/dev/null
      # OTA 包里还可能有 boot.img / vendor_boot.img，顺手带出来做参照
      unzip -l "$INPUT" | awk '{print $4}' | grep -E '^(boot|vendor_boot|dtbo|vbmeta[^/]*)\.img$' \
        | while read -r n; do unzip -o -j "$INPUT" "$n" -d "$SCRATCH" >/dev/null 2>&1 || true; done
    else
      info "zip：没有 payload.bin，整包解开再找镜像"
      unzip -o -q "$INPUT" -d "$SCRATCH"
    fi ;;
  *.tgz|*.tar.gz|*.tar)
    need_cmd tar
    info "tar：解开 fastboot 包"
    tar -xf "$INPUT" -C "$SCRATCH" ;;
  *.img|*.bin)
    info "单镜像输入"
    cp -f "$INPUT" "$SCRATCH/" ;;
  *)
    if [ -d "$INPUT" ]; then collect_from_dir "$INPUT"
    else die "不认识的输入类型：$INPUT" 2; fi ;;
esac

# 有些包解出来是嵌套目录，统一摊平到 SCRATCH/media 下
if ! ls "$SCRATCH"/*.img >/dev/null 2>&1 && ! [ -f "$SCRATCH/payload.bin" ]; then
  nested="$(find "$SCRATCH" -mindepth 2 -maxdepth 4 -name '*.img' -printf '%h\n' | head -1)"
  [ -n "$nested" ] && cp -f "$nested"/*.img "$SCRATCH/" 2>/dev/null || true
fi

# ── 2. payload.bin → 逐分区镜像 ────────────────────────────────────────────
if [ -f "$SCRATCH/payload.bin" ]; then
  [ -x "$PDG" ] || die "需要 payload-dumper-go 解 payload.bin：先跑 scripts/00_preflight.sh --install"
  info "payload.bin → $(basename "$OUTDIR")"
  # -c 是并发 worker 数（不是 -w；payload-dumper-go 的短选项见 --help）
  # -p 只解指定分区：OS4 的 OTA 包 9-10 GB，全解会白占 3-4 GB
  #    （vendor/odm 用 nabu 自己的，源机型的那份解出来也没有用）
  pdg_args=(-o "$OUTDIR" -c "$(nproc)")
  if [ -n "$ONLY" ]; then
    pdg_args+=(-p "$ONLY")
    info "只解这些分区：$ONLY"
  fi
  "$PDG" "${pdg_args[@]}" "$SCRATCH/payload.bin" \
    || die "payload-dumper-go 失败"
  ok "payload 解出 $(ls -1 "$OUTDIR"/*.img 2>/dev/null | wc -l) 个分区"
fi

# ── 3. super.img → 逻辑分区 ────────────────────────────────────────────────
SUPER="$SCRATCH/super.img"
if [ -f "$SUPER" ]; then
  if is_sparse "$SUPER"; then
    info "super.img 是 sparse，先展开"
    unsparse "$SUPER" "$SCRATCH/super.raw.img"
    SUPER="$SCRATCH/super.raw.img"
  fi
  if have lpunpack; then
    info "lpunpack 拆 super"
    lpunpack "$SUPER" "$OUTDIR" || die "lpunpack 失败"
  else
    die "输入是 fastboot 包（super.img），需要 lpunpack 才能拆逻辑分区。
     三选一：
       1) 改用 OTA zip（内含 payload.bin）作为 --input，本脚本可直接解；
       2) 自行提供 lpunpack（AOSP system/core/fs_mgr/liblp 里的 host 工具）放进 PATH；
       3) 先用别的工具把 super.img 拆成独立分区镜像，再用 --input <目录> 喂进来。"
  fi
  rm -f "$SCRATCH/super.raw.img"
fi

# ── 4. 其余裸镜像直接收下 ──────────────────────────────────────────────────
shopt -s nullglob
for f in "$SCRATCH"/*.img; do
  base="$(basename "$f")"
  [ "$base" = "super.img" ] && continue
  [ -f "$OUTDIR/$base" ] || cp -f "$f" "$OUTDIR/$base"
done
shopt -u nullglob

# ── 5. 每个镜像体检 + 建索引 ───────────────────────────────────────────────
mapfile -t IMAGES < <(find "$OUTDIR" -maxdepth 1 -name '*.img' | sort)
[ "${#IMAGES[@]}" -gt 0 ] || die "没有解出任何镜像，检查输入包结构" 2

INDEX="$OUTDIR/index.json"
{
  printf '{\n  "generated_at": "%s",\n  "input": "%s",\n  "images": [\n' \
    "$(now_iso)" "$(json_escape "$INPUT")"
  first=1
  for f in "${IMAGES[@]}"; do
    fs="$(detect_fs "$f")"
    size="$(bytes_of "$f")"
    sha="$(sha256_of "$f")"
    name="$(basename "$f" .img)"
    [ "$first" = "1" ] || printf ',\n'
    first=0
    printf '    {"name": "%s", "file": "%s", "bytes": %s, "sha256": "%s", "fs": "%s"}' \
      "$name" "$(basename "$f")" "$size" "$sha" "$fs"
    log "$(printf '%-16s %8s  %-8s %s' "$name" "$(human "$size")" "$fs" "$sha")"
  done
  printf '\n  ]\n}\n'
} > "$INDEX"

# ── 6. 必需分区检查 ────────────────────────────────────────────────────────
need_parts="${KEEP_LIST:-$(cfg config/target/nabu.toml partitions.take)}"
for p in $need_parts; do
  if [ -f "$OUTDIR/$p.img" ]; then
    ok "必需分区 $p.img 就位"
  else
    warn "缺少必需分区 $p.img —— 源包可能不带这个分区（部分机型合并进 system）"
  fi
done

ok "解包完成：${#IMAGES[@]} 个镜像，索引 $INDEX"
