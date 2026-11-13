# 扩展数据源

Mac 设置 → 数据源 → 安装数据源。可以选择本地目录，或填写 HTTPS / SSH Git 仓库地址（清单放在仓库根目录）。SSH 使用本机已有的密钥与 known_hosts，不弹交互式密码输入；HTTPS 地址不能含账号或令牌。

先读取清单、复制插件快照，展示权限与配置，不执行插件。确认后安装，默认停用；进入详情确认配置后再开启。全局暂停或停用会结束正在运行的插件。更新从原来源重新读取，重新展示完整权限和配置，确认后停用并替换代码，保留游标与兼容配置；需要手动再次开启。升级主程序保留安装的插件。

详情里的卸载可选保留记录或删除全部相关记录。删除先停用插件、等待它退出，经后台服务现有的单条真删接口逐条处理；相关修正与提炼结果按现有流程删除、重新生成。中断时保留插件供重试，已经删除的记录不恢复。卸载也清理插件配置和游标。重新安装时已删除记录仍由墓碑防止再次导入。

## 最小清单

目录中提供 `plugin.json` 和入口文件。完整可运行示例见 [`examples/text-file-plugin`](../examples/text-file-plugin)。它不默认安装，安装后也不默认开启。

```json
{
  "schema": 1,
  "id": "ext-text-file",
  "name": "文本文件",
  "version": "1.0.0",
  "description": "读取用户指定的 UTF-8 文本文件。",
  "entry": "main.ts",
  "permissions": ["读取配置指定的单个文本文件"],
  "config": [
    {"key": "path", "label": "文件完整路径", "type": "string", "required": true}
  ]
}
```

- `id` 用 `ext-` 开头的小写字母、数字和连字符，与内置来源隔离。记录的 `source` 是 `plugin.` 加 id，并把 `-` 改成 `_`，例如 `plugin.ext_text_file`；必须提供稳定的 `source_ref`。其他来源的输出会被拒绝。
- `entry` 是目录内的 `.ts` / `.js` / `.mjs` 文件，不能使用绝对路径、`..` 或符号链接。目录最多 25 MB、2000 个文件，`.git` 不复制。
- `permissions` 用可读文字准确声明读取范围和所需系统权限。它是安装前的告知，不是能力沙箱；不自动申请系统权限。只安装可信代码。用户开启后，插件继承采集端的操作系统权限；系统隐私设置入口在详情中。
- `config` 支持 `string`、`number`、`boolean`，可有 `description`、`required`、`default`。表单据此生成。普通配置不支持保存密钥，疑似密钥会被拒绝。不要把密码或令牌放在清单、默认值和 Git 地址中。
- 运行时通过 `RA_PLUGIN_CONFIG` 得到配置 JSON。入口仍按 [contracts.md 第 2 节](contracts.md#2-插件协议) 接收 `--device`、`--state`、`--since`，向 stdout 输出逐行 JSON，stderr 仅作日志，不写入 History。
- Bun 执行入口，不自动安装依赖或加载 `.env`；使用 Bun / Node 内置模块，其他代码需要随插件打包。程序不联网、不调用模型，遵守同一只读采集协议。
- 权限声明不阻止恶意代码绕开应用，因此只安装可信来源。正常 runner 路径对来源命名、稳定键、黑名单、记录格式与密钥做统一检查。密码管理器和隐私窗口的记录被过滤，其他格式错误、伪造来源或入库失败会阻止游标推进。
- 状态位于数据目录 `plugins/<id>/state.json`，由 runner 成功入库后原子提交，插件只读；代码和配置位于 `extensions/<id>/`。这些是实现路径，用户无需手动编辑。

开发时可以通过本机 CLI 预览或调试（界面使用相同入口）：

```sh
printf '%s\n' '{"action":"prepare","source":"/absolute/path/to/plugin"}' | bun hub/src/cli.ts plugins
# 输出 preview.ticket、manifest、values。确认权限后再 install，或 discard 清理预览。
# 以下命令会执行已安装的插件，通常应从 Mac 设置页启动，由它处理启停和串行调度。
bun hub/src/cli.ts plugin-run ext-text-file --hub http://127.0.0.1:47823
```

`plugins` 从 stdin 读取 JSON：`list`；`prepare {source,id?}`（id 表示更新）；`install {ticket,values}`；`configure {id,values}`；`discard {ticket}`；`uninstall {id,deleteRecords,hub?}`。管理命令不读取系统采集来源，不打开数据库。界面负责操作确认与串行化，请不要在界面操作期间另开 CLI 修改同一个插件。
