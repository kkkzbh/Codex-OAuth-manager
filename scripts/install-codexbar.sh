#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COLLECTOR_MANIFEST="$ROOT_DIR/native/codexbar-collector/Cargo.toml"
COLLECTOR_BUILD_DIR="$ROOT_DIR/native/codexbar-collector/target/release"
COLLECTOR_SOURCE="$COLLECTOR_BUILD_DIR/codexbar-collector"
COLLECTOR_DEST="$HOME/.local/bin/codexbar-collector"
BRIDGE_SOURCE="$ROOT_DIR/scripts/codexbar-plasmoid-bridge.sh"
BRIDGE_DEST="$HOME/.local/bin/codexbar-plasmoid-bridge"
ACCOUNTS_BRIDGE_SOURCE="$ROOT_DIR/scripts/codexbar-accounts-plasmoid-bridge.sh"
ACCOUNTS_BRIDGE_DEST="$HOME/.local/bin/codexbar-accounts-plasmoid-bridge"
PLASMOID_DIR="$ROOT_DIR/plasma/local.codexbar.tokens"
ACCOUNTS_PLASMOID_DIR="$ROOT_DIR/plasma/local.codexbar.accounts"

mkdir -p "$HOME/.local/bin"

cargo build --release --manifest-path "$COLLECTOR_MANIFEST"
install -Dm755 "$COLLECTOR_SOURCE" "$COLLECTOR_DEST"
install -Dm755 "$BRIDGE_SOURCE" "$BRIDGE_DEST"
install -Dm755 "$ACCOUNTS_BRIDGE_SOURCE" "$ACCOUNTS_BRIDGE_DEST"

if kpackagetool6 -t Plasma/Applet -l | grep -q '^local\.codexbar\.tokens$'; then
  kpackagetool6 -t Plasma/Applet -u "$PLASMOID_DIR"
else
  kpackagetool6 -t Plasma/Applet -i "$PLASMOID_DIR"
fi

if kpackagetool6 -t Plasma/Applet -l | grep -q '^local\.codexbar\.accounts$'; then
  kpackagetool6 -t Plasma/Applet -u "$ACCOUNTS_PLASMOID_DIR"
else
  kpackagetool6 -t Plasma/Applet -i "$ACCOUNTS_PLASMOID_DIR"
fi

echo "Installed collector to $COLLECTOR_DEST"
echo "Installed plasmoid bridge to $BRIDGE_DEST"
echo "Installed accounts plasmoid bridge to $ACCOUNTS_BRIDGE_DEST"
echo "Installed plasmoid local.codexbar.tokens"
echo "Installed plasmoid local.codexbar.accounts"
echo "Add 'CodexBar Tokens' and/or 'CodexBar Accounts' from Plasma widgets to your panel."
