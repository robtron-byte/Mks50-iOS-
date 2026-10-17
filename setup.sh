#!/bin/bash
# MKS-50 iOS – one-time setup on your Mac.
#
#   ./setup.sh                 detect team, set bundle IDs, compile check, open Xcode
#   ./setup.sh TEAMID          use this team ID instead of detecting it
#
# Writes Config/Signing.local.xcconfig (not committed) and build.log.
set -uo pipefail
cd "$(dirname "$0")"

bold() { printf "\033[1m%s\033[0m\n" "$*"; }
ok()   { printf "  \033[32m✓\033[0m %s\n" "$*"; }
warn() { printf "  \033[33m!\033[0m %s\n" "$*"; }
fail() { printf "  \033[31m✗\033[0m %s\n" "$*"; exit 1; }

bold "1/4  Xcode prüfen"
command -v xcodebuild >/dev/null || fail "xcodebuild nicht gefunden. Bitte Xcode aus dem App Store installieren."
if xcode-select -p | grep -q CommandLineTools; then
    warn "Es sind nur die Command Line Tools aktiv. Schalte auf Xcode um (Admin-Passwort):"
    sudo xcode-select -s /Applications/Xcode.app/Contents/Developer || fail "Umschalten fehlgeschlagen"
fi
XCODE_VERSION=$(xcodebuild -version | head -1 | awk '{print $2}')
[ "${XCODE_VERSION%%.*}" -ge 16 ] 2>/dev/null || fail "Xcode $XCODE_VERSION gefunden, benötigt wird 16 oder neuer."
ok "Xcode $XCODE_VERSION"
if ! xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1; then
    warn "Xcode-Erstinstallation wird abgeschlossen (Admin-Passwort):"
    sudo xcodebuild -runFirstLaunch
fi

bold "2/4  Signing einrichten"
TEAM="${1:-}"
if [ -z "$TEAM" ]; then
    # Team ID = OU field of an "Apple Development" certificate in the keychain.
    TEAM=$(security find-certificate -a -c "Apple Development" -p 2>/dev/null \
        | openssl x509 -noout -subject 2>/dev/null \
        | sed -n 's/.*OU *= *\([A-Z0-9]\{10\}\).*/\1/p' | head -1)
fi
if [ -n "$TEAM" ]; then
    ok "Team ID: $TEAM"
else
    warn "Kein Entwickler-Zertifikat gefunden (normal beim allerersten Mal)."
    echo "     Team ID eingeben, falls bekannt – sonst Enter und das Team später in Xcode wählen."
    read -r -p "     Team ID: " TEAM
fi
USER_PART=$(whoami | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9')
DEFAULT_PREFIX="de.${USER_PART:-dev}"
read -r -p "     Bundle-ID-Präfix [$DEFAULT_PREFIX]: " PREFIX
PREFIX="${PREFIX:-$DEFAULT_PREFIX}"
cat > Config/Signing.local.xcconfig <<CFG
// Written by setup.sh – personal signing settings (not committed).
DEVELOPMENT_TEAM = $TEAM
BUNDLE_ID_PREFIX = $PREFIX
CFG
ok "App: $PREFIX.mks50   Plugin: $PREFIX.mks50.AUv3"

bold "3/4  Testbuild (ohne Signing, prüft ob alles kompiliert)"
if xcodebuild -project MKS50.xcodeproj -scheme MKS50 -configuration Debug \
        -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build > build.log 2>&1; then
    ok "Kompiliert fehlerfrei"
else
    printf "  \033[31m✗\033[0m Build fehlgeschlagen. Fehler:\n\n"
    grep -E "error:" build.log | sort -u | head -40
    echo
    warn "Komplettes Log: $(pwd)/build.log – bitte die Fehler an Claude schicken."
    exit 1
fi

bold "4/4  Projekt öffnen"
open MKS50.xcodeproj
cat <<TXT

  Jetzt in Xcode:
   1. iPhone per Kabel anschließen, entsperren, "Vertrauen" bestätigen.
   2. Oben als Ziel dein iPhone wählen (Schema: MKS50).
TXT
if [ -z "$TEAM" ]; then
cat <<TXT
   3. Xcode → Settings → Accounts → "+" → mit deiner Apple-ID anmelden.
   4. Links das blaue Projekt "MKS50" → Targets MKS50 und MKS50AU →
      Signing & Capabilities → Team = deine Apple-ID (beide Targets!).
      (Oder danach ./setup.sh erneut ausführen – dann wird das Team erkannt.)
TXT
fi
cat <<TXT
   ▶  Cmd+R drücken.

  Beim ersten Start auf dem iPhone:
   • Einstellungen → Datenschutz & Sicherheit → Entwicklermodus → an (Neustart)
   • Einstellungen → Allgemein → VPN & Geräteverwaltung → Entwickler vertrauen
TXT
