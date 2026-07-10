#!/usr/bin/env node
// The ONLY pre-compose processing. Reads config.json (the single DEPLOY_CONFIG_JSON
// secret) and writes .env that the committed compose files consume. It does NOT
// generate any compose — services live in docker-compose.omniroute.yml, edit there.
//
// Responsibilities (kept minimal on purpose):
//   1. Cloudflare: turn email+globalApiKey (or a given apiToken) into the scoped
//      token + accountId + zoneId that DockFlare needs, and verify it.
//   2. OmniRoute: generate & persist JWT_SECRET / API_KEY_SECRET so sessions stay
//      valid across redeploys (fixes the login-loop), and set AUTH_COOKIE_SECURE.
//   3. Write .env, .df-seed.json (for the headless DockFlare seed), and .deploy-plan
//      (which compose files to use).
//
// Zero deps, Node 18+.
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { randomBytes } from 'node:crypto';

const cfg = JSON.parse(readFileSync(process.env.CONFIG_FILE || 'config.json', 'utf8'));
const cf = cfg.cloudflare || {};
const omni = cfg.omniroute || {};
const access = cfg.access || {};
const mode = String(access.mode || 'public').toLowerCase();
const API = 'https://api.cloudflare.com/client/v4';

// --- Persisted OmniRoute secrets (stable across redeploys) -----------------
const SECRETS_FILE = '.omniroute-secrets.json';
let secrets;
if (existsSync(SECRETS_FILE)) {
  secrets = JSON.parse(readFileSync(SECRETS_FILE, 'utf8'));
} else {
  secrets = {
    JWT_SECRET: randomBytes(48).toString('base64'),
    API_KEY_SECRET: randomBytes(32).toString('hex'),
  };
  writeFileSync(SECRETS_FILE, JSON.stringify(secrets));
}

const envLines = [
  `JWT_SECRET=${secrets.JWT_SECRET}`,
  `API_KEY_SECRET=${secrets.API_KEY_SECRET}`,
  `AUTH_COOKIE_SECURE=${mode === 'tailscale' ? 'false' : 'true'}`,
];

if (mode === 'tailscale') {
  const ts = access.tailscale || {};
  if (!ts.authKey) throw new Error('access.tailscale.authKey is required for tailscale mode');
  envLines.push(`TS_AUTHKEY=${ts.authKey}`);
  envLines.push(`TAILNET=${ts.tailnet || 'your-tailnet.ts.net'}`);
  writeFileSync('.env', envLines.join('\n') + '\n');
  writeFileSync('.deploy-plan', 'MODE=tailscale\nCOMPOSE_FILES="-f docker-compose.omniroute.tailscale.yml"\n');
  console.log('Prepared .env (mode=tailscale).');
  process.exit(0);
}

// ============================ public mode ==================================
function authHeaders() {
  if (cf.apiToken) return { Authorization: `Bearer ${cf.apiToken}` };
  if (cf.email && cf.globalApiKey) return { 'X-Auth-Email': cf.email, 'X-Auth-Key': cf.globalApiKey };
  throw new Error('Cloudflare auth missing: provide cloudflare.apiToken OR cloudflare.email + cloudflare.globalApiKey');
}
const H = { 'Content-Type': 'application/json', ...authHeaders() };

async function cfReq(method, path, body, headers) {
  const r = await fetch(API + path, { method, headers: headers || H, body: body ? JSON.stringify(body) : undefined });
  const j = await r.json().catch(() => ({}));
  if (!r.ok || j.success === false) {
    const msg = (j.errors && j.errors[0] && j.errors[0].message) || r.statusText;
    throw new Error(`Cloudflare ${method} ${path} failed: ${msg}`);
  }
  return j.result;
}

const domain = String(cf.domain || '').trim();
if (!domain) throw new Error('cloudflare.domain is required in public mode');

// Account
let accountId = cf.accountId;
if (!accountId) {
  const accts = await cfReq('GET', '/accounts?per_page=50');
  if (!accts || !accts.length) throw new Error('No Cloudflare account visible to these credentials');
  if (accts.length > 1) throw new Error(`Multiple accounts; set cloudflare.accountId. ${accts.map((a) => `${a.name}=${a.id}`).join(', ')}`);
  accountId = accts[0].id;
}

// Zone (covers domain, handles subdomains)
let zoneId = cf.zoneId;
if (!zoneId) {
  const zones = await cfReq('GET', '/zones?per_page=50');
  const match = zones.filter((z) => domain === z.name || domain.endsWith('.' + z.name)).sort((a, b) => b.name.length - a.name.length)[0];
  if (!match) throw new Error(`No Cloudflare zone covers "${domain}". Add the domain to Cloudflare or set cloudflare.zoneId.`);
  zoneId = match.id;
}

// Token: use provided, else mint one granting all account+zone groups (by scope,
// not by name — Cloudflare renames groups) and verify it can list tunnels.
let apiToken = cf.apiToken;
let tokenSource = 'provided';
if (!apiToken) {
  tokenSource = 'minted';
  const groups = await cfReq('GET', '/user/tokens/permission_groups?per_page=200');
  const ACC = 'com.cloudflare.api.account';
  const ZONE = 'com.cloudflare.api.account.zone';
  const scopesOf = (g) => (Array.isArray(g.scopes) ? g.scopes : []);
  const isZone = (g) => scopesOf(g).includes(ZONE);
  const accountGroups = groups.filter((g) => scopesOf(g).includes(ACC) && !isZone(g)).map((g) => ({ id: g.id }));
  const zoneGroups = groups.filter(isZone).map((g) => ({ id: g.id }));
  console.log(`Permission groups resolved: account=${accountGroups.length} zone=${zoneGroups.length}`);
  if (!accountGroups.length) throw new Error('No account-scoped permission groups; provide cloudflare.apiToken instead.');
  const policies = [{ effect: 'allow', resources: { [`${ACC}.${accountId}`]: '*' }, permission_groups: accountGroups }];
  if (zoneGroups.length) policies.push({ effect: 'allow', resources: { [`${ACC}.zone.${zoneId}`]: '*' }, permission_groups: zoneGroups });
  const tok = await cfReq('POST', '/user/tokens', { name: `dockflare-omniroute ${new Date().toISOString().slice(0, 10)}`, policies });
  apiToken = tok && tok.value;
  if (!apiToken) throw new Error('Token mint returned no value; provide cloudflare.apiToken instead.');
  const bearer = { 'Content-Type': 'application/json', Authorization: `Bearer ${apiToken}` };
  await cfReq('GET', `/accounts/${accountId}/cfd_tunnel?is_deleted=false&per_page=1`, undefined, bearer);
  console.log('Token verification OK: Cloudflare Tunnel access confirmed.');
}

const tunnelName = cf.tunnelName || 'dockflare-omniroute';

envLines.push(
  `CF_API_TOKEN=${apiToken}`,
  `CF_ACCOUNT_ID=${accountId}`,
  `CF_ZONE_ID=${zoneId}`,
  `TUNNEL_NAME=${tunnelName}`,
  `CLOUDFLARED_NETWORK_NAME=cloudflare-net`,
  `SCAN_ALL_NETWORKS=true`,
  `BASE_DOMAIN=${domain}`,
);
writeFileSync('.env', envLines.join('\n') + '\n');

// Seed input for the headless DockFlare config (Operational Mode, no wizard).
const dfl = cfg.dockflare || {};
const pw = dfl.password || randomBytes(18).toString('base64url');
writeFileSync('.df-seed.json', JSON.stringify({
  cf_api_token: apiToken, cf_account_id: accountId, cf_zone_id: zoneId,
  tunnel_name: tunnelName, username: dfl.username || 'admin', password: pw,
  master_api_key: dfl.masterApiKey || null,
}));
writeFileSync('.df-admin.txt', `DockFlare admin — user: ${dfl.username || 'admin'} password: ${pw}\n`);

writeFileSync('.deploy-plan', 'MODE=public\nCOMPOSE_FILES="-f docker-compose.dockflare.yml -f docker-compose.omniroute.yml"\n');

console.log(`Prepared .env (mode=public): account=${accountId} zone=${zoneId} token=${tokenSource} domain=${domain}`);
