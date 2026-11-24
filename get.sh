#!/bin/bash
# One-line installer: downloads the latest Tearoff.pkg and opens it in Installer.
#   curl -fsSL https://raw.githubusercontent.com/au12/Tearoff/main/get.sh | bash
set -euo pipefail
DEST="$HOME/Downloads/Tearoff.pkg"
echo "→ Downloading the latest Tearoff installer to ~/Downloads…"
curl -fsSL -o "$DEST" "https://github.com/au12/Tearoff/releases/download/latest/Tearoff.pkg"
echo "→ Opening the installer"
open "$DEST"
