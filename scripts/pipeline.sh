#!/usr/bin/env bash
# shellcheck shell=bash
#
# pipeline —— 一条命令跑完 01→07
#
#   scripts/pipeline.sh --rom-url <URL> [--sha256 <hex>] [--source pad8]
#                       [--profile balanced] [--target-firmware DIR]
#                       [--vndk-from DIR] [--boot-in <原厂 boot.img>]
#                       [--strict] [--skip-kernel] [--stages 01,02,03]
#
# 每个 stage 都可以单独重跑（产物目录互不覆盖），所以失败时不用从头来：
#   直接看日志最后一行是哪个 stage，修完单独跑那一个，再跑 --stages 06,07。
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROM_URL=""
ROM_SHA=""
SOURCE_ID=""
PROFILE="balanced"
TARGET_FW=""
VNDK_FROM=""
BOOT_IN=""
STRICT=""
SKIP_KERNEL=0
STAGES="01,02,03,04,05,06,07"

while [ $# -gt 0 ]; do
  case "$1" in
    --rom-url)         ROM_URL="$2"; shift 2 ;;
    --sha256)          ROM_SHA="$2"; shift 2 ;;
    --source)          SOURCE_ID="$2"; shift 2 ;;
    --profile)         PROFILE="$2"; shift 2 ;;
    --target-firmware) TARGET_FW="$2"; shift 2 ;;
    --vndk-from)       VNDK_FROM="$2"; shift 2 ;;
    --boot-in)         BOOT_IN="$2"; shift 2 ;;
    --strict)          STRICT="--strict"; shift ;;
    --skip-kernel)     SKIP_KERNEL=1; shift ;;
    --stages)          STAGES="$2"; shift 2 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) die "未知参数 $1" 2 ;;
  esac
done

prepare_dirs
PIPE_START="$(date +%s)"
declare -a RUN=()

run_stage() {
  local name="$1"; shift
  local t0 t1
  info "════════ $name ════════"
  t0="$(date +%s)"
  "$@" || die "stage $name 失败" 6
  t1="$(date +%s)"
  RUN+=("$name|$((t1 - t0))")
  ok "$name 用时 $((t1 - t0))s"
}

for st in ${STAGES//,/ }; do
  case "$st" in
    00) run_stage "00 preflight" env LOG_TAG="$LOG_TAG" bash "$REPO_ROOT/scripts/00_preflight.sh" ;;
    01)
      [ -n "$ROM_URL" ] || die "stage 01 需要 --rom-url" 2
      args=(bash "$REPO_ROOT/scripts/01_fetch.sh" --url "$ROM_URL")
      [ -n "$ROM_SHA" ] && args+=(--sha256 "$ROM_SHA")
      [ -n "$SOURCE_ID" ] && args+=(--source "$SOURCE_ID")
      run_stage "01 fetch" "${args[@]}" ;;
    02)
      # 取 work/rom 里最新的那个非 json 文件（01 会写 fetch.json）
      ROM_FILE=""
      for f in "$WORK_ROOT/rom"/*; do
        [ -f "$f" ] || continue
        case "$f" in *.json) continue ;; esac
        if [ -z "$ROM_FILE" ] || [ "$f" -nt "$ROM_FILE" ]; then ROM_FILE="$f"; fi
      done
      [ -n "$ROM_FILE" ] || die "stage 02 找不到 ROM 文件（先跑 01）" 2
      run_stage "02 unpack" bash "$REPO_ROOT/scripts/02_unpack.sh" --input "$ROM_FILE" ;;
    03)
      run_stage "03 debloat" bash "$REPO_ROOT/scripts/03_debloat.sh" --profile "$PROFILE" ;;
    04)
      args=(bash "$REPO_ROOT/scripts/04_port.sh")
      [ -n "$TARGET_FW" ] && args+=(--target-firmware "$TARGET_FW")
      [ -n "$VNDK_FROM" ] && args+=(--vndk-from "$VNDK_FROM")
      [ -n "$STRICT" ] && args+=("$STRICT")
      run_stage "04 port" "${args[@]}" ;;
    05)
      if [ "$SKIP_KERNEL" = "1" ]; then
        warn "--skip-kernel：跳过 05"
      else
        args=(bash "$REPO_ROOT/scripts/05_kernel.sh")
        [ -n "$BOOT_IN" ] && args+=(--boot-in "$BOOT_IN")
        run_stage "05 kernel" "${args[@]}"
      fi ;;
    06)
      args=(bash "$REPO_ROOT/scripts/06_package.sh")
      [ -n "$TARGET_FW" ] && args+=(--target-firmware "$TARGET_FW")
      run_stage "06 package" "${args[@]}" ;;
    07) run_stage "07 verify" bash "$REPO_ROOT/scripts/07_verify.sh" ;;
    *) die "未知 stage: $st（可用：00 01 02 03 04 05 06 07）" 2 ;;
  esac
done

# 汇总
TOTAL=$(( $(date +%s) - PIPE_START ))
REPORT="$OUT_ROOT/pipeline-summary.txt"
{
  echo "nabu-os4-port pipeline"
  echo "generated: $(now_iso)"
  echo "source   : ${SOURCE_ID:-unknown}"
  echo "profile  : $PROFILE"
  echo "stages   : $STAGES"
  echo
  printf '%-16s %6s\n' "stage" "秒"
  for row in "${RUN[@]}"; do
    IFS='|' read -r n s <<<"$row"
    printf '%-16s %6s\n' "$n" "$s"
  done
  echo
  echo "total: ${TOTAL}s"
  echo
  echo "产物："
  ls -lh "$OUT_ROOT/package" 2>/dev/null | sed 's/^/  /' || echo "  （没有 package 目录）"
} | tee "$REPORT"

ok "流水线完成，耗时 ${TOTAL}s，报告 $REPORT"
