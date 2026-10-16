#!/bin/bash
# Prüft, dass jeder Schlüssel in App/Localizable.xcstrings und App/InfoPlist.xcstrings
# auf Deutsch UND Portugiesisch (pt-PT) übersetzt und nicht leer ist, und dass die
# Platzhalter (%@, %lld) in beiden Sprachen gleich sind.
# Die Oberfläche steht vorerst auf pt-PT; die Entscheidung PT/BR ist offen (PLAN.md §7).
set -euo pipefail
cd "$(dirname "$0")/.."

/usr/bin/env python3 -I - App/Localizable.xcstrings App/InfoPlist.xcstrings <<'PY'
import json, re, sys

LANGS = ["de", "pt-PT"]
bad = 0

def texts(entry, lang):
    loc = entry.get("localizations", {}).get(lang)
    if not loc:
        return []
    if "stringUnit" in loc:
        return [loc["stringUnit"].get("value", "")]
    plural = loc.get("variations", {}).get("plural", {})
    return [v.get("stringUnit", {}).get("value", "") for v in plural.values()]

for path in sys.argv[1:]:
    cat = json.load(open(path))
    for key, entry in cat["strings"].items():
        per = {l: texts(entry, l) for l in LANGS}
        for l in LANGS:
            if not per[l] or any(not t.strip() for t in per[l]):
                print(f"{path}: '{key}' fehlt oder ist leer auf {l}")
                bad += 1
        ph = {l: {m for t in per[l] for m in re.findall(r"%(?:lld|@|d)", t)} for l in LANGS}
        if ph["de"] != ph["pt-PT"]:
            print(f"{path}: Platzhalter von '{key}' unterscheiden sich: {ph}")
            bad += 1
    print(f"{path}: {len(cat['strings'])} Schlüssel geprüft")

sys.exit(1 if bad else 0)
PY
echo "Übersetzungen vollständig."
