#!/usr/bin/env node
// Resolves the Cloudflare bits DockFlare needs, from the least possible input.
//
// Auth precedence (fallback chain):
//   1) cloudflare.apiToken                 -> used as-is (scoped token, Bearer).  ["current" method]
//   2) cloudflare.email + cloudflare.globalApiKey -> used to auto-derive everything. [primary]
//
// Auto-derivation with global key:
//   - accountId : from GET /accounts (unless cloudflare.accountId is set)
//   - zoneId    : from the zone that covers cloudflare.domain (unless cloudflare.zoneId is set)
//   - apiToken  : minted via POST /user/tokens (DockFlare only accepts a scoped Bearer token).
//
// Token minting: we DON'T guess permission-group names (Cloudflare renames them, e.g.
// "Cloudflare Tunnel" -> "Cloudflare One Connector: cloudflared"). Instead we read every
// permission group's own `scopes` and grant ALL account-scoped groups on this account +
// ALL zone-scoped groups on this zone. Since the caller already holds the global key
// (full access), this is no broader in practice, but it guarantees tunnel + DNS + access
// perms and is immune to renames. Earlier name-matching produced an EMPTY account policy,
// so tunnel creation returned 403 code 10000 (auth error) and no DNS was ever created.
//
// Writes .cf-resolved.json = { apiToken, accountId, zoneId, tunnelName }. Zero deps, Node 18+.
import { readFileSync, writeFileSync } from 'node:fs';

const cfg = JSON.parse(readFileSync(process.env.CONFIG_FILE || 'config.json', 'utf8'));
const cf = cfg.cloudflare || {};
const API = 'https://api.cloudflare.com/client/v4';

function authHeaders() {
  if (cf.apiToken) return { Authorization: `Bearer ${cf.apiToken}` };
  if (cf.email && cf.globalApiKey) return { 'X-Auth-Email': cf.email, 'X-Auth-Key': cf.globalApiKey };
  throw new Error('Cloudflare auth missing: provide cloudflare.apiToken OR cloudflare.email + cloudflare.globalApiKey');
}
const H = { 'Content-Type': 'application/json', ...authHeaders() };

async function cfReq(method, path, body, headers) {
  const r = await fetch(API + path, {
    method,
    headers: headers || H,
    body: body ? JSON.stringify(body) : undefined,
  });
  const j = await r.json().catch(() => ({}));
  if (!r.ok || j.success === false) {
    const msg = (j.errors && j.errors[0] && j.errors[0].message) || r.statusText;
    throw new Error(`Cloudflare ${method} ${path} failed: ${msg}`);
  }
  return j.result;
}

const domain = String(cf.domain || '').trim();

// --- Account ID ---
let accountId = cf.accountId;
if (!accountId) {
  const accts = await cfReq('GET', '/accounts?per_page=50');
  if (!accts || !accts.length) throw new Error('No Cloudflare account visible to these credentials');
  if (accts.length > 1) {
    const opts = accts.map((a) => `${a.name}=${a.id}`).join(', ');
    throw new Error(`Multiple accounts found; set cloudflare.accountId. Options: ${opts}`);
  }
  accountId = accts[0].id;
}

// --- Zone ID (zone that covers the domain; handles subdomains) ---
let zoneId = cf.zoneId;
if (!zoneId) {
  if (!domain) throw new Error('Set cloudflare.domain (or cloudflare.zoneId) so the zone can be resolved');
  const zones = await cfReq('GET', '/zones?per_page=50');
  const match = zones
    .filter((z) => domain === z.name || domain.endsWith('.' + z.name))
    .sort((a, b) => b.name.length - a.name.length)[0];
  if (!match) throw new Error(`No Cloudflare zone covers "${domain}". Add the domain to Cloudflare first, or set cloudflare.zoneId.`);
  zoneId = match.id;
}

// --- API token for DockFlare ---
let apiToken = cf.apiToken;
let tokenSource = 'provided';
if (!apiToken) {
  tokenSource = 'minted';
  const groups = await cfReq('GET', '/user/tokens/permission_groups?per_page=200');
  const ACCOUNT_SCOPE = 'com.cloudflare.api.account';
  const ZONE_SCOPE = 'com.cloudflare.api.account.zone';

  // Partition by each group's declared scope. A zone group put under an account
  // resource (or vice-versa) is rejected by Cloudflare, so we must key off scopes.
  const scopesOf = (g) => (Array.isArray(g.scopes) ? g.scopes : []);
  const isZone = (g) => scopesOf(g).includes(ZONE_SCOPE);
  const isAccount = (g) => scopesOf(g).includes(ACCOUNT_SCOPE) && !isZone(g);

  const accountGroups = groups.filter(isAccount).map((g) => ({ id: g.id }));
  const zoneGroups = groups.filter(isZone).map((g) => ({ id: g.id }));

  console.log(`Permission groups resolved: account=${accountGroups.length} zone=${zoneGroups.length}`);
  if (!accountGroups.length)
    throw new Error('No account-scoped permission groups resolved; cannot mint a working token. Provide cloudflare.apiToken instead.');

  const policies = [
    { effect: 'allow', resources: { [`${ACCOUNT_SCOPE}.${accountId}`]: '*' }, permission_groups: accountGroups },
  ];
  if (zoneGroups.length)
    policies.push({ effect: 'allow', resources: { [`${ACCOUNT_SCOPE}.zone.${zoneId}`]: '*' }, permission_groups: zoneGroups });

  const tok = await cfReq('POST', '/user/tokens', {
    name: `dockflare-omniroute ${new Date().toISOString().slice(0, 10)}`,
    policies,
  });
  apiToken = tok && tok.value;
  if (!apiToken) throw new Error('Token mint returned no value. Provide cloudflare.apiToken instead.');

  // Verify the fresh token can actually do the account-scoped op that matters
  // (list tunnels). Fail loud here instead of silently 403-ing inside DockFlare.
  const bearer = { 'Content-Type': 'application/json', Authorization: `Bearer ${apiToken}` };
  try {
    await cfReq('GET', `/accounts/${accountId}/cfd_tunnel?is_deleted=false&per_page=1`, undefined, bearer);
    console.log('Token verification OK: account-scoped Cloudflare Tunnel access confirmed.');
  } catch (e) {
    throw new Error(`Minted token cannot access Cloudflare Tunnel API (${e.message}). ` +
      `The global key may lack tunnel rights, or Zero Trust is not initialized. Provide cloudflare.apiToken instead.`);
  }
}

const resolved = { apiToken, accountId, zoneId, tunnelName: cf.tunnelName || 'dockflare-omniroute' };
writeFileSync('.cf-resolved.json', JSON.stringify(resolved));
console.log(`Cloudflare resolved: account=${accountId} zone=${zoneId} token=${tokenSource}`);
