# 内核：4.14.180 + 平板驱动整合

> 这一段是整条链路里**唯一已经在真机上验证过**的部分（见第 5 节的验证记录）。
> 换句话说：ROM 段是新写的，内核段的每个结论都有设备日志支撑。

## 1. 为什么必须是 4.14.180，不能"顺便升个 4.19"

nabu 的 `/vendor/lib/modules` 里的 `.ko` 是用 **4.14.180 + CONFIG_MODVERSIONS** 编的，
vermagic 形如：

```
4.14.180-perf-gde52a0344e18 SMP preempt mod_unload modversions aarch64
```

模块加载器（`kernel/module.c` 的 `same_magic()`）在 `CONFIG_MODVERSIONS=y` 时
**只比较 vermagic 的尾部**（`SMP preempt mod_unload modversions aarch64`），
所以 `LOCALVERSION` 改不改都不影响加载；但 **符号 CRC 必须对得上**——
这只有在同一个 4.14.180 base 上编译才成立。

结论：换 4.19/5.x 内核 ⇒ 厂商模块全部加载失败 ⇒ 触控/音频/WiFi 直接没有。
所以内核段的目标不是"换版本"，而是"在同一个 base 上加东西"。

`05_kernel.sh` 构建完会 grep 版本串里的 `4.14.180` 和 `modversions` 做自检。

## 2. 构建与打包的物理约束

| 项 | 值 | 为什么 |
| --- | --- | --- |
| boot header | v3 | `boot.img` 的 header 版本；`tools/repack_boot.js` 只支持 v3 |
| 内核格式 | **未压缩** arm64 Image（magic `ARMd` @0x38） | boot 分区里放的是裸 Image，不是 `Image.gz` |
| DTB 位置 | `vendor_boot` | 所以 `Image.gz-dtb` 尾巴上的 dtb 要丢掉 |
| 打包方式 | AnyKernel3，只替换内核段 | 保留原 header/ramdisk/cmdline，影响面最小 |

`05_kernel.sh` 从 `Image.gz-dtb` 里用 zlib 解出裸 Image，断言 `ARMd`，
然后用 `kernel/scripts/pack-anykernel.sh` 打 AnyKernel3 zip。
给 `--boot-in <原厂 boot.img>` 时，另外用 `tools/repack_boot.js` 生成一份
可直接 `fastboot boot` 的 `boot-nabu-os4.img`（做过往返校验：改回原内核后字节一致）。

## 3. 平板驱动整合：到底加了什么

内核主体（`nt36xxx` 触控、`xiaomi-keyboard` 键盘盖、面板、音频）来自
`PerezChilli/android_kernel_xiaomi_nabu`，本仓库加的是三件东西：

### 3.1 熄屏挂起：autosleep + 屏幕状态门控

4.14 默认没有 `/sys/power/autosleep`。`CONFIG_PM_AUTOSLEEP=y` 只是让节点出现；
**仅把 `autosleep_state` 初值改成 `PM_SUSPEND_MEM` 不会真的挂起**——必须经
`pm_autosleep_set_state()` 才会排队挂起工作。

但也不能开机就 arm：autosleep 的语义是"没有 wakelock 就立刻挂起"，而移植 ROM
亮屏时并不持 wakelock，无条件 arm 会变成"使用中反复 suspend/resume"，表现为
屏幕固定频率闪黑。

所以补丁做了两件事：

- `patches/0001-autosleep-default-mem.patch`：`autosleep_state` 初值 → `PM_SUSPEND_MEM`；
- `patches/0002-autosleep-screen-gate.patch`：新增 `kernel/power/nabu_autosleep_gate.c`
  - `late_initcall` 先 `pm_autosleep_set_state(PM_SUSPEND_ON)`（开机不 arm）；
  - 注册树里已有的 `drm_notifier`（`drivers/gpu/drm/msm/dsi-staging/dsi_drm.c`，
    `EXPORT_SYMBOL`）：
    - `DRM_EVENT_BLANK` + `DRM_BLANK_POWERDOWN` → arm（`PM_SUSPEND_MEM`）
    - `DRM_EARLY_EVENT_BLANK` + `DRM_BLANK_UNBLANK` → disarm（`PM_SUSPEND_ON`）

  > 同一个 `drm_notifier` 还被 NVT 触控和 `xiaomi-keyboard` 用着，所以这条路径
  > 一定是通的——不需要为了挂起再引入一套新的电源状态通知机制。

Makefile 的编译项由 `05_kernel.sh` **追加**（`obj-$(CONFIG_PM_AUTOSLEEP) += nabu_autosleep_gate.o`），
不塞进补丁，避免上游重排 Makefile 后 apply 失败。

### 3.2 `/proc/kallsyms` 收紧到 0400

原树是 `0444`，任何 App 都能 grep `ksu_*` 符号 —— 这是原生 root 检测最常见的
指纹来源。改成 `0400` 后 root 仍可读。补丁是 `05_kernel.sh` 里的一行 `sed`，
因为它在 `kernel/kallsyms.c` 里只有一处匹配。

### 3.3 性能配置片段（可选）

`kernel/configs/perf.fragment`：BBR + fq_codel + BFQ + 关调试项。
每一项都是 4.14 已有的上游选项，**不改源码**，所以厂商模块的 vermagic 不受影响。
真正落地的选项看构建产物里的 `out/.config` 与 `reference-config.diff`。

其中 `CONFIG_KPROBES=y` 是**必须保留**的：KernelSU 的非 GKI 实现用
`register_kprobe()` 装 `su`/`ksud` 钩子，`kernel/ksu.c` 里这两个初始化在
`#ifdef CONFIG_KPROBES` 之内。关掉它，编出来的内核**没有 `/system/bin/su`**，
而且构建日志一切正常——是个很隐蔽的坑。

## 4. 触控笔（进行中，不属于当前流水线的产出）

已知事实（来自对 nabu `vendor_boot.img` 与 `nt36xxx.c` 的分析）：

- 驱动在 `nt36xxx.c`（Novatek NT36523 host-download SPI，
  Kconfig 里是 `CONFIG_TOUCHSCREEN_NT36523_HOSTDL_SPI`）；
- 笔帧 40 字节，上报入口是 `nvt_ts_work_func`；帧首字节 `01`=有效 / `ff`=离笔 / `f0`=无效；
- 笔的坐标域与手指不同，存在已知的漂移需要校准；
- 每次 resume 会重下固件；充电时笔会被互斥关闭。

**侧键（笔上的按键）目前没有上报。** 这条链路还差"按键帧里的字节定位"这一步，
做法是在 `nvt_ts_work_func` 注入只读 printk 探针、`fastboot boot` 临时启动、
逐列比对按键前后的帧数据。

> 这一段刻意没有做成仓库里的补丁：偏移量是跟着具体内核二进制走的
> （`4.14.180-moon-os3-...` 上算出来的偏移，换内核就得重算），
> 放进 CI 会让"补丁应用成功但功能错位"这种失败变得难以发现。

## 5. 验证记录（真机，2026-11-27，`fastboot boot` 临时启动）

已验证：

- 开机 1.5 s 注册门控，`/sys/power/autosleep` 为 `off`；13.9 s 收到首个 `UNBLANK`，
  打印 `display on, disarming autosleep`；
- 亮屏静置 3 分 20 秒：`success=0 fail=0`，`/sys/power/autosleep=off`，
  dmesg 无 `PM: suspend` 记录（亮屏不再有挂起尝试）；
- 熄屏：打印 `display off, arming autosleep`，`autosleep=mem`；
  期间 `success=14`、`fail=1`（`alarmtimer` / `-EBUSY`，属良性否决）；
- 亮屏立即回到 `off`；
- `su -c id` 正常（`context=u:r:ksu:s0`），KSU 模块与内核版本未受影响。

未验证 / 注意：

- **拔线后的连续睡眠时长**：上面 14 次挂起是插着 USB 测的，USB 事件会反复唤醒
  （屏幕本来就是灭的，不会闪屏）。"拔线连睡 2 分钟以上"仍需人工确认。
- 本文的验证用的是 HyperOS 3 / Android 16 的移植 ROM。**OS4 的 boot 镜像换内核后
  是同样的打包路径，但"能起内核"不等于"能起系统"**——后者取决于 PORTING.md 的
  三道坎，与内核无关。

## 6. 怎么读 `suspend_stats`

```
success=11  fail=50  last_failed_dev=alarmtimer  last_failed_errno=-16
```

`fail` 不是故障，是**挂起被否决**的次数；`-16` = `-EBUSY`（"现在别睡，有活要干"）。
最常见的良性否决是 `alarmtimer`（有即将到期的唤醒定时器）。
插着充电线时 `typec-cc-state-change` / `usbin-uv` / `ssusb` 会不断把设备唤醒，
所以测连续睡眠**一定要拔线**。
