# Termius Reimagined sync server

A small Vapor server that stores your end-to-end encrypted vault records in SQLite.
It never sees plaintext; clients authenticate with a bearer API key.

## Develop locally on the Mac

Generate one key per Mac (so a single Mac can be revoked later):

```sh
openssl rand -hex 32
```

Run natively from this `Server/` directory:

```sh
SYNC_API_KEYS=dev-key DATABASE_PATH=/tmp/sync.sqlite swift run Run serve --hostname 127.0.0.1 --port 8080
```

Or with Docker (the build context is the repository root, because the server depends on
`Packages/CoreSSH`; Compose handles that):

```sh
SYNC_API_KEYS=dev-key docker compose up --build
```

Check it:

```sh
curl http://localhost:8080/health
# {"status":"ok"}
```

All other endpoints require `Authorization: Bearer <key>`.

## Deploy from GHCR

Pushes to `main` that touch `Server/` or `Packages/CoreSSH/` (and tags named `server-v*`) run
tests and publish `ghcr.io/cwland/termius-reimagined-sync` for linux/amd64, tagged `latest`
(main only), the short commit sha, and the git tag.

The repository is private, so the package is too. On the server, log in once with a personal
access token that has the `read:packages` scope:

```sh
docker login ghcr.io -u cwland
```

Copy `docker-compose.deploy.yml` to the server, create `.env` next to it (comma-separated
keys, one per Mac), and start it:

```sh
echo 'SYNC_API_KEYS=key-for-mac-mini,key-for-macbook' > .env
docker compose -f docker-compose.deploy.yml up -d
```

To update:

```sh
docker compose -f docker-compose.deploy.yml pull
docker compose -f docker-compose.deploy.yml up -d
```

Set `SYNC_IMAGE_TAG` in `.env` (a short sha or `server-vX.Y.Z`) to pin a version instead of
`latest`.

## Revoking a Mac

Remove its key from `SYNC_API_KEYS` and run `docker compose up -d` again (add
`-f docker-compose.deploy.yml` for the GHCR deployment).

## Behind your reverse proxy

The server speaks plain HTTP on port 8080 and terminates no TLS, so put it behind your
reverse proxy for HTTPS (for example Nginx Proxy Manager, reached over Tailscale).

The compose file publishes `8080:8080` on all interfaces so a proxy on another host can reach
it. If your proxy runs on the same host, publish only to localhost: `127.0.0.1:8080:8080`.

The server has no path-prefix support of its own: routes are mounted at `/health` and
`/v1/...`. If you publish it under a prefix such as `https://host/sync/`, the proxy must
strip the prefix before forwarding to the server (for Nginx: `location /sync/ {
proxy_pass http://<server-ip>:8080/; }`, with the trailing slash). Use an address the proxy
can reach: the server's IP or hostname, or `termius-sync:8080` only if the proxy shares a
Docker network with the container. Serving it on its own
hostname needs no rewriting. Forward the `Authorization` header unchanged, and allow request
bodies of at least 10 MB (the server's limit; Nginx defaults to 1 MB, so set
`client_max_body_size 10m`).

## Backups

All state is one SQLite file, `/data/sync.sqlite`, in the `sync-data` Docker volume.
Back up that volume, for example:

```sh
docker compose stop termius-sync
docker run --rm -v server_sync-data:/data -v "$PWD":/backup ubuntu \
  tar czf /backup/sync-data.tgz -C /data .
docker compose start termius-sync
```

(The volume name is prefixed with the Compose project name; check `docker volume ls`.)
Records are encrypted client-side, so the backup is useless without your sync passphrase.
