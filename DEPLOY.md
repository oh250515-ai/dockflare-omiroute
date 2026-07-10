# Deploy guide

Everything is driven by **one** GitHub Actions secret: `DEPLOY_CONFIG_JSON`.
It is a single JSON object. See [`config.example.json`](config.example.json).

## 1. What you must provide

### A) Cloudflare
- **API token** with these permissions (Account + Zone):
  - `Account > Cloudflare Tunnel > Edit`
  - `Account > Account Settings > Read`
  - `Account > Access: Apps and Policies > Edit`
  - `Zone > DNS > Edit`
  - `Zone > Zone > Read`
- **Account ID** — Cloudflare dashboard > any zone > right sidebar, or the account URL.
- **Zone ID** — the zone (domain) overview page > right sidebar.
- **Base domain** — a hostname inside that zone you want versions under,
  e.g. `omni.example.com`. Versions become `latest.omni.example.com`,
  `v3-8-45.omni.example.com`, etc. A wildcard is not required — DockFlare
  creates each DNS record itself.

### B) A Docker host (persistent server)
OmniRoute is a long-running service, not serverless, so it needs a Linux host
with **Docker + docker compose plugin** and **SSH** access. That is the only
runtime dependency — the host does not need Node, git, or anything else.
- `host`, `user`, `port` (default 22), and an **SSH private key** whose public
  half is in the user's `~/.ssh/authorized_keys`.
- The deploy user should be able to run `docker` (in the `docker` group).

### C) Versions
- List the OmniRoute versions to run in parallel, e.g. `["latest", "3.8.45"]`.
- `flavor`: `base` (default, lean) or `web` (adds Chromium for web-cookie
  providers like gemini-web / claude-turnstile).
- `env`: optional OmniRoute environment values (provider API keys, etc.).
  OmniRoute also runs with none and lets you configure providers in its UI.

## 2. Build the secret

Take `config.example.json`, fill it in, then collapse it to a single line and
save it as the repo secret `DEPLOY_CONFIG_JSON`:

> GitHub repo > Settings > Secrets and variables > Actions > New repository secret
> Name: `DEPLOY_CONFIG_JSON`

The SSH private key must be embedded with `\n` escapes (real newlines also work
in the GitHub secret box, but the workflow normalizes either way).

## 3. Deploy

Push to `main`, or run the **Deploy** workflow manually (Actions tab >
workflow_dispatch). The workflow:
1. Reads `DEPLOY_CONFIG_JSON`.
2. Rsyncs this repo to `<server.path>` on your host.
3. Renders `.env` + `docker-compose.omniroute.yml` from the JSON (inside a
   throwaway Node container on the host).
4. `docker compose up -d` for DockFlare + every OmniRoute version and waits
   until each is healthy.

DockFlare then provisions the tunnel, DNS records and ingress automatically.
First provisioning takes a minute or two per hostname.

## 4. Verify

- DockFlare UI: `http://<server-ip>:5000` (restrict/remove this port once happy).
- Each version: `https://latest.<baseDomain>`, `https://v3-8-45.<baseDomain>`, ...

## Adding / removing versions later

Edit the `versions` array in `DEPLOY_CONFIG_JSON` and re-run the workflow.
New versions get their own container + hostname; removed ones are cleaned up
(`--remove-orphans`), and DockFlare tears down their DNS/ingress after its grace
period.
