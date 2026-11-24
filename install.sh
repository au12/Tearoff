#!/bin/bash
# From a source checkout: builds Tearoff.app, packs dist/Tearoff.pkg and opens the installer.
# (Release builds: just download Tearoff.pkg from GitHub Releases and open it.)
set -euo pipefail
cd "$(dirname "$0")"
if [[ -d "Tearoff.app" && ! -f "Package.swift" ]]; then
  echo "This folder has a prebuilt Tearoff.app — use Tearoff.pkg from the release instead." >&2
  exit 1
fi
./build.sh
scripts/make_pkg.sh
open dist/Tearoff.pkg
