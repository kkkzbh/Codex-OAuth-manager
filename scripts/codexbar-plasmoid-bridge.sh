#!/usr/bin/env bash
set -uo pipefail

LOG_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/codexbar"
LOG_FILE="$LOG_DIR/plasmoid-bridge.log"
COLLECTOR_PATH="${COLLECTOR_PATH:-$HOME/.local/bin/codexbar-collector}"
REFRESH_INTERVAL_SECONDS="${REFRESH_INTERVAL_SECONDS:-3}"

mkdir -p "$LOG_DIR"

timestamp() {
  date -Iseconds
}

printf '[%s] start collector=%s ttl=%s\n' "$(timestamp)" "$COLLECTOR_PATH" "$REFRESH_INTERVAL_SECONDS" >>"$LOG_FILE"

stderr_file="$(mktemp)"
if output="$("$COLLECTOR_PATH" snapshot --format json --ttl-seconds "$REFRESH_INTERVAL_SECONDS" 2>"$stderr_file")"; then
  printf '[%s] ok bytes=%s\n' "$(timestamp)" "${#output}" >>"$LOG_FILE"
  printf '%s\n' "$output"
  rm -f "$stderr_file"
  exit 0
fi

status=$?
stderr_output="$(cat "$stderr_file")"
printf '[%s] fail status=%s stderr=%s\n' "$(timestamp)" "$status" "$stderr_output" >>"$LOG_FILE"
printf '%s\n' "$stderr_output" >&2
rm -f "$stderr_file"
exit "$status"
