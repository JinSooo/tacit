# Tacit 网页备用入口

Mac 原生窗口是主要查看入口，网页从同机后台读取记录。所有接口和鉴权规则见 [接口契约](../docs/contracts.md)。

在仓库根目录运行：

```sh
bun x vite build --config web/vite.config.ts
bun hub/src/cli.ts serve
bun hub/src/cli.ts open
```

默认连接真实用户数据目录，开发实验请为后台设置独立的 `RA_DATA_DIR` 和 `RA_DB_KEY`。

开发服务器使用 `bun x vite --config web/vite.config.ts`；`/v1` 代理到本机 47823 端口，设置 `RA_PORT` 时跟随该端口。当前日常入口仅保留状态页（其余页面代码仍保留在仓库中），跟随系统明暗模式。

```sh
bun test web/test
bun x tsc --noEmit
```

前端测试使用合成数据和模拟 API。真实服务、屏幕尺寸、键盘操作和弹窗仍需要浏览器验收，不以测试快照代替视觉核对。
