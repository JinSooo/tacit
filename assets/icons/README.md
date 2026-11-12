# Tacit 图标资源

保留原版形状，使用铜绿、暖炭灰和暖白配色。唯一绘图源是
`collector/Sources/Collector/Viewer/IconArt.swift`；生成稿不参与生产资源。

在 macOS 的仓库根目录运行：

```sh
./scripts/export-icons.sh
./scripts/export-icons.sh --check
```

| 位置 | 用途 |
| --- | --- |
| `generated/master-1024.png` | 透明背景的原版应用图标，1024px |
| `generated/macos/` | ICNS 和完整的 1× / 2× iconset；应用构建也从同一 Swift 源生成 |
| `generated/menubar/` | 记录中、暂停、缺权限的 18 / 36 / 54px 黑色 alpha 模板；Mac 运行时由系统着色 |
| `generated/android/res/` | 五档密度的传统、圆形、自适应前景、单色主题和通知图标，以及 API 26 / 33 XML |
| `generated/android/play-store-512.png` | 不透明商店图标 |
| `../../../web/public/icons/` | PNG favicon、180px Apple touch、192 / 512px 普通和 maskable 图标 |
| `../../../web/public/favicon.ico` | 内含 16 / 32 / 48px 的 favicon |
| `generated/preview.png` | 原图、实际尺寸菜单栏和 Android 遮罩预览 |

网页已接入 favicon 和 Apple touch 图标。PWA 图标先作为资源交付，尚未添加 manifest 或离线能力。
Android 工程尚未建立；将 `generated/android/res/` 合入未来应用的 `src/main/res/`，
设置 `android:icon="@mipmap/ic_launcher"` 和 `android:roundIcon="@mipmap/ic_launcher_round"`。
通知使用 `R.drawable.ic_stat_tacit`，系统负责着色，不使用彩色应用图标。

自适应前景采用 108dp 图层，原版圆环的完整外径为 62.82dp，位于中央 66dp 安全圆内。
单色层使用白色 alpha 轮廓。背景由独立 XML 提供，交给 Launcher 裁切，不预先烘焙圆角。
网页 maskable 版本为不透明满底，主体完整处于半径 40% 的安全圆内。
尺寸依据：[Android 自适应图标](https://developer.android.com/develop/ui/compose/system/icon_design_adaptive)、
[网页 maskable 图标](https://web.dev/articles/maskable-icon)。

本次资源不改变应用名、包标识、数据目录，也不自动安装或重启现有服务。
