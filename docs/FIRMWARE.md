# 怎么拿到 OS4 固件

> 结论先说：**不要手抄链接。** 用 `tools/findrom.js` 现查，它会顺手挑一个能通的镜像域名。
> 本文记录的域名可用性是 2026-11-27 实测的，会变。

## 1. 一条命令

```bash
node tools/findrom.js --list                     # 哪些平板有 OS4 条目
node tools/findrom.js --device uke               # 打印最新 OS4 OTA 直链
node tools/findrom.js --device uke --check       # 顺带校验：挑能通的镜像 + 打印真实大小
node tools/findrom.js --device yupei --check --json   # 给 CI 用：url/mirror/bytes/md5
```

数据源是 [XiaomiFirmwareUpdater/miui-updates-tracker](https://github.com/XiaomiFirmwareUpdater/miui-updates-tracker)
的 `data/latest.yml`（社区维护的机器可读索引，每次构建现拉）。

`--device` 后面是**代号**，不是型号：`yupei`=Pad 8/9、`piano`=Pad 8 Pro、`uke`=Pad 7、
`muyu`=Pad 7 Pro、`jinghu`=Pad 7 Ultra、`violin`=Pad 7S Pro 12.5、`yili`=K Pad 2、
`yingtian`=Pad 9 Pro Max。完整映射在 `config/sources.toml`。

## 2. 镜像域名：同一份文件，可用性差别很大

小米把同一个包挂在多个 CDN 域名下（路径完全相同，只换 host）。2026-11-27 实测：

| host | 用途 | 结果 |
| --- | --- | --- |
| `cdnorg.d.miui.com` | OTA / Fastboot | ✅ 206 Partial Content |
| `bigota.d.miui.com` | OTA / Fastboot | ❌ 403（`kngx` 错误页，570 B） |
| `hugeota.d.miui.com` | OTA | ❌ 403（同上） |
| `*.oss-ap-southeast-1.aliyuncs.com` | Fastboot | ✅ 206（AliyunOSS） |

所以 `findrom.js` 默认把 `d.miui.com` 的链接改写到 `cdnorg`；`--check` 会按
`cdnorg → bigota → hugeota → 原链接` 顺序实测，**返回第一个 2xx 的那个**。

> 为什么用 `Range: bytes=0-0` 而不是 `HEAD`：这些 CDN 对 `HEAD` 直接 403
> （实测 168 B 错误页），而带 Range 的 GET 会返回 206 + `Content-Range: bytes 0-0/<总大小>`，
> 既验证了可达性，又拿到了准确体积。

## 3. 两种包型，选错会卡在解包

| | Recovery（OTA zip） | Fastboot（tgz） |
| --- | --- | --- |
| 内容 | `payload.bin` + 少量 img | `super.img` + 各物理分区 img |
| 解包 | `payload-dumper-go`，逐逻辑分区 | 需要 `lpunpack` 才能拆 super |
| 体积 | 8.6–10.6 GB | 9.7–12.9 GB |
| 本流水线 | ✅ 直接支持（`02_unpack.sh`） | ⚠️ 需要你自备 `lpunpack` |

**默认用 Recovery 包**：体积小、`payload.bin` 里的分区是独立的，不需要拆 super。

Fastboot 包只有在"OTA 包拿不到"时才用。它的 `super.img` 拆法：

```bash
simg2img super.img super.raw.img      # 若是 sparse
lpunpack super.raw.img out/           # AOSP system/core/fs_mgr/liblp 的 host 工具
```

## 4. 体积与磁盘预算

以 `uke`（Pad 7）的 OTA 为例：zip 9.13 GB。

| 步骤 | 峰值增量 | 说明 |
| --- | --- | --- |
| 01 下载 | 9.1 GB | |
| 02 解包 | 4–6 GB | 用 `--only` 只解 `system,product,system_ext,boot`；全解会多 3–4 GB |
| 03 精简 | 3–5 GB | 逐分区处理，处理完即删解包树 |
| 05 内核 | 6–8 GB | 源码 + 构建输出 |
| 06 打包 | 3–4 GB | 切分后产物 |

GitHub 的 `ubuntu-24.04` 删完预装 SDK 后约 40–45 GB 可用，跑得下；但**不要关掉
`build-rom.yml` 里的"释放磁盘空间"步骤**。`00_preflight.sh --min-free-gb 30` 会兜底。

## 5. 校验和：tracker 给的是 md5，流水线要 sha256

tracker 的条目里只有 `md5`。本流水线的 `01_fetch.sh --sha256` 校验的是 sha256，
两者不能互转。三个选择：

1. **不填**：`rom_sha256` 留空，`01_fetch.sh` 会记录实际 sha256 并给出警告
   （第一次运行时正好用它拿到值）；
2. **先下后算**：自己下完 `sha256sum` 一遍，把结果填进 CI 输入；
3. **放 Release**：把 zip 传到你自己仓库的 Release，用资产直链 + sha256，
   这是复现性最好的做法（也避免依赖小米 CDN 的可用性）。

## 6. 两个不要

- **不要把固件提交进仓库**：8–13 GB 且是厂商二进制。`.gitignore` 已挡了
  `*.zip` / `*.img` / `*.tgz`，但别指望它兜住 `git add -f`。
- **不要把临时签名直链贴进文档当"固定地址"**：这类链接会过期，
  下一个人照着跑必然失败。要固定就用 Release 资产。

## 7. 在 CI 里怎么用

`build-rom.yml` 的 `rom_url` **留空**即可：`source` 选代号，工作流会调
`findrom --check` 现解析并把最终 URL 写进 job summary。

要固定输入就填 `rom_url`（+ 可选 `rom_sha256`），此时完全不走 tracker。
