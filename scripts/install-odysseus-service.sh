#!/usr/bin/env bash
# install-odysseus-service.sh — Install Odysseus as a systemd user service.
#
# Default mode is read-only diagnostics. Pass --install to actually install.
#
# USAGE
#   scripts/install-odysseus-service.sh              # diagnose only
#   scripts/install-odysseus-service.sh --install    # install + enable service
#   scripts/install-odysseus-service.sh --install --update-env   # also write .env
#   scripts/install-odysseus-service.sh --uninstall  # stop + disable + remove unit
#   scripts/install-odysseus-service.sh --help

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
UNIT_TEMPLATE="${REPO_ROOT}/odysseus-ui.service"
UNIT_NAME="odysseus-ui"
SYSTEMD_USER_DIR="${HOME}/.config/systemd/user"
INSTALLED_UNIT="${SYSTEMD_USER_DIR}/${UNIT_NAME}.service"
ENV_FILE="${REPO_ROOT}/.env"
ENV_EXAMPLE="${REPO_ROOT}/.env.example"

# ─── arg parsing ─────────────────────────────────────────────────────────────

OPT_INSTALL=0
OPT_UNINSTALL=0
OPT_UPDATE_ENV=0

_usage() {
    cat <<'USAGE'
Usage: scripts/install-odysseus-service.sh [OPTIONS]

Options:
  --install       Install and enable the odysseus-ui systemd user service.
  --uninstall     Stop, disable, and remove the service (only if this project's
                  working directory is referenced in the installed unit).
  --update-env    Write APP_PORT to .env (requires --install; creates a
                  timestamped backup first).
  --help          Show this help.

Default (no flags): diagnostics only — checks whether the service is installed,
uvicorn is available, and what port Odysseus is configured to use. Never modifies
anything.
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

echo "=== Odysseus service setup ==="
echo

_platform_ok=1

if [ "$(uname -s)" != "Linux" ]; then
    _warn "This script targets Linux + systemd."
    _info "On macOS: use start-macos.sh or build-macos-app.sh."
    _info "On Windows: use launch-windows.ps1."
    _platform_ok=0
fi

if [ "${_platform_ok}" -eq 1 ] && ! systemctl --user status >/dev/null 2>&1; then
    _warn "systemd user session not available on this system."
    _info "Start Odysseus manually:"
    _info "  python -m uvicorn app:app --host 127.0.0.1 --port 7000"
    _platform_ok=0
fi

if [ "${_platform_ok}" -eq 0 ]; then
    echo
    echo "=== Diagnostics only (non-systemd platform) ==="
    printf '[PASS] %d  [WARN] %d  [FAIL] %d\n' "${PASS}" "${WARN}" "${FAIL}"
    exit 0
fi

_pass "systemd user session available"

# ─── find uvicorn binary ─────────────────────────────────────────────────────

UVICORN_BIN=""

# 1. Prefer the project venv
if [ -f "${REPO_ROOT}/.venv/bin/uvicorn" ]; then
    UVICORN_BIN="${REPO_ROOT}/.venv/bin/uvicorn"
    _pass "uvicorn found in project venv: ${UVICORN_BIN}"
elif [ -f "${REPO_ROOT}/venv/bin/uvicorn" ]; then
    UVICORN_BIN="${REPO_ROOT}/venv/bin/uvicorn"
    _pass "uvicorn found in project venv: ${UVICORN_BIN}"
fi

# 2. Fall back to PATH
if [ -z "${UVICORN_BIN}" ] && command -v uvicorn >/dev/null 2>&1; then
    UVICORN_BIN="$(command -v uvicorn)"
    _warn "uvicorn found in PATH (not the project venv): ${UVICORN_BIN}"
fi

if [ -z "${UVICORN_BIN}" ]; then
    _fail "uvicorn not found. Run: pip install -r requirements.txt"
    if [ "${OPT_INSTALL}" -eq 1 ]; then
        exit 1
    fi
fi

# ─── resolve app port ────────────────────────────────────────────────────────

APP_PORT="7000"
if [ -f "${ENV_FILE}" ]; then
    _env_port="$(grep '^APP_PORT=' "${ENV_FILE}" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '[:space:]' || true)"
    if [ -n "${_env_port}" ]; then
        APP_PORT="${_env_port}"
        _info "Using APP_PORT=${APP_PORT} from .env"
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
    if nc -z 127.0.0.1 "${APP_PORT}" 2>/dev/null; then
        _port_open=1
        _pass "Odysseus port ${APP_PORT} is open (server is running)"
    else
        _info "Odysseus port ${APP_PORT} is not open (server not running)"
    fi
fi

# ─── uninstall ───────────────────────────────────────────────────────────────

if [ "${OPT_UNINSTALL}" -eq 1 ]; then
    echo
    echo "=== Uninstalling odysseus-ui service ==="
    echo
    if [ "${_service_installed}" -eq 0 ]; then
        _warn "Service unit not found — nothing to uninstall."
        exit 0
    fi
    # Safety: only stop if our unit references this project's working directory,
    # so we never stop an Odysseus that belongs to a different install.
    if ! grep -q "${REPO_ROOT}" "${INSTALLED_UNIT}" 2>/dev/null; then
        _fail "The installed unit does not reference this project's directory."
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
    if [ "${_service_installed}" -eq 0 ]; then
        _info "Install the service with:"
        _info "  scripts/install-odysseus-service.sh --install"
    fi
    printf '[PASS] %d  [WARN] %d  [FAIL] %d\n' "${PASS}" "${WARN}" "${FAIL}"
    exit 0
fi

echo
echo "=== Installing odysseus-ui service ==="
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
    -e "s|@@UVICORN_BIN@@|${UVICORN_BIN}|g" \
    -e "s|@@REPO_ROOT@@|${REPO_ROOT}|g" \
    -e "s|@@APP_PORT@@|${APP_PORT}|g" \
    "${UNIT_TEMPLATE}" > "${INSTALLED_UNIT}"

_pass "Unit written: ${INSTALLED_UNIT}"

# Reload, enable, start
_step "Reloading systemd user daemon..."
systemctl --user daemon-reload

_step "Enabling and starting ${UNIT_NAME}..."
systemctl --user enable "${UNIT_NAME}"
systemctl --user start "${UNIT_NAME}"

# Wait up to 15s for port to open (Odysseus takes longer than ChromaDB to boot)
_step "Waiting for Odysseus to start (up to 15s)..."
_started=0
for i in $(seq 1 15); do
    if command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "${APP_PORT}" 2>/dev/null; then
        _started=1
        break
    fi
    sleep 1
done

if [ "${_started}" -eq 1 ]; then
    _pass "Odysseus is running on port ${APP_PORT}"
    _info "Open http://127.0.0.1:${APP_PORT}"
else
    _warn "Port ${APP_PORT} is not open after 15s. Check the service log:"
    _info "  journalctl --user -u ${UNIT_NAME} -n 40"
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

        _write_or_update "APP_PORT" "${APP_PORT}"
    fi
fi

# ─── summary ─────────────────────────────────────────────────────────────────

echo
echo "=== Done ==="
echo
_info "Service status: systemctl --user status ${UNIT_NAME}"
_info "Service logs:   journalctl --user -u ${UNIT_NAME} -n 40"
_info "Stop:           systemctl --user stop ${UNIT_NAME}"
_info "Uninstall:      scripts/install-odysseus-service.sh --uninstall"
echo
printf '[PASS] %d  [WARN] %d  [FAIL] %d\n' "${PASS}" "${WARN}" "${FAIL}"
