# 移植方法论：把 OS4 的 system 侧套到 nabu 的 vendor 上

> 本文记录的是**判断依据**，不是"照做就能开机"的配方。第三、四节的每一行都
> 对应一个真实失败模式；看完再动手，能省掉几次刷机。

## 1. 为什么不能把源机型的 super 整个刷进来

小米 Pad 8 / Pad 7 这些 OS4 机型和 nabu 的差别不是"分辨率不同"，而是三层绑定：

| 层 | 依赖什么 | 换 SoC 后是否还能用 |
| --- | --- | --- |
| bootloader / 分区表 | 具体机型的 GPT、A/B 槽、super 布局 | ❌ 分区大小和槽位都不同 |
| `vendor` / `odm` / `vendor_dlkm` | SoC（SM8150 vs 骁龙 8 系）、面板、触控 IC、PMIC、音频 codec | ❌ HAL 直接对着硬件寄存器 |
| 内核 | 板级 DTB、驱动、模块 vermagic | ❌ 源机型的 dtb 描述的是另一块板子 |

所以**唯一可行**的形态是 hybrid：

```
        ┌──────────────── 来自 OS4 源机型 ────────────────┐
        │  system.img   product.img   system_ext.img      │  框架、系统应用、UI
        └─────────────────────────────────────────────────┘
        ┌──────────────── 留在 nabu 自己身上 ─────────────┐
        │  vendor.img  odm.img  vendor_dlkm.img            │  HAL、驱动、firmware
        │  vendor_boot.img  dtbo.img  vbmeta*              │  内核命令行、DTB、校验
        │  boot.img ← 本仓库内核段构建                     │  4.14.180 + 平板驱动
        └─────────────────────────────────────────────────┘
```

`port/manifest.toml` 就是这张图的机器可读版本；`04_port.sh` 按它组装并校验。

**注意**：这不是新发明。这台 nabu 现在跑的就是同形态的移植（HyperOS 3 / Android 16
system + nabu 的 vendor + 4.14.180 内核），所以"system 侧跨版本、vendor 侧保持"
在 nabu 上是被验证过能走通的路子。OS4 的增量风险在第 3 节。

## 2. 移植层实际改了什么

`04_port.sh` 只做四件事，都可逐条核对（报告在 `work/ported/port-report.md`）：

1. **设备身份**：`ro.product.device/model/brand/…` → nabu。
   不改的话，源机型的 `ro.product.device` 会让资源、相机、OTA 去找不存在的配置，
   同时与 `/vendor/build.prop` 里的 `ro.vendor.product.device=nabu` 对不上。
2. **vendor ABI**：`ro.vndk.version=33`、`ro.board.api_level=33`。
   这两个值是 hybrid 的关键开关，见 3.1。
3. **形态**：`ro.build.characteristics=tablet`，避免被重判成手机布局。
4. **overlay**：`port/overlay/<分区>/` 的文件覆盖（面板参数、权限白名单等）。

它**不改** vendor、不搬 blob、不 patch 二进制。需要改二进制的事，属于 3.2/3.3
那类"必须真机迭代"的工作，硬塞进脚本只会让失败更难定位。

## 3. 三道坎（按踩坑概率排序）

### 3.1 VNDK / vendor API level

OS4 是 Android 17，system 自带的是 vndk-37 那一套；nabu 的 vendor 是 Android 13，
它的 HAL `.so` 链接的是 vndk-33 的 `libbase` / `libcutils` / `libhidlbase`。

- 只把 `ro.vndk.version` 改成 33 而 system 里**没有** `lib64/vndk-33/`：linker 找不到
  依赖，`init` 第一个阶段就失败，表现是**卡第一屏、没有 logcat**（adbd 还没起）。
- 正确做法是两者同时满足：属性指向 33 **且** system 里真有那个目录。
  `04_port.sh` 会检查；缺了可以 `--vndk-from <nabu 已解包的 system 树>` 把目录补进去。

排查口诀：**卡第一屏 + 无 logcat ⇒ 先怀疑 linker/VNDK，不要怀疑内核。**

### 3.2 HIDL → AIDL

OS4 的框架期望 AIDL 版 HAL，nabu 的 vendor 只提供 HIDL：
graphics composer、audio、power、thermal、sensors、camera 都是这个情况。
Android 14 起 HIDL 处于"兼容但弃用"，到 17 是否还保留这些 shim 是**本移植最大的
不确定性**。判断方法（不用刷机也能看）：

```bash
# 在源 system 镜像里找 HIDL 运行时是否还在
fsck.erofs --extract=./sys work/images/system.img
ls ./sys/lib64/ | grep -i hidl        # 有 libhidlbase.so / libhidltransport.so 就还有戏
```

- 有 → hybrid 的前提成立，继续；
- 没有 → 这个源版本不能作为基座，换 OS4 早期版本或另一个机型。

### 3.3 SELinux

OS4 的 `system` 侧 sepolicy 不认识 nabu 的 vendor 域（`hal_nvt_touch`、
`xiaomi_keyboard` 之类）。典型表现：开机后在 `dmesg`/`logcat` 里刷
`avc: denied { find } for ... scontext=u:r:system_server:s0`，某个服务起不来。

- 快速验证：`adb shell setenforce 0` 后功能恢复 ⇒ 就是 sepolicy。
- 正式做法是把 nabu 的 vendor sepolicy 与 OS4 的 system sepolicy 合并/追加，
  这属于"per-ROM 调整"，本仓库不预置（预置了也不可能通用）。

## 4. 子系统矩阵

| 子系统 | 依赖在哪 | 移植方式 | 风险 | 怎么验（不刷机/真机） |
| --- | --- | --- | --- | --- |
| 显示/面板 | kernel 面板驱动 + vendor HWC(HIDL) + `vendor/etc/panel` | 保留 nabu 侧，overlay 调 dpi/亮度 | **高**（composer 版本） | `dmesg \| grep -i dsi`；屏幕是否亮 |
| 触控 | kernel `nt36xxx` + vendor firmware | 保留 nabu 侧 | 中 | 触摸是否响应；`getevent` |
| 触控笔 | 同上，笔帧 40 字节 | 保留 nabu 侧；侧键需改驱动（见 KERNEL.md） | 中 | 笔悬停/落笔/侧键 |
| 音频 | vendor audio HAL(HIDL) + codec | 保留 nabu 侧 | 中 | 放音/录音/耳机 |
| WiFi/BT | vendor wlan HAL + firmware | 保留 nabu 侧 | 中 | 扫到 AP；蓝牙耳机 |
| 相机 | vendor camera provider（HIDL 2.4） | 首版不做 | **高** | — |
| 传感器 | vendor sensors HAL | 保留 nabu 侧 | 低 | 自动旋转 |
| 充电/电量 | kernel + vendor health HAL | 保留 nabu 侧 | 低 | 插电显示 |
| 键盘盖 | kernel `xiaomi-keyboard` + vendor | 保留 nabu 侧 | 低 | 合盖/按键 |
| 蜂窝/指纹/NFC | nabu 没有 | 直接忽略 | — | — |

## 5. 分阶段验证（每次只改一个变量）

```bash
# 阶段 0：内核单独验（不写任何分区）
fastboot boot out/boot-nabu-os4.img

# 阶段 1：只换 system 侧，vendor 保持原厂
adb reboot fastboot
./flash.sh --go            # 只刷 boot/system/product/system_ext

# 阶段 2：失败回退（boot 一定能救回来）
fastboot flash boot <原厂 boot.img>
# 极端情况：进 fastbootd 重新刷原厂 super 侧
```

铁律：**先 `fastboot boot` 临时启动，确认能起再 `fastboot flash`。**
`fastboot boot` 不写分区，重启即恢复。

## 6. 失败排查树

| 现象 | 最可能的原因 | 下一步 |
| --- | --- | --- |
| 卡第一屏、无 logcat、无 adbd | VNDK/linker 缺库 | 查 `lib64/vndk-33`；`--vndk-from` 注入 |
| 卡第一屏、有 `init` 日志但 `system_server` 起不来 | sepolicy 或 framework jar 缺依赖 | `setenforce 0` 验证；看 `avc: denied` |
| 开机动画循环 | `system_server` 崩 | `adb logcat` 抓 `FATAL EXCEPTION` |
| 亮屏但黑屏/花屏 | composer/面板参数 | 换 OS4 早期版本；比对 `vendor/etc/panel` |
| 触摸无反应但显示正常 | 触控固件/权限 | `getevent -l`；看 `nvt` 驱动 probe 日志 |
| 能进系统但无声音 | audio HAL 接口不匹配 | 看 `audioserver` 日志 |
| 电量显示异常/充不进 | health HAL | 看 `BatteryService` 日志 |

## 7. 这份仓库没做的事（别误读）

- 没有验证过任何一个 OS4 源固件在 nabu 上开机；
- 没有做相机、蜂窝、指纹的适配；
- 没有做 vendor sepolicy 合并（那需要针对具体 ROM 迭代）；
- 没有处理 OS4 的 `super` 分区布局变化（只按逻辑分区刷写，见 `06_package.sh`）。

`docs/STATUS.md` 是这些"没做"的权威清单。
