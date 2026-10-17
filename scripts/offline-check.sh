#!/bin/bash
# Beweist „nach der Einrichtung keine Netzwerkzugriffe“: liest einen Satz vor, während dem Prozess
# jeder Netzwerkzugriff vom Betriebssystem verboten ist (sandbox-exec, deny network*).
# Voraussetzung: Modelle sind im ModelStore (vorleser-cli models status), Debug- oder Release-Build der CLI.
#   scripts/offline-check.sh [Ausgabe.mp3]
set -euo pipefail
cd "$(dirname "$0")/.."
CLI="${VORLESER_CLI:-Packages/VorleserCore/.build/debug/vorleser-cli}"
OUT="${1:-spike-output/phase5/offline-check.mp3}"
mkdir -p "$(dirname "$OUT")"

echo "Kontrolle: Netz muss gesperrt sein …"
if sandbox-exec -p '(version 1)(allow default)(deny network*)' /usr/bin/curl -sS -m 6 -o /dev/null https://huggingface.co 2>/dev/null; then
    echo "FEHLER: Die Sperre wirkt nicht." >&2
    exit 1
fi
echo "ok, gesperrt."

# Braucht mindestens eine eigene deutsche Stimme (vorleser-cli voices).
echo "Guten Tag, dieser Satz wird ohne Netzwerk vorgelesen." | sandbox-exec -p '(version 1)(allow default)(deny network*)' \
    "$CLI" read - --work-dir spike-output/phase5/work --lang de --fresh -o "$OUT"
echo "Bestanden: $OUT"
