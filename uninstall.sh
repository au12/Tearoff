#!/bin/bash
# Removes Tearoff, its command, its Print dialog item, its printer driver and the printers that
# use it (asks for your password).
set -uo pipefail

osascript -e 'tell application "Tearoff" to quit' >/dev/null 2>&1 || true
pkill -x Tearoff 2>/dev/null || true

for q in $(lpstat -v 2>/dev/null | sed -n 's/^device for \([^:]*\):.*/\1/p'); do
  if grep -q "Tearoff" "/etc/cups/ppd/$q.ppd" 2>/dev/null; then sudo lpadmin -x "$q"; fi
done
sudo rm -rf /Applications/Tearoff.app /Library/Printers/Tearoff "/Library/PDF Services/Print Label with Tearoff" \
  /usr/local/bin/tearoff /Library/Logs/Tearoff /Users/Shared/Tearoff
for id in app driver pdfservice launch; do sudo pkgutil --forget "com.au12.tearoff.$id" >/dev/null 2>&1 || true; done

rm -rf "$HOME/Applications/Tearoff.app" "$HOME/Library/Logs/Tearoff"
rm -f "$HOME/.local/bin/tearoff" "$HOME/Library/PDF Services/Print Label with Tearoff"
defaults delete com.au12.tearoff >/dev/null 2>&1 || true
echo "✓ Tearoff removed"
