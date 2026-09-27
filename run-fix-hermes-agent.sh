#!/usr/bin/env bash
# Repair the known Hermes Python 3.11 / RAG MCP 2.x deployment issue.
# Safe scope: dependencies and virtual environments only. It does not modify
# model/provider configuration, credentials, sessions, routes, or source files.

set -Eeuo pipefail
umask 077

MODE="fix"
TARGET_PYTHON="3.14.7"
CORE_DIR="/opt/hermes/hermes-agent"
RAG_DIR="/opt/hermes-rag"
HERMES_HOME="${HERMES_HOME:-/root/.hermes}"
BACKUP_ROOT="/root/hermes_fix_backups"
MIN_FREE_KB=1572864  # 1.5 GiB

usage() {
  cat <<'EOF'
Usage:
  curl -fsSL <RAW_GITHUB_URL>/run-fix-hermes-agent.sh | bash
  sudo bash run-fix-hermes-agent.sh --check
  sudo bash run-fix-hermes-agent.sh --fix

Options:
  --check                 Inspect only. Exit 2 if repair is needed.
  --fix                   Back up, repair, restart, and verify (default).
  --python-version VER    Core Python version (default: 3.14.7).
  --core-dir PATH         Hermes source path.
  --rag-dir PATH          Hermes RAG path.
  --help                  Show this help.

Exit codes:
  0  Healthy / repair completed and verified
  1  Error or verification failure
  2  Check detected the known dependency issue
EOF
}

log()  { printf '[hermes-repair] %s\n' "$*"; }
warn() { printf '[hermes-repair] WARNING: %s\n' "$*" >&2; }
die()  { printf '[hermes-repair] ERROR: %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) MODE="check"; shift ;;
    --fix) MODE="fix"; shift ;;
    --python-version) [[ $# -ge 2 ]] || die "Missing value for $1"; TARGET_PYTHON="$2"; shift 2 ;;
    --core-dir) [[ $# -ge 2 ]] || die "Missing value for $1"; CORE_DIR="${2%/}"; shift 2 ;;
    --rag-dir) [[ $# -ge 2 ]] || die "Missing value for $1"; RAG_DIR="${2%/}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "Run as root (sudo -i)."
for cmd in systemctl journalctl uv curl python3; do
  command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: $cmd"
done
[[ -f "$CORE_DIR/pyproject.toml" ]] || die "Missing $CORE_DIR/pyproject.toml"
[[ -f "$CORE_DIR/uv.lock" ]] || die "Missing $CORE_DIR/uv.lock; refusing an unlocked repair."
[[ -x "$CORE_DIR/.venv/bin/python" ]] || die "Missing core venv: $CORE_DIR/.venv"

CORE_PY="$CORE_DIR/.venv/bin/python"
RAG_PY="$RAG_DIR/.venv/bin/python"
HAS_RAG=0
[[ -x "$RAG_PY" && -f "$RAG_DIR/pyproject.toml" ]] && HAS_RAG=1

service_exists() { systemctl cat "$1" >/dev/null 2>&1; }
CORE_SERVICES=()
for svc in hermes-dashboard hermes-gateway; do
  service_exists "$svc" && CORE_SERVICES+=("$svc")
done
RAG_SERVICE=""
if [[ $HAS_RAG -eq 1 ]] && service_exists hermes-rag; then RAG_SERVICE="hermes-rag"; fi
[[ ${#CORE_SERVICES[@]} -gt 0 ]] || die "No Hermes dashboard/gateway systemd units found."

core_python_version="$($CORE_PY -c 'import platform; print(platform.python_version())' 2>/dev/null || true)"
core_import_output="$($CORE_PY - <<'PY' 2>&1 || true
import importlib
mods = ["ruamel.yaml", "openai", "fastapi", "uvicorn", "httpx", "pydantic", "hermes_cli.main"]
failed = []
for name in mods:
    try:
        importlib.import_module(name)
    except Exception as exc:
        failed.append(f"{name}: {type(exc).__name__}: {exc}")
if failed:
    print("\n".join(failed))
    raise SystemExit(1)
print("OK")
PY
)"
CORE_NEEDS_FIX=0
[[ "$core_python_version" == 3.14.* ]] || CORE_NEEDS_FIX=1
[[ "$core_import_output" == "OK" ]] || CORE_NEEDS_FIX=1

RAG_NEEDS_FIX=0
rag_mcp_version="not-installed"
rag_import_output="not-present"
if [[ $HAS_RAG -eq 1 ]]; then
  rag_mcp_version="$($RAG_PY -c 'import importlib.metadata; print(importlib.metadata.version("mcp"))' 2>/dev/null || printf 'not-installed')"
  rag_import_output="$($RAG_PY -c 'import mcp.server.fastmcp; import hermes_rag.mcp_server; print("OK")' 2>&1 || true)"
  [[ "$rag_import_output" == "OK" ]] || RAG_NEEDS_FIX=1
  [[ "$rag_mcp_version" == 1.* ]] || RAG_NEEDS_FIX=1
fi

log "Core path: $CORE_DIR"
log "Core Python: ${core_python_version:-unknown}"
if [[ "$core_import_output" == "OK" ]]; then
  log "Core imports: OK"
else
  warn "Core imports failed: ${core_import_output//$'\n'/; }"
fi
if [[ $HAS_RAG -eq 1 ]]; then
  log "RAG path: $RAG_DIR"
  log "RAG MCP: $rag_mcp_version"
  if [[ "$rag_import_output" == "OK" ]]; then
    log "RAG FastMCP imports: OK"
  else
    warn "RAG FastMCP imports failed: ${rag_import_output//$'\n'/; }"
  fi
else
  log "RAG environment not present; skipping RAG."
fi

if [[ $CORE_NEEDS_FIX -eq 0 && $RAG_NEEDS_FIX -eq 0 ]]; then
  log "The known dependency issue is not present. No changes needed."
  exit 0
fi

if [[ "$MODE" == "check" ]]; then
  log "Repair recommended. Re-run with --fix."
  exit 2
fi

free_kb="$(df -Pk "$CORE_DIR" | python3 -c 'import sys; rows=sys.stdin.read().splitlines(); print(rows[-1].split()[3])')"
[[ "$free_kb" =~ ^[0-9]+$ ]] || die "Could not determine free disk space."
(( free_kb >= MIN_FREE_KB )) || die "Less than 1.5 GiB free; refusing to rebuild the venv."

# Validate that the source lock can resolve for the target runtime before stopping anything.
if [[ $CORE_NEEDS_FIX -eq 1 ]]; then
  log "Preflighting uv.lock with Python $TARGET_PYTHON..."
  uv python install "$TARGET_PYTHON"
  (
    cd "$CORE_DIR"
    uv sync --locked --dry-run --python "$TARGET_PYTHON" --extra all >/dev/null
  ) || die "uv.lock cannot resolve with Python $TARGET_PYTHON; nothing was changed."
fi

TS="$(date +%Y%m%d-%H%M%S)"
BAK="$BACKUP_ROOT/dependency-fix-$TS"
mkdir -p "$BAK"
chmod 700 "$BACKUP_ROOT" "$BAK"
printf '%s\n' "$BAK" > "$BACKUP_ROOT/latest-dependency-fix"

backup_file() {
  local src="$1" dst="${2:-}"
  [[ -e "$src" ]] || return 0
  if [[ -n "$dst" ]]; then cp -a "$src" "$BAK/$dst"; else cp -a "$src" "$BAK/"; fi
}

backup_file "$HERMES_HOME/config.yaml"
backup_file "$HERMES_HOME/auth.json"
backup_file "/opt/hermes/.env" "hermes-service.env"
for svc in "${CORE_SERVICES[@]}"; do
  systemctl cat "$svc" > "$BAK/${svc}.unit.txt" 2>/dev/null || true
done
[[ -n "$RAG_SERVICE" ]] && systemctl cat "$RAG_SERVICE" > "$BAK/${RAG_SERVICE}.unit.txt" 2>/dev/null || true

(
  cd "$CORE_DIR"
  git rev-parse HEAD > "$BAK/core-git-head.txt" 2>/dev/null || true
  git status --short > "$BAK/core-git-status.txt" 2>/dev/null || true
  uv pip freeze --python .venv/bin/python > "$BAK/core-packages-before.txt" 2>/dev/null || true
)
if [[ $HAS_RAG -eq 1 ]]; then
  (
    cd "$RAG_DIR"
    uv pip freeze --python .venv/bin/python > "$BAK/rag-packages-before.txt" 2>/dev/null || true
    cp -a pyproject.toml "$BAK/rag-pyproject.toml"
  )
fi

SERVICES_STOPPED=0
CORE_MOVED=0
OLD_CORE_VENV="$BAK/core-venv-before-rebuild"
cleanup() {
  local rc=$?
  if [[ $CORE_MOVED -eq 1 && ! -x "$CORE_DIR/.venv/bin/python" && -d "$OLD_CORE_VENV" ]]; then
    warn "Restoring previous core venv after interrupted/failed rebuild."
    rm -rf "$CORE_DIR/.venv"
    mv "$OLD_CORE_VENV" "$CORE_DIR/.venv"
  fi
  if [[ $SERVICES_STOPPED -eq 1 ]]; then
    warn "Starting stopped Hermes services during cleanup."
    [[ -n "$RAG_SERVICE" ]] && systemctl start "$RAG_SERVICE" >/dev/null 2>&1 || true
    for svc in "${CORE_SERVICES[@]}"; do systemctl start "$svc" >/dev/null 2>&1 || true; done
  fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

log "Stopping only affected Hermes services..."
for svc in "${CORE_SERVICES[@]}"; do systemctl stop "$svc"; done
[[ -n "$RAG_SERVICE" ]] && systemctl stop "$RAG_SERVICE"
SERVICES_STOPPED=1

# Copy SQLite files only while writers are stopped.
for f in state.db state.db-wal state.db-shm; do backup_file "$HERMES_HOME/$f"; done

if [[ $CORE_NEEDS_FIX -eq 1 ]]; then
  log "Rebuilding core venv from the committed uv.lock..."
  mv "$CORE_DIR/.venv" "$OLD_CORE_VENV"
  CORE_MOVED=1
  if ! (
    cd "$CORE_DIR"
    uv sync --locked --python "$TARGET_PYTHON" --extra all
  ); then
    rm -rf "$CORE_DIR/.venv"
    mv "$OLD_CORE_VENV" "$CORE_DIR/.venv"
    CORE_MOVED=0
    die "Core rebuild failed; previous venv restored."
  fi
  uv pip freeze --python "$CORE_DIR/.venv/bin/python" > "$BAK/core-packages-after.txt" 2>/dev/null || true
fi

if [[ $RAG_NEEDS_FIX -eq 1 ]]; then
  log "Pinning only the companion RAG environment to MCP 1.30.0..."
  uv pip install --python "$RAG_PY" "mcp==1.30.0" || die "RAG MCP repair failed."
  uv pip freeze --python "$RAG_PY" > "$BAK/rag-packages-after.txt" 2>/dev/null || true
fi

FIX_EPOCH="$(date +%s)"
[[ -n "$RAG_SERVICE" ]] && systemctl start "$RAG_SERVICE"
for svc in "${CORE_SERVICES[@]}"; do systemctl start "$svc"; done
SERVICES_STOPPED=0
trap - EXIT INT TERM

log "Verifying exact service interpreters..."
"$CORE_DIR/.venv/bin/python" - <<'PY'
import importlib, sys
assert sys.version_info[:2] == (3, 14), sys.version
for name in ["ruamel.yaml", "openai", "fastapi", "uvicorn", "httpx", "pydantic", "hermes_cli.main"]:
    importlib.import_module(name)
print("core imports: OK")
PY
if [[ $HAS_RAG -eq 1 ]]; then
  "$RAG_PY" - <<'PY'
import importlib, importlib.metadata
assert importlib.metadata.version("mcp") == "1.30.0"
importlib.import_module("mcp.server.fastmcp")
importlib.import_module("hermes_rag.mcp_server")
print("RAG imports: OK")
PY
fi

wait_http() {
  local url="$1" expected="${2:-200}" code="000"
  # First boot after rebuilding the venv can take longer while Hermes creates
  # its local state and warms imports. systemd may be active before port 9119
  # is listening, so allow up to two minutes instead of reporting a false fail.
  for _ in {1..60}; do
    code="$(curl -sS --connect-timeout 2 -m 5 -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || true)"
    [[ "$code" == "$expected" ]] && return 0
    sleep 2
  done
  warn "$url returned HTTP $code (expected $expected)"
  return 1
}

for svc in "${CORE_SERVICES[@]}"; do systemctl is-active --quiet "$svc" || die "$svc is not active."; done
[[ -n "$RAG_SERVICE" ]] && systemctl is-active --quiet "$RAG_SERVICE" || [[ -z "$RAG_SERVICE" ]] || die "$RAG_SERVICE is not active."
wait_http "http://127.0.0.1:9119/" 200 || die "Dashboard verification failed."
wait_http "http://127.0.0.1:9119/api/status" 200 || die "Dashboard API verification failed."
if service_exists hermes-mgmt; then
  systemctl is-active --quiet hermes-mgmt || die "hermes-mgmt is not active."
  wait_http "http://127.0.0.1:9997/health" 200 || die "Management API verification failed."
fi

if [[ $HAS_RAG -eq 1 ]]; then
  rag_code="$(curl -sS -m 10 -o "$BAK/rag-initialize-response.txt" -w '%{http_code}' \
    -X POST http://127.0.0.1:9998/mcp \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    --data '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"repair-check","version":"1.0"}}}' || true)"
  [[ "$rag_code" == "200" ]] || die "RAG initialize returned HTTP $rag_code."
  grep -q '"serverInfo"' "$BAK/rag-initialize-response.txt" || die "RAG initialize response lacks serverInfo."
fi

"$CORE_DIR/.venv/bin/python" - <<PY
import os, sqlite3
path = os.path.join(${HERMES_HOME@Q}, "state.db")
if os.path.exists(path):
    db = sqlite3.connect("file:" + path + "?mode=ro", uri=True)
    result = db.execute("PRAGMA quick_check").fetchone()[0]
    print("database quick_check:", result)
    if result != "ok":
        raise SystemExit(1)
else:
    print("database: not present (not modified by this script)")
PY

before=""
for svc in "${CORE_SERVICES[@]}"; do before+="$svc=$(systemctl show "$svc" -p NRestarts --value) "; done
[[ -n "$RAG_SERVICE" ]] && before+="$RAG_SERVICE=$(systemctl show "$RAG_SERVICE" -p NRestarts --value)"
sleep 10
after=""
for svc in "${CORE_SERVICES[@]}"; do after+="$svc=$(systemctl show "$svc" -p NRestarts --value) "; done
[[ -n "$RAG_SERVICE" ]] && after+="$RAG_SERVICE=$(systemctl show "$RAG_SERVICE" -p NRestarts --value)"
[[ "$before" == "$after" ]] || die "Restart counters increased: before=[$before] after=[$after]"

journal_args=()
for svc in "${CORE_SERVICES[@]}"; do journal_args+=("-u" "$svc"); done
[[ -n "$RAG_SERVICE" ]] && journal_args+=("-u" "$RAG_SERVICE")
fresh_errors="$(journalctl "${journal_args[@]}" --since "@$FIX_EPOCH" --no-pager -o cat 2>/dev/null | grep -Ei 'traceback|modulenotfound|no module named|failed with result' || true)"
[[ -z "$fresh_errors" ]] || die "Fresh service errors detected after repair: $fresh_errors"

log "Repair complete and verified."
log "Backup: $BAK"
log "No model/provider/credential/session/source configuration was changed."
