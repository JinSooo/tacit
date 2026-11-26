<!-- source: docs/plugins.md @ 91538ecb855b79c5fb7c9bbe8f8463a48755ec8f -->

English | [简体中文](../plugins.md)

# Source plugins

This specification describes third-party Sources. The app currently hides the install option. Existing plugins can still be updated or uninstalled from their source details.

To install a plugin, open **Settings › Sources › Install source** on Mac. Choose a local directory or enter an HTTPS or SSH Git repository URL. Put the manifest at the repository root. SSH uses the Mac's existing keys and `known_hosts` without an interactive password prompt. Use HTTPS URLs without usernames or tokens.

Tacit reads the manifest and takes a snapshot, then previews the permissions and configuration before running any code. Installed plugins start disabled. Confirm the configuration in the source details before enabling the plugin. Pausing all capture or disabling the source stops a running plugin. To update, Tacit reads from the original location and shows the full permissions and configuration again. Once confirmed, Tacit disables the plugin and replaces its code, keeping its cursor and compatible settings. Enable it again when you're ready. App upgrades keep installed plugins.

When uninstalling from the source details, choose whether to keep or delete the records. To delete them, Tacit disables the plugin, waits for it to exit, and deletes its records in batches through the Background service. Related corrections and summaries follow the usual deletion and regeneration process. An interruption leaves the plugin installed so you can retry. Records already deleted stay deleted. Uninstalling also removes the plugin configuration and cursor. Tombstones prevent a reinstall from importing records you've deleted.

## Minimal manifest

The directory contains `plugin.json` and an entry file. See the runnable [text file plugin](../../examples/text-file-plugin). Install and enable the example manually.

```json
{
  "schema": 1,
  "id": "ext-text-file",
  "name": "Text file",
  "version": "1.0.0",
  "description": "Reads a UTF-8 text file you select.",
  "entry": "main.ts",
  "permissions": ["Read the single text file selected in settings"],
  "access": {"readFiles": ["path"]},
  "config": [
    {"key": "path", "label": "Full path to the file", "type": "string", "required": true}
  ]
}
```

- Begin `id` with `ext-` and use lowercase letters, digits, and hyphens. To form the record's `source`, prefix the ID with `plugin.` and replace hyphens with underscores, as in `plugin.ext_text_file`. Provide a stable `source_ref`. Tacit rejects output claiming a different source.
- `entry` points to a `.ts`, `.js`, or `.mjs` file inside the directory. Absolute paths, `..`, and symlinks are disallowed. The directory may contain up to 25 MB and 2,000 files. The snapshot excludes `.git`.
- `permissions` describes the plugin's purpose. `access.readFiles` and `access.readDirectories` grant access through named text fields in `config`. Users confirm the full paths. Directory access includes subdirectories. Tacit validates access at installation, configuration, and runtime, shows the proposed paths, and saves the resolved paths so later symlink changes cannot widen access. Users grant system privacy permissions separately.
- Without `access`, legacy plugins can read only their own code and cursor. To read files, update the manifest and confirm installation again. Free-text permission descriptions grant no access. Tacit disallows network access, writes, and subprocesses and refuses to run without those restrictions.
- `config` supports `string`, `number`, and `boolean`, with optional `description`, `required`, and `default` fields. Tacit builds the form from the manifest. The form rejects values that look like secrets. Keep passwords and tokens out of manifests, default values, and Git URLs.
- The entry receives configuration JSON through `RA_PLUGIN_CONFIG` and takes `--device`, `--state`, and `--since` as described in [section 2 of the API contracts](../contracts.md#2-插件协议) (Chinese). It emits newline-delimited JSON to stdout. Tacit uses stderr for logging and excludes it from saved records.
- Bun runs the entry without installing dependencies or loading `.env`. Use Bun or Node built-ins and bundle any additional code with the plugin. The same read-only capture protocol applies. Plugin code cannot access the network or call models.
- On Mac, Seatbelt denies access by default. It allows the system files required to start Bun, the plugin code, its read-only cursor, and the approved paths. It blocks network access, writes (apart from the stdout pipe and `/dev/null`), launching other programs, and Keychain access. Directory grants never cover Tacit's data or common credential directories. Install plugins only from sources you trust. Built-in Sources use their existing system permissions.
- This uses `/usr/bin/sandbox-exec`, which Apple has deprecated. A future implementation should use App Sandbox and XPC. If the tool is absent, isolation fails, or the platform is unsupported, Tacit blocks the plugin and shows why.
- The runner validates source names, stable keys, exclusion rules, record schemas, and secrets. It filters records from password managers and private windows. Invalid records, forged sources, or failed writes prevent the cursor from advancing.
- The runner commits `plugins/<id>/state.json` atomically in the data directory after successful ingest. Plugins can read this state. Code and settings live in `extensions/<id>/`. Use Settings to manage these files.

The Mac app uses the same local CLI you can use for previews or debugging.

```sh
printf '%s\n' '{"action":"prepare","source":"/absolute/path/to/plugin"}' | bun hub/src/cli.ts plugins
# Returns preview.ticket, manifest, and values. Confirm access before install, or use discard.
# This runs an installed plugin. Mac Settings normally manages start, stop, and scheduling.
bun hub/src/cli.ts plugin-run ext-text-file --hub http://127.0.0.1:47823
```

`plugins` reads JSON from stdin. It accepts `list`, `prepare {source,id?}` (supply `id` for an update), `install {ticket,values}`, `configure {id,values}`, `discard {ticket}`, and `uninstall {id,deleteRecords,hub?}`. Management commands leave system capture sources and the database alone. Settings handles confirmation and runs operations in sequence. Wait for any operation in Settings to finish before using the CLI to change the same plugin.
