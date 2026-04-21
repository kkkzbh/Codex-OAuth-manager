#!/usr/bin/env bash
set -uo pipefail

LOG_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/codexbar"
LOG_FILE="$LOG_DIR/workers-bridge.log"
MAIN_PATTERN="${CODEX_APP_MAIN_PATTERN:-/codex-app/current/Codex --no-sandbox}"
SESSIONS_DIR="${CODEX_SESSIONS_DIR:-$HOME/.codex/sessions}"
ACTIVE_WINDOW_S="${CODEX_ACTIVE_WINDOW_S:-15}"
STATUS_PATH="${CODEX_WORKING_SESSIONS_STATUS_PATH:-}"

if [ -z "$STATUS_PATH" ] && [ -n "${XDG_RUNTIME_DIR:-}" ]; then
  STATUS_PATH="$XDG_RUNTIME_DIR/codex-app/working-sessions.json"
fi

mkdir -p "$LOG_DIR"

ts() { date +%s; }

emit_and_exit() {
  printf '%s\n' "$1"
  exit 0
}

json_escape() {
  # Minimal escape for path/string inside double-quoted JSON.
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

read_runtime_status_payload() {
  [ -n "$STATUS_PATH" ] || return 1
  [ -r "$STATUS_PATH" ] || return 1
  command -v python3 >/dev/null 2>&1 || return 1

  python3 - "$STATUS_PATH" "${main_pid:-}" <<'PY'
import json
import os
import sys
import time

status_path = sys.argv[1]
detected_main_pid = int(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2].isdigit() else 0

try:
    with open(status_path, "r", encoding="utf-8") as handle:
        data = json.load(handle)

    if data.get("schema") != 1:
        raise ValueError("unsupported schema")

    count = int(data.get("count", 0))
    if count < 0:
        raise ValueError("negative count")

    pid = int(data.get("pid", 0) or 0)
    app_running = bool(data.get("app_running"))

    if app_running:
        if pid <= 0:
            raise ValueError("missing pid")
        try:
            os.kill(pid, 0)
        except ProcessLookupError as exc:
            raise ValueError("stale pid") from exc
        except PermissionError:
            pass
    elif detected_main_pid > 0:
        raise ValueError("runtime status says stopped while app process exists")

    payload = {
        "count": count if app_running else 0,
        "app_running": app_running,
        "main_pid": pid if pid > 0 else detected_main_pid,
        "source": "codex-runtime-status",
        "window_s": 0,
        "active_files": [],
        "ts": int(time.time()),
    }
    print(json.dumps(payload, separators=(",", ":")))
except Exception:
    sys.exit(1)
PY
}

main_pid="$(pgrep -f "$MAIN_PATTERN" | head -n1 || true)"
app_running="false"
main_pid_json="0"
if [ -n "$main_pid" ]; then
  app_running="true"
  main_pid_json="$main_pid"
fi

runtime_payload="$(read_runtime_status_payload 2>/dev/null || true)"
if [ -n "$runtime_payload" ]; then
  printf '[%s] source=codex-runtime-status main_pid=%s status_path=%s\n' \
    "$(date -Iseconds)" "$main_pid_json" "$STATUS_PATH" \
    >>"$LOG_FILE" 2>/dev/null || true
  emit_and_exit "$runtime_payload"
fi

count=0
active_files_list=""
if [ -d "$SESSIONS_DIR" ]; then
  now=$(ts)
  cutoff=$((now - ACTIVE_WINDOW_S))
  # Find rollout*.jsonl files modified after cutoff.
  while IFS= read -r -d '' f; do
    count=$((count + 1))
    if [ -z "$active_files_list" ]; then
      active_files_list="\"$(json_escape "$f")\""
    else
      active_files_list="$active_files_list,\"$(json_escape "$f")\""
    fi
  done < <(find "$SESSIONS_DIR" -type f -name 'rollout-*.jsonl' -newermt "@$cutoff" -print0 2>/dev/null)
fi

printf '[%s] main_pid=%s count=%s window=%ss\n' \
  "$(date -Iseconds)" "${main_pid:-none}" "$count" "$ACTIVE_WINDOW_S" \
  >>"$LOG_FILE" 2>/dev/null || true

emit_and_exit "{\"count\":$count,\"app_running\":$app_running,\"main_pid\":$main_pid_json,\"source\":\"rollout-mtime\",\"window_s\":$ACTIVE_WINDOW_S,\"active_files\":[$active_files_list],\"ts\":$(ts)}"
