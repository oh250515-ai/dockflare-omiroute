#!/usr/bin/env node
// Prints every Docker image the deploy pulls, one per line, so CI can cache them.
// Derived from config.json (versions + flavor + access mode). Zero deps, Node 18+.
import { readFileSync } from 'node:fs';

const cfg = JSON.parse(readFileSync(process.env.CONFIG_FILE || 'config.json', 'utf8'));
const omni = cfg.omniroute || {};
const mode = String((cfg.access || {}).mode || 'public').toLowerCase();
const flavor = String(omni.flavor || 'base').toLowerCase();
const versions = Array.isArray(omni.versions) && omni.versions.length ? omni.versions : ['latest'];
const tag = (v) => (flavor === 'web' ? `${v}-web` : `${v}`);

const images = new Set();
for (const v of versions) images.add(`diegosouzapw/omniroute:${tag(v)}`);

if (mode === 'tailscale') {
  images.add('tailscale/tailscale:latest');
} else {
  // DockFlare control-plane stack (public mode).
  images.add('alplat/dockflare:stable');
  images.add('redis:7-alpine');
  images.add('tecnativa/docker-socket-proxy:v0.4.1');
  images.add('alpine:3.20');
  images.add('cloudflare/cloudflared:latest'); // pulled by DockFlare to run the tunnel
}

process.stdout.write([...images].join('\n') + '\n');
