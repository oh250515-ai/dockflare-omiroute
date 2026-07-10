# Deploy guide

Everything is driven by **one** secret: `DEPLOY_CONFIG_JSON` (a single JSON object).
Design in one line: **committed compose files define the services; one small step
(`scripts/prepare-env.mjs`) turns the secret into the `.env` those files consume, then
`docker compose up`.** No compose is generated at deploy time.

Minimum secret:

```json
{
  "cloudflare": {
    "email": "you@example.com",
    "globalApiKey": "YOUR_CLOUDFLARE_GLOBAL_API_KEY",
    "domain": "omni.example.com"
  }
}
```

---

## What goes in the secret (and what does NOT)

The secret only carries values that must become **environment** for DockFlare/OmniRoute.
**Versions, ports and hostnames are NOT here** — they live in `docker-compose.omniroute.yml`.

### `cloudflare` (required)

| Field | Required? | What it does |
| --- | --- | --- |
| `email` | Yes* | Cloudflare login email; used with `globalApiKey` to call the API. |
| `globalApiKey` | Yes* | Global API Key. From it, `prepare-env` auto-derives account ID, zone ID, and **mints a scoped token** DockFlare needs (DockFlare only accepts a scoped Bearer token, not the global key). |
| `domain` | Yes | Base domain, e.g. `omni.example.com`. Becomes `${BASE_DOMAIN}` in `.env`; the compose services build `latest.<domain>`, `v3-8-45.<domain>` from it. Must already be a Cloudflare zone. |
| `apiToken` | No (fallback) | A ready scoped token. If set, used directly; `email`/`globalApiKey` not needed. |
| `accountId` | No (fallback) | Skip account auto-discovery (needed if your login sees multiple accounts). |
| `zoneId` | No (fallback) | Skip zone auto-discovery. |
| `tunnelName` | No | Cloudflare Tunnel name DockFlare creates. Default `dockflare-omniroute`. |

*Either (`email` + `globalApiKey`) **or** `apiToken`.

### `dockerhub` (optional — faster pulls)

| Field | What it does |
| --- | --- |
| `username` / `token` | `docker login` before pulling, for a higher/faster Docker Hub rate limit. Omit to pull anonymously. |

### `dockflare` (optional — admin login)

| Field | What it does |
| --- | --- |
| `username` / `password` | DockFlare UI admin login seeded headlessly. If omitted: user `admin`, random password (printed in the deploy log / `.df-admin.txt`). |

### `access` (optional — public vs private)

| Field | What it does |
| --- | --- |
| `mode` | `public` (default) = internet via Cloudflare Tunnel. `tailscale` = tailnet-only, uses `docker-compose.omniroute.tailscale.yml`, no DockFlare/Cloudflare. |
| `tailscale.authKey` | Required if `mode=tailscale`. A `tskey-…` auth key. |
| `tailscale.tailnet` | Your tailnet name (for the printed URLs). |

### `server` (optional — remote host over SSH)

Omit for a self-hosted/persistent runner (deploy on the runner's own Docker). Include to
deploy to a remote host (required with ephemeral hosted runners).

| Field | What it does |
| --- | --- |
| `host` | Remote host IP/DNS. Its presence switches to SSH mode. |
| `user` / `port` / `path` | SSH user (default `root`), port (22), remote dir (`/opt/dockflare-omniroute`). |
| `sshKey` | SSH **private** key (public half in the host's `authorized_keys`). |

---

## Changing versions / ports / hostnames

Edit **`docker-compose.omniroute.yml`** (not the secret). To add a version, copy a service
block and change: `container_name`, `image` tag, the `hostname` subdomain, and the volume
name. `${BASE_DOMAIN}`, `${JWT_SECRET}`, `${API_KEY_SECRET}` are filled from `.env`
automatically. Full patterns + examples for other apps: [`docs/DOCKFLARE-FOR-ANY-APP.md`](docs/DOCKFLARE-FOR-ANY-APP.md).

## Where it runs

OmniRoute is a **long-running service**, so it needs a persistent Docker host. Hosted
GitHub/Azure runners are ephemeral. Two supported shapes:

1. **Hosted runner + remote host (SSH).** Include the `server` block.
2. **Self-hosted / persistent runner.** Omit `server`; set repo var `DEPLOY_RUNNER=self-hosted`
   (GitHub) or a self-hosted `pool.name` (Azure). Deploys on that machine's own Docker.

## Platforms

| Platform | File | Runner choice |
| --- | --- | --- |
| GitHub Actions | `.github/workflows/deploy.yml` | `DEPLOY_RUNNER` repo var (unset = hosted) |
| Azure Pipelines | `azure-pipelines.yml` | `pool.vmImage` (hosted) or `pool.name` (self-hosted) |

Both call `scripts/ci-deploy.sh` → `scripts/deploy.sh`, which runs `prepare-env` then
`docker compose up` from the committed files. Docker-image caching is built into both.

## Steps

1. Fill in `config.example.json`, save it as the secret:
   - GitHub: repo > Settings > Secrets and variables > Actions > new secret `DEPLOY_CONFIG_JSON`.
   - Azure: Pipeline > Edit > Variables > secret variable `DEPLOY_CONFIG_JSON`.
2. (Self-hosted only) register the runner/agent on your Docker host and set the runner selector.
3. Run **Deploy** (push to `main` on a self-hosted runner, or workflow_dispatch). It runs
   `prepare-env` → seeds DockFlare → `docker compose up` → waits until OmniRoute is serving.

## Verify

- Public: `https://latest.<domain>`, `https://v3-8-45.<domain>` (DockFlare UI on host `:5000`).
- Tailscale: `http://latest.<tailnet>.ts.net:20128`, reachable only from your tailnet.

## Testing quickly (no persistent host)

Run the **Keep-alive test** workflow. It deploys on the ephemeral hosted runner and holds the
job open (~5.5h) with live diagnostics so you can reach the URLs while it lives. It tears down
when the job ends — not for real use.

## If something breaks

See the **Troubleshooting log** in [`README.md`](README.md) (8 real issues + fast triage order)
and run `scripts/diagnose.sh` for a full snapshot.
