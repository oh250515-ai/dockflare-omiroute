# Deploy guide

Everything is driven by **one** secret: `DEPLOY_CONFIG_JSON` — a single JSON object.
The absolute minimum is Cloudflare login + a domain + which versions to run:

```json
{
  "cloudflare": {
    "email": "you@example.com",
    "globalApiKey": "YOUR_CLOUDFLARE_GLOBAL_API_KEY",
    "domain": "omni.example.com"
  },
  "omniroute": {
    "versions": ["latest", "3.8.45"]
  }
}
```

Everything else is optional and has a fallback. Full field reference below.

---

## Config reference (what each field does)

### `cloudflare` (required)

| Field | Required? | What it does |
| --- | --- | --- |
| `email` | Yes* | Your Cloudflare login email. Used with `globalApiKey` to talk to the Cloudflare API. |
| `globalApiKey` | Yes* | Your Global API Key (dash > My Profile > API Tokens > Global API Key). From this we auto-derive the account ID, the zone ID, and we **mint a scoped API token** with exactly the permissions DockFlare needs (DockFlare only accepts a scoped token, not the global key). |
| `domain` | Yes | The hostname your versions live under, e.g. `omni.example.com`. Each version becomes a subdomain: `latest.omni.example.com`, `v3-8-45.omni.example.com`. The domain (or its parent) must already be added to Cloudflare — we look up the zone automatically. |
| `apiToken` | No (fallback) | A scoped API token. If set, it's used directly and `email`/`globalApiKey` are not needed. This is the "current" method; the global key is just the easier primary path. |
| `accountId` | No (fallback) | Skip account auto-discovery. Needed only if your login sees **multiple** accounts. |
| `zoneId` | No (fallback) | Skip zone auto-discovery. Provide it if you'd rather not have us resolve it from `domain`. |
| `tunnelName` | No | Name of the Cloudflare Tunnel DockFlare creates/owns. Default `dockflare-omniroute`. |

*Either (`email` + `globalApiKey`) **or** `apiToken` must be present.

> The scoped token we mint gets: Cloudflare Tunnel write, Account Settings read, Access (Apps/Policies/Orgs) write, Service Tokens write, Zone read, DNS write. If minting ever fails (Cloudflare renames permission groups occasionally), just drop a scoped `apiToken` into the config and it uses that instead.

### `omniroute` (required)

| Field | Required? | What it does |
| --- | --- | --- |
| `versions` | Yes | List of OmniRoute versions to run in parallel, e.g. `["latest", "3.8.45"]`. Each runs as its own container from the prebuilt image `diegosouzapw/omniroute:<version>` and gets its own subdomain. Add/remove entries and re-run to scale. |
| `flavor` | No | `base` (default, lean ~250MB) or `web` (adds Chromium/Playwright for web-cookie providers like gemini-web / claude-turnstile). `web` pulls the `<version>-web` image tag. |
| `env` | No | Extra environment values passed to every OmniRoute container (e.g. provider API keys). OmniRoute also runs fine with none and lets you configure providers in its UI. |

### `server` (optional — see "Where it runs")

Omit it entirely when deploying on a **self-hosted / persistent runner** (the runner's own machine is the Docker host). Include it to deploy to a **remote host over SSH** (required when using ephemeral GitHub/Azure hosted runners).

| Field | Required? | What it does |
| --- | --- | --- |
| `host` | Yes (if block present) | Remote host IP/DNS. Its presence is the switch: present = SSH to remote; absent = deploy locally on the runner. |
| `user` | No | SSH user (default `root`). Should be able to run `docker`. |
| `port` | No | SSH port (default `22`). |
| `path` | No | Remote directory to sync into (default `/opt/dockflare-omniroute`). |
| `sshKey` | Yes (if block present) | SSH **private** key (its public half in the host's `authorized_keys`). Newlines as real `\n` or escaped. |

### `access` (optional — public vs private)

| Field | Required? | What it does |
| --- | --- | --- |
| `mode` | No | `public` (default) = exposed on the internet via Cloudflare Tunnel. `tailscale` = reachable **only inside your tailnet** (private), no public DNS, DockFlare/Cloudflare not used. |
| `tailscale.authKey` | Yes (if `mode=tailscale`) | A Tailscale auth key (tskey-…). Each version joins your tailnet as its own node. |
| `tailscale.tailnet` | No | Your tailnet name (e.g. `tailXXXX.ts.net`), only used to print the right URLs. |

---

## Where it runs (the `server` question)

OmniRoute is a **long-running service**, so it needs a persistent Docker host. GitHub/Azure **hosted** runners are ephemeral — they're deleted when the job ends — so they can't host it. Two supported shapes:

1. **Hosted runner + remote host (SSH).** Include the `server` block. The pipeline runs on a throwaway runner, rsyncs the repo to your host, and runs the deploy there.
2. **Self-hosted / persistent runner.** Install a GitHub Actions runner (or Azure agent) on your own always-on box, **omit** the `server` block, and it deploys on that same machine's Docker — no SSH at all. This is the "runs directly in the pipeline" case.

## Platforms

| Platform | File | Runner choice |
| --- | --- | --- |
| GitHub Actions | `.github/workflows/deploy.yml` | Repo variable `DEPLOY_RUNNER` (unset = `ubuntu-latest` hosted; set to `self-hosted` for your box) |
| Azure Pipelines | `azure-pipelines.yml` | `pool.vmImage` (hosted) or swap to `pool.name` of your self-hosted pool |

Both call the same `scripts/ci-deploy.sh`, which auto-picks local vs remote from the `server` block.

## Steps

1. Fill in `config.example.json`, collapse to the secret:
   - GitHub: repo > Settings > Secrets and variables > Actions > new secret `DEPLOY_CONFIG_JSON`.
   - Azure: Pipeline > Edit > Variables > secret variable `DEPLOY_CONFIG_JSON`.
2. (Self-hosted only) register the runner/agent on your Docker host and set the runner selector.
3. Push to `main` (or run the workflow/pipeline manually). It bootstraps Cloudflare, renders compose, `docker compose up -d`, and waits for every OmniRoute container to be healthy.

## Verify

- Public mode: `https://latest.<domain>`, `https://v3-8-45.<domain>`, … (DockFlare UI on host `:5000`).
- Tailscale mode: `http://latest.<tailnet>.ts.net:20128`, etc., reachable only from your tailnet.

## Scaling versions later

Edit `omniroute.versions` in the secret and re-run. New versions get their own container + hostname; removed ones are cleaned up (`--remove-orphans`), and in public mode DockFlare tears down their DNS/ingress after its grace period.
