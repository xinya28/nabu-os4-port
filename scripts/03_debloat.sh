#!/usr/bin/env bash
# shellcheck shell=bash
#
# 03_debloat —— 精简 system / product / system_ext
#
#   scripts/03_debloat.sh [--images work/images] [--profile balanced]
#                         [--parts system,product] [--out work/debloated]
#                         [--list debloat/packages.txt] [--keep debloat/keep.txt]
#                         [--dry-run] [--keep-extracted]
#
# 做三件事，每件都可单独核对：
#   1. 解包每个分区，用 AXML 解析出真实的包名（不是目录名）；
#   2. 按 profile 选中 tier，与 keep 名单求差集后删除 APK 目录；
#   3. 用原镜像的参数（块大小 / 压缩 / file_contexts）重新生成 erofs。
#
# 安全阀：profile 选中的包若命中 debloat/keep.txt，直接 exit 3，不删任何文件。
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/image_lib.sh"

IMAGES="$WORK_ROOT/images"
PROFILE="balanced"
LIST="$REPO_ROOT/debloat/packages.txt"
KEEP="$REPO_ROOT/debloat/keep.txt"
OUT="$WORK_ROOT/debloated"
PARTS=""
DRY=0
KEEP_EXTRACTED=0

while [ $# -gt 0 ]; do
  case "$1" in
    --images)         IMAGES="$2"; shift 2 ;;
    --profile)        PROFILE="$2"; shift 2 ;;
    --parts)          PARTS="$2"; shift 2 ;;
    --out)            OUT="$2"; shift 2 ;;
    --list)           LIST="$2"; shift 2 ;;
    --keep)           KEEP="$2"; shift 2 ;;
    --dry-run)        DRY=1; shift ;;
    --keep-extracted) KEEP_EXTRACTED=1; shift ;;
    -h|--help)        sed -n '2,16p' "$0"; exit 0 ;;
    *) die "未知参数 $1" 2 ;;
  esac
done

prepare_dirs
stage_banner "03 debloat (profile=$PROFILE)"
need_file "$LIST"
need_file "$KEEP"
need_dir "$IMAGES" "先跑 scripts/02_unpack.sh"

EXTRACT="$WORK_ROOT/extract"
SELINUX_DIR="$WORK_ROOT/selinux"
export SELINUX_DIR
mkdir -p "$OUT" "$WORK_ROOT/debloat" "$EXTRACT" "$SELINUX_DIR"

# ── 1. profile → tier 集合 ─────────────────────────────────────────────────
TIERS=""
if [ "$PROFILE" != "none" ]; then
  TIERS="$(python3 "$REPO_ROOT/tools/cfg.py" get "$REPO_ROOT/config/profiles.toml" "profile.$PROFILE.tiers" "")"
  [ -n "$TIERS" ] || die "未知 profile '$PROFILE'（可选：none / minimal / balanced / aggressive）" 2
fi
log "profile=$PROFILE tiers=[${TIERS:-无}]"

# ── 2. 生成待删集合 ────────────────────────────────────────────────────────
WANTED="$WORK_ROOT/debloat/wanted.txt"
: > "$WANTED"
while IFS= read -r raw || [ -n "$raw" ]; do
  line="$(strip_comment "$raw")"
  [ -z "$line" ] && continue
  read -r tier pkg _rest <<<"$line"
  [ -n "${pkg:-}" ] || continue
  case " $TIERS " in
    *" $tier "*) printf '%s\n' "$pkg" >> "$WANTED" ;;
  esac
done < "$LIST"

declare -A KEEPSET=()
while IFS= read -r raw || [ -n "$raw" ]; do
  line="$(strip_comment "$raw")"
  [ -z "$line" ] && continue
  read -r pkg _rest <<<"$line"
  [ -n "${pkg:-}" ] && KEEPSET["$pkg"]=1
done < "$KEEP"

# ── 3. 安全阀：待删 ∩ 保护名单 → 立刻中止 ─────────────────────────────────
conflicts=()
while IFS= read -r pkg; do
  [ -n "$pkg" ] || continue
  if [ -n "${KEEPSET[$pkg]:-}" ]; then conflicts+=("$pkg"); fi
done < "$WANTED"

if [ "${#conflicts[@]}" -gt 0 ]; then
  for c in "${conflicts[@]}"; do printf '  - %s\n' "$c" >&2; done
  die "debloat/packages.txt 与 debloat/keep.txt 冲突（上面这些包不许删）。
     这是配置错误，不是运行时错误：把该行从 packages.txt 删掉，或从 keep.txt 移除。
     构建已中止，未删除任何文件。" 3
fi
ok "保护名单检查通过（待删 $(wc -l < "$WANTED" | tr -d ' ') 个包，无冲突）"

# ── 4. 逐分区处理 ──────────────────────────────────────────────────────────
[ -n "$PARTS" ] || PARTS="$(cfg config/target/nabu.toml partitions.take)"
REPORT="$OUT/debloat-report.txt"
SUMMARY="$OUT/debloat-summary.json"
{
  echo "# debloat report"
  echo
  echo "- generated: $(now_iso)"
  echo "- profile  : $PROFILE (tiers: ${TIERS:-none})"
  echo "- source   : $IMAGES"
  echo
} > "$REPORT"

total_saved=0
declare -a summary_rows=()

for part in $PARTS; do
  img="$IMAGES/$part.img"
  if [ ! -f "$img" ]; then
    warn "$part.img 不存在，跳过"
    continue
  fi
  fs="$(detect_fs "$img")"
  case "$fs" in
    erofs|ext4|f2fs) ;;
    *) warn "$part.img 格式为 '$fs'，跳过精简"; continue ;;
  esac

  in_size="$(bytes_of "$img")"
  root="$EXTRACT/$part"
  info "[$part] $fs $(human "$in_size") → 解包"
  require_free "$WORK_ROOT" 12 "解包 $part"
  extract_image "$img" "$fs" "$root"
  harvest_contexts "$root" "$part"

  PKGS="$WORK_ROOT/debloat/$part.pkgs.json"
  python3 "$REPO_ROOT/tools/pkgscan.py" --root "$root" --json "$PKGS" \
    || die "包名扫描失败：$part"

  HITS="$WORK_ROOT/debloat/$part.hits.tsv"
  MISSES="$WORK_ROOT/debloat/$part.misses.txt"
  python3 "$REPO_ROOT/tools/matchpkg.py" --json "$PKGS" --wanted "$WANTED" \
    --hits "$HITS" --misses "$MISSES" || die "包匹配失败：$part"

  n_hit="$(wc -l < "$HITS" | tr -d ' ')"
  saved=0
  {
    echo "## $part  ($fs, $(human "$in_size"))"
    echo
    echo "命中 $n_hit 个待删包："
    echo
  } >> "$REPORT"

  if [ "$n_hit" -gt 0 ]; then
    while IFS=$'\t' read -r dir pkg bytes; do
      [ -n "$dir" ] || continue
      saved=$((saved + bytes))
      echo "  - \`$pkg\`  $(human "$bytes")  ($dir)" >> "$REPORT"
      if [ "$DRY" = "0" ]; then
        if [ -d "$root/$dir" ]; then
          as_root rm -rf "${root:?}/$dir"
        else
          warn "$part: 目录不存在 $dir（包 $pkg）"
        fi
      fi
    done < "$HITS"
  else
    echo "  （本分区没有命中任何条目）" >> "$REPORT"
  fi

  if [ -s "$MISSES" ]; then
    {
      echo
      echo "这份固件里不存在（清单条目未命中，可能是别的机型/版本）："
      sed 's/^/  - /' "$MISSES"
    } >> "$REPORT"
  fi
  echo >> "$REPORT"

  total_saved=$((total_saved + saved))

  if [ "$DRY" = "1" ]; then
    info "[$part] dry-run：命中 $n_hit 个包，可回收 $(human "$saved")，不重打包"
    summary_rows+=("$part|$in_size|$in_size|$n_hit|$saved|dry-run")
    rm -rf "$root"
    continue
  fi

  out_img="$OUT/$part.img"
  tmp_img="$OUT/.$part.img.tmp"
  rm -f "$tmp_img"
  info "[$part] 重打包（已删 $n_hit 个包，回收 $(human "$saved")）"
  repack_image "$root" "$img" "$tmp_img" "$fs" "$part"
  mv -f "$tmp_img" "$out_img"
  out_size="$(bytes_of "$out_img")"
  log "[$part] $(human "$in_size") → $(human "$out_size")"

  {
    echo "结果：$(human "$in_size") → $(human "$out_size")  ($(basename "$out_img"))"
    echo
  } >> "$REPORT"

  summary_rows+=("$part|$in_size|$out_size|$n_hit|$saved|ok")

  if [ "$KEEP_EXTRACTED" = "0" ]; then rm -rf "$root"; fi
done

# profile=none / dry-run 之外，把未处理的分区原样带过去：下游只认 $OUT
if [ "$DRY" = "0" ]; then
  for f in "$IMAGES"/*.img; do
    [ -f "$f" ] || continue
    b="$(basename "$f")"
    [ -f "$OUT/$b" ] || cp -f "$f" "$OUT/$b"
  done
fi

# ── 5. 汇总 ────────────────────────────────────────────────────────────────
{
  printf '{\n  "generated_at": "%s",\n  "profile": "%s",\n  "tiers": "%s",\n  "dry_run": %s,\n' \
    "$(now_iso)" "$PROFILE" "$TIERS" "$([ "$DRY" = "1" ] && echo true || echo false)"
  printf '  "saved_bytes_total": %s,\n  "parts": [\n' "$total_saved"
  first=1
  for row in "${summary_rows[@]:-}"; do
    [ -n "$row" ] || continue
    IFS='|' read -r p in_s out_s n saved status <<<"$row"
    [ "$first" = "1" ] || printf ',\n'
    first=0
    printf '    {"part": "%s", "before_bytes": %s, "after_bytes": %s, "removed": %s, "removed_bytes": %s, "status": "%s"}' \
      "$p" "$in_s" "$out_s" "$n" "$saved" "$status"
  done
  printf '\n  ]\n}\n'
} > "$SUMMARY"

ok "精简完成：共回收 $(human "$total_saved")；报告 $REPORT"
