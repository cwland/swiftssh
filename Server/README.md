# Termius Reimagined sync server

A small Vapor server that stores your end-to-end encrypted vault records in SQLite.
It never sees plaintext; clients authenticate with a bearer API key.

## Run it

1. Generate one key per Mac (so a single Mac can be revoked later):

   ```sh
   openssl rand -hex 32
   ```

2. From this `Server/` directory, start it with the keys comma-separated:

   ```sh
   SYNC_API_KEYS=key-for-mac-mini,key-for-macbook docker compose up -d --build
   ```

   To keep the keys out of your shell history, put `SYNC_API_KEYS=...` in `Server/.env`
   (Compose reads it automatically). The build context is the repository root, because the
   server depends on `Packages/CoreSSH`.

3. Check it:

   ```sh
   curl http://localhost:8080/health
   # {"status":"ok"}
   ```

All other endpoints require `Authorization: Bearer <key>`.

## Revoking a Mac

Remove its key from `SYNC_API_KEYS` and run `docker compose up -d` again.

## TLS

The server speaks plain HTTP on port 8080. Put it behind your reverse proxy for HTTPS
(for example Nginx Proxy Manager). A path prefix such as `https://host/sync/` works, as
long as the proxy strips the prefix before forwarding to `termius-sync:8080`.

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
Records are encrypted client-side, so the backup is useless without your vault password.
