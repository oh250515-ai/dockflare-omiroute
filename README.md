# dockflare-omiroute

Config-only deployment that publishes **OmniRoute** through **Cloudflare Tunnel**
(managed by **DockFlare**) — or privately over **Tailscale**. No application code;
it reuses the upstream projects as prebuilt Docker images driven by labels + env.

- OmniRoute: https://github.com/diegosouzapw/OmniRoute (image `diegosouzapw/omniroute`)
- DockFlare: https://github.com/ChrispyBacon-dev/DockFlare (image `alplat/dockflare`)

## One secret, minimal config

Everything is one JSON object in the secret `DEPLOY_CONFIG_JSON`. Minimum:

```json
{
  "cloudflare": { "email": "you@example.com", "globalApiKey": "...", "domain": "omni.example.com" },
  "omniroute": { "versions": ["latest", "3.8.45"] }
}
```

From just email + global key + domain we auto-derive the Cloudflare **account ID**,
**zone ID**, and **mint the scoped token** DockFlare needs. Everything else
(`apiToken`, `accountId`, `zoneId`, `server`, `flavor`, `env`, `access`) is optional
with fallbacks. See [`config.example.json`](config.example.json) and [`DEPLOY.md`](DEPLOY.md).

## How it works

1. A bootstrap step resolves Cloudflare creds from the one secret.
2. DockFlare creates/owns a Cloudflare Tunnel and its own `cloudflared`.
3. Each OmniRoute **version** runs from `diegosouzapw/omniroute:<version>` (no build).
4. DockFlare reads each container's labels and auto-creates hostname + DNS + ingress.
5. Reach each version at its own subdomain: `latest.<domain>`, `v3-8-45.<domain>`, …

Run as many versions in parallel as you list.

## Access modes

- **public** (default): internet-facing via Cloudflare Tunnel.
- **tailscale**: private, tailnet-only. Each version joins your tailnet as its own
  node; no public DNS. Set `access.mode = "tailscale"` + `access.tailscale.authKey`.

## Deploy targets

| Platform | File |
| --- | --- |
| GitHub Actions | [`.github/workflows/deploy.yml`](.github/workflows/deploy.yml) |
| Azure Pipelines | [`azure-pipelines.yml`](azure-pipelines.yml) |

Each supports **hosted** runners (deploy to a remote host via SSH — include `server`)
or **self-hosted / persistent** runners (deploy on the runner's own Docker — omit
`server`). Both call `scripts/ci-deploy.sh`, which auto-picks local vs remote.

## Files

| File | Purpose |
| --- | --- |
| `scripts/cf-bootstrap.mjs` | Resolve Cloudflare account/zone + mint scoped token (zero deps) |
| `scripts/render.mjs` | Generate `.env` + OmniRoute compose for the chosen access mode |
| `scripts/deploy.sh` | On-host: bootstrap → render → `docker compose up` → health wait |
| `scripts/ci-deploy.sh` | Pick local (self-hosted) vs remote (SSH) from the `server` block |
| `docker-compose.dockflare.yml` | DockFlare control plane (public mode only) |
| `.github/workflows/deploy.yml` / `azure-pipelines.yml` | CI entrypoints |
| `config.example.json` | Shape of the single `DEPLOY_CONFIG_JSON` secret |
