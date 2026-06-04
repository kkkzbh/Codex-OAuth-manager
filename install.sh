#!/usr/bin/env bash
set -euo pipefail

REPO="kkkzbh/Codex-OAuth-manager"
APP_NAME="codex-oauth-manager"
VERSION="0.0.1"
TARGET="linux-x86_64"
ARCHIVE_NAME="${APP_NAME}-v${VERSION}-${TARGET}.tar.gz"
PLASMOID_ID="com.github.kkkzbh.codex-oauth-manager.accounts"
INSTALL_ROOT="${CODEX_OAUTH_MANAGER_INSTALL_ROOT:-$HOME/.local}"
BIN_DIR="$INSTALL_ROOT/bin"
COLLECTOR_DEST="$BIN_DIR/codexbar-collector"
BRIDGE_DEST="$BIN_DIR/codexbar-accounts-plasmoid-bridge"

info() {
  printf '%s\n' "$*"
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

have() {
  command -v "$1" >/dev/null 2>&1
}

confirm() {
  local prompt="$1"
  local answer
  printf '%s [y/N] ' "$prompt" >&2
  IFS= read -r answer || answer=""
  case "$answer" in
    y|Y) return 0 ;;
    *) return 1 ;;
  esac
}

script_dir() {
  local source="${BASH_SOURCE[0]}"
  while [ -L "$source" ]; do
    local dir
    dir="$(cd -P "$(dirname "$source")" >/dev/null 2>&1 && pwd)"
    source="$(readlink "$source")"
    [[ "$source" != /* ]] && source="$dir/$source"
  done
  cd -P "$(dirname "$source")" >/dev/null 2>&1 && pwd
}

detect_package_manager() {
  if have dnf; then
    printf 'dnf\n'
  elif have apt-get; then
    printf 'apt\n'
  elif have pacman; then
    printf 'pacman\n'
  else
    return 1
  fi
}

dependency_install_command() {
  local manager="$1"
  shift
  case "$manager" in
    dnf)
      printf 'sudo dnf install -y'
      for package in "$@"; do printf ' %q' "$package"; done
      ;;
    apt)
      printf 'sudo apt-get update && sudo apt-get install -y'
      for package in "$@"; do printf ' %q' "$package"; done
      ;;
    pacman)
      printf 'sudo pacman -S --needed'
      for package in "$@"; do printf ' %q' "$package"; done
      ;;
    *)
      return 1
      ;;
  esac
}

install_dependency_packages() {
  local manager="$1"
  shift
  local command_text
  command_text="$(dependency_install_command "$manager" "$@")"

  info "Missing dependency packages: $*"
  info "Install command: $command_text"
  if ! confirm "Install missing dependencies?"; then
    info "Dependency installation declined."
    info "Run this manually, then retry:"
    info "  $command_text"
    exit 1
  fi

  case "$manager" in
    dnf)
      sudo dnf install -y "$@"
      ;;
    apt)
      sudo apt-get update
      sudo apt-get install -y "$@"
      ;;
    pacman)
      sudo pacman -S --needed "$@"
      ;;
  esac
}

ensure_platform() {
  [ "$(uname -s)" = "Linux" ] || die "only Linux is supported"
  [ "$(uname -m)" = "x86_64" ] || die "only x86_64 Linux is supported"
}

ensure_dependencies() {
  local missing_packages=()
  local package_manager
  package_manager="$(detect_package_manager || true)"

  if ! have tar; then
    missing_packages+=("tar")
  fi

  if ! have install; then
    missing_packages+=("coreutils")
  fi

  if ! have kpackagetool6; then
    case "$package_manager" in
      dnf) install_dependency_packages "$package_manager" kf6-kpackage ;;
      apt) install_dependency_packages "$package_manager" kpackagetool6 ;;
      pacman) install_dependency_packages "$package_manager" kpackage ;;
      *) die "kpackagetool6 is missing and no supported package manager was found" ;;
    esac
  fi

  if ((${#missing_packages[@]} > 0)); then
    case "$package_manager" in
      dnf|apt|pacman) install_dependency_packages "$package_manager" "${missing_packages[@]}" ;;
      *) die "missing required packages: ${missing_packages[*]}" ;;
    esac
  fi

  if ! have codex; then
    cat >&2 <<'EOF'
warning: codex was not found in PATH.
CodexBar Accounts needs the Codex CLI command. You do not need to be logged in
before installing; the widget's + button can run `codex login` after install.
Install Codex first, then retry this installer.
EOF
    exit 1
  fi
}

ensure_bootstrap_dependencies() {
  have tar && return 0

  local package_manager
  package_manager="$(detect_package_manager || true)"
  case "$package_manager" in
    dnf|apt|pacman) install_dependency_packages "$package_manager" tar ;;
    *) die "tar is required to unpack the release archive" ;;
  esac
}

download_file() {
  local url="$1"
  local dest="$2"
  if have curl; then
    curl -fsSL "$url" -o "$dest"
  elif have wget; then
    wget -qO "$dest" "$url"
  else
    die "curl or wget is required to download release assets"
  fi
}

bootstrap_from_latest_release() {
  [ "${CODEX_OAUTH_MANAGER_NO_BOOTSTRAP:-}" != "1" ] || die "release payload files are missing"

  ensure_platform
  ensure_bootstrap_dependencies

  local release_base="${CODEX_OAUTH_MANAGER_RELEASE_BASE:-https://github.com/${REPO}/releases/latest/download}"
  local tmp_dir
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT

  info "Downloading ${ARCHIVE_NAME} from GitHub Releases..."
  download_file "$release_base/$ARCHIVE_NAME" "$tmp_dir/$ARCHIVE_NAME"
  tar -xzf "$tmp_dir/$ARCHIVE_NAME" -C "$tmp_dir"
  exec env CODEX_OAUTH_MANAGER_NO_BOOTSTRAP=1 "$tmp_dir/${APP_NAME}-v${VERSION}-${TARGET}/install.sh" "$@"
}

install_payload() {
  local root="$1"
  local collector="$root/bin/codexbar-collector"
  local bridge="$root/scripts/codexbar-accounts-plasmoid-bridge.sh"
  local plasmoid_dir="$root/plasma/$PLASMOID_ID"

  [ -x "$collector" ] || die "missing release collector binary: $collector"
  [ -f "$bridge" ] || die "missing accounts bridge: $bridge"
  [ -d "$plasmoid_dir" ] || die "missing accounts plasmoid: $plasmoid_dir"

  mkdir -p "$BIN_DIR"
  install -Dm755 "$collector" "$COLLECTOR_DEST"
  install -Dm755 "$bridge" "$BRIDGE_DEST"

  if kpackagetool6 -t Plasma/Applet -l | grep -Fxq "$PLASMOID_ID"; then
    kpackagetool6 -t Plasma/Applet -u "$plasmoid_dir"
  else
    kpackagetool6 -t Plasma/Applet -i "$plasmoid_dir"
  fi

  info "Installed collector to $COLLECTOR_DEST"
  info "Installed accounts plasmoid bridge to $BRIDGE_DEST"
  info "Installed plasmoid $PLASMOID_ID"
  info "Add 'CodexBar Accounts' from Plasma widgets to your panel."
}

main() {
  ensure_platform

  local root
  root="$(script_dir)"
  if [ ! -x "$root/bin/codexbar-collector" ]; then
    bootstrap_from_latest_release "$@"
  fi

  ensure_dependencies
  install_payload "$root"
}

main "$@"
