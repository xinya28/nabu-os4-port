# CI：在 GitHub Actions 上跑

## 1. 三个 workflow

| 文件 | 触发 | 跑什么 | 典型耗时 | 产物 |
| --- | --- | --- | --- | --- |
| `lint.yml` | push / PR | shellcheck、python 语法、`scripts/selftest.sh`、TOML 可解析 | 2–4 min | 无（门禁） |
| `build-kernel.yml` | dispatch / `kernel/**` 改动 | `05_kernel.sh` 全流程 | 40–70 min | AnyKernel3 zip、Image、SHA256SUMS |
| `build-rom.yml` | 仅 dispatch | `00→07` 全链路 | 60–120 min | 按 1.8 GiB 切分的镜像包 + 报告 |

`build-rom.yml` 故意**不**挂在 push 上：它要下载 5–7 GB 固件、跑一小时，
而且没有 `rom_url` 根本没法跑。内核段改动会通过 `build-kernel.yml` 单独验证。

## 2. runner 需求（为什么第一步是删磁盘）

`ubuntu-24.04` 默认只有约 14 GB 可用。峰值占用大致是：

| 阶段 | 增量 | 说明 |
| --- | --- | --- |
| 下载 ROM | 5–7 GB | 不缓存，见第 3 节 |
| 02 解包 | 6–8 GB | payload 里所有分区 |
| 03 精简 | 3–5 GB | 一个分区的解包树（逐个处理、处理完即删） |
| 04 移植 | 3–5 GB | 同上 |
| 05 内核 | 6–8 GB | 源码 + 构建输出 |
| 06 打包 | 3–4 GB | 切分后的产物 |

所以每个 job 第一步都删 `/usr/local/lib/android`、`/usr/share/dotnet` 之类
（能回收 25–30 GB）。`00_preflight.sh --min-free-gb 25` 会再兜一道底：
**磁盘不够就直接失败**，而不是跑到一半 `No space left on device`。

如果还是不够，两个办法：

- `build_kernel: false`，内核用上一轮的产物（`05_kernel.sh --image <Image>` 也支持外部 Image）；
- 换 self-hosted runner（`runs-on:` 改一行即可）。

## 3. 为什么不缓存 ROM

- 单个 cache 条目上限 10 GB，一个 5–7 GB 的包放进去几乎占满；
- 小米 CDN 直链带签名和时效，缓存 key 很难稳定表达"同一份固件"；
- 缓存命中率低（每个 OS4 版本都要重新下），收益不够抵掉配额。

要"固定输入"的正确做法是：**把固件放进你自己的 Release 资产**，然后把
`rom_url` 填成那个资产链接（私有仓库可用 `GITHUB_TOKEN` 拉）。这样自带 sha256 校验，
也不需要公开直链。

## 4. 密钥

只需要内置的 `GITHUB_TOKEN`：

- `build-rom.yml` 的 `permissions: contents: write` 用于发布 Release；
- 不需要任何 PAT。

**不要把 ROM 直链、账号 cookie、设备序列号写进仓库。** `.gitignore` 挡了
`*.img` / `*.zip` / `*.bin`，但挡不住把直链贴进 issue 或 commit message。

## 5. artifact 与 Release

- 单个 artifact 里每个文件都要 < 2 GiB，所以 `06_package.sh` 会把超限的镜像
  切成 `*.part-NN`，并**重建** `SHA256SUMS`（按实际存在的文件）；
- 产物默认保留 14 天；要长期保存就用 dispatch 里的 `release_tag`，会走
  `gh release create` 发到 Release。

## 6. 常见失败与对策

| 现象 | 原因 | 对策 |
| --- | --- | --- |
| `00 preflight` 报缺 `mkfs.erofs` | apt 包名/源问题 | `erofs-utils`（Ubuntu 22.04+ 才有） |
| `02 unpack` 报需要 `lpunpack` | 输入是 fastboot tgz | 改用 OTA zip（含 `payload.bin`） |
| `02 unpack` 报 `payload-dumper-go` | 没跑 `--install` | `00_preflight.sh --install` |
| `03` 报 exit 3 | 待删 ∩ 保护名单 | 修 `debloat/packages.txt`，这是配置错误 |
| `03/04` 报 `No space left` | 磁盘不够 | 见第 2 节 |
| `04` strict 失败 | 缺 vndk 目录 | `--vndk-from <nabu system 树>` 注入 |
| `05` 编译失败后重试仍失败 | 上游内核树变了 | 换 `branch` 或看日志里的第一个 error |
| `07` SHA256SUMS 校验失败 | 产物被切分但校验表没重建 | 已在 06 修；若复现请提 issue |

## 7. 本地等价跑法

CI 里没有秘密：三个 workflow 调的都是 `scripts/*.sh`，本地一条命令等价：

```bash
bash scripts/pipeline.sh --rom-url file:///path/to/os4-ota.zip \
     --source pad8 --profile balanced --boot-in /path/to/nabu-boot.img
```

`file://` 和本地绝对路径都支持（`01_fetch.sh` 里显式处理），所以可以先手动下好固件
再跑，避免重复下载。
