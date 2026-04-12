#!/usr/bin/env bash
set -uo pipefail

LOG_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/codexbar"
LOG_FILE="$LOG_DIR/accounts-plasmoid-bridge.log"
COLLECTOR_PATH="${COLLECTOR_PATH:-$HOME/.local/bin/codexbar-collector}"
REFRESH_INTERVAL_SECONDS="${REFRESH_INTERVAL_SECONDS:-120}"
SOFT_TTL_SECONDS="${SOFT_TTL_SECONDS:-60}"
HARD_TTL_SECONDS="${HARD_TTL_SECONDS:-900}"
FETCH_TIMEOUT_SECONDS="${FETCH_TIMEOUT_SECONDS:-12}"
WARMUP_TIMEOUT_SECONDS="${WARMUP_TIMEOUT_SECONDS:-30}"
FETCH_CONCURRENCY="${FETCH_CONCURRENCY:-4}"
CODEX_HOME_PATH="${CODEX_HOME_PATH:-${CODEX_HOME:-$HOME/.codex}}"
TERMINAL_COMMAND="${TERMINAL_COMMAND:-}"
LOGIN_COMMAND="${LOGIN_COMMAND:-codex login}"
AUTO_SWITCH_5H_THRESHOLD="${AUTO_SWITCH_5H_THRESHOLD:-10}"
AUTO_SWITCH_WEEKLY_THRESHOLD="${AUTO_SWITCH_WEEKLY_THRESHOLD:-5}"
CLASH_VERGE_CONFIG_PATH="${CLASH_VERGE_CONFIG_PATH:-$HOME/.local/share/io.github.clash-verge-rev.clash-verge-rev/clash-verge.yaml}"
DEFAULT_NO_PROXY="${DEFAULT_NO_PROXY:-localhost,127.0.0.1,::1}"

mkdir -p "$LOG_DIR"

timestamp() {
  date -Iseconds
}

has_proxy_env() {
  [[ -n "${http_proxy:-}" \
    || -n "${https_proxy:-}" \
    || -n "${all_proxy:-}" \
    || -n "${HTTP_PROXY:-}" \
    || -n "${HTTPS_PROXY:-}" \
    || -n "${ALL_PROXY:-}" ]]
}

detect_clash_verge_port() {
  local config_path="${1:-}"
  [[ -f "$config_path" ]] || return 1

  awk -F ':' '
    /^[[:space:]]*mixed-port:[[:space:]]*[0-9]+[[:space:]]*$/ {
      value=$2
      gsub(/[^0-9]/, "", value)
      print value
      exit
    }
    /^[[:space:]]*port:[[:space:]]*[0-9]+[[:space:]]*$/ {
      value=$2
      gsub(/[^0-9]/, "", value)
      print value
      exit
    }
  ' "$config_path"
}

port_is_listening() {
  local port="${1:-}"
  [[ "$port" =~ ^[0-9]+$ ]] || return 1
  ss -ltn "( sport = :$port )" 2>/dev/null | grep -q LISTEN
}

bootstrap_proxy_env() {
  if has_proxy_env; then
    return 0
  fi

  local detected_port
  detected_port="$(detect_clash_verge_port "$CLASH_VERGE_CONFIG_PATH" || true)"
  if [[ -z "$detected_port" ]] || ! port_is_listening "$detected_port"; then
    return 0
  fi

  local proxy_url="http://127.0.0.1:${detected_port}"
  export http_proxy="$proxy_url"
  export https_proxy="$proxy_url"
  export all_proxy="$proxy_url"
  export HTTP_PROXY="$proxy_url"
  export HTTPS_PROXY="$proxy_url"
  export ALL_PROXY="$proxy_url"
  export no_proxy="${no_proxy:-${NO_PROXY:-$DEFAULT_NO_PROXY}}"
  export NO_PROXY="$no_proxy"
  printf '[%s] proxy=bootstrapped source=clash-verge port=%s\n' "$(timestamp)" "$detected_port" >>"$LOG_FILE"
}

bootstrap_proxy_env

cmd="${1:-snapshot}"
shift || true

printf '[%s] cmd=%s collector=%s\n' "$(timestamp)" "$cmd" "$COLLECTOR_PATH" >>"$LOG_FILE"

case "$cmd" in
  snapshot)
    exec "$COLLECTOR_PATH" accounts-snapshot --format json \
      --codex-home "$CODEX_HOME_PATH" \
      --soft-ttl-seconds "$SOFT_TTL_SECONDS" \
      --hard-ttl-seconds "$HARD_TTL_SECONDS" \
      --timeout-seconds "$FETCH_TIMEOUT_SECONDS" \
      --concurrency "$FETCH_CONCURRENCY" \
      "$@"
    ;;
  activate)
    exec "$COLLECTOR_PATH" account activate --codex-home "$CODEX_HOME_PATH" "$@"
    ;;
  remove)
    exec "$COLLECTOR_PATH" account remove --codex-home "$CODEX_HOME_PATH" "$@"
    ;;
  warmup)
    exec "$COLLECTOR_PATH" account warmup --codex-home "$CODEX_HOME_PATH" \
      --timeout-seconds "$WARMUP_TIMEOUT_SECONDS" \
      "$@"
    ;;
  login)
    if [[ -n "$TERMINAL_COMMAND" ]]; then
      exec "$COLLECTOR_PATH" account login --terminal "$TERMINAL_COMMAND" --command "$LOGIN_COMMAND" "$@"
    fi
    exec "$COLLECTOR_PATH" account login --command "$LOGIN_COMMAND" "$@"
    ;;
  auto-switch)
    exec "$COLLECTOR_PATH" account auto-switch --codex-home "$CODEX_HOME_PATH" \
      --soft-ttl-seconds "$SOFT_TTL_SECONDS" \
      --hard-ttl-seconds "$HARD_TTL_SECONDS" \
      --timeout-seconds "$FETCH_TIMEOUT_SECONDS" \
      --concurrency "$FETCH_CONCURRENCY" \
      --threshold-5h-percent "$AUTO_SWITCH_5H_THRESHOLD" \
      --threshold-weekly-percent "$AUTO_SWITCH_WEEKLY_THRESHOLD" \
      "$@"
    ;;
  *)
    printf 'unknown command: %s\n' "$cmd" >&2
    exit 1
    ;;
esac
