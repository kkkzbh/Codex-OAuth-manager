#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COLLECTOR_MANIFEST="$ROOT_DIR/native/codexbar-collector/Cargo.toml"
COLLECTOR_BUILD_DIR="$ROOT_DIR/native/codexbar-collector/target/release"
COLLECTOR_SOURCE="$COLLECTOR_BUILD_DIR/codexbar-collector"
COLLECTOR_DEST="$HOME/.local/bin/codexbar-collector"
ACCOUNTS_BRIDGE_SOURCE="$ROOT_DIR/scripts/codexbar-accounts-plasmoid-bridge.sh"
ACCOUNTS_BRIDGE_DEST="$HOME/.local/bin/codexbar-accounts-plasmoid-bridge"
ACCOUNTS_PLASMOID_ID="com.github.kkkzbh.codex-oauth-manager.accounts"
ACCOUNTS_PLASMOID_DIR="$ROOT_DIR/plasma/$ACCOUNTS_PLASMOID_ID"

mkdir -p "$HOME/.local/bin"

cargo build --release --manifest-path "$COLLECTOR_MANIFEST"
install -Dm755 "$COLLECTOR_SOURCE" "$COLLECTOR_DEST"
install -Dm755 "$ACCOUNTS_BRIDGE_SOURCE" "$ACCOUNTS_BRIDGE_DEST"

if kpackagetool6 -t Plasma/Applet -l | grep -Fxq "$ACCOUNTS_PLASMOID_ID"; then
  kpackagetool6 -t Plasma/Applet -u "$ACCOUNTS_PLASMOID_DIR"
else
  kpackagetool6 -t Plasma/Applet -i "$ACCOUNTS_PLASMOID_DIR"
fi

echo "Installed collector to $COLLECTOR_DEST"
echo "Installed accounts plasmoid bridge to $ACCOUNTS_BRIDGE_DEST"
echo "Installed plasmoid $ACCOUNTS_PLASMOID_ID"
echo "Add 'CodexBar Accounts' from Plasma widgets to your panel."
