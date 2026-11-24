#!/bin/bash
# Removes Tearoff, its command, its Print dialog menu item and (with your password) its printer driver.
set -uo pipefail

osascript -e 'tell application "Tearoff" to quit' >/dev/null 2>&1 || true
pkill -x Tearoff 2>/dev/null || true
rm -rf "/Applications/Tearoff.app" "$HOME/Applications/Tearoff.app"
rm -f "$HOME/.local/bin/tearoff" "$HOME/Library/PDF Services/Print Label with Tearoff"

if [[ -d /Library/Printers/Tearoff ]]; then
  echo "→ Removing the printer driver and the printers that use it (your password)…"
  for q in $(lpstat -v 2>/dev/null | sed -n 's/^device for \([^:]*\):.*/\1/p'); do
    if grep -q "Tearoff" "/etc/cups/ppd/$q.ppd" 2>/dev/null; then sudo lpadmin -x "$q"; fi
  done
  sudo rm -rf /Library/Printers/Tearoff
fi
defaults delete com.au12.tearoff >/dev/null 2>&1 || true
echo "✓ Tearoff removed"
