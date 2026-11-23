# Tacit 图标资源

以 2026-11-13 选定的第 1 版为视觉目标：保留圆环、横向文字行和短末行，
铜绿由浅到深，暖炭灰平底和暖白外环，去掉光晕、高光和立体描边。唯一绘图源是
`collector/Sources/Collector/Viewer/IconArt.swift`；生成稿不参与生产资源。

`reference/tacit-selected-20261113.png` 是选定的应用图标生图稿；
`reference/tacit-companions-20261113.png` 是配套方向稿。后者小图的行数并不完全一致，
以这里的尺寸规则和同源导出的 `generated/preview.png` 为准。
完整应用图标为五行；Mac 菜单栏按用户 2026-11-13 最终选择的 A 版恢复三行，内部半径为可绘制宽度的 27%，保留较宽的环内留白。
Mac 应用图标 16 / 32pt（含 2×）、网页 favicon 和 Android 通知仍用三行简化版，都保留短末行。菜单栏暂停和缺权限状态保留圆环，内部换成暂停符号或感叹号。

在 macOS 的仓库根目录运行：

```sh
./scripts/export-icons.sh
./scripts/export-icons.sh --check
```

| 位置 | 用途 |
| --- | --- |
| `generated/master-1024.png` | 透明画布上的选定版应用图标，1024px |
| `generated/macos/` | ICNS 和完整的 1× / 2× iconset；应用构建也从同一 Swift 源生成 |
| `generated/menubar/` | 记录中、暂停、缺权限的 18 / 36 / 54px 黑色 alpha 模板；Mac 运行时由系统着色 |
| `generated/android/res/` | 五档密度的传统、圆形、自适应前景、单色主题和通知图标，以及 API 26 / 33 XML |
| `generated/android/play-store-512.png` | 不透明商店图标 |
| `../../../web/public/icons/` | PNG favicon、180px Apple touch、192 / 512px 普通和 maskable 图标 |
| `../../../web/public/favicon.ico` | 内含 16 / 32 / 48px 的 favicon |
| `generated/preview.png` | 应用图标、实际尺寸 favicon、浅深色菜单栏和 Android 遮罩预览 |

网页已接入 favicon 和 Apple touch 图标。PWA 图标先作为资源交付，尚未添加 manifest 或离线能力。
`android/app/src/main/res/` 里的图标是 `generated/android/res/` 的原样拷贝，`android/scripts/verify.sh` 逐个比对，
重新导出后要一起复制过去。HyperOS 桌面只显示前景层中间约 66dp，旧拷贝（圆环 62dp）因此贴边（2026-11-23）。
通知使用 `R.drawable.ic_stat_tacit`，系统负责着色，不使用彩色应用图标。

自适应前景采用 108dp 图层，圆环的完整外径约 49dp，位于中央 66dp 安全圆内。
安全圆是裁切上限，不是应填满的尺寸；在桌面可见区域保留深色留白。
导出与 `--check` 都检查五档密度的彩色和单色实际像素边界，防止圆环再次贴边；
同时检查 Mac 菜单栏 18 / 36 / 54px 的实际像素中三行清晰分离，防止小尺寸挤成一块。
单色层使用白色 alpha 轮廓。背景由独立 XML 提供，交给 Launcher 裁切，不预先烘焙圆角。
网页 maskable 版本为不透明满底，主体完整处于半径 40% 的安全圆内。
尺寸依据：[Android 自适应图标](https://developer.android.com/develop/ui/compose/system/icon_design_adaptive)、
[网页 maskable 图标](https://web.dev/articles/maskable-icon)。

本次资源不改变应用名、包标识、数据目录，也不自动安装或重启现有服务。
