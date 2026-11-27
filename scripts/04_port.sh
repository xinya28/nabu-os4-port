#!/usr/bin/env bash
# shellcheck shell=bash
#
# 04_port —— 移植层：把 OS4 的 system 侧改成"能在 nabu 的 vendor 上跑"的样子
#
#   scripts/04_port.sh [--images work/debloated] [--out work/ported]
#                      [--target-firmware <nabu 固件目录>] [--vndk-from <nabu system 树>]
#                      [--parts system,product] [--strict] [--dry-run]
#
# 这一阶段只做四件可核查的事，不做"魔法"：
#   1. 覆盖 port/overlay/<分区>/ 里的文件（面板参数、权限白名单等设备适配）；
#   2. 按 port/props/nabu.prop 改 build.prop（设备身份 / vendor ABI / 形态）；
#   3. 校验 hybrid 的假设是否成立（vndk 目录、tablet 形态）；
#   4. 记录保留分区（vendor 等）的 sha256，让"这份包基于哪份固件"可复现。
#
# 明确不做：不改 vendor 分区、不搬 blob、不 patch 二进制。那些属于
# "还需要真机迭代"的部分，见 docs/PORTING.md 的子系统矩阵。
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/image_lib.sh"

IMAGES="$WORK_ROOT/debloated"
OUT="$WORK_ROOT/ported"
MANIFEST="$REPO_ROOT/port/manifest.toml"
TARGET_FW=""
VNDK_FROM=""
PARTS=""
STRICT=0
DRY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --images)          IMAGES="$2"; shift 2 ;;
    --out)             OUT="$2"; shift 2 ;;
    --manifest)        MANIFEST="$2"; shift 2 ;;
    --target-firmware) TARGET_FW="$2"; shift 2 ;;
    --vndk-from)       VNDK_FROM="$2"; shift 2 ;;
    --parts)           PARTS="$2"; shift 2 ;;
    --strict)          STRICT=1; shift ;;
    --dry-run)         DRY=1; shift ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) die "未知参数 $1" 2 ;;
  esac
done

prepare_dirs
stage_banner "04 port (hybrid: OS4 system + nabu vendor)"
need_dir "$IMAGES" "先跑 scripts/03_debloat.sh"
need_file "$MANIFEST"

[ -n "$PARTS" ] || PARTS="$(cfg port/manifest.toml from_source.parts)"
PROP_TABLE_REL="$(cfg port/manifest.toml props.table "port/props/nabu.prop")"
PROP_TABLE="$REPO_ROOT/$PROP_TABLE_REL"
PROP_FILES="$(cfg port/manifest.toml props.files "build.prop")"
OVERLAY_DIR="$REPO_ROOT/$(cfg port/manifest.toml overlay.dir "port/overlay")"
OVERWRITE="$(cfg port/manifest.toml props.overwrite 1)"
REQ_VNDK="$(cfg port/manifest.toml validate.require_vndk_dir 1)"
REQ_TABLET="$(cfg port/manifest.toml validate.require_tablet_characteristic 1)"
FAIL_MISSING="$(cfg port/manifest.toml validate.fail_on_missing 0)"
[ "$STRICT" = "1" ] && FAIL_MISSING=1

need_file "$PROP_TABLE"
mkdir -p "$OUT" "$WORK_ROOT/port"

problems=()
warnings=()
declare -A PROP_STATS=()   # "part:status" → 次数
declare -A OVERLAY_COUNT=()

add_problem() { problems+=("$1"); warn "PROBLEM: $1"; }
add_warning() { warnings+=("$1"); warn "$1"; }

# ── 1. 保留分区：只记录 sha256，不复制二进制 ──────────────────────────────
kept_entries=()
if [ -n "$TARGET_FW" ] && [ -d "$TARGET_FW" ]; then
  info "目标固件目录：$TARGET_FW（只记录 sha256，不复制二进制）"
  for kp in $(cfg port/manifest.toml keep_from_target.parts); do
    f="$TARGET_FW/$kp.img"
    if [ -f "$f" ]; then
      kept_entries+=("$kp|$(sha256_of "$f")|$(bytes_of "$f")")
      log "保留 $kp.img  $(human "$(bytes_of "$f")")  $(sha256_of "$f")"
    else
      add_warning "保留分区 $kp.img 不在 $TARGET_FW —— 打包时会缺少它，刷写前需自行补上"
    fi
  done
else
  add_warning "未提供 --target-firmware：无法记录 vendor 侧基线，产物只能刷 system 侧"
fi

# ── 2. 逐分区注入 + 重打包 ─────────────────────────────────────────────────
for part in $PARTS; do
  img="$IMAGES/$part.img"
  if [ ! -f "$img" ]; then
    add_warning "$part.img 不存在（03 精简可能跳过），本 stage 也跳过"
    continue
  fi
  fs="$(detect_fs "$img")"
  case "$fs" in erofs|ext4) ;; *) add_warning "$part.img 格式 $fs，跳过移植注入"; continue ;; esac

  root="$WORK_ROOT/port/$part"
  info "[$part] 解包 $fs 镜像"
  require_free "$WORK_ROOT" 12 "解包 $part"
  extract_image "$img" "$fs" "$root"
  harvest_contexts "$root" "$part"

  # 2a. overlay
  n_overlay=0
  if [ -d "$OVERLAY_DIR/$part" ]; then
    info "[$part] 覆盖 overlay：$OVERLAY_DIR/$part"
    as_root cp -a "$OVERLAY_DIR/$part/." "$root/"
    n_overlay="$(find "$OVERLAY_DIR/$part" -type f | wc -l | tr -d ' ')"
  fi
  OVERLAY_COUNT["$part"]="$n_overlay"

  # 2b. props
  for pf in $PROP_FILES; do
    target="$root/$pf"
    if [ ! -f "$target" ]; then
      if [ "$pf" = "build.prop" ] && [ "$part" = "system" ]; then
        log "[$part] $pf 不存在，新建"
      else
        continue
      fi
    fi
    tsv="$WORK_ROOT/port/$part.$(echo "$pf" | tr '/' '_').props.tsv"
    propset_args=(--file "$target" --table "$PROP_TABLE" --report "$tsv")
    [ "$OVERWRITE" = "1" ] && propset_args+=(--overwrite)
    [ "$DRY" = "1" ] && propset_args+=(--dry-run)
    as_root python3 "$REPO_ROOT/tools/propset.py" "${propset_args[@]}" \
      || die "propset 失败：$part/$pf"
    if [ -f "$tsv" ]; then
      while IFS= read -r stat_line; do
        [ -n "${stat_line:-}" ] || continue
        status="${stat_line%%$'\t'*}"
        PROP_STATS["$part:$status"]=$(( ${PROP_STATS["$part:$status"]:-0} + 1 ))
      done < "$tsv"
      # 报告文件可能是 root 建的，读出来就够了
      chmod 644 "$tsv" 2>/dev/null || true
    fi
  done

  # 2c. VNDK：把 nabu 的 vndk 目录搬进来（可选，但往往是能开机的前提）
  vndk_ver="$(grep -hoE '^ro\.vndk\.version=[0-9]+' "$root/build.prop" 2>/dev/null | head -1 | cut -d= -f2 || true)"
  [ -n "${vndk_ver:-}" ] || vndk_ver="$(grep -hoE '^ro\.vndk\.version=[0-9]+' "$root/system/build.prop" 2>/dev/null | head -1 | cut -d= -f2 || true)"

  if [ -n "${vndk_ver:-}" ]; then
    have_vndk=0
    for cand in "$root/lib64/vndk-$vndk_ver" "$root/system/lib64/vndk-$vndk_ver" \
                "$root/lib/vndk-$vndk_ver" "$root/system/lib/vndk-$vndk_ver"; do
      [ -d "$cand" ] && have_vndk=1 && log "[$part] vndk-$vndk_ver 目录存在：${cand#$root/}"
    done
    if [ "$have_vndk" = "0" ]; then
      if [ -n "$VNDK_FROM" ] && [ -d "$VNDK_FROM" ]; then
        info "[$part] 从 $VNDK_FROM 搬运 vndk-$vndk_ver"
        for abi in lib64 lib; do
          src="$VNDK_FROM/$abi/vndk-$vndk_ver"
          [ -d "$src" ] || continue
          as_root mkdir -p "$root/$abi"
          as_root cp -a "$src" "$root/$abi/"
          log "[$part] 注入 $abi/vndk-$vndk_ver"
        done
      fi
      if [ "$REQ_VNDK" = "1" ]; then
        add_problem "$part 声称 ro.vndk.version=$vndk_ver，但镜像里没有 vndk-$vndk_ver 目录；vendor 侧 HAL 很可能在 linker 阶段就起不来（用 --vndk-from 注入）"
      else
        add_warning "$part 缺少 vndk-$vndk_ver 目录（校验已关闭）"
      fi
    fi
  else
    log "[$part] 未声明 ro.vndk.version（该分区不需要，或属性在别处）"
  fi

  # 2d. tablet 形态
  if [ "$REQ_TABLET" = "1" ] && [ "$part" = "system" ]; then
    chars="$(grep -hoE '^ro\.build\.characteristics=.*' "$root/build.prop" 2>/dev/null | head -1 || true)"
    case "$chars" in
      *tablet*) ok "[$part] 形态检查通过：$chars" ;;
      *) add_problem "system/build.prop 的 ro.build.characteristics 不含 tablet（当前：${chars:-未设置}）；OS4 会按手机布局加载资源" ;;
    esac
  fi

  # 2e. 重打包
  if [ "$DRY" = "1" ]; then
    info "[$part] dry-run：不重打包"
  else
    info "[$part] 重打包 → $OUT/$part.img"
    repack_image "$root" "$img" "$OUT/.$part.img.tmp" "$fs" "$part"
    mv -f "$OUT/.$part.img.tmp" "$OUT/$part.img"
    out_size="$(bytes_of "$OUT/$part.img")"
    in_size="$(bytes_of "$img")"
    log "[$part] $(human "$in_size") → $(human "$out_size")"
  fi
  rm -rf "$root"
done

# 未处理的分区原样带过去，保证下游只认 $OUT
if [ "$DRY" = "0" ]; then
  for f in "$IMAGES"/*.img; do
    [ -f "$f" ] || continue
    b="$(basename "$f")"
    [ -f "$OUT/$b" ] || cp -f "$f" "$OUT/$b"
  done
fi

# ── 3. 报告 ────────────────────────────────────────────────────────────────
REPORT="$OUT/port-report.md"
{
  echo "# 移植层报告"
  echo
  echo "- 生成时间: $(now_iso)"
  echo "- 源镜像  : \`$IMAGES\`"
  echo "- 目标固件: \`${TARGET_FW:-未提供}\`"
  echo "- 严格模式: $([ "$FAIL_MISSING" = "1" ] && echo 是 || echo 否)"
  echo
  echo "## 组成"
  echo
  echo "| 分区 | 来源 |"
  echo "| --- | --- |"
  for p in $PARTS; do echo "| \`$p\` | OS4 源机型（经精简 + 注入） |"; done
  for p in $(cfg port/manifest.toml keep_from_target.parts); do echo "| \`$p\` | nabu 原厂固件（不随包分发） |"; done
  echo
  echo "## 属性注入"
  echo
  echo "| 分区 | 新增 | 覆盖 | 未变 | 跳过 |"
  echo "| --- | --- | --- | --- | --- |"
  for p in $PARTS; do
    echo "| \`$p\` | ${PROP_STATS["$p:appended"]:-0} | ${PROP_STATS["$p:replaced"]:-0} | ${PROP_STATS["$p:unchanged"]:-0} | ${PROP_STATS["$p:skipped"]:-0} |"
  done
  echo
  echo "## overlay"
  echo
  for p in $PARTS; do echo "- \`$p\`: ${OVERLAY_COUNT[$p]:-0} 个文件"; done
  echo
  if [ "${#problems[@]}" -gt 0 ]; then
    echo "## 阻塞问题"
    echo
    for x in "${problems[@]}"; do echo "- $x"; done
    echo
  fi
  if [ "${#warnings[@]}" -gt 0 ]; then
    echo "## 警告"
    echo
    for x in "${warnings[@]}"; do echo "- $x"; done
    echo
  fi
} > "$REPORT"

MANIFEST_JSON="$OUT/port-manifest.json"
{
  printf '{\n  "generated_at": "%s",\n  "strict": %s,\n  "images": "%s",\n' \
    "$(now_iso)" "$([ "$FAIL_MISSING" = "1" ] && echo true || echo false)" "$(json_escape "$IMAGES")"
  printf '  "target_firmware": "%s",\n  "source_parts": "%s",\n  "kept_parts": [\n' \
    "$(json_escape "$TARGET_FW")" "$PARTS"
  first=1
  for e in "${kept_entries[@]:-}"; do
    [ -n "$e" ] || continue
    IFS='|' read -r p s b <<<"$e"
    [ "$first" = "1" ] || printf ',\n'
    first=0
    printf '    {"part": "%s", "sha256": "%s", "bytes": %s}' "$p" "$s" "$b"
  done
  printf '\n  ],\n  "problems": ['
  first=1
  for x in "${problems[@]:-}"; do
    [ -n "$x" ] || continue
    [ "$first" = "1" ] || printf ', '
    first=0
    printf '"%s"' "$(json_escape "$x")"
  done
  printf '],\n  "warnings": ['
  first=1
  for x in "${warnings[@]:-}"; do
    [ -n "$x" ] || continue
    [ "$first" = "1" ] || printf ', '
    first=0
    printf '"%s"' "$(json_escape "$x")"
  done
  printf ']\n}\n'
} > "$MANIFEST_JSON"

if [ "${#problems[@]}" -gt 0 ] && [ "$FAIL_MISSING" = "1" ]; then
  die "移植层校验失败（${#problems[@]} 个阻塞问题），见 $REPORT" 4
fi

ok "移植层完成：报告 $REPORT"
