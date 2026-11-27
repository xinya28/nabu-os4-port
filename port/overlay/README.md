# port/overlay —— 设备适配文件覆盖层

目录结构就是分区布局：

```
port/overlay/
├── system/
│   └── etc/
│       └── ...            → 覆盖到 system.img 的 /etc/...
├── product/
└── system_ext/
```

`04_port.sh` 会把 `port/overlay/<分区>/` 整棵树 `cp -a` 到解包后的分区根目录，
同名文件覆盖，新文件新增。

## 这里该放什么

只放"OS4 的默认值在 nabu 上明确不对、且改文件就能解决"的东西：

| 场景 | 放哪 | 举例 |
| --- | --- | --- |
| 屏幕参数/亮度曲线 | `system/etc/displayconfig/` 或 `system/etc/` | nabu 的 `display_id_*.xml`、亮度节点 |
| 传感器/输入设备能力 | `system/etc/` | `input-port-associations.xml` |
| 权限白名单（源机型多出来的 HAL 权限会刷 deny） | `system/etc/permissions/` | `privapp-permissions-*.xml` |
| 平板 UI 的 dpi / 最小宽度 | `system/etc/`、`product/etc/` | 覆盖 `ro.sf.lcd_density` 相关配置 |
| 键盘盖/笔的按键映射 | `system/usr/keylayout/` | `.kl` 文件 |

## 这里**不要**放什么

- **vendor 侧任何东西**：`vendor/` 不在本 stage 的处理范围里，写进来也不会被使用；
  放进去只会让人误以为生效了。
- **从原厂固件里抠出来的二进制**：仓库是公开的，别把厂商二进制提交上来
  （`.gitignore` 已挡 `*.bin`/`*.img`，但 `.so`/`.apk` 挡不住，靠自觉）。
- **系统 APK 的反编译产物**：那是"改功能"，不是"适配"，应该放 kernel/patches
  或单独的分支，不要混进覆盖层——覆盖层必须是可审阅的小文件集合。

## 排查方式

`04_port.sh` 的报告 `work/ported/port-report.md` 里会列出每个分区覆盖了多少文件。
如果某个覆盖没生效，先看报告里的计数，再确认路径大小写（Android 的 ext4/erofs
区分大小写，而 Windows 上不区分，这是最常见的"本地路径对、CI 上失效"）。
