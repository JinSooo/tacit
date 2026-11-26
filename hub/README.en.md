<!-- source: hub/README.md @ 0fc2c0dc2b01c2f47f3365339faf169712763aa7 -->

English | [简体中文](README.md)

# Tacit Background service

The Bun service receives text records, stores them in an encrypted database, indexes them for full-text search, and schedules summary jobs. It also serves the Web view and AI tools. The Mac app handles capture and system permissions. See the [API contracts](../docs/contracts.md) (Chinese) for request formats and boundaries.

Run these commands from the repository root.

```sh
bun hub/src/cli.ts serve
bun hub/src/cli.ts run-plugin browser -- bun plugins/browser/main.ts
```

These commands use your real data directory by default. For development and tests, point `RA_DATA_DIR` to an isolated directory and set a separate `RA_DB_KEY`. Keep experimental imports and deletions away from your real data.

- Management, Web view, and MCP listen on `127.0.0.1` in local mode. The port comes from `RA_PORT`, then `hub.json` in the data directory, then the default `47823`. If there is a valid Invite link or a paired device, Tacit opens a separate encrypted device port. It defaults to `47824`. See section 6.3 of the API contracts.
- The default data directory is `~/Library/Application Support/record-anything/`. The directory and `RA_*` variables retain the original internal name. Without `RA_DB_KEY`, the service reads the database key from macOS Keychain. A read failure leaves the existing key intact.
- All endpoints except the health check require authentication. The Web view and capture app use an admin token. MCP and hooks use a separate restricted AI tools token with read access and append access when explicitly authorized. Settings and record deletion require admin access.
- Records go through schema validation, deduplication, and secret filtering. Before advancing a plugin cursor, check `accepted`, `duplicates`, and `rejected` in the response. HTTP 200 alone does not tell you whether a record was saved.
- Deleting a record removes its corrections, index entries, and affected summaries. Tacit writes a tombstone without the record contents and queues a rebuild. Affected summaries stay hidden until the rebuild finishes.
- Summary jobs run in a separate process from the HTTP service. Adapters call model services, local models, or signed-in CLIs. The selected model determines whether text goes to a cloud service.
- Tacit uses plugin stderr to categorize errors within a size limit and discards the raw output. See [Source plugins](../docs/en/plugins.md) for third-party access and isolation rules.

```sh
bun test
bun x tsc --noEmit
```

Automated tests use synthetic data, temporary directories, and separate keys. Device permissions, Keychain access, and long-running performance require separate verification.
