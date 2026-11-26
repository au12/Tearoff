#!/bin/bash
# End-to-end through the real macOS printing system: a CUPS queue using the Tearoff driver points
# at a fake Zebra on 127.0.0.1:9100; fixture PDFs are printed with `lp` (exactly what ⌘P does) and
# the ZPL that arrives is decoded and scanned: right number of labels (extra codes included), every
# barcode reading the way expected.json says.
#
#   bash tests/cups_e2e.sh build/Tearoff.app [OUTDIR]               # installs the driver itself (sudo)
#   bash tests/cups_e2e.sh /Applications/Tearoff.app OUTDIR --installed   # driver already installed by the .pkg
set -uo pipefail
APP="$1"
OUT="${2:-cups-out}"
MODE="${3:-}"
CLI="$APP/Contents/Helpers/tearoff"
ROOT=/Library/Printers/Tearoff
rm -rf "$OUT"; mkdir -p "$OUT"

python3 tests/fake_zebra.py "$OUT" > "$OUT/fake_zebra.log" 2>&1 &
FAKE=$!
trap 'kill $FAKE 2>/dev/null' EXIT
sleep 1

if [[ "$MODE" != "--installed" ]]; then
  echo "→ Installing driver"
  "$CLI" ppd > "$OUT/Tearoff.ppd"
  sudo mkdir -p "$ROOT/Filters"
  sudo cp -f "$APP/Contents/Helpers/tearoff-filter" "$ROOT/Filters/tearoff-filter"
  sudo cp -f "$OUT/Tearoff.ppd" "$ROOT/Tearoff.ppd"
  sudo chown -R root:wheel "$ROOT"
  sudo chmod 755 "$ROOT" "$ROOT/Filters" "$ROOT/Filters/tearoff-filter"
  sudo chmod 644 "$ROOT/Tearoff.ppd"
fi
(cupstestppd -W translations "$ROOT/Tearoff.ppd" || true) > "$OUT/cupstestppd.txt" 2>&1
cat "$OUT/cupstestppd.txt"
sudo cupsctl --debug-logging 2>/dev/null || true
sudo lpadmin -p TearoffTest -E -v socket://127.0.0.1:9100 -P "$ROOT/Tearoff.ppd" -o printer-is-shared=false
sudo cupsenable TearoffTest; sudo cupsaccept TearoffTest

FIXTURES=(01_image_letter_dashed.pdf 03_vector_letter_unframed_rotated.pdf 04_two_up.pdf 08_browser_4x6_shrunk.pdf
          14_qr_return_no_label.pdf 17_low_res_return.pdf)
for f in "${FIXTURES[@]}"; do
  echo "→ lp $f"
  lp -d TearoffTest -t "$f" "tests/fixtures/$f"
  for _ in $(seq 1 90); do
    [[ -z "$(lpstat -o TearoffTest 2>/dev/null)" ]] && break
    sleep 1
  done
  sleep 1
done
sleep 2
sudo cat /var/log/cups/error_log 2>/dev/null | grep -iE "tearoff|E \[" | tail -n 120 > "$OUT/cups_error_log.txt" || true
grep -E "Tearoff (timing|perf log)|Tearoff:" "$OUT/cups_error_log.txt" | tail -n 12

echo "→ Where the sandboxed filter could write its timing log:"
for f in /Library/Logs/Tearoff/filter.jsonl /Users/Shared/Tearoff/filter.jsonl /private/tmp/tearoff-filter.jsonl; do
  if [[ -s "$f" ]]; then echo "  ✓ $f ($(wc -l < "$f" | tr -d ' ') lines)"; cp "$f" "$OUT/$(echo "$f" | tr '/' '_')"; else echo "  ✗ $f"; fi
done

python3 - "$CLI" "$OUT" "${FIXTURES[@]}" <<'PY'
import json, os, subprocess, sys
import zxingcpp
from PIL import Image
cli, out, fixtures = sys.argv[1], sys.argv[2], sys.argv[3:]
expected = json.load(open("tests/fixtures/expected.json"))
fail = 0
for i, name in enumerate(fixtures, start=1):
    job = os.path.join(out, f"job-{i}.zpl")
    if not os.path.exists(job):
        print(f"FAIL {name}: no job arrived at the printer"); fail += 1; continue
    zpl = open(job, "rb").read().decode("ascii", "replace")
    r = subprocess.run([cli, "zpl2png", job, os.path.join(out, f"job-{i}")], capture_output=True, text=True)
    pngs = [l for l in r.stdout.split("\n") if l.endswith(".png")]
    exp = expected[name]["labels"]
    problems = []
    if len(pngs) != len(exp):
        problems.append(f"{len(pngs)} label(s) in the ZPL, expected {len(exp)}")
    if "^PW812^LL1218" not in zpl:
        problems.append("missing ^PW812^LL1218")
    for k, (png, e) in enumerate(zip(pngs, exp)):
        found = {b.text: b.orientation for b in zxingcpp.read_barcodes(Image.open(png).convert("L"))}
        want = e.get("orientation", 0)
        for code in e["barcodes"]:
            if found.get(code) != want:
                problems.append(f"#{k+1} {code}: {f'reads at {found[code]} deg' if code in found else 'does not scan'}")
    if problems:
        fail += 1; print(f"FAIL {name}: " + "; ".join(problems))
    else:
        print(f"PASS {name}: {len(pngs)} label(s), {len(zpl)//1024} KB of ZPL")
sys.exit(1 if fail else 0)
PY
STATUS=$?

echo "→ Slip text retyped inside the sandboxed filter"
python3 - <<'PY' || STATUS=1
import glob, json, sys
counts = {}
for f in glob.glob("/Library/Logs/Tearoff/filter.jsonl") + glob.glob("/Users/Shared/Tearoff/filter.jsonl") + glob.glob("/private/tmp/tearoff-filter.jsonl"):
    for line in open(f):
        try:
            c = json.loads(line).get("counters", {})
        except ValueError:
            continue
        for k, v in c.items():
            if k.startswith("hri_"):
                counts[k] = counts.get(k, 0) + v
print("  ", counts or "no counters")
retyped = counts.get("hri_ocr", 0) + counts.get("hri_layout", 0)
if retyped < 2:
    print("FAIL: expected the two slips' text to be retyped"); sys.exit(1)
print(f"PASS: {retyped} slip line(s) retyped ({counts.get('hri_ocr', 0)} confirmed by OCR)")
PY

echo "→ Status and identity against the fake printer"
"$CLI" status --printer 127.0.0.1 || STATUS=1

echo "→ Raw ZPL through a macOS queue (how the app feeds USB printers)"
N=$(( ${#FIXTURES[@]} + 1 ))
"$CLI" test-label --queue TearoffTest || STATUS=1
for _ in $(seq 1 30); do [[ -s "$OUT/job-$N.zpl" ]] && break; sleep 1; done
sleep 1
if grep -q '\^XA' "$OUT/job-$N.zpl" 2>/dev/null && ! grep -q '\^GFA' "$OUT/job-$N.zpl"; then
  echo "PASS raw queue: the test label arrived as sent ($(wc -c < "$OUT/job-$N.zpl" | tr -d ' ') bytes)"
else
  echo "FAIL raw queue: job-$N.zpl missing or filtered"; ls "$OUT"; STATUS=1
fi

echo "→ The queue's Shift Label Down option reaches the printer"
grep -q '\^LT\|\^LS' "$OUT/job-1.zpl" && { echo "FAIL shift: job 1 overrode the printer's own label position"; STATUS=1; }
N=$(( N + 1 ))
lp -d TearoffTest -o TearoffShiftDown=40 -o TearoffShiftRight=n8 "tests/fixtures/06_page_4x6_vector.pdf" >/dev/null || STATUS=1
for _ in $(seq 1 30); do [[ -s "$OUT/job-$N.zpl" ]] && break; sleep 1; done
sleep 1
if grep -q '\^FO0,40\^GFA' "$OUT/job-$N.zpl" 2>/dev/null && ! grep -q '\^LT\|\^LS' "$OUT/job-$N.zpl"; then
  echo "PASS shift: the picture moved 40 dots down (^FO0,40), printer position untouched"
else
  echo "FAIL shift: expected ^FO0,40 and no ^LT/^LS in job-$N.zpl"; STATUS=1
fi

echo "→ A USB printer prints through the Mac printer for its device"
USB_URI='usb://Zebra%20Technologies/ZTC%20GX420d?serial=TEAROFFCI01'
# created stopped (no -E) but accepting: nothing is plugged in, so the job waits in the queue
sudo lpadmin -p TearoffUSBTest -v "$USB_URI" -P "$ROOT/Tearoff.ppd" -o printer-is-shared=false
sudo cupsaccept TearoffUSBTest
if "$CLI" test-label --printer "$USB_URI"; then
  if lpstat -o TearoffUSBTest 2>/dev/null | grep -q TearoffUSBTest; then
    echo "PASS usb: the job went to TearoffUSBTest"
  else
    echo "FAIL usb: no job on TearoffUSBTest"; STATUS=1
  fi
else
  echo "FAIL usb: couldn't send to $USB_URI"; STATUS=1
fi
"$CLI" status --printer "$USB_URI" | tee "$OUT/usb-status.txt" || true
grep -q "TearoffUSBTest" "$OUT/usb-status.txt" || { echo "FAIL usb status: didn't name the queue"; STATUS=1; }
if "$CLI" test-label --printer 'usb://Zebra%20Technologies/ZTC%20ZD421?serial=NOTPLUGGEDIN' 2> "$OUT/usb-missing.txt"; then
  echo "FAIL usb: a USB printer with no Mac printer should be refused"; STATUS=1
else
  echo "PASS usb: refused with: $(cat "$OUT/usb-missing.txt")"
fi
"$CLI" discover --usb || true
cancel -a TearoffUSBTest 2>/dev/null || sudo cancel -a TearoffUSBTest 2>/dev/null || true
sudo lpadmin -x TearoffUSBTest || true

sudo lpadmin -x TearoffTest || true
exit $STATUS
