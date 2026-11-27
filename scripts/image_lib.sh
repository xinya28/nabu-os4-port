#!/usr/bin/env bash
# shellcheck shell=bash
#
# 镜像重打包 —— 03_debloat.sh 与 04_port.sh 共用同一套实现。
#
# 为什么单独一个文件：erofs 重打包有三个"错了不报错、只是开不了机"的点：
#   1. 块大小与原镜像不一致 → 部分 bootloader/vendor 的 dm-verity 尺寸假设错位；
#   2. 原镜像有压缩、重打包没压缩 → 分区塞不下（system 往往刚好卡着 super 的剩余空间）；
#   3. 丢了 file_contexts → SELinux 在 enforcing 下把 init 自己拒掉。
# 这三件事集中在这里做，改一次就两个 stage 都受益。
#
# 依赖：lib.sh（log/warn/die/as_root）、mkfs.erofs、dump.erofs、mke2fs。

SELINUX_DIR="${SELINUX_DIR:-$WORK_ROOT/selinux}"

# 从解包树里收集该分区自带的 SELinux 上下文表。
# 命名带分区前缀，避免 system 的 plat_file_contexts 被 product 的同名文件覆盖。
harvest_contexts() {
  local root="$1" part="$2" n=0
  mkdir -p "$SELINUX_DIR"
  while IFS= read -r -d '' f; do
    cp -f "$f" "$SELINUX_DIR/${part}.$(basename "$f")" && n=$((n + 1))
  done < <(find "$root" -type f -name '*_file_contexts' 2>/dev/null)
  log "file_contexts: 从 $part 收集到 $n 个"
}

# 合并成 mkfs.erofs 能吃的单个文件；system 的放最前面（优先级最低，后者覆盖前者）
merged_contexts() {
  local merged="$SELINUX_DIR/merged_file_contexts"
  mkdir -p "$SELINUX_DIR"
  : > "$merged"
  local part f
  for part in system system_ext product vendor odm; do
    for f in "$SELINUX_DIR/$part".*_file_contexts; do
      [ -f "$f" ] || continue
      cat "$f" >> "$merged"
    done
  done
  # 兜底：任何名字的 *_file_contexts 都收进来
  for f in "$SELINUX_DIR"/*_file_contexts; do
    case "$(basename "$f")" in
      merged_file_contexts) continue ;;
      system.*|system_ext.*|product.*|vendor.*|odm.*) continue ;;
    esac
    [ -f "$f" ] && cat "$f" >> "$merged"
  done
  if [ -s "$merged" ]; then printf '%s\n' "$merged"; fi
}

# erofs_original_params <img> → 输出 "<block_size> <compression_or_empty>"
erofs_original_params() {
  local img="$1" stat_out bs comp
  stat_out="$(dump.erofs -s "$img" 2>/dev/null || true)"
  bs="$(grep -oiE 'block size[: ]+[0-9]+' <<<"$stat_out" | grep -oE '[0-9]+' | head -1 || true)"
  [ -n "${bs:-}" ] || bs=4096
  if grep -qiE 'compressed' <<<"$stat_out"; then
    comp="-zlz4hc,10"
  else
    comp=""
  fi
  printf '%s %s\n' "$bs" "$comp"
}

repack_erofs() {
  local root="$1" orig="$2" dest="$3"
  local ctx params bs comp args=()
  ctx="$(merged_contexts)"
  read -r bs comp <<<"$(erofs_original_params "$orig")"

  args=(-b "$bs" --mount-point=/ -T 1230768000)
  [ -n "$comp" ] && args+=("$comp")
  if [ -n "$ctx" ]; then
    args+=(--file-contexts "$ctx")
  else
    warn "没有找到任何 file_contexts，重打包出来的镜像在 enforcing 下可能起不来"
  fi

  log "mkfs.erofs -b $bs ${comp:-不压缩}$( [ -n "$ctx" ] && echo ' + contexts' )"
  as_root mkfs.erofs "${args[@]}" "$dest" "$root" || die "mkfs.erofs 失败（$root）"
  dump.erofs --stat "$dest" >/dev/null 2>&1 || die "生成的 erofs 校验失败：$dest"
}

repack_ext4() {
  local root="$1" dest="$2" label="${3:-android}"
  local kb
  kb=$(( $(du -sk "$root" | cut -f1) * 12 / 10 + 32768 ))
  warn "ext4 重打包会丢 SELinux label（非 SELinux 主机写不了 security.* xattr）"
  as_root mke2fs -q -t ext4 -b 4096 -L "$label" -d "$root" -F "$dest" "${kb}K" \
    || die "mke2fs 失败（$root）"
}

# repack_image <root> <orig> <dest> <fs> <label>
repack_image() {
  local root="$1" orig="$2" dest="$3" fs="$4" label="${5:-android}"
  rm -f "$dest"
  case "$fs" in
    erofs) repack_erofs "$root" "$orig" "$dest" ;;
    ext4)  repack_ext4  "$root" "$dest" "$label" ;;
    f2fs)  die "f2fs 重打包未实现：$label。这类分区用 profile=none 跳过精简/移植" ;;
    *)     die "不支持重打包的分区格式 '$fs'：$label" ;;
  esac
}
