# History 网页

在仓库根目录运行：

```sh
bunx vite build --config web/vite.config.ts
bun hub/src/cli.ts serve
bun hub/src/cli.ts open
```

开发时运行 `bunx vite --config web/vite.config.ts`，`/v1` 代理到本机 47823 端口。类型检查用 `bunx tsc -p web`，纯函数测试随根目录 `bun test` 一起执行。

如果根目录的 `node_modules` 是指向只读位置的软链接，先执行 `mkdir -p web/node_modules/.vite-temp`。Vite 在读取配置前会把配置编译缓存写到最近的 `node_modules/.vite-temp`，这一步尚不能使用配置里的 `cacheDir`；该本地目录不安装依赖，包仍从根目录解析，依赖缓存则写到 `web/.vite`。

页面使用系统字体和系统明暗模式，以日期、时间列和细分隔线组织记录；来源用细色条区分。设备框可直接输入设备名，已读取记录里的设备会作为候选项。没有额外的设备枚举接口。
