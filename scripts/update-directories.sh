#!/usr/bin/env bash
# Refreshes the bundled snapshots of the audit directories:
#
#   scripts/update-directories.sh
#
# Verrou makes no network request to a third party: the list of the sites
# that offer two-factor authentication (2fa.directory) and the directory of
# the sites that accept passkeys (passkeys.2fa.directory) are embedded in
# the Rust core (include_bytes!, read by verrou-core's watchtower and
# passkey_upgrade) and frozen at build time. This script downloads fresh
# copies into crates/verrou-core/src/data/; commit the result to ship them
# with the next build. Run it by hand whenever a refresh is wanted.
#
# Both lists are open data of the 2fa.directory project (CC BY-SA 4.0,
# https://2fa.directory/api) — keep this attribution with the snapshots.
set -euo pipefail

cd "$(dirname "$0")/.."
DEST="crates/verrou-core/src/data"

mkdir -p "$DEST"
curl -fsSL -o "$DEST/tfa.json" https://api.2fa.directory/v3/tfa.json
curl -fsSL -o "$DEST/supported.json" https://passkeys-api.2fa.directory/v1/supported.json

# A readable snapshot is at least a non-trivial JSON document.
python3 - "$DEST/tfa.json" "$DEST/supported.json" <<'EOF'
import json, sys
for path in sys.argv[1:]:
    with open(path) as handle:
        data = json.load(handle)
    entries = len(data)
    assert entries > 100, f"{path}: only {entries} entries?"
    print(f"{path}: {entries} entries")
EOF

echo "snapshots refreshed; commit them to ship a new one"
