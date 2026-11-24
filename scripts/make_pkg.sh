#!/bin/bash
# Builds dist/Tearoff.pkg, a standard macOS Installer package, from build/Tearoff.app:
#   TearoffApp        /Applications/Tearoff.app + /usr/local/bin/tearoff        (required)
#   TearoffDriver     /Library/Printers/Tearoff (CUPS filter + PPD)              (optional, on)
#   TearoffPDFService /Library/PDF Services/Print Label with Tearoff             (optional, on)
#   TearoffLaunch     opens Tearoff when the install finishes                    (hidden)
# Set SIGN_IDENTITY="Developer ID Installer: …" to sign it.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Tearoff.app"
[[ -d "$APP" ]] || { echo "Run ./build.sh first" >&2; exit 1; }
VERSION="${VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")}"
WORK="build/pkg"
rm -rf "$WORK"
mkdir -p "$WORK/root-app/Applications" "$WORK/root-driver/Library/Printers/Tearoff/Filters" \
         "$WORK/root-pdf/Library/PDF Services" "$WORK/packages" "$WORK/resources" dist

ditto "$APP" "$WORK/root-app/Applications/Tearoff.app"
cp "$APP/Contents/Helpers/tearoff-filter" "$WORK/root-driver/Library/Printers/Tearoff/Filters/tearoff-filter"
"$APP/Contents/Helpers/tearoff" ppd > "$WORK/root-driver/Library/Printers/Tearoff/Tearoff.ppd"
cp pkg/pdf-service.sh "$WORK/root-pdf/Library/PDF Services/Print Label with Tearoff"
chmod 755 "$WORK/root-driver/Library/Printers/Tearoff" "$WORK/root-driver/Library/Printers/Tearoff/Filters" \
          "$WORK/root-driver/Library/Printers/Tearoff/Filters/tearoff-filter" \
          "$WORK/root-pdf/Library/PDF Services/Print Label with Tearoff"
chmod 644 "$WORK/root-driver/Library/Printers/Tearoff/Tearoff.ppd"
chmod 755 pkg/scripts/*/*

# Never let Installer "relocate" the app onto some other copy with the same bundle ID.
pkgbuild --analyze --root "$WORK/root-app" "$WORK/app.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Set :0:BundleIsRelocatable false" "$WORK/app.plist"

pkgbuild --quiet --root "$WORK/root-app" --component-plist "$WORK/app.plist" --identifier com.au12.tearoff.app \
  --version "$VERSION" --install-location / --ownership recommended --scripts pkg/scripts/app "$WORK/packages/TearoffApp.pkg"
pkgbuild --quiet --root "$WORK/root-driver" --identifier com.au12.tearoff.driver --version "$VERSION" \
  --install-location / --ownership recommended --scripts pkg/scripts/driver "$WORK/packages/TearoffDriver.pkg"
pkgbuild --quiet --root "$WORK/root-pdf" --identifier com.au12.tearoff.pdfservice --version "$VERSION" \
  --install-location / --ownership recommended --scripts pkg/scripts/pdfservice "$WORK/packages/TearoffPDFService.pkg"
pkgbuild --quiet --nopayload --identifier com.au12.tearoff.launch --version "$VERSION" \
  --scripts pkg/scripts/launch "$WORK/packages/TearoffLaunch.pkg"

sed "s/__VERSION__/$VERSION/g" pkg/Distribution.xml > "$WORK/Distribution.xml"
cp pkg/resources/* "$WORK/resources/"
SIGN=()
[[ -n "${SIGN_IDENTITY:-}" ]] && SIGN=(--sign "$SIGN_IDENTITY")
productbuild --quiet --distribution "$WORK/Distribution.xml" --resources "$WORK/resources" \
  --package-path "$WORK/packages" --version "$VERSION" "${SIGN[@]+"${SIGN[@]}"}" dist/Tearoff.pkg
echo "✓ dist/Tearoff.pkg ($VERSION, $(du -h dist/Tearoff.pkg | cut -f1 | tr -d ' '))"
