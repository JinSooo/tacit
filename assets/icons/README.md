# Tacit 图标资源

应用图标采用「墨轴纪事」主题：暖炭灰微渐变底板配克制顶缘微光，左侧连续细时间轴串联三段由长到短的活动胶囊（顶部此刻节点为铜绿空心环配铜绿渐变条，下方依次为暖白与暖灰），呼应主窗口的简约时间线。唯一绘图源是 `collector/Sources/Collector/Viewer/IconArt.swift`。

16 / 32pt 小尺寸应用图标与网页 Favicon 简化为两段疏版墨轴；Mac 菜单栏与 Android 通知正常态采用无框三段单色墨轴，菜单栏暂停和缺权限状态保留圆环配暂停符号或感叹号；Android 自适应彩色与单色图层保持同一墨轴轮廓与安全留白。

在 macOS 的仓库根目录运行：

```sh
./scripts/export-icons.sh
./scripts/export-icons.sh --check
```

| 位置 | 用途 |
| --- | --- |
| `generated/master-1024.png` | 透明画布上的应用图标母版，1024px |
| `generated/macos/` | ICNS 和完整的 1× / 2× iconset；应用构建也从同一 Swift 源生成 |
| `generated/menubar/` | 记录中、暂停、缺权限的 18 / 36 / 54px 黑色 alpha 模板；Mac 运行时由系统着色 |
| `generated/android/res/` | 五档密度的传统、圆形、自适应前景、单色主题和通知图标，以及 API 26 / 33 XML |
| `generated/android/play-store-512.png` | 不透明商店图标 |
| `../../../web/public/icons/` | PNG favicon、180px Apple touch、192 / 512px 普通和 maskable 图标 |
| `../../../web/public/favicon.ico` | 内含 16 / 32 / 48px 的 favicon |
| `generated/preview.png` | 应用图标、实际尺寸 favicon、浅深色菜单栏和 Android 遮罩预览 |

网页已接入 favicon 和 Apple touch 图标。PWA 图标先作为资源交付，尚未添加 manifest 或离线能力。
`android/app/src/main/res/` 里的图标是 `generated/android/res/` 的原样拷贝，`android/scripts/verify.sh` 逐个比对，重新导出后需同步复制过去。通知使用 `R.drawable.ic_stat_tacit`，由系统负责着色，不使用彩色应用图标。

自适应前景采用 108dp 图层，主体位于中央 66dp 安全圆内，在各类桌面裁切形状下均保留充足深色留白。导出与 `--check` 会校验五档密度的彩色和单色实际像素边界，并检查 Mac 菜单栏 18 / 36 / 54px 的清晰分离度。单色层使用白色 alpha 轮廓，背景由独立 XML 提供，交给 Launcher 裁切，不预先烘焙圆角。网页 maskable 版本为不透明满底，主体完整处于半径 40% 的安全圆内。

尺寸依据：[Android 自适应图标](https://developer.android.com/develop/ui/compose/system/icon_design_adaptive)、[网页 maskable 图标](https://web.dev/articles/maskable-icon)。
