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
//   - apiToken  : minted via POST /user/tokens with exactly the perms DockFlare needs
//                 (DockFlare only accepts a scoped Bearer token, not a global key).
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

async function cfReq(method, path, body) {
  const r = await fetch(API + path, { method, headers: H, body: body ? JSON.stringify(body) : undefined });
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
  const groups = await cfReq('GET', '/user/tokens/permission_groups');
  const byName = (frag) => {
    const g = groups.find((x) => x.name.toLowerCase().includes(frag));
    return g ? { id: g.id } : null;
  };
  const uniq = (arr) => { const s = new Set(); return arr.filter((x) => x && !s.has(x.id) && s.add(x.id)); };
  // Names drift over time (CF renames perms), so match on stable fragments.
  const accountGroups = uniq([
    byName('cloudflare tunnel'), byName('cloudflared'),
    byName('account settings'),
    byName('access: apps'), byName('access: policies'), byName('access: organizations'),
    byName('service tokens'),
  ]);
  const zoneGroups = uniq([byName('dns write'), byName('dns'), byName('zone read')]);
  const policies = [];
  if (accountGroups.length)
    policies.push({ effect: 'allow', resources: { [`com.cloudflare.api.account.${accountId}`]: '*' }, permission_groups: accountGroups });
  if (zoneGroups.length)
    policies.push({ effect: 'allow', resources: { [`com.cloudflare.api.account.zone.${zoneId}`]: '*' }, permission_groups: zoneGroups });
  if (!policies.length)
    throw new Error('Could not resolve Cloudflare permission groups to mint a token. Provide cloudflare.apiToken instead.');
  const tok = await cfReq('POST', '/user/tokens', {
    name: `dockflare-omniroute ${new Date().toISOString().slice(0, 10)}`,
    policies,
  });
  apiToken = tok && tok.value;
  if (!apiToken) throw new Error('Token mint returned no value. Provide cloudflare.apiToken instead.');
}

const resolved = { apiToken, accountId, zoneId, tunnelName: cf.tunnelName || 'dockflare-omniroute' };
writeFileSync('.cf-resolved.json', JSON.stringify(resolved));
console.log(`Cloudflare resolved: account=${accountId} zone=${zoneId} token=${tokenSource}`);
