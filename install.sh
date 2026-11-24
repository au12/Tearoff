#!/bin/bash
# Installs Tearoff.app, the `tearoff` command and the Print dialog's
# "Print Label with Tearoff" menu item. Works from a git checkout (builds from source)
# or from a release zip that already contains Tearoff.app next to this script.
set -euo pipefail
cd "$(dirname "$0")"

if [[ -d "Tearoff.app" && ! -f "Package.swift" ]]; then
  SRC="Tearoff.app"                       # prebuilt (release zip)
else
  ./build.sh
  SRC="build/Tearoff.app"
fi

DEST_DIR="/Applications"
[[ -w "$DEST_DIR" ]] || DEST_DIR="$HOME/Applications"
mkdir -p "$DEST_DIR"
DEST="$DEST_DIR/Tearoff.app"

osascript -e 'tell application "Tearoff" to quit' >/dev/null 2>&1 || true
pkill -x Tearoff 2>/dev/null || true
rm -rf "$DEST"
ditto "$SRC" "$DEST"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST" >/dev/null 2>&1 || true

mkdir -p "$HOME/.local/bin"
ln -sf "$DEST/Contents/Helpers/tearoff" "$HOME/.local/bin/tearoff"

# PDF ▾ menu item in every Print dialog
SERVICE="$HOME/Library/PDF Services/Print Label with Tearoff"
mkdir -p "$(dirname "$SERVICE")"
cat > "$SERVICE" <<'EOS'
#!/bin/sh
# Print dialog PDF service: $1 title, $2 options, $3 PDF. Copy it (the print system deletes
# its temp file when we return) and hand it to Tearoff, which prints it right away.
dest="${TMPDIR:-/tmp}/tearoff-print-$$.pdf"
cp "$3" "$dest" && open -b com.au12.tearoff "$dest"
EOS
chmod 755 "$SERVICE"

# If the system driver is installed, refresh its filter so it matches this build.
if [[ -d /Library/Printers/Tearoff/Filters ]]; then
  echo "→ Updating the Tearoff printer driver (your password)…"
  sudo cp -f "$DEST/Contents/Helpers/tearoff-filter" /Library/Printers/Tearoff/Filters/tearoff-filter
  sudo chown root:wheel /Library/Printers/Tearoff/Filters/tearoff-filter
  sudo chmod 755 /Library/Printers/Tearoff/Filters/tearoff-filter
fi

cat <<EOF

✓ Installed: $DEST

Next: Tearoff opens now. Pick your Zebra under Printer, then (optional) install the
system printer under Print Driver so ⌘P in any app prints crisp labels.

Command line:  tearoff print label.pdf --printer 10.0.10.50
EOF
open "$DEST"
