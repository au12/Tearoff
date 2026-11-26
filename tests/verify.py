#!/usr/bin/env python3
"""Runs `tearoff extract --json` on every fixture and checks: label count, exact printer size,
orientation (every expected barcode reads left-to-right, or bottom-to-top for an extra code laid
on its side), the kind of each output, and that every expected code decodes from the 203 dpi output.

    python3 tests/verify.py build/Tearoff.app/Contents/Helpers/tearoff tests/fixtures out/
"""
import json
import os
import subprocess
import sys

import zxingcpp
from PIL import Image


def main():
    cli, fixtures, out = sys.argv[1:4]
    os.makedirs(out, exist_ok=True)
    expected = json.load(open(os.path.join(fixtures, "expected.json")))
    failures = 0
    for name, exp in sorted(expected.items()):
        res = subprocess.run([cli, "extract", os.path.join(fixtures, name), "--out", out, "--json"],
                             capture_output=True, text=True)
        problems = []
        try:
            labels = json.loads(res.stdout or "[]")
        except json.JSONDecodeError:
            labels = []
            problems.append("bad JSON: " + res.stdout[:200] + res.stderr[:200])
        if res.returncode != 0:
            problems.append(f"exit {res.returncode}: {res.stderr.strip()[:300]}")
        if len(labels) != len(exp["labels"]):
            problems.append(f"found {len(labels)} label(s), expected {len(exp['labels'])}")
        for i, (lab, e) in enumerate(zip(labels, exp["labels"])):
            im = Image.open(lab["png"]).convert("L")
            if im.size != (812, 1218):
                problems.append(f"#{i + 1} is {im.size}, expected 812x1218")
            if "page" in e and lab["page"] != e["page"]:
                problems.append(f"#{i + 1} from page {lab['page']}, expected {e['page']}")
            if "kind" in e and lab["kind"] != e["kind"]:
                problems.append(f"#{i + 1} is a {lab['kind']}, expected {e['kind']}")
            if e.get("hri") and not lab.get("hri"):
                problems.append(f"#{i + 1}: the barcode's text wasn't retyped")
            want = e.get("orientation", 0)
            found = {b.text: b.orientation for b in zxingcpp.read_barcodes(im)}
            for code in e["barcodes"]:
                if code not in found:
                    problems.append(f"#{i + 1} code {code} does not scan")
                elif found[code] != want:
                    problems.append(f"#{i + 1} code {code} reads at {found[code]} deg, expected {want}")
        ms = max([l.get("ms", 0) for l in labels] or [0])
        if problems:
            failures += 1
            print(f"FAIL {name}: " + "; ".join(problems))
        else:
            kinds = ",".join(l["kind"] for l in labels)
            fits = sum(l["gridFitted"] for l in labels)
            retyped = [l["hri"] for l in labels if l.get("hri")]
            note = f", text retyped ({', '.join(retyped)})" if retyped else ""
            print(f"PASS {name}: {len(labels)} label(s) [{kinds}] grid-fit {fits}{note}, {ms} ms")
    print(f"\n{len(expected) - failures}/{len(expected)} fixtures passed")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
