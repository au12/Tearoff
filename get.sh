#!/bin/bash
# One-line installer:
#   curl -fsSL https://raw.githubusercontent.com/au12/Tearoff/main/get.sh | bash
set -euo pipefail
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
echo "→ Downloading the latest Tearoff build…"
curl -fsSL -o "$TMP/Tearoff.zip" "https://github.com/au12/Tearoff/releases/download/latest/Tearoff.zip"
ditto -x -k "$TMP/Tearoff.zip" "$TMP"
bash "$TMP/Tearoff/install.sh"
