# ChromaDB Native Service Setup — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give native (non-Docker) Odysseus installs a first-class ChromaDB setup experience: a service install script, a systemd user unit template, setup.py prompts, and a helpful terminal link in `chroma_client.py` when ChromaDB is unreachable.

**Architecture:** `install-chromadb-service.sh` auto-fills paths and installs an `odysseus-chromadb` systemd user service (no sudo). `setup.py` prompts at step 6 (Linux + systemd only) to run either service installer. `chroma_client.py` emits an OSC 8 terminal hyperlink to the install script when the server is unreachable and we're not in Docker. The existing `odysseus-ui.service` template is updated to reference the new companion service.

**Tech Stack:** bash, Python 3.11, systemd `--user`, `uv tool install chromadb`, OSC 8 terminal hyperlinks.

---

## File Map

| Action | Path | Responsibility |
|--------|------|----------------|
| Create | `scripts/install-chromadb-service.sh` | Detect systemd, install `chroma` via uv, write + enable user unit, optional `--update-env` |
| Create | `odysseus-chromadb.service` | Systemd user unit template (project root, next to `odysseus-ui.service`) |
| Modify | `setup.py` | Step 6: interactive service-install prompts (Linux + systemd only) |
| Modify | `src/chroma_client.py` | OSC 8 hint link on connection failure; DuckDB future comment |
| Modify | `odysseus-ui.service` | Add `Wants=odysseus-chromadb.service` and `After=odysseus-chromadb.service` |
| Create | `docs/chromadb-service-setup-pr.md` | PR description + upstream submission text |

---

## Task 1: Create `odysseus-chromadb.service` template

**Files:**
- Create: `odysseus-chromadb.service`

- [ ] **Step 1: Write the service template**

```ini
# odysseus-chromadb.service
# Systemd user unit for the ChromaDB vector-store server used by Odysseus.
# install-chromadb-service.sh fills in @@CHROMA_BIN@@ and @@DATA_DIR@@
# and installs to ~/.config/systemd/user/. Do NOT edit the installed copy —
# re-run the script to regenerate it.
#
# Manual install:
#   scripts/install-chromadb-service.sh

[Unit]
Description=ChromaDB vector store (Odysseus companion)
After=network.target

[Service]
Type=simple
ExecStart=@@CHROMA_BIN@@ run --host 127.0.0.1 --port 8100 --path @@DATA_DIR@@/chroma
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
```

Save that exact content to `odysseus-chromadb.service` in the project root.

- [ ] **Step 2: Verify it parses as valid unit syntax**

```bash
systemd-analyze verify odysseus-chromadb.service 2>&1 || echo "placeholder tokens — expected warning, not an error"
```

Expected: warning about `@@` tokens but no hard parse error.

- [ ] **Step 3: Commit**

```bash
git add odysseus-chromadb.service
git commit -m "feat: add odysseus-chromadb.service systemd user unit template"
```

---

## Task 2: Create `scripts/install-chromadb-service.sh`

**Files:**
- Create: `scripts/install-chromadb-service.sh`

- [ ] **Step 1: Write the script**

```bash
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
  --uninstall     Stop, disable, and remove the service (only if installed by
                  this script via the project data path).
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

if [ ! -d /run/systemd/private ] && ! systemctl --user status >/dev/null 2>&1; then
    _warn "systemd user session not available on this system."
    _info "On macOS: add a launchd plist or start chroma manually."
    _info "On Windows: add to Task Scheduler or run in a separate terminal."
    _info "On Linux without systemd: run chroma in a tmux session or add to /etc/rc.local."
    _info ""
    _info "Manual start command:"
    _info "  chroma run --host 127.0.0.1 --port 8100 --path ${DATA_DIR}/chroma"
    _platform_ok=0
fi

if [ "$(uname -s)" != "Linux" ]; then
    _warn "This script targets Linux + systemd. See manual instructions above."
    _platform_ok=0
fi

if [ "${_platform_ok}" -eq 0 ]; then
    echo
    echo "=== Diagnostics only (non-systemd platform) ==="
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

# 2. Check uv tool location directly
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
    # Safety: only stop if our unit's ExecStart path contains this repo's data dir
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
    printf '\n[PASS] %d  [WARN] %d  [FAIL] %d\n' "${PASS}" "${WARN}" "${FAIL}"
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

# Create systemd user directory
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
```

Save that content to `scripts/install-chromadb-service.sh`.

- [ ] **Step 2: Make executable**

```bash
chmod +x scripts/install-chromadb-service.sh
```

- [ ] **Step 3: Verify help text runs without error**

```bash
scripts/install-chromadb-service.sh --help
```

Expected: usage text printed, exit 0.

- [ ] **Step 4: Verify diagnostics mode (no install)**

```bash
scripts/install-chromadb-service.sh
```

Expected: `[PASS]`/`[WARN]`/`[INFO]` lines, no file changes, exit 0.

- [ ] **Step 5: Commit**

```bash
git add scripts/install-chromadb-service.sh
git commit -m "feat: add install-chromadb-service.sh for native systemd user setup"
```

---

## Task 3: Update `src/chroma_client.py`

**Files:**
- Modify: `src/chroma_client.py`

- [ ] **Step 1: Replace the connection-failure block and add DuckDB comment**

Open `src/chroma_client.py`. Replace the block starting at the `if not _port_open(host, port):` check through `client = chromadb.HttpClient(host=host, port=port)` with the following:

```python
    if not _port_open(host, port):
        # Emit an actionable hint for native (non-Docker) installs.
        # OSC 8 hyperlinks are rendered as clickable links in modern terminals
        # (GNOME Terminal, kitty, iTerm2, Windows Terminal, etc.).
        _in_docker = os.path.exists("/.dockerenv")
        if not _in_docker:
            try:
                with open("/proc/1/cgroup", "r", encoding="utf-8", errors="ignore") as _fh:
                    _in_docker = any(m in _fh.read() for m in ("docker", "containerd", "kubepods"))
            except Exception:
                pass
        if not _in_docker:
            _script = os.path.join(
                os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                "scripts", "install-chromadb-service.sh",
            )
            _link = f"\033]8;;file://{_script}\033\\scripts/install-chromadb-service.sh\033]8;;\033\\"
            logger.warning(
                "ChromaDB not reachable at %s:%s — for native installs, set up "
                "the service with: %s",
                host, port, _link,
            )
        raise RuntimeError(
            f"ChromaDB is not reachable at {host}:{port}. "
            f"Docker users: `docker compose up chromadb`. "
            f"Native users: run scripts/install-chromadb-service.sh --install "
            f"or set CHROMADB_HOST / CHROMADB_PORT to point at a running instance."
        )

    # FUTURE(duckdb): swap HttpClient for a DuckDB-based vector backend here
    client = chromadb.HttpClient(host=host, port=port)
```

The complete `get_chroma_client()` function should now look like:

```python
def get_chroma_client():
    """Get or create the singleton ChromaDB HTTP client.

    Raises RuntimeError with a clear install hint if the `chromadb` package
    is not installed — it's an optional dependency (RAG + memory vectors).
    """
    global _client
    if _client is not None:
        return _client

    try:
        import chromadb
    except ImportError as e:
        raise RuntimeError(
            "ChromaDB integration is not installed. Install the optional "
            "dependency with: pip install chromadb-client"
        ) from e

    host = os.getenv("CHROMADB_HOST", "localhost")
    port = int(os.getenv("CHROMADB_PORT", "8100"))

    if not _port_open(host, port):
        _in_docker = os.path.exists("/.dockerenv")
        if not _in_docker:
            try:
                with open("/proc/1/cgroup", "r", encoding="utf-8", errors="ignore") as _fh:
                    _in_docker = any(m in _fh.read() for m in ("docker", "containerd", "kubepods"))
            except Exception:
                pass
        if not _in_docker:
            _script = os.path.join(
                os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                "scripts", "install-chromadb-service.sh",
            )
            _link = f"\033]8;;file://{_script}\033\\scripts/install-chromadb-service.sh\033]8;;\033\\"
            logger.warning(
                "ChromaDB not reachable at %s:%s — for native installs, set up "
                "the service with: %s",
                host, port, _link,
            )
        raise RuntimeError(
            f"ChromaDB is not reachable at {host}:{port}. "
            f"Docker users: `docker compose up chromadb`. "
            f"Native users: run scripts/install-chromadb-service.sh --install "
            f"or set CHROMADB_HOST / CHROMADB_PORT to point at a running instance."
        )

    # FUTURE(duckdb): swap HttpClient for a DuckDB-based vector backend here
    client = chromadb.HttpClient(host=host, port=port)

    client.heartbeat()
    _client = client
    logger.info(f"ChromaDB connected: {host}:{port}")
    return _client
```

- [ ] **Step 2: Verify the file parses cleanly**

```bash
.venv/bin/python -c "import src.chroma_client; print('ok')"
```

Expected: `ok`

- [ ] **Step 3: Verify the warning fires when port is closed**

```bash
.venv/bin/python -c "
import logging, os
logging.basicConfig(level=logging.WARNING)
os.environ['CHROMADB_PORT'] = '19999'  # nothing listening here
try:
    from src.chroma_client import get_chroma_client, reset_client
    reset_client()
    get_chroma_client()
except RuntimeError as e:
    print('RuntimeError (expected):', e)
"
```

Expected: a `WARNING` log line mentioning `scripts/install-chromadb-service.sh`, then `RuntimeError (expected): ChromaDB is not reachable...`

- [ ] **Step 4: Commit**

```bash
git add src/chroma_client.py
git commit -m "fix(chroma_client): add OSC8 hint link and DuckDB future comment"
```

---

## Task 4: Update `setup.py` with service prompts

**Files:**
- Modify: `setup.py`

- [ ] **Step 1: Add the service-prompt function before `main()`**

Insert the following function immediately before the `def main():` line in `setup.py`:

```python
def _systemd_user_available() -> bool:
    """Return True if systemd --user session is available on this Linux host."""
    if sys.platform != "linux":
        return False
    import subprocess
    try:
        result = subprocess.run(
            ["systemctl", "--user", "status"],
            capture_output=True, timeout=5
        )
        return result.returncode in (0, 3)  # 0=running, 3=degraded but available
    except Exception:
        return False


def prompt_service_install():
    """Offer to install ChromaDB (and Odysseus) as systemd user services.

    Only runs on Linux with a live systemd user session and only when
    stdin is an interactive terminal.
    """
    if not sys.stdin.isatty():
        return
    if not _systemd_user_available():
        return

    import subprocess

    print()
    print("6. Service setup (systemd --user)...")
    print("   Installing as a service means ChromaDB and/or Odysseus")
    print("   start automatically when you log in — no manual `chroma run` needed.")
    print()

    script_dir = os.path.join(BASE_DIR, "scripts")
    chroma_script = os.path.join(script_dir, "install-chromadb-service.sh")
    odysseus_script = os.path.join(BASE_DIR, "install-service.sh")

    # ChromaDB service
    ans_chroma = input("   Install ChromaDB as a systemd user service? [y/N] ").strip().lower()
    if ans_chroma in ("y", "yes"):
        if os.path.exists(chroma_script):
            print("   Running install-chromadb-service.sh --install ...")
            result = subprocess.run(
                ["bash", chroma_script, "--install"],
                cwd=BASE_DIR
            )
            if result.returncode == 0:
                print("  [ok] ChromaDB service installed")
            else:
                print("  [warn] ChromaDB service install returned non-zero — check output above")
        else:
            print(f"  [warn] Script not found: {chroma_script}")

    # Odysseus service
    ans_odysseus = input("   Install Odysseus as a systemd user service? [y/N] ").strip().lower()
    if ans_odysseus in ("y", "yes"):
        if os.path.exists(odysseus_script):
            print("   Running install-service.sh ...")
            result = subprocess.run(
                ["bash", odysseus_script],
                cwd=BASE_DIR
            )
            if result.returncode == 0:
                print("  [ok] Odysseus service installed")
            else:
                print("  [warn] Odysseus service install returned non-zero — check output above")
        else:
            print(f"  [warn] Script not found: {odysseus_script}")
```

- [ ] **Step 2: Add the call to `prompt_service_install()` at the end of `main()`**

Inside `main()`, after the existing step 5 admin block and before `print("\n=== Setup complete ===")`, add:

```python
    try:
        prompt_service_install()
    except Exception as e:
        print(f"  [warn] Service setup prompt failed: {e}")
```

The tail of `main()` should look like:

```python
    print("\n5. Creating initial admin...")
    admin_status = "failed"
    try:
        admin_status = create_default_admin()
    except Exception as e:
        print(f"  [warn] Admin creation failed: {e}")
        admin_status = "failed"

    try:
        prompt_service_install()
    except Exception as e:
        print(f"  [warn] Service setup prompt failed: {e}")

    print("\n=== Setup complete ===")
    # ... rest of main() unchanged ...
```

- [ ] **Step 3: Verify setup.py still parses cleanly**

```bash
.venv/bin/python -c "import setup; print('ok')"
```

Expected: `ok`

- [ ] **Step 4: Verify non-interactive path skips the prompt silently**

```bash
echo "" | .venv/bin/python setup.py 2>&1 | tail -10
```

Expected: setup completes, no service prompt output (stdin is not a tty when piped).

- [ ] **Step 5: Commit**

```bash
git add setup.py
git commit -m "feat(setup): prompt to install chromadb and odysseus systemd user services"
```

---

## Task 5: Update `odysseus-ui.service` template

**Files:**
- Modify: `odysseus-ui.service`

- [ ] **Step 1: Add ChromaDB dependency lines**

The current `[Unit]` section is:

```ini
[Unit]
Description=Odysseus UI
After=network.target
```

Replace it with:

```ini
[Unit]
Description=Odysseus UI
After=network.target odysseus-chromadb.service
Wants=odysseus-chromadb.service
```

- [ ] **Step 2: Verify the file still has valid unit structure**

```bash
grep -E "^\[|^Description|^After|^Wants|^Type|^User|^Working|^ExecStart|^Restart|^WantedBy" odysseus-ui.service
```

Expected: all key fields printed in order.

- [ ] **Step 3: Commit**

```bash
git add odysseus-ui.service
git commit -m "feat: odysseus-ui.service wants odysseus-chromadb.service companion"
```

---

## Task 6: Write the PR description document

**Files:**
- Create: `docs/chromadb-service-setup-pr.md`

- [ ] **Step 1: Write the document**

```markdown
# ChromaDB Native Service Setup — PR Description

> This file documents the changes made in this branch for your review.
> When you are ready to submit upstream, use the "Upstream PR Text" section below.

## Summary of Changes

### Problem
The native (non-Docker) install path in Odysseus had a gap: `requirements.txt` installs `chromadb-client`
(the HTTP-only client), but no documentation or tooling told users to also run a ChromaDB server.
Docker users got ChromaDB for free via Compose; native users silently lost vector memory and Personal Docs RAG.

### What Was Added

**`scripts/install-chromadb-service.sh`**
A new setup helper script (mirroring the style of `scripts/check-docker-gpu.sh`) that:
- Detects systemd user session availability
- Installs `chromadb` globally via `uv tool install` if the `chroma` binary is not found
- Fills path placeholders in `odysseus-chromadb.service` and installs it to `~/.config/systemd/user/`
- Runs `systemctl --user enable --now odysseus-chromadb`
- Optionally writes `CHROMADB_HOST` / `CHROMADB_PORT` to `.env` via `--update-env` (with timestamped backup)
- Has `--uninstall` to cleanly remove the service (safety check: only removes if the unit references this project's data dir)
- Read-only diagnostics by default; `--install` required for any changes

**`odysseus-chromadb.service`**
A systemd user unit template (project root, beside `odysseus-ui.service`) with `@@CHROMA_BIN@@` and
`@@DATA_DIR@@` placeholders filled by the install script. `Restart=on-failure` keeps the server alive.

**`odysseus-ui.service`** (updated)
Added `Wants=odysseus-chromadb.service` and `After=... odysseus-chromadb.service` so that when
Odysseus is installed as a service, ChromaDB starts first automatically.

**`setup.py`** (updated)
Added step 6 at the end of the interactive setup flow: prompts the user (Linux + systemd only,
interactive terminal only) whether they want to install ChromaDB and/or Odysseus as systemd user services.
Non-Linux, non-systemd, and non-interactive runs skip this step silently.

**`src/chroma_client.py`** (updated)
- When ChromaDB is not reachable and the app is not running in Docker: emits a `logger.warning` with an
  OSC 8 terminal hyperlink to `scripts/install-chromadb-service.sh` (clickable in GNOME Terminal, kitty,
  iTerm2, Windows Terminal). The `RuntimeError` message is also updated to mention the native fix path.
- Added a single `# FUTURE(duckdb): swap HttpClient for a DuckDB-based vector backend here` comment at the
  `chromadb.HttpClient()` call site for future contributors.

### What Was NOT Changed
- Docker behaviour is unchanged — `docker compose up chromadb` still works exactly as before.
- `requirements.txt` still uses `chromadb-client` (the lightweight HTTP client), matching the intended
  Docker-first architecture. The `uv tool install chromadb` in the setup script installs the full server
  binary globally, separate from the project venv.
- No code auto-starts ChromaDB without user consent. The service is only installed if the user explicitly
  runs `install-chromadb-service.sh --install` or answers `y` to the `setup.py` prompt.

---

## Upstream PR Text

Use this text verbatim when submitting to the original repo:

---

**Title:** `feat: native ChromaDB service setup for non-Docker installs`

**Body:**

### Problem

Native installs (`pip install -r requirements.txt && python setup.py`) install `chromadb-client`
but provide no guidance on running the ChromaDB server itself. Docker users get ChromaDB from Compose;
native users silently lose vector memory and Personal Docs RAG with no clear fix path.

The README troubleshooting section mentions the `chromadb-client` / `chromadb` conflict but doesn't
close the loop: it doesn't tell native users *how* to start a server.

### Solution

A minimal, opt-in setup path for native installs that mirrors the existing `scripts/check-docker-gpu.sh`
conventions:

- **`scripts/install-chromadb-service.sh`** — installs `chromadb` via `uv tool` (global, not venv-scoped),
  generates a filled-in systemd user unit, and enables it. Read-only diagnostics by default; `--install`
  required to make changes. `--uninstall` for clean removal. `--update-env` (with backup) to write
  `CHROMADB_HOST`/`CHROMADB_PORT` to `.env`.
- **`odysseus-chromadb.service`** — unit template (beside `odysseus-ui.service`).
- **`odysseus-ui.service`** — adds `Wants=` / `After=odysseus-chromadb.service` so both services start
  together when Odysseus is installed as a service.
- **`setup.py`** — step 6 prompts (Linux + systemd + interactive only) to run either installer. Skipped
  silently elsewhere.
- **`src/chroma_client.py`** — OSC 8 terminal hyperlink hint in the warning when ChromaDB is unreachable
  on a native install; updated `RuntimeError` message; single `FUTURE(duckdb)` comment at the backend
  selection site.

### Non-goals / out of scope

- No changes to Docker behaviour.
- No auto-start of ChromaDB without user consent.
- No macOS launchd or Windows Task Scheduler support (logged as future work).
- No DuckDB implementation (comment only).

### Testing

```bash
# Diagnostics (read-only)
scripts/install-chromadb-service.sh

# Full install
scripts/install-chromadb-service.sh --install

# Verify service
systemctl --user status odysseus-chromadb
journalctl --user -u odysseus-chromadb -n 20

# Verify Odysseus connects
python -c "from src.chroma_client import get_chroma_client; print(get_chroma_client().heartbeat())"

# Uninstall
scripts/install-chromadb-service.sh --uninstall
```

### Checklist
- [x] Read-only by default, no surprises
- [x] Works without sudo
- [x] Skips silently on non-Linux / non-systemd / non-interactive
- [x] Uninstall is clean and safe (path-ownership check)
- [x] Docker path unchanged
- [x] No new required dependencies
```

- [ ] **Step 2: Commit**

```bash
git add docs/chromadb-service-setup-pr.md
git commit -m "docs: add PR description for chromadb native service setup"
```

---

## Task 7: End-to-end test and debug loop

**Files:** none (testing only)

- [ ] **Step 1: Run diagnostics mode**

```bash
scripts/install-chromadb-service.sh
```

Expected: PASS/INFO/WARN lines, no errors. Note whether `chroma` binary is found.

- [ ] **Step 2: Run install (installs uv tool if needed)**

```bash
scripts/install-chromadb-service.sh --install
```

Expected: `chroma` is installed or found, unit is written to `~/.config/systemd/user/odysseus-chromadb.service`, service is started, `[PASS] ChromaDB is running on port 8100`.

- [ ] **Step 3: Verify the service is active**

```bash
systemctl --user status odysseus-chromadb
```

Expected: `Active: active (running)`.

- [ ] **Step 4: Verify `chroma_client.py` connects**

```bash
.venv/bin/python -c "
from src.chroma_client import get_chroma_client, reset_client
reset_client()
c = get_chroma_client()
print('heartbeat:', c.heartbeat())
"
```

Expected: `heartbeat: {'nanosecond heartbeat': <number>}` (or similar dict).

- [ ] **Step 5: Verify warning+link fires when server is down**

```bash
systemctl --user stop odysseus-chromadb
sleep 1
.venv/bin/python -c "
import logging, os
logging.basicConfig(level=logging.WARNING)
os.environ['CHROMADB_PORT'] = '8100'
try:
    from src.chroma_client import get_chroma_client, reset_client
    reset_client()
    get_chroma_client()
except RuntimeError as e:
    print('RuntimeError (expected):', str(e)[:80])
"
systemctl --user start odysseus-chromadb
```

Expected: `WARNING` line mentioning `scripts/install-chromadb-service.sh`, then RuntimeError message mentioning `--install`.

- [ ] **Step 6: Verify uninstall is safe**

```bash
scripts/install-chromadb-service.sh --uninstall
systemctl --user status odysseus-chromadb 2>&1 | head -3
```

Expected: service is stopped/removed.

- [ ] **Step 7: Reinstall for the final state**

```bash
scripts/install-chromadb-service.sh --install
systemctl --user status odysseus-chromadb | grep -E "Active|running"
```

Expected: `Active: active (running)`.

- [ ] **Step 8: Fix any failures and re-run steps 1–7**

If any step fails, fix the relevant file, re-run `git add` + `git commit --amend` or a new commit, and repeat.

---

## Task 8: Final commit, push, and PR

- [ ] **Step 1: Check git status is clean**

```bash
git status
git log --oneline -8
```

Expected: working tree clean, last 5–6 commits are the feature commits above.

- [ ] **Step 2: Push to origin (jeunjetta fork)**

```bash
git push origin main
```

Expected: push succeeds to `https://github.com/jeunjetta/odysseus.git`.

- [ ] **Step 3: Verify push succeeded**

```bash
git log --oneline origin/main -5
```

Expected: commits are visible on remote.

- [ ] **Step 4: Done**

The branch is now pushed to your fork. When you are ready to submit upstream, use the PR text in
`docs/chromadb-service-setup-pr.md`.

---

## Self-Review Checklist

- [x] `odysseus-chromadb.service` template created with placeholders — Task 1
- [x] `install-chromadb-service.sh` created with diagnostics, install, uninstall, --update-env — Task 2
- [x] `chroma_client.py` OSC 8 hint + RuntimeError message + DuckDB comment — Task 3
- [x] `setup.py` step 6 with both prompts, systemd guard, non-interactive guard — Task 4
- [x] `odysseus-ui.service` Wants/After updated — Task 5
- [x] PR description document — Task 6
- [x] End-to-end test loop — Task 7
- [x] Push + PR instructions — Task 8
- [x] No placeholders or TBDs in any task
- [x] All code blocks are complete and runnable
- [x] Function/variable names consistent across tasks
