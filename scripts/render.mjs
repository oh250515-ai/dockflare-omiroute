#!/usr/bin/env node
// Renders .env + docker-compose.omniroute.yml + .deploy-plan from config.json.
// Two access modes:
//   public    (default) -> exposed on the internet via Cloudflare Tunnel (DockFlare).
//   tailscale            -> reachable only inside your tailnet (private), no public DNS.
// Zero deps, Node 18+.
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { randomBytes } from 'node:crypto';

const cfg = JSON.parse(readFileSync(process.env.CONFIG_FILE || 'config.json', 'utf8'));
const omni = cfg.omniroute || {};
const access = cfg.access || {};
const mode = String(access.mode || 'public').toLowerCase();
const flavor = String(omni.flavor || 'base').toLowerCase();
const versions = Array.isArray(omni.versions) && omni.versions.length ? omni.versions : ['latest'];

const slug = (v) => (v === 'latest' ? 'latest' : 'v' + String(v).replace(/[^a-zA-Z0-9]+/g, '-').replace(/^-+|-+$/g, ''));
const imageTag = (v) => (flavor === 'web' ? `${v}-web` : `${v}`);

// --- OmniRoute required secrets --------------------------------------------
// OmniRoute signs its dashboard session cookies with JWT_SECRET and encrypts
// stored API keys with API_KEY_SECRET. If JWT_SECRET is absent the app runs with
// an insecure/unstable default, so a fresh session cookie can't be re-verified on
// the next request -> you log in, then every click bounces back to /login.
// Behind the HTTPS Cloudflare tunnel we ALSO need AUTH_COOKIE_SECURE=true so the
// cookie is accepted. We generate the secrets once and PERSIST them to
// .omniroute-secrets.json so they stay stable across redeploys (on a persistent
// host); regenerating them every deploy would silently log everyone out.
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

// Base env applied to every OmniRoute container. User-supplied omniroute.env wins.
const baseEnv = {
  PORT: '20128',
  JWT_SECRET: secrets.JWT_SECRET,
  API_KEY_SECRET: secrets.API_KEY_SECRET,
  AUTH_COOKIE_SECURE: 'true', // served over HTTPS via the tunnel
};
if (omni.initialPassword) baseEnv.INITIAL_PASSWORD = String(omni.initialPassword);
const userEnv = omni.env || {};

// Build the merged env lines for a given public base URL (host-specific).
function envLinesFor(publicUrl) {
  const merged = { ...baseEnv };
  if (publicUrl) merged.NEXT_PUBLIC_BASE_URL = publicUrl;
  for (const [k, v] of Object.entries(userEnv)) {
    if (v !== '' && v != null) merged[k] = v; // user override wins
  }
  return Object.entries(merged).map(([k, v]) => `      - ${k}=${v}`).join('\n') + '\n';
}

const health =
  `    healthcheck:\n` +
  `      test: ["CMD", "node", "healthcheck.mjs"]\n` +
  `      interval: 30s\n      timeout: 5s\n      retries: 3\n      start_period: 20s\n`;

let envLines = [];
let servicesYaml = '';
const volumes = new Set();
let composeFiles = [];
const urls = [];

if (mode === 'tailscale') {
  const ts = access.tailscale || {};
  if (!ts.authKey) throw new Error('access.tailscale.authKey is required for tailscale mode');
  envLines.push(`TS_AUTHKEY=${ts.authKey}`);
  const tailnet = ts.tailnet || '<your-tailnet>.ts.net';
  for (const v of versions) {
    const s = slug(v);
    const name = `omniroute-${s}`;
    const tsName = `ts-${s}`;
    const publicUrl = `http://${s}.${tailnet}:20128`;
    servicesYaml +=
      `\n  ${tsName}:\n` +
      `    image: tailscale/tailscale:latest\n` +
      `    container_name: ${tsName}\n` +
      `    hostname: ${s}\n` +
      `    environment:\n` +
      `      - TS_AUTHKEY=\${TS_AUTHKEY}\n` +
      `      - TS_HOSTNAME=${s}\n` +
      `      - TS_STATE_DIR=/var/lib/tailscale\n` +
      `    volumes:\n      - ${tsName}-state:/var/lib/tailscale\n` +
      `    devices:\n      - /dev/net/tun\n` +
      `    cap_add:\n      - NET_ADMIN\n` +
      `    restart: unless-stopped\n` +
      `  ${name}:\n` +
      `    image: diegosouzapw/omniroute:${imageTag(v)}\n` +
      `    container_name: ${name}\n` +
      `    depends_on:\n      - ${tsName}\n` +
      `    network_mode: service:${tsName}\n` +
      `    restart: unless-stopped\n    stop_grace_period: 40s\n` +
      `    volumes:\n      - ${name}-data:/app/data\n` +
      `    environment:\n` +
      envLinesFor(publicUrl) +
      health;
    volumes.add(`${tsName}-state`);
    volumes.add(`${name}-data`);
    urls.push(`${publicUrl}  (tailnet-only)  ->  omniroute:${imageTag(v)}`);
  }
  composeFiles = ['docker-compose.omniroute.yml'];
} else {
  if (!existsSync('.cf-resolved.json'))
    throw new Error('.cf-resolved.json missing; run scripts/cf-bootstrap.mjs before render in public mode');
  const cfr = JSON.parse(readFileSync('.cf-resolved.json', 'utf8'));
  const base = String((cfg.cloudflare || {}).domain || '').trim();
  if (!base) throw new Error('cloudflare.domain is required in public mode');
  envLines.push(
    `CF_API_TOKEN=${cfr.apiToken}`,
    `CF_ACCOUNT_ID=${cfr.accountId}`,
    `CF_ZONE_ID=${cfr.zoneId}`,
    `TUNNEL_NAME=${cfr.tunnelName}`,
    `CLOUDFLARED_NETWORK_NAME=cloudflare-net`,
    `SCAN_ALL_NETWORKS=true`,
  );
  for (const v of versions) {
    const s = slug(v);
    const name = `omniroute-${s}`;
    const host = `${s}.${base}`;
    servicesYaml +=
      `\n  ${name}:\n` +
      `    image: diegosouzapw/omniroute:${imageTag(v)}\n` +
      `    container_name: ${name}\n` +
      `    restart: unless-stopped\n    stop_grace_period: 40s\n` +
      `    volumes:\n      - ${name}-data:/app/data\n` +
      `    environment:\n` +
      envLinesFor(`https://${host}`) +
      `    labels:\n` +
      `      - dockflare.enable=true\n` +
      `      - dockflare.hostname=${host}\n` +
      `      - dockflare.service=http://${name}:20128\n` +
      `    networks:\n      - cloudflare-net\n` +
      health;
    volumes.add(`${name}-data`);
    urls.push(`https://${host}  ->  omniroute:${imageTag(v)}`);
  }
  composeFiles = ['docker-compose.dockflare.yml', 'docker-compose.omniroute.yml'];
}

writeFileSync('.env', envLines.join('\n') + '\n');

let compose =
  `# AUTO-GENERATED by scripts/render.mjs (mode=${mode}) — do not edit by hand.\n` +
  `services:${servicesYaml}\n` +
  `volumes:\n` + [...volumes].map((v) => `  ${v}:`).join('\n') + '\n';
if (mode !== 'tailscale') {
  compose += `\nnetworks:\n  cloudflare-net:\n    name: cloudflare-net\n    external: true\n`;
}
writeFileSync('docker-compose.omniroute.yml', compose);

writeFileSync('.deploy-plan', `MODE=${mode}\nCOMPOSE_FILES="${composeFiles.map((f) => `-f ${f}`).join(' ')}"\n`);

console.log(`Rendered (mode=${mode}):`);
urls.forEach((u) => console.log('  ' + u));
