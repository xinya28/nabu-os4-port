<div align="center">

# nabu-os4-port

**小米平板 5（nabu / SM8150-AC）移植 澎湃OS 4 / Android 17 的构建流水线**

[![](https://img.shields.io/badge/powered_by-dsh-4D6BFE?style=flat-square&logo=deepseek&logoColor=white)](https://github.com/deepseek-ai/deepseek-harness)
[![Device](https://img.shields.io/badge/device-nabu_%2F_Xiaomi_Pad_5-FF6900?style=flat-square)](config/target/nabu.toml)
[![Source](https://img.shields.io/badge/source-OS4_%2F_Android_17-4D6BFE?style=flat-square)](config/sources.toml)
[![Kernel](https://img.shields.io/badge/kernel-4.14.180_%2B_nabu_drivers-0F6CBD?style=flat-square)](docs/KERNEL.md)
[![CI](https://img.shields.io/badge/CI-GitHub_Actions-2EA043?style=flat-square&logo=githubactions&logoColor=white)](.github/workflows)
[![License](https://img.shields.io/badge/license-GPL--2.0--only-CA5010?style=flat-square)](LICENSE)

</div>

---

## 这是什么

一条**可复现、可在 GitHub Actions 上跑**的流水线，把「拿另一台小米平板的澎湃OS 4
移植到小米平板 5」拆成七个能单独验证的阶段：

```
01 fetch ──► 02 unpack ──► 03 debloat ──► 04 port ──► 06 package ──► 07 verify
                                                            ▲
                                             05 kernel ─────┘
```

| 阶段 | 干什么 | 关键点 |
| --- | --- | --- |
| `01 fetch` | 下源固件 | sha256 校验；支持 `file://` 本地包 |
| `02 unpack` | 拆成裸分区镜像 | OTA `payload.bin` 用 payload-dumper-go；fastboot 包要 `lpunpack` |
| `03 debloat` | 精简 | 按 **AXML 解析出的真实包名**删，不按目录名；保护名单冲突直接中止 |
| `04 port` | 移植注入 | 设备身份 / vendor ABI / tablet 形态 / overlay，并**校验 hybrid 前提** |
| `05 kernel` | 内核 | 4.14.180 + 平板驱动 + 熄屏挂起门控，出 AnyKernel3 |
| `06 package` | 打包 | 逐分区镜像 + 刷写脚本；>1.8 GiB 自动切分 |
| `07 verify` | 自检 | 校验和、erofs 完整性、boot.img 结构 |

**仓库里没有任何厂商二进制。** 固件由你提供（`rom_url`），产物在你的 Actions 里构建。

## 先说清楚：现在到哪了

| 能力 | 状态 |
| --- | --- |
| 内核构建（4.14.180 + 平板驱动整合 + autosleep 门控） | ✅ **已在真机验证**（`fastboot boot`，`success=14`，详见 [KERNEL.md](docs/KERNEL.md)） |
| 精简 / 移植注入 / 打包 / 自检 | 🧪 已实现，**未用真实 OS4 固件跑过** |
| OS4 在 nabu 上开机 | ❌ **未验证** |

完整清单见 [docs/STATUS.md](docs/STATUS.md)。这张表是权威版本，README 不重复免责声明。

## 为什么不能"把源机型的包整个刷进来"

因为 `vendor` / `odm` / `vendor_dlkm` 是绑着 SoC、面板、触控 IC、PMIC 的：

| 层 | 换 SoC 后 |
| --- | --- |
| bootloader / 分区表 | ❌ 槽位与 super 布局都不同 |
| vendor / odm / vendor_dlkm | ❌ HAL 直接对着硬件寄存器 |
| 内核 | ❌ 源机型的 dtb 描述的是另一块板子 |

所以只能 **hybrid**：

```
OS4 源机型  ──►  system / product / system_ext   （框架、系统应用、UI）
nabu 自己   ──►  vendor / odm / vendor_dlkm / dtbo / vendor_boot
本仓库      ──►  boot（4.14.180 + 平板驱动）
```

`port/manifest.toml` 是这张图的机器可读版本，`04_port.sh` 按它组装并校验。
三道真正的坎（VNDK、HIDL→AIDL、SELinux）和排查树在 [docs/PORTING.md](docs/PORTING.md)。

## 用 GitHub Actions 跑

### 内核（不依赖 ROM，先跑这个）

`Actions → build-kernel → Run workflow`

| 输入 | 默认 | 说明 |
| --- | --- | --- |
| `branch` | `nabu-w-oss-bks` | 内核源码分支（带 BakaSU + SUSFS） |
| `localversion` | `-perf` | UTS 后缀 |
| `perf` | ✅ | BBR / fq_codel / BFQ |
| `autosleep` | ✅ | 熄屏挂起 + 屏幕状态门控 |
| `ksu_version` | 空 | 固定 KSU_VERSION |

产物：`nabu-kernel-<branch>-<sha>.zip`（AnyKernel3）、裸 `Image`、`SHA256SUMS.kernel`。

### ROM

`Actions → build-rom → Run workflow`

| 输入 | 必填 | 说明 |
| --- | --- | --- |
| `source` | ✅ | 源机型**代号**：`yupei`(Pad 8/9) `piano`(Pad 8 Pro) `uke`(Pad 7) `muyu`(Pad 7 Pro) `jinghu`(Pad 7 Ultra) `violin`(Pad 7S Pro) `yili`(K Pad 2) `yingtian`(Pad 9 Pro Max) |
| `rom_url` | 空即可 | 留空 ⇒ 按 `source` 现查最新 OS4 固件并自动挑可用镜像；填了就完全走你给的链接 |
| `rom_sha256` | 可选 | 留空只记录不校验（第一次跑用它拿到值） |
| `debloat_profile` | ✅ | `none` / `minimal` / `balanced` / `aggressive`（首次建议 `none` 或 `minimal`） |
| `parts_only` | ✅ | 只解这些分区，默认 `system,product,system_ext,boot`（省 3–4 GB） |
| `build_kernel` | ✅ | 关掉就只出 system 侧 |
| `strict` | ✅ | 移植层校验失败即中止（首次试移植建议关） |
| `release_tag` | 空 | 非空则发布到 Release |

**没有固件地址也不用自己找**：

```bash
node tools/findrom.js --list                  # 哪些平板有 OS4 条目
node tools/findrom.js --device uke --check     # 打印能通的直链 + 真实大小
```

它会从 [XiaomiFirmwareUpdater](https://github.com/XiaomiFirmwareUpdater/miui-updates-tracker)
的索引里取最新 OS4 包，并按实测结果挑镜像域名（`bigota` / `hugeota` 会 403，`cdnorg` 正常）。
体积、磁盘预算、Recovery/Fastboot 两种包型的取舍都在 [docs/FIRMWARE.md](docs/FIRMWARE.md)。

产物按 1.8 GiB 切分，附 `port-report.md` / `debloat-report.txt` / `verify-report.txt`。

磁盘与配额的细节见 [docs/CI.md](docs/CI.md)（峰值要 25–30 GB，第一步就是删磁盘）。

## 本地跑

依赖：Linux、root（保留 uid/gid）、`erofs-utils`、`android-sdk-libsparse-utils`、
`python3`、`zip/unzip`、`zstd`。

```bash
# 自检：不碰 ROM，2 分钟
bash scripts/selftest.sh

# 全链路
bash scripts/pipeline.sh \
  --rom-url file:///path/to/os4-ota.zip \
  --source pad8 \
  --profile balanced \
  --boot-in /path/to/nabu-boot.img

# 只重跑某一阶段（产物目录互不覆盖，不用从头来）
bash scripts/03_debloat.sh --profile minimal --dry-run
bash scripts/06_package.sh
bash scripts/07_verify.sh
```

## 产物怎么刷

包里有 `flash.sh`（`fastbootd` 刷逻辑分区）和 `README-FLASH.txt`：

```bash
sha256sum -c SHA256SUMS
adb reboot fastboot        # fastbootd，不是 bootloader
./flash.sh                 # 先看 dry-run
./flash.sh --go
```

铁律：**先用 `fastboot boot out/boot-nabu-os4.img` 临时启动**（不写分区，重启即恢复），
确认内核没问题再刷 system 侧。

包里**没有** `vendor` / `odm` / `vendor_dlkm` —— 那些是 nabu 原厂固件，仓库不分发；
移植的前提是设备上那份 vendor 侧保持原厂。

## 目录

```
config/target/nabu.toml    目标设备事实（SoC / boot 约束 / 分区归属）
config/sources.toml        源机型登记表（不含下载地址）
config/profiles.toml       精简档位（tier → profile）
debloat/packages.txt       精简清单（tier + 包名 + 说明）
debloat/keep.txt           保护名单（冲突即中止构建）
port/manifest.toml         移植层组成 + 校验开关
port/props/nabu.prop       属性注入表（每行都写了为什么）
port/overlay/              设备适配文件覆盖层
kernel/source.toml         内核源码 / 工具链 / 补丁 / 配置片段
kernel/patches/            autosleep 两项补丁
kernel/configs/            perf / suspend 片段
scripts/00..07 + lib      流水线各阶段
tools/                     AXML 解析、包匹配、属性注入、boot.img repack、固件解析
docs/                      PORTING / KERNEL / DEBLOAT / CI / FIRMWARE / STATUS
```

## 已知风险（按优先级）

1. **HIDL→AIDL**：OS4 框架期望 AIDL HAL，nabu 的 vendor 只有 HIDL。Android 17 是否还带
   这些 shim，决定 hybrid 是否成立。判断方法（不用刷机）在 [PORTING.md §3.2](docs/PORTING.md)。
2. **VNDK**：`ro.vndk.version=33` 必须与 system 里真实的 `lib64/vndk-33` 同时成立，
   否则**卡第一屏且没有 logcat**。`04_port.sh` 会检查，可用 `--vndk-from` 注入。
3. **SELinux**：OS4 的 system sepolicy 不认识 nabu 的 vendor 域，需要 per-ROM 合并。
4. 相机、蜂窝、指纹不在目标范围；触控笔侧键尚未实现。

## 许可

本仓库的脚本、配置、补丁以 **GPL-2.0-only** 发布（见 [LICENSE](LICENSE)），与 Linux 内核一致。
内核源码版权归 [PerezChilli/android_kernel_xiaomi_nabu](https://github.com/PerezChilli/android_kernel_xiaomi_nabu) 作者；
AnyKernel3 由 [osm0sis](https://github.com/osm0sis/AnyKernel3) 提供；payload-dumper-go 由 [ssut](https://github.com/ssut/payload-dumper-go) 提供。
厂商固件不在本仓库内，其版权归小米及各自权利人。
