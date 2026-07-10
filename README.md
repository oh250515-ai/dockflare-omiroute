# dockflare-omiroute

Config-only deployment that publishes **OmniRoute** to the internet through
**Cloudflare Tunnel**, using **DockFlare** to auto-manage the tunnel, DNS and
Zero Trust Access. No application code — it reuses the upstream open-source
projects as-is (prebuilt Docker images + labels).

- OmniRoute: https://github.com/diegosouzapw/OmniRoute (image `diegosouzapw/omniroute`)
- DockFlare: https://github.com/ChrispyBacon-dev/DockFlare (image `alplat/dockflare`)

## How it works

1. **DockFlare** (control plane) reads your Cloudflare credentials from `.env`,
   creates/owns a Cloudflare Tunnel and runs its own `cloudflared` connector.
2. Each **OmniRoute version** runs as its own container from the official
   prebuilt image (`diegosouzapw/omniroute:<version>`). No building.
3. DockFlare sees each OmniRoute container's labels and automatically creates a
   public hostname + DNS record + tunnel ingress rule for it.
4. You reach each version at its own subdomain:
   - `latest`  → `https://latest.<baseDomain>`
   - `3.8.45`  → `https://v3-8-45.<baseDomain>`

Run as many versions in parallel as you list — just add them to `versions`.

## One secret, one variable

The deploy uses a **single** GitHub Actions secret: `DEPLOY_CONFIG_JSON`.
It holds one JSON object with everything (Cloudflare creds, target server, the
OmniRoute versions to run). See [`config.example.json`](config.example.json)
and [`DEPLOY.md`](DEPLOY.md).

On push to `main` (or manual run), the workflow:
1. Reads `DEPLOY_CONFIG_JSON`.
2. Ships this repo to your Docker host over SSH.
3. Renders `.env` + `docker-compose.omniroute.yml` from the JSON.
4. Runs `docker compose up -d` and waits until every OmniRoute version is healthy.

## What you need to provide

See [`DEPLOY.md`](DEPLOY.md) for the step-by-step. In short:
- A Cloudflare account: **API token**, **Account ID**, **Zone ID**, and a
  **base domain** in that zone (e.g. `omni.example.com`).
- A **Docker host** (any Linux server/VPS with Docker + SSH) — OmniRoute is a
  long-running service, so it needs a persistent host (it is not serverless).
- Which **OmniRoute versions** to expose (e.g. `latest`, `3.8.45`).

## Files

| File | Purpose |
| --- | --- |
| `docker-compose.dockflare.yml` | DockFlare control plane (dockflare + socket-proxy + redis) |
| `scripts/render.mjs` | Generates `.env` + OmniRoute compose from `config.json` (zero deps) |
| `scripts/deploy.sh` | Runs on the host: render → `docker compose up` → health wait |
| `.github/workflows/deploy.yml` | CI: reads the one secret, deploys over SSH |
| `config.example.json` | Shape of the single `DEPLOY_CONFIG_JSON` secret |
