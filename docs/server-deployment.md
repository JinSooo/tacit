English | [简体中文](zh/server-deployment.md)

# Run the Tacit Background service on a server

You can run the Tacit Background service on an always-on Linux server or a computer with Docker. Mac and Android devices connect over an encrypted protocol. For Windows, see [section 7](#7-windows-with-docker-desktop).

Server mode uses `RA_HUB_MODE=server` and is the default on systems other than macOS.

- The encrypted device port stays open. It defaults to `0.0.0.0:47824` and can be changed with `RA_LAN_PORT`. It serves only `/v1/device/hello`, `/v1/device`, and `/v1/device/events`.
- The unencrypted localhost management port and Web view are off by default. Bearer token management endpoints are never exposed on `0.0.0.0`.
- Summary models use API providers only (`anthropic` or `openai-compatible`). Without `models.json`, summaries stay paused and status shows why.
- The service encrypts database and device keys, model API keys, and Relay mailbox tokens using an external, read-only master key. It stores the encrypted values in `secrets.enc` in the data directory.

## 1. Create and back up the master key

Create the master key yourself. It is a random 32-byte value written as 64 hexadecimal characters. Tacit requires you to supply it.

Generate the file outside the data directory and set its permissions to `0400`. Inside the container the service runs as `bun`, with UID and GID `1000`.

```bash
mkdir -p /etc/tacit /srv/tacit-data
openssl rand -hex 32 > /etc/tacit/master.key
chown 1000:1000 /etc/tacit/master.key /srv/tacit-data
chmod 0400 /etc/tacit/master.key
chmod 0700 /srv/tacit-data
```

Back up the master key separately from the data directory. For example, keep the key in a password manager or on offline media and back up the data directory as usual. Losing the key makes the encrypted `secrets.enc` and `history.db` unrecoverable.

The service refuses to start if the key is under `/srv/tacit-data` (`RA_DATA_DIR`), missing, too broadly readable, or incompatible with an existing `secrets.enc`.

## 2. Get the image and start the container

Each Mac release publishes the same Background service code to GitHub Container Registry for `linux/amd64` and `linux/arm64`. The image tag matches the Mac version.

```bash
docker pull ghcr.io/jinsooo/tacit-hub:<version>
docker tag ghcr.io/jinsooo/tacit-hub:<version> tacit-hub:local
```

You can also build the image from the repository root.

```bash
docker build -f hub/Dockerfile -t tacit-hub:local .
```

Use the same version on the server and Mac when possible. Compatibility depends on the device protocol. If versions differ, check the release notes.

### With `docker run`

```bash
docker run -d \
  --name tacit-hub \
  --hostname tacit-hub \
  --restart unless-stopped \
  -e TZ=Asia/Shanghai \
  -p 47824:47824 \
  -v /srv/tacit-data:/data \
  -v /etc/tacit/master.key:/run/secrets/tacit_master_key:ro \
  tacit-hub:local
```

`--hostname` gives the Background service a name to display on your devices. Docker supplies a container ID by default.

The container entry point is `bun hub/src/cli.ts run`. It supervises `serve` for network requests and `distill` for summaries, forwards `SIGTERM` and `SIGINT`, and restarts failed processes with a backoff.

### With Docker Compose

```yaml
services:
  tacit-hub:
    image: tacit-hub:local
    hostname: tacit-hub
    build:
      context: .
      dockerfile: hub/Dockerfile
    restart: unless-stopped
    environment:
      TZ: Asia/Shanghai
      RA_LAN_PORT: "47824"
    ports:
      # Bind to a private network or Tailscale IP.
      - "100.64.0.10:47824:47824"
    volumes:
      - /srv/tacit-data:/data
    secrets:
      - source: tacit_master_key
        target: /run/secrets/tacit_master_key
        uid: "1000"
        gid: "1000"
        mode: 0400

secrets:
  tacit_master_key:
    file: /etc/tacit/master.key
```

## 3. Set the time zone

Tacit uses local calendar days for the Timeline, daily model usage, and daily summaries. Set the time zone explicitly on the server. In order of precedence, use either of these settings.

1. Set `TZ`, for example with `-e TZ=Asia/Shanghai`. This is the recommended option.
2. Set `timezone` in `/data/hub.json` to a valid IANA time zone.

   ```json
   {
     "timezone": "Asia/Shanghai"
   }
   ```

If neither is set and the container's process time zone is UTC, Tacit writes a warning to stderr on startup and exposes it as `timezone.warning` in the status response.

## 4. Pair the first Admin device

In the running container, run `pair --role admin`. Use `--address` to supply an address and port the Mac can reach, such as a private IP, a Tailscale IP, or an HTTPS reverse proxy URL.

```bash
docker exec -it tacit-hub bun hub/src/cli.ts pair --role admin --address http://192.168.1.20:47824
```

Without `--address`, the Invite link contains the address seen inside the container, such as `172.17.0.3`. Devices outside the container cannot reach that address.

The command prints a single-use Invite link that starts with `tacit://pair?d=...`. An `admin` invitation expires after 5 minutes. `collect` and `view` invitations expire after 10 minutes. On the Mac, paste the link under **Settings › Background service and connection › Connect to a remote service**, then follow the setup prompts. That Mac becomes an Admin device.

To set up or include a Relay mailbox in the invitation, add `--relay`.

```bash
docker exec -it tacit-hub bun hub/src/cli.ts pair --role admin --address http://192.168.1.20:47824 --relay https://relay.example.com
```

These local maintenance commands operate directly on the server database.

```bash
docker exec -it tacit-hub bun hub/src/cli.ts devices list
docker exec -it tacit-hub bun hub/src/cli.ts devices set-role <device_id> <collect|view|admin> [--force]
docker exec -it tacit-hub bun hub/src/cli.ts devices remove <device_id> [--force]
```

For temporary troubleshooting over an SSH tunnel, append `--local-status-port <port>` to the startup command to open a local diagnostics endpoint at `127.0.0.1:<port>` inside the container.

## 5. Network access

Use a private network such as Tailscale or WireGuard, or sync through a [Relay mailbox](../relay/README.md). Keep port 47824 off the public internet when possible. The device protocol uses end-to-end HPKE encryption and mutual X25519 authentication. A proxy cannot read plaintext or forge requests, but a public connection still exposes the server's IP and request timing. If you need public access, put an HTTPS reverse proxy such as Caddy, Nginx, or Cloudflare Tunnel in front of the device port.

## 6. Move an existing Mac database to the server

To keep all existing records and summaries, perform these steps in order.

1. Export the database key on the old Mac. Keep the 64-character hexadecimal `db-key` value from the output private.

   ```bash
   bun hub/src/cli.ts keys export
   ```

2. Quit Tacit on the old Mac or stop the Background service. Check that no `hub` or `distill` process is using `history.db` before copying it.
3. Copy `~/Library/Application Support/record-anything/history.db` from the old Mac to `/srv/tacit-data/history.db` on the server. Set permissions to `0600` and ownership to `1000:1000`. If you use API models on the Mac, you can also copy `models.json` as long as all providers are `anthropic` or `openai-compatible`.
4. Import the original database key into the server's `secrets.enc`. In Bash, paste the exported key at the hidden prompt. The import reads it from stdin.

   ```bash
   read -rs -p 'Database key: ' tacit_db_key
   printf '\n'
   printf '%s' "$tacit_db_key" | \
     docker run --rm -i \
       -v /srv/tacit-data:/data \
       -v /etc/tacit/master.key:/run/secrets/tacit_master_key:ro \
       tacit-hub:local \
       bun hub/src/cli.ts keys import-db-key
   unset tacit_db_key
   ```

   The command opens `/data/history.db` read-only to verify the key before writing `/data/secrets.enc`.
5. Start the container as in [section 2](#2-get-the-image-and-start-the-container), then pair an Admin Mac as in [section 4](#4-pair-the-first-admin-device).
6. Configure `anthropic` or `openai-compatible` in `/data/models.json` and set the corresponding model API key. The server resumes summaries once the configuration is ready.
7. Check that the migrated data is intact, then disable launch at login for the old local Background service.

## 7. Windows with Docker Desktop

Windows 10 and 11 can run the same Linux image in Docker Desktop with the WSL 2 backend. Run the commands below in PowerShell.

- **Use Docker volumes for the key and data.** Windows directory mounts can appear as root-owned with mode `0777` inside the container. Tacit rejects a broadly readable master key, and Windows directory mounts are slow and unreliable for SQLite.
- **Keep a user signed in.** Docker Desktop runs after sign-in. In Docker Desktop, enable startup at Windows sign-in. The container starts with it when you use `--restart unless-stopped`. Starting Docker Desktop over SSH can stop the service when SSH disconnects and prevent image pulls because Windows credentials are unavailable.
- **Check the firewall.** If devices on the local network cannot connect, check that Windows Firewall allows port 47824.

1. Install Docker Desktop, confirm that `docker info` returns version information, and pull or build `tacit-hub:local` as in [section 2](#2-get-the-image-and-start-the-container).
2. Generate the master key in a Docker volume and start the container.

   ```powershell
   docker volume create tacit-key
   docker volume create tacit-data
   docker run --rm -u 0 -v tacit-key:/key --entrypoint sh tacit-hub:local -c 'umask 077; head -c 32 /dev/urandom | od -An -tx1 -v | tr -d " \n" > /key/master.key; chown bun:bun /key/master.key; chmod 400 /key/master.key'
   docker run -d --name tacit-hub --hostname tacit-hub --restart unless-stopped `
     -e TZ=Asia/Shanghai `
     -e RA_MASTER_KEY_FILE=/run/secrets/tacit/master.key `
     -p 47824:47824 `
     -v tacit-data:/data `
     -v tacit-key:/run/secrets/tacit:ro `
     tacit-hub:local
   ```

3. Back up the master key in a password manager. The key lives in the `tacit-key` volume and can be lost if you delete the volume or reinstall Docker.

   ```powershell
   docker run --rm -v tacit-key:/key:ro --entrypoint cat tacit-hub:local /key/master.key
   ```

4. Use the Windows PC's local network or Tailscale IP to generate an Admin Invite link. Paste it on your Mac as in [section 4](#4-pair-the-first-admin-device).

   ```powershell
   docker exec tacit-hub bun hub/src/cli.ts pair --role admin --address http://192.168.1.20:47824
   ```

5. Once connected, configure your API model and key in **Settings › AI models** on the Mac. Tacit saves the settings to the server.
