English | [简体中文](README.zh-CN.md)

# Tacit Web view

The Mac app is the main place to browse your records. The Web view reads records from the Background service on the same machine. See the [API contracts](../docs/contracts.md) (Chinese) for endpoints and authentication.

Run these commands from the repository root.

```sh
bun x vite build --config web/vite.config.ts
bun hub/src/cli.ts serve
bun hub/src/cli.ts open
```

The service uses your actual data directory by default. Set a separate `RA_DATA_DIR` and `RA_DB_KEY` on the Background service when experimenting.

Start the development server with `bun x vite --config web/vite.config.ts`. It proxies `/v1` to local port 47823 unless you set `RA_PORT`. The Web view currently opens to the status page and follows the system theme. The repository still contains the other views.

```sh
bun test web/test
bun x tsc --noEmit
```

Frontend tests use synthetic data and mock API responses. Use a real browser to check the running service, viewport sizes, keyboard navigation, and dialogs.
