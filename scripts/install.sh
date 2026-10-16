#!/bin/bash
# Baut Vorleser in der Release-Konfiguration und installiert die App nach /Applications.
# Voraussetzungen: Xcode 27, `brew install xcodegen`.
#
# Signieren (PLAN.md §4.7):
#   Ohne Angabe wird ad hoc signiert ("Sign to Run Locally"). Dann fragt macOS nach jedem
#   Neubau erneut nach dem Mikrofon. Besser: das kostenlose Personal Team nutzen.
#     VORLESER_TEAM=ABCDE12345 scripts/install.sh
#   (Team-ID: Xcode > Settings > Accounts > Apple-ID > Team auswählen.)
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Vorleser"
DEST="/Applications/${APP_NAME}.app"
DERIVED="build/DerivedData"

command -v xcodegen >/dev/null || { echo "xcodegen fehlt: brew install xcodegen" >&2; exit 1; }

scripts/check-strings.sh

xcodegen generate

SIGN_ARGS=()
if [[ -n "${VORLESER_TEAM:-}" ]]; then
  SIGN_ARGS+=(DEVELOPMENT_TEAM="${VORLESER_TEAM}" CODE_SIGN_IDENTITY="Apple Development" CODE_SIGN_STYLE=Automatic)
else
  echo "Hinweis: Kein VORLESER_TEAM gesetzt, es wird ad hoc signiert (Mikrofon-Frage nach jedem Neubau)."
fi

xcodebuild -scheme "${APP_NAME}" -configuration Release -derivedDataPath "${DERIVED}" \
  ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"} build

BUILT="${DERIVED}/Build/Products/Release/${APP_NAME}.app"
[[ -d "${BUILT}" ]] || { echo "Gebaute App nicht gefunden: ${BUILT}" >&2; exit 1; }

# Läuft die App noch, würde das Ersetzen sie mitten im Betrieb austauschen.
if pgrep -x "${APP_NAME}" >/dev/null; then
  echo "Hinweis: ${APP_NAME} läuft gerade. Bitte beenden (Cmd+Q) und dann noch einmal installieren." >&2
  exit 2
fi

if [[ -d "${DEST}" ]]; then
  echo "Ersetze die alte Version in ${DEST} ..."
  rm -rf "${DEST}"
fi
cp -R "${BUILT}" "${DEST}"
echo "Fertig: ${DEST}"
