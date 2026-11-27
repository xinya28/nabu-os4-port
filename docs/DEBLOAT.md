# 精简（debloat）：为什么这么设计

精简是整条链路里**最容易做错、又最难发现**的一步：删错了不会报错，只会在半小时后
变成一次 bootloop。所以 `03_debloat.sh` 的设计目标不是"删得多"，而是**删得可解释**。

## 1. 按 package 名匹配，不按目录名

真实固件里目录名和包名不是一一对应的（`MiuiVideo` 目录里可能是
`com.miui.videoplayer`），用目录名匹配必然错配。所以：

1. `tools/pkgscan.py` 解析每个 APK 里 **二进制 AndroidManifest.xml**（AXML）的
   `manifest/@package` 属性，得到权威包名；
2. `tools/matchpkg.py` 把它和清单求交集；
3. 只有交集里的目录会被 `rm -rf`。

自己写 AXML 解析而不是装 `aapt`/`apkanalyzer`，是因为 CI 上装 Android SDK 要几个 G，
而这里只需要一个属性。

## 2. 三层安全阀

| 层 | 机制 | 失败时 |
| --- | --- | --- |
| 档位 | `config/profiles.toml` 的 tier 选择 | 不在档位里的条目根本不会进待删集合 |
| 保护名单 | `debloat/keep.txt` | 待删集合与保护名单有交集 ⇒ **exit 3，不删任何文件** |
| 条目可空 | 清单里不存在的包 | 静默忽略（不同机型组件差异大），但报告里单列"未命中" |

第一条对应 `minimal` 档只删纯应用层；第二条防的是"手滑把 `com.miui.home` 写进
packages.txt"这种错误——它是配置错误，必须当场中止，而不是跳过继续。

## 3. 为什么用 `file_contexts` 而不是保留 xattr

解包时如果能把 `security.selinux` xattr 原样带回来，重打包就"无损"了。但：
非 SELinux 主机（GitHub runner 就是）**没有权限写 `security.*` xattr**，
`cp -a` / `fsck.erofs --extract` 都拿不到标签。

所以正确做法是反过来：解包只要 `uid/gid/mode`（这个 root 能保留），
标签在建镜像时**由 `mkfs.erofs --file-contexts` 从上下文表重新套上去**。
上下文表本身是普通文本文件，从镜像里的 `*/etc/selinux/*_file_contexts` 取即可。

`scripts/image_lib.sh` 的 `harvest_contexts()` 会把各分区的上下文表收集到
`work/selinux/`，`merged_contexts()` 按 `system → system_ext → product` 顺序合并
（后者覆盖前者，和 Android 的优先级一致）。

## 4. 为什么必须 root

`fsck.erofs --extract` 和 `cp -a` 只有在 euid=0 时才保留 uid/gid。
以普通用户解包，重打包出来的 `system.img` 会全部变成 `root:root`，
`system_server` 找不到自己需要的属主文件，表现同样是**卡第一屏**。

`00_preflight.sh` 会检查免密 sudo；没有就明确警告，而不是"跑完看起来成功"。

## 5. 继承原镜像的参数

`erofs_original_params()` 从原镜像 superblock 里读两块：

- **块大小**：不继承的话，dm-verity / super 的尺寸假设可能错位；
- **是否压缩**：原镜像没压缩就不要引入压缩（反过来也一样）——
  `system` 往往正好卡着 super 剩余空间，压缩策略变了可能导致放不下。

时间戳固定成 `1230768000`（2009-01-01），让同样的输入得到同样的输出（可复现）。

## 6. ext4 的已知限制

`ext4` 分区重打包走 `mke2fs -d`，**会丢 SELinux 标签**（同第 3 节的原因）。
`03_debloat.sh` 对 ext4 会打印警告，`docs/PORTING.md` 也记了这一条。
现代 OS4 机型的 `system/product/system_ext` 基本都是 erofs，所以主路径不受影响；
`vendor` 是 ext4，但它本来就不在精简范围里。

## 7. 怎么审查一次精简

1. 先跑 `--dry-run`：只解包 + 扫描 + 匹配，不删除、不重打包；
2. 看 `out/debloated/debloat-report.txt`：
   - "命中"列表里的每一项都是 `包名 + 大小 + 目录`，可以逐条判断；
   - "未命中"列表告诉你清单里哪些条目对这份固件不适用（据此清理清单）；
3. 确认没问题再用 `balanced` / `aggressive` 实跑；
4. 实跑后 `out/debloated/debloat-summary.json` 里每个分区的 `after_bytes`
   必须 > 0（`07_verify.sh` 会检查这一点，防"重打包失败但被吞掉"）。

## 8. 回滚

精简只改 `work/debloated/` 与 `work/ported/` 下的产物，**不碰** `work/images/`
（02 解包出来的原始镜像）。想回到未精简状态：

```bash
scripts/03_debloat.sh --profile none      # 直接把原镜像带过去
```

或者干脆重跑 `02_unpack.sh`（幂等，会覆盖 `work/images`）。
