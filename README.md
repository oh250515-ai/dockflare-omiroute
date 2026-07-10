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

## From keep-alive (test) to a persistent deployment

The keep-alive run dies with the runner. For something that stays up, pick one:

### Option A — Your own server over SSH (simplest)
Add a `server` block to `DEPLOY_CONFIG_JSON` and run **Deploy** (not keep-alive):
```json
{ "cloudflare": { "...": "..." }, "omniroute": { "versions": ["latest","3.8.45"] },
  "server": { "host": "1.2.3.4", "user": "deploy", "port": 22, "path": "/opt/dockflare-omniroute",
              "sshKey": "-----BEGIN OPENSSH PRIVATE KEY-----\n...\n-----END OPENSSH PRIVATE KEY-----" } }
```
Requirements on the host: Docker + compose plugin, the deploy user in the `docker` group,
and its public key in `~/.ssh/authorized_keys`. The hosted runner just rsyncs + runs the deploy there.

### Option B — Self-hosted runner (no SSH)
Install a GitHub Actions runner on your always-on box, set repo variable
`DEPLOY_RUNNER=self-hosted`, and **omit** the `server` block. Deploy runs on that
machine's own Docker. Same idea on Azure: swap `pool.vmImage` for your self-hosted `pool.name`.

Either way the state lives in Docker volumes (`dockflare_data`, `omniroute-*-data`), so the
tunnel + config survive restarts. Re-running the deploy is idempotent (seed is skipped if present).

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

Exposing a **different** app with this same DockFlare setup? See
[`docs/DOCKFLARE-FOR-ANY-APP.md`](docs/DOCKFLARE-FOR-ANY-APP.md) (reusable playbook, in Vietnamese).

## Troubleshooting log (issues hit during bring-up)

Real problems we hit getting this live, and how each was found/fixed. Check here first.

| # | Symptom | Root cause | Fix / how to spot it |
| --- | --- | --- | --- |
| 1 | Stack "green" but URL dies minutes later | GitHub/Azure **hosted** runners are ephemeral — destroyed at job end, taking the tunnel with them | Use a **self-hosted runner** or a `server` block (remote host over SSH). `keepalive.yml` is only for temporary testing. |
| 2 | Container up, but **no DNS / no tunnel ever created** | DockFlare only configures itself once its **encrypted config** (`dockflare_config.dat` + `dockflare.key`) exists. `CF_API_TOKEN` env just **pre-fills the setup wizard**; a human still had to click through it | Headless seed: `scripts/seed-dockflare.py` writes that encrypted config directly, run **inside the DockFlare image** so crypto/hash libs match. Diagnostics **section 2** shows if the config is present. |
| 3 | `ci-deploy.sh exited non-zero` on the very first line, nothing ran | `read` consumed `node`'s output which had **no trailing newline** → `read` returns non-zero at EOF → `set -e` aborted immediately | Use `console.log` (newline) not `process.stdout.write`, plus `|| true` guard. Spotted via `bash -x` verbose deploy in the CI log. |
| 4 | Tunnel create → **403 code 10000 Authentication error**; DNS never appears | The minted token had **zero account-scoped permissions** — we matched permission groups by **name**, and Cloudflare had renamed them (e.g. "Cloudflare Tunnel" → "Cloudflare One Connector: cloudflared"), so the account policy came out empty. Tunnel is account-scoped | `scripts/cf-bootstrap.mjs` now partitions permission groups by their declared **`scopes`** (grant ALL account groups + ALL zone groups), and **verifies** the new token can list tunnels before proceeding. Look for `Permission groups resolved: account=N zone=M` and `Token verification OK`. Seen in diagnostics **section 4**. |
| 5 | Log spam: `access.api.error.not_enabled` (Access/Zero Trust) | Zero Trust Access isn't initialized on the account | **Harmless in public mode** — DockFlare falls back to a local policy reference. Only matters if you use Access policies. |
| 6 | Slow first run (re-downloads ~400MB per image) | Anonymous, sequential pulls | Add the `dockerhub` block, rely on parallel prepull + image cache (see **Speed**). First run is always cold. |
| 7 | OmniRoute shows **(unhealthy)** / `file data stream has unexpected number of bytes` | **RESOLVED: false-negative, not an outage.** OmniRoute's own Docker healthcheck fails in some network setups (upstream [#3151](https://github.com/diegosouzapw/OmniRoute/issues/3151) / [#296](https://github.com/diegosouzapw/OmniRoute/issues/296)) even though the app serves fine on `:20128`. The `file data stream` line is a non-fatal Next.js static-asset warning. Verified: the public URL returns the real app | `scripts/deploy.sh` no longer blocks only on Docker health — it also accepts a container that **actually serves HTTP** on 20128. If a URL genuinely 502s, check diagnostics **section 7** and try a different `versions` tag. |

### Fast triage order

1. **CI log**: did `ci-deploy.sh` print `Cloudflare resolved: ...` and `Token verification OK`? If not → issue #3 or #4.
2. **Section 2**: is the DockFlare config seeded? If not → issue #2.
3. **Section 4**: any `403` / `Authentication error` / `code 10000`? → issue #4 (token perms).
4. **Section 6**: is the `cloudflared` connector running? No connector = tunnel wasn't created (issue #4).
5. **Section 8**: are the CNAMEs live yet? `Status:3` = NXDOMAIN (DockFlare hasn't created them). `Status:0` = created.
6. **Section 7**: OmniRoute healthy? If URL resolves but 502s → issue #7 (usually a false-negative).

## Sổ tay xử lý sự cố (tiếng Việt)

Các lỗi thật đã gặp khi đưa hệ thống lên, kèm cách phát hiện và sửa. Xem trước tiên khi kẹt.

| # | Triệu chứng | Nguyên nhân gốc | Cách sửa / dấu hiệu nhận biết |
| --- | --- | --- | --- |
| 1 | Stack "xanh" nhưng URL chết sau vài phút | Runner **hosted** của GitHub/Azure là máy dùng-một-lần, hết job là xoá, kéo theo tunnel | Dùng **self-hosted runner** hoặc khối `server` (host qua SSH). `keepalive.yml` chỉ để test tạm. |
| 2 | Container chạy nhưng **không có DNS / không tạo tunnel** | DockFlare chỉ cấu hình khi có **file config mã hóa**. Đặt `CF_API_TOKEN` chỉ **điền sẵn wizard**, vẫn phải bấm tay | Seed headless: `scripts/seed-dockflare.py` ghi thẳng config, chạy **bằng chính image DockFlare**. Kiểm tra section 2 của `diagnose.sh`. |
| 3 | `ci-deploy.sh` thoát ngay dòng đầu, không chạy gì | `read` đọc output của `node` **thiếu newline cuối** -> `read` trả exit ≠ 0 -> `set -e` giết script | Dùng `console.log` (có newline) thay `process.stdout.write`, thêm chặn `|| true`. Phát hiện nhờ `bash -x`. |
| 4 | Tạo tunnel -> **403 code 10000**; DNS không bao giờ lên | Token mint ra **không có quyền account** vì match permission-group theo **tên** mà Cloudflare đã đổi tên. Tunnel là account-scoped | `cf-bootstrap.mjs` giờ phân loại group theo **`scopes`** (cấp toàn bộ account + zone) và **verify** token trước. Tìm dòng `Permission groups resolved` + `Token verification OK`. |
| 5 | Log spam `access.api.error.not_enabled` | Zero Trust chưa bật trên account | **Vô hại ở public mode** — DockFlare dùng policy cục bộ. Chỉ quan trọng nếu dùng Access. |
| 6 | Lần đầu chạy chậm (tải lại ~400MB/image) | Pull ẩn danh, tuần tự | Thêm khối `dockerhub`, dùng prepull song song + image cache (mục **Speed**). Lần đầu luôn nguội. |
| 7 | OmniRoute báo **(unhealthy)** | **Đã xử lý: false-negative, không phải chết.** Healthcheck của OmniRoute lỗi trong một số setup mạng (upstream #3151/#296) dù app vẫn phục vụ trên `:20128`. Đã xác minh URL công khai trả về app thật | `deploy.sh` không còn chỉ chờ Docker health, mà chấp nhận container **đang phục vụ HTTP**. Nếu URL thật sự 502 -> soi section 7, thử tag `versions` khác. |

## Files

| File | Purpose |
| --- | --- |
| `scripts/cf-bootstrap.mjs` | Resolve Cloudflare account/zone + mint & verify scoped token |
| `scripts/seed-dockflare.py` | Headlessly seed DockFlare's encrypted config (run inside its image) |
| `scripts/render.mjs` | Generate `.env` + OmniRoute compose for the chosen access mode |
| `scripts/deploy.sh` | On-host: bootstrap → pull → seed → `docker compose up` → readiness wait |
| `scripts/ci-deploy.sh` | Pick local (self-hosted) vs remote (SSH) from the `server` block |
| `scripts/diagnose.sh` | 9-section diagnostics snapshot |
| `scripts/image-cache.sh` / `scripts/lib.sh` | Image caching + shared helpers (host node, parallel pull, docker login) |
| `scripts/keepalive.sh` | Test-only: deploy on runner, probe URLs, hold job open |
| `docker-compose.dockflare.yml` | DockFlare control plane (public mode only) |
| `docs/DOCKFLARE-FOR-ANY-APP.md` | Reusable playbook: expose any app via DockFlare (VN) |
| `.github/workflows/deploy.yml` / `azure-pipelines.yml` | CI entrypoints (image cache built in) |
| `.github/workflows/keepalive.yml` | Test-only keep-alive workflow |
| `config.example.json` | Shape of the single `DEPLOY_CONFIG_JSON` secret |
