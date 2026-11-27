# 状态清单（诚实版）

最后更新：2026-11-27

这张表回答一个问题：**哪些是"已经验证过"，哪些只是"代码写完了"。**
没有中间态——"看起来能跑"不算验证。

## 1. 流水线各段

| 段 | 状态 | 证据 / 说明 |
| --- | --- | --- |
| 00 preflight | 🧪 已实现，未在 CI 实跑 | `selftest.sh` 只做了语法与 `--help` 冒烟；apt 包名按 Ubuntu 24.04 写 |
| 01 fetch | 🧪 已实现，未实跑 | 支持 http/https/file/本地路径；sha256 校验逻辑有自检 |
| 02 unpack | 🧪 已实现，未实跑 | `payload.bin` 路径依赖 payload-dumper-go 2.1.0（已核对资产名）；tgz 路径需自备 `lpunpack` |
| 03 debloat | 🧪 已实现，未用真实 ROM 跑过 | AXML 解析器只在合成数据上测过；`packages.txt` 未经真实固件校准 |
| 04 port | 🧪 已实现，未实跑 | 属性注入有自检；vndk/tablet 校验逻辑未经真实镜像触发 |
| 05 kernel | ✅ **已在真机验证** | 同一套补丁/配置/打包路径在此前的内核 CI 上构建并 `fastboot boot` 验证（详见 KERNEL.md 第 5 节） |
| 06 package | 🧪 已实现，未实跑 | 切分 + 重建 SHA256SUMS 的逻辑未在 >2 GiB 产物上验证过 |
| 07 verify | 🧪 已实现，未实跑 | boot.img 的结构断言（header v3 / ARMd）逻辑正确，但未跑过真实产物 |
| lint / selftest | 🧪 已实现 | 首次 push 后由 Actions 给出结论 |

## 2. 关键结论

| 结论 | 状态 | 依据 |
| --- | --- | --- |
| 内核必须 4.14.180 + modversions | ✅ 成立 | vendor 模块 vermagic + 符号 CRC；升 4.19 会全部加载失败 |
| 熄屏挂起需要屏幕状态门控 | ✅ 成立 | 真机：亮屏 3′20″ 内 0 次挂起；熄屏 deep suspend `success=14` |
| OS4 只能以 hybrid 形态移植 | ✅ 成立（架构层面） | vendor/HAL 与 SoC 绑定；整包搬必然不起 |
| OS4 的 system 能在 nabu 的 vendor 上跑起来 | ❌ **未验证** | 取决于 HIDL/AIDL 与 sepolicy，见 PORTING.md 第 3 节 |
| 精简后的镜像能开机 | ❌ **未验证** | 需要真机；删错包只能靠回归发现 |
| 触控笔侧键能上报 | ❌ **未实现** | 帧内字节定位未完成，见 KERNEL.md 第 4 节 |

## 3. 明确没做的事

- 没有下载、也没有分析过任何一份真实的 OS4 固件（本仓库不附带固件）；
- 没有在 nabu 上刷过 OS4 的任何一份 system 镜像；
- 没有做 vendor sepolicy 合并、没有做相机/蜂窝适配；
- 没有处理 OS4 的 `super` 布局（只按逻辑分区刷写，不重建 super）；
- 没有 CI 实跑记录（仓库刚建，第一次 dispatch 之后应回填这张表）。

## 4. 下一步该按什么顺序做

1. **先跑 lint**：`workflow_dispatch` 触发 `lint.yml`，确认脚本本身没问题；
2. **再出内核**：`build-kernel.yml`，产物刷到真机（`fastboot boot`）确认内核段没退化；
3. **拿到一份 OS4 OTA zip**，`build-rom.yml` 用 `debloat_profile: none` + `build_kernel: false`
   先跑通 01→04 的镜像级链路（不改任何东西，只验证解包/重打包是否无损）；
4. 用 `profile: minimal` 再跑一次，对比 `debloat-report.txt`，校准 `packages.txt`；
5. 才开始试刷 system 侧，并按 PORTING.md 第 5 节分阶段验证；
6. 每解决一个子系统，回填第 2 节的状态（带日志/截图依据）。

> 顺序的意义：每一步只引入一个变量。跳过 1/2 直接刷移植包，出问题时无法判断
> 是"脚本写错"还是"移植本身不通"。
