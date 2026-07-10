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
(`apiToken`, `accountId`, `zoneId`, `server`, `flavor`, `env`, `access`, `dockerhub`) is
optional with fallbacks. See [`config.example.json`](config.example.json) and [`DEPLOY.md`](DEPLOY.md).

## How it works

1. A bootstrap step resolves Cloudflare creds from the one secret.
2. DockFlare is **seeded headlessly** (encrypted config written directly) so it boots
   straight into Operational Mode, then creates/owns a Cloudflare Tunnel + `cloudflared`.
3. Each OmniRoute **version** runs from `diegosouzapw/omniroute:<version>` (no build).
4. DockFlare reads each container's labels and auto-creates hostname + DNS + ingress.
5. Reach each version at its own subdomain: `latest.<domain>`, `v3-8-45.<domain>`, …

## Access modes

- **public** (default): internet-facing via Cloudflare Tunnel.
- **tailscale**: private, tailnet-only. Set `access.mode = "tailscale"` + `access.tailscale.authKey`.

## Deploy targets

| Platform | File |
| --- | --- |
| GitHub Actions | [`.github/workflows/deploy.yml`](.github/workflows/deploy.yml) |
| Azure Pipelines | [`azure-pipelines.yml`](azure-pipelines.yml) |

Each supports **hosted** runners (deploy to a remote host via SSH — include `server`)
or **self-hosted / persistent** runners (deploy on the runner's own Docker — omit
`server`). Both call `scripts/ci-deploy.sh`, which auto-picks local vs remote.

> `keepalive.yml` is a **test-only** workflow: it runs the whole stack on the ephemeral
> GitHub-hosted runner and holds the job open (~5.5h) so you can reach it from the internet.
> The machine (and tunnel) are destroyed when the job ends — use a persistent host for real use.

## Speed

Three layers, all in `scripts/lib.sh` + `scripts/image-cache.sh`:
1. **Docker Hub login** (optional `dockerhub` block) for a higher/faster pull rate.
2. **Parallel prepull** of all images (compose pulls sequentially; images are ~400MB each).
3. **Image cache** between CI runs (`docker save`/`load` a tarball; keyed by the image list).

## Debugging

`scripts/diagnose.sh` prints a 9-section snapshot (containers, seeded config, DockFlare
logs, cloudflared connector, per-version OmniRoute health, live DNS, network membership).
The keep-alive workflow runs it after deploy and every ~2 min while waiting, and runs the
deploy with `bash -x` so every command shows in the CI log.

## Troubleshooting log (issues hit during bring-up)

Real problems we hit getting this live, and how each was found/fixed. Check here first.

| # | Symptom | Root cause | Fix / how to spot it |
| --- | --- | --- | --- |
| 1 | Stack "green" but URL dies minutes later | GitHub/Azure **hosted** runners are ephemeral — destroyed at job end, taking the tunnel with them | Use a **self-hosted runner** or a `server` block (remote host over SSH). `keepalive.yml` is only for temporary testing. |
| 2 | Container up, but **no DNS / no tunnel ever created** | DockFlare only configures itself once its **encrypted config** (`dockflare_config.dat` + `dockflare.key`) exists. `CF_API_TOKEN` env just **pre-fills the setup wizard**; a human still had to click through it | Headless seed: `scripts/seed-dockflare.py` writes that encrypted config directly, run **inside the DockFlare image** so crypto/hash libs match. Diagnostics **section 2** shows if the config is present. |
| 3 | `ci-deploy.sh exited non-zero` on the very first line, nothing ran | `read` consumed `node`'s output which had **no trailing newline** → `read` returns non-zero at EOF → `set -e` aborted immediately | Use `console.log` (newline) not `process.stdout.write`, plus `|| true` guard. Spotted via `bash -x` verbose deploy in the CI log. |
| 4 | Tunnel create → **403 code 10000 Authentication error**; DNS never appears | The minted token had **zero account-scoped permissions** — we matched permission groups by **name**, and Cloudflare had renamed them (e.g. "Cloudflare Tunnel" → "Cloudflare One Connector: cloudflared"), so the account policy came out empty. Tunnel is account-scoped | `scripts/cf-bootstrap.mjs` now partitions permission groups by their declared **`scopes`** (grant ALL account groups + ALL zone groups), and **verifies** the new token can list tunnels before proceeding. Look for `Permission groups resolved: account=N zone=M` and `Token verification OK`. Fix: seen in diagnostics **section 4** (DockFlare logs). |
| 5 | Log spam: `access.api.error.not_enabled` (Access/Zero Trust) | Zero Trust Access isn't initialized on the account | **Harmless in public mode** — DockFlare falls back to a local policy reference. Only matters if you use Access policies. |
| 6 | Slow first run (re-downloads ~400MB per image) | Anonymous, sequential pulls | Add the `dockerhub` block, rely on parallel prepull + image cache (see **Speed**). First run is always cold. |
| 7 | OmniRoute shows **(unhealthy)** / `file data stream has unexpected number of bytes` | Under investigation — app still binds `:20128`. May be a strict healthcheck vs. a real image issue | If a version returns 502 through the tunnel, check diagnostics **section 7** (per-version logs). Try pinning a different `versions` tag. |

### Fast triage order

1. **CI log**: did `ci-deploy.sh` print `Cloudflare resolved: ...` and `Token verification OK`? If not → issue #3 or #4.
2. **Section 2**: is the DockFlare config seeded? If not → issue #2.
3. **Section 4**: any `403` / `Authentication error` / `code 10000`? → issue #4 (token perms).
4. **Section 6**: is the `cloudflared` connector running? No connector = tunnel wasn't created (issue #4).
5. **Section 8**: are the CNAMEs live yet? `Status:3` = NXDOMAIN (DockFlare hasn't created them). `Status:0` = created.
6. **Section 7**: OmniRoute healthy? If URL resolves but 502s → issue #7.

## Files

| File | Purpose |
| --- | --- |
| `scripts/cf-bootstrap.mjs` | Resolve Cloudflare account/zone + mint & verify scoped token |
| `scripts/seed-dockflare.py` | Headlessly seed DockFlare's encrypted config (run inside its image) |
| `scripts/render.mjs` | Generate `.env` + OmniRoute compose for the chosen access mode |
| `scripts/deploy.sh` | On-host: bootstrap → pull → seed → `docker compose up` → health wait |
| `scripts/ci-deploy.sh` | Pick local (self-hosted) vs remote (SSH) from the `server` block |
| `scripts/diagnose.sh` | 9-section diagnostics snapshot |
| `scripts/image-cache.sh` / `scripts/lib.sh` | Image caching + shared helpers (host node, parallel pull, docker login) |
| `scripts/keepalive.sh` | Test-only: deploy on runner, probe URLs, hold job open |
| `docker-compose.dockflare.yml` | DockFlare control plane (public mode only) |
| `.github/workflows/deploy.yml` / `azure-pipelines.yml` | CI entrypoints (image cache built in) |
| `.github/workflows/keepalive.yml` | Test-only keep-alive workflow |
| `config.example.json` | Shape of the single `DEPLOY_CONFIG_JSON` secret |
