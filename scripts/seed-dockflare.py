#!/usr/bin/env python3
# Headless DockFlare config seeder.
#
# DockFlare only becomes operational when /app/data/{dockflare.key,dockflare_config.dat}
# exist. Setting CF_* env vars ONLY pre-fills the web setup wizard — the container
# otherwise sits in "Pre-Flight Mode" forever and never creates the tunnel/DNS.
#
# This writes those two files directly, in the exact format step4_finalize produces,
# so DockFlare boots straight into Operational Mode with zero clicks.
#
# MUST be run INSIDE the alplat/dockflare image so cryptography (Fernet) and
# werkzeug (password hash) match DockFlare's own versions byte-for-byte.
#
# Reads /work/.df-seed.json, writes into /app/data. Idempotent: if the config
# already exists it leaves it untouched.
import json
import os
import sys
import secrets

from cryptography.fernet import Fernet
from werkzeug.security import generate_password_hash

DATA = os.environ.get('DF_DATA_DIR', '/app/data')
key_file = os.path.join(DATA, 'dockflare.key')
cfg_file = os.path.join(DATA, 'dockflare_config.dat')
os.makedirs(DATA, exist_ok=True)

if os.path.exists(key_file) and os.path.exists(cfg_file):
    print('DockFlare already configured (dockflare_config.dat present) — leaving as-is.')
    sys.exit(0)

with open('/work/.df-seed.json', 'r', encoding='utf-8') as fh:
    seed = json.load(fh)

if not seed.get('cf_api_token') or not seed.get('cf_account_id'):
    print('Seed missing cf_api_token/cf_account_id — cannot seed DockFlare.', file=sys.stderr)
    sys.exit(1)

payload = {
    'cf_api_token': seed['cf_api_token'],
    'cf_account_id': seed['cf_account_id'],
    'tunnel_name': seed.get('tunnel_name', 'dockflare-omniroute'),
    'cf_zone_id': seed.get('cf_zone_id') or None,
    'tunnel_dns_scan_zone_names': '',
    'grace_period_seconds': int(seed.get('grace_period_seconds', 28800)),
    'preserve_unmanaged_cf_ingress_fields': False,
    'username': seed.get('username', 'admin'),
    'password': generate_password_hash(seed['password']),
    'master_api_key': seed.get('master_api_key') or secrets.token_urlsafe(40),
}

key = Fernet.generate_key()
with open(key_file, 'wb') as fh:
    fh.write(key)
with open(cfg_file, 'wb') as fh:
    fh.write(Fernet(key).encrypt(json.dumps(payload).encode('utf-8')))

print('DockFlare seeded: user=%s tunnel=%s zone=%s (Operational Mode on next boot).'
      % (payload['username'], payload['tunnel_name'], payload['cf_zone_id']))
