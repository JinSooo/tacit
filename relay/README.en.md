<!-- source: relay/README.md @ ef4ef3b743987f4da6a0c20b393e13d257257fb9 -->

English | [简体中文](README.md)

# Tacit Relay mailbox

When the phone and Mac are on different networks or the Mac is asleep, the phone drops encrypted messages in the mailbox. The Mac retrieves them when it wakes. The mailbox can see when messages arrive and how large they are. The contents stay end-to-end encrypted. See section 6.8 of the [API contracts](../docs/contracts.md) (Chinese).

The same code runs on Cloudflare Workers or in Docker.

## Cloudflare Workers free plan

You'll need a Cloudflare account and a domain hosted on Cloudflare. The default `workers.dev` hostname is disabled because some networks cannot reach it. Run this from `relay/`:

```sh
npx wrangler@4 deploy --route 'relay.example.com/*' --var TACIT_RELAY_CREATE_CODE:<creation-code>
```

Without a creation code, anyone can create a mailbox space within the daily creation and usage limits.

## Docker

```sh
docker build -t tacit-relay relay
docker run -d --name tacit-relay -p 8787:8787 -v tacit-relay:/data \
  -e TACIT_RELAY_CREATE_CODE=<creation-code> tacit-relay
```

Mailbox connections require HTTPS. Use a reverse proxy such as Caddy or Nginx and set `TACIT_RELAY_IP_HEADER=X-Forwarded-For` so the creation rate limit can use the client's IP.

## Limits

| Environment variable | Public mailbox default |
| --- | --- |
| `TACIT_RELAY_MESSAGE_BYTES` | 1 MiB |
| `TACIT_RELAY_SPACE_BYTES` | 100 MiB |
| `TACIT_RELAY_RETENTION_DAYS` | 30 days |
| `TACIT_RELAY_IDLE_DAYS` | 90 days |
| `TACIT_RELAY_DAILY_REQUESTS` | 20,000 |
| `TACIT_RELAY_SPACES_PER_IP` | 3 |

## Development

```sh
bun test relay/
bun relay/src/bun.ts
```

The local server defaults to port 8787 and writes its database to `/data/relay.db`. Set `TACIT_RELAY_DB` to use a different path.
