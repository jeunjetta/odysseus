#!/usr/bin/env bash
# install-chromadb-service.sh — Install ChromaDB as a systemd user service for
# native (non-Docker) Odysseus installs.
#
# Default mode is read-only diagnostics. Pass --install to actually install.
#
# USAGE
#   scripts/install-chromadb-service.sh              # diagnose only
#   scripts/install-chromadb-service.sh --install    # install + enable service
#   scripts/install-chromadb-service.sh --install --update-env   # also write .env
#   scripts/install-chromadb-service.sh --uninstall  # stop + disable + remove unit
#   scripts/install-chromadb-service.sh --help

set -euo pipefail

# ─── output helpers ──────────────────────────────────────────────────────────

PASS=0; FAIL=0; WARN=0
_pass() { printf '\033[32m[PASS]\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
_fail() { printf '\033[31m[FAIL]\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
_info() { printf '\033[34m[INFO]\033[0m %s\n' "$*"; }
_warn() { printf '\033[33m[WARN]\033[0m %s\n' "$*"; WARN=$((WARN+1)); }
_step() { printf '\033[36m[STEP]\033[0m %s\n' "$*"; }

# ─── paths ───────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
UNIT_TEMPLATE="${REPO_ROOT}/odysseus-chromadb.service"
UNIT_NAME="odysseus-chromadb"
SYSTEMD_USER_DIR="${HOME}/.config/systemd/user"
INSTALLED_UNIT="${SYSTEMD_USER_DIR}/${UNIT_NAME}.service"
DATA_DIR="${REPO_ROOT}/data"
ENV_FILE="${REPO_ROOT}/.env"
ENV_EXAMPLE="${REPO_ROOT}/.env.example"

# ─── arg parsing ─────────────────────────────────────────────────────────────

OPT_INSTALL=0
OPT_UNINSTALL=0
OPT_UPDATE_ENV=0

_usage() {
    cat <<'USAGE'
Usage: scripts/install-chromadb-service.sh [OPTIONS]

Options:
  --install       Install and enable the odysseus-chromadb systemd user service.
  --uninstall     Stop, disable, and remove the service (only if this project's
                  data directory is referenced in the installed unit).
  --update-env    Write CHROMADB_HOST and CHROMADB_PORT to .env (requires
                  --install; creates a timestamped backup first).
  --help          Show this help.

Default (no flags): diagnostics only — checks whether the service is installed,
chroma binary is available, and port 8100 is reachable. Never modifies anything.
USAGE
}

for arg in "$@"; do
    case "$arg" in
        --install)     OPT_INSTALL=1 ;;
        --uninstall)   OPT_UNINSTALL=1 ;;
        --update-env)  OPT_UPDATE_ENV=1 ;;
        --help|-h)     _usage; exit 0 ;;
        *) _fail "Unknown argument: $arg"; _usage; exit 1 ;;
    esac
done

if [ "${OPT_INSTALL}" -eq 1 ] && [ "${OPT_UNINSTALL}" -eq 1 ]; then
    _fail "--install and --uninstall are mutually exclusive."
    exit 1
fi

if [ "${OPT_UPDATE_ENV}" -eq 1 ] && [ "${OPT_INSTALL}" -eq 0 ]; then
    _fail "--update-env requires --install."
    exit 1
fi

# ─── platform check ──────────────────────────────────────────────────────────

echo "=== ChromaDB service setup (Odysseus) ==="
echo

_platform_ok=1

if [ "$(uname -s)" != "Linux" ]; then
    _warn "This script targets Linux + systemd."
    _info "On macOS: add a launchd plist or start chroma manually."
    _info "On Windows: add to Task Scheduler or run in a separate terminal."
    _info ""
    _info "Manual start command:"
    _info "  chroma run --host 127.0.0.1 --port 8100 --path ${DATA_DIR}/chroma"
    _platform_ok=0
fi

if [ "${_platform_ok}" -eq 1 ] && ! systemctl --user status >/dev/null 2>&1; then
    _warn "systemd user session not available on this system."
    _info "On Linux without systemd: run chroma in a tmux session or add to /etc/rc.local."
    _info ""
    _info "Manual start command:"
    _info "  chroma run --host 127.0.0.1 --port 8100 --path ${DATA_DIR}/chroma"
    _platform_ok=0
fi

if [ "${_platform_ok}" -eq 0 ]; then
    echo
    echo "=== Diagnostics only (non-systemd platform) ==="
    printf '[PASS] %d  [WARN] %d  [FAIL] %d\n' "${PASS}" "${WARN}" "${FAIL}"
    exit 0
fi

_pass "systemd user session available"

# ─── find or install chroma binary ───────────────────────────────────────────

CHROMA_BIN=""

# 1. Check PATH (covers uv tool installs and system packages)
if command -v chroma >/dev/null 2>&1; then
    CHROMA_BIN="$(command -v chroma)"
    _pass "chroma binary found: ${CHROMA_BIN}"
fi

# 2. Check uv tool location directly (may not be in PATH yet)
if [ -z "${CHROMA_BIN}" ] && [ -f "${HOME}/.local/bin/chroma" ]; then
    CHROMA_BIN="${HOME}/.local/bin/chroma"
    _pass "chroma binary found via uv tool path: ${CHROMA_BIN}"
fi

# 3. Install via uv tool if not found
if [ -z "${CHROMA_BIN}" ]; then
    if [ "${OPT_INSTALL}" -eq 0 ]; then
        _warn "chroma binary not found. Run with --install to install it via uv."
    else
        if ! command -v uv >/dev/null 2>&1; then
            _fail "uv not found. Install uv first: https://docs.astral.sh/uv/getting-started/installation/"
            exit 1
        fi
        _step "Installing chromadb via uv tool install (global, not project-scoped)..."
        uv tool install chromadb
        if [ -f "${HOME}/.local/bin/chroma" ]; then
            CHROMA_BIN="${HOME}/.local/bin/chroma"
            _pass "chromadb installed: ${CHROMA_BIN}"
        else
            _fail "uv tool install succeeded but chroma binary not found at ${HOME}/.local/bin/chroma"
            exit 1
        fi
    fi
fi

# ─── check current service state ─────────────────────────────────────────────

_service_installed=0
if [ -f "${INSTALLED_UNIT}" ]; then
    _service_installed=1
    _pass "Service unit already installed: ${INSTALLED_UNIT}"
else
    _info "Service unit not installed (${INSTALLED_UNIT} not found)"
fi

_port_open=0
if command -v nc >/dev/null 2>&1; then
    if nc -z 127.0.0.1 8100 2>/dev/null; then
        _port_open=1
        _pass "ChromaDB port 8100 is open (server is running)"
    else
        _info "ChromaDB port 8100 is not open (server not running)"
    fi
fi

# ─── uninstall ───────────────────────────────────────────────────────────────

if [ "${OPT_UNINSTALL}" -eq 1 ]; then
    echo
    echo "=== Uninstalling odysseus-chromadb service ==="
    echo
    if [ "${_service_installed}" -eq 0 ]; then
        _warn "Service unit not found — nothing to uninstall."
        exit 0
    fi
    # Safety: only stop if our unit references this project's data directory,
    # so we never stop a ChromaDB that belongs to another application.
    if ! grep -q "${DATA_DIR}" "${INSTALLED_UNIT}" 2>/dev/null; then
        _fail "The installed unit does not reference this project's data directory."
        _info "Remove manually if intended: rm ${INSTALLED_UNIT}"
        exit 1
    fi
    _step "Stopping and disabling ${UNIT_NAME}..."
    systemctl --user stop "${UNIT_NAME}" 2>/dev/null || true
    systemctl --user disable "${UNIT_NAME}" 2>/dev/null || true
    rm -f "${INSTALLED_UNIT}"
    systemctl --user daemon-reload
    _pass "Service removed: ${INSTALLED_UNIT}"
    echo
    printf '[PASS] %d  [WARN] %d  [FAIL] %d\n' "${PASS}" "${WARN}" "${FAIL}"
    exit 0
fi

# ─── install ─────────────────────────────────────────────────────────────────

if [ "${OPT_INSTALL}" -eq 0 ]; then
    echo
    echo "=== Diagnostics complete (read-only mode) ==="
    echo
    if [ -z "${CHROMA_BIN}" ]; then
        _info "Install ChromaDB and the service with:"
        _info "  scripts/install-chromadb-service.sh --install"
    elif [ "${_service_installed}" -eq 0 ]; then
        _info "Install the service with:"
        _info "  scripts/install-chromadb-service.sh --install"
    fi
    printf '[PASS] %d  [WARN] %d  [FAIL] %d\n' "${PASS}" "${WARN}" "${FAIL}"
    exit 0
fi

echo
echo "=== Installing odysseus-chromadb service ==="
echo

if [ ! -f "${UNIT_TEMPLATE}" ]; then
    _fail "Unit template not found: ${UNIT_TEMPLATE}"
    _info "Make sure you are running from the Odysseus project root."
    exit 1
fi

# Create systemd user directory if needed
mkdir -p "${SYSTEMD_USER_DIR}"

# Fill in template placeholders and write unit
sed \
    -e "s|@@CHROMA_BIN@@|${CHROMA_BIN}|g" \
    -e "s|@@DATA_DIR@@|${DATA_DIR}|g" \
    "${UNIT_TEMPLATE}" > "${INSTALLED_UNIT}"

_pass "Unit written: ${INSTALLED_UNIT}"

# Reload, enable, start
_step "Reloading systemd user daemon..."
systemctl --user daemon-reload

_step "Enabling and starting ${UNIT_NAME}..."
systemctl --user enable "${UNIT_NAME}"
systemctl --user start "${UNIT_NAME}"

# Wait up to 10s for port to open
_step "Waiting for ChromaDB to start (up to 10s)..."
_started=0
for i in $(seq 1 10); do
    if command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 8100 2>/dev/null; then
        _started=1
        break
    fi
    sleep 1
done

if [ "${_started}" -eq 1 ]; then
    _pass "ChromaDB is running on port 8100"
else
    _warn "Port 8100 is not open after 10s. Check the service log:"
    _info "  journalctl --user -u ${UNIT_NAME} -n 30"
fi

# ─── optional .env update ────────────────────────────────────────────────────

if [ "${OPT_UPDATE_ENV}" -eq 1 ]; then
    echo
    echo "=== Updating .env ==="
    echo
    if [ ! -f "${ENV_FILE}" ] && [ -f "${ENV_EXAMPLE}" ]; then
        cp "${ENV_EXAMPLE}" "${ENV_FILE}"
        _pass "Created .env from .env.example"
    fi
    if [ ! -f "${ENV_FILE}" ]; then
        _fail ".env not found and .env.example is missing — cannot update .env."
    else
        _backup_ts="$(date +%Y%m%d-%H%M%S)"
        _backup="${ENV_FILE}.bak.${_backup_ts}"
        cp "${ENV_FILE}" "${_backup}"
        _info "Backup created: .env.bak.${_backup_ts}"

        _write_or_update() {
            local _key="$1" _val="$2"
            if grep -q "^${_key}=" "${ENV_FILE}"; then
                local _tmp="${ENV_FILE}.tmp"
                sed "s|^${_key}=.*|${_key}=${_val}|" "${ENV_FILE}" > "${_tmp}" && mv "${_tmp}" "${ENV_FILE}"
                _pass "Updated ${_key}=${_val} in .env"
            else
                printf '\n%s=%s\n' "${_key}" "${_val}" >> "${ENV_FILE}"
                _pass "Added ${_key}=${_val} to .env"
            fi
        }

        _write_or_update "CHROMADB_HOST" "localhost"
        _write_or_update "CHROMADB_PORT" "8100"
    fi
fi

# ─── summary ─────────────────────────────────────────────────────────────────

echo
echo "=== Done ==="
echo
_info "Service status: systemctl --user status ${UNIT_NAME}"
_info "Service logs:   journalctl --user -u ${UNIT_NAME} -n 30"
_info "Stop:           systemctl --user stop ${UNIT_NAME}"
_info "Uninstall:      scripts/install-chromadb-service.sh --uninstall"
echo
printf '[PASS] %d  [WARN] %d  [FAIL] %d\n' "${PASS}" "${WARN}" "${FAIL}"
