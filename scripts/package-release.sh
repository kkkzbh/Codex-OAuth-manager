#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${CODEX_OAUTH_MANAGER_VERSION:-0.0.1}"
TARGET="${CODEX_OAUTH_MANAGER_TARGET:-linux-x86_64}"
PACKAGE_NAME="codex-oauth-manager-v${VERSION}-${TARGET}"
DIST_DIR="$ROOT_DIR/dist"
PACKAGE_DIR="$DIST_DIR/$PACKAGE_NAME"
PLASMOID_ID="com.github.kkkzbh.codex-oauth-manager.accounts"
COLLECTOR_MANIFEST="$ROOT_DIR/native/codexbar-collector/Cargo.toml"
COLLECTOR_BIN="$ROOT_DIR/native/codexbar-collector/target/release/codexbar-collector"

rm -rf "$PACKAGE_DIR"
mkdir -p "$PACKAGE_DIR/bin" "$PACKAGE_DIR/scripts" "$PACKAGE_DIR/plasma" "$DIST_DIR"

cargo build --release --manifest-path "$COLLECTOR_MANIFEST"

install -Dm755 "$COLLECTOR_BIN" "$PACKAGE_DIR/bin/codexbar-collector"
install -Dm755 "$ROOT_DIR/install.sh" "$PACKAGE_DIR/install.sh"
install -Dm755 \
  "$ROOT_DIR/scripts/codexbar-accounts-plasmoid-bridge.sh" \
  "$PACKAGE_DIR/scripts/codexbar-accounts-plasmoid-bridge.sh"

cp -a "$ROOT_DIR/plasma/$PLASMOID_ID" "$PACKAGE_DIR/plasma/$PLASMOID_ID"

(
  cd "$PACKAGE_DIR/plasma"
  zip -qrT "$DIST_DIR/$PLASMOID_ID.plasmoid" "$PLASMOID_ID"
)

(
  cd "$DIST_DIR"
  tar -czf "$PACKAGE_NAME.tar.gz" "$PACKAGE_NAME"
  sha256sum "$PACKAGE_NAME.tar.gz" "$PLASMOID_ID.plasmoid" > checksums.txt
)

printf 'Release assets written to %s\n' "$DIST_DIR"
printf '  %s\n' "$DIST_DIR/$PACKAGE_NAME.tar.gz"
printf '  %s\n' "$DIST_DIR/$PLASMOID_ID.plasmoid"
printf '  %s\n' "$DIST_DIR/checksums.txt"
