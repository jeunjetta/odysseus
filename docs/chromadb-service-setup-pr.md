# Native Service Setup (ChromaDB + Odysseus) — PR Description

> This file documents the changes made in this branch for your review.
> When you are ready to submit upstream, use the **Upstream PR Text** section below.

---

## Summary of Changes

### Problem

The native (non-Docker) install path had two gaps:

1. `requirements.txt` installs `chromadb-client` (the HTTP-only client), but
   nothing tells users to also run a ChromaDB server. Docker users get ChromaDB
   for free from Compose; native users silently lose vector memory and Personal
   Docs RAG with no clear fix path.

2. The existing `odysseus-ui.service` template had hardcoded `YOURUSER` and
   `/home/YOURUSER/odysseus-ui` placeholders requiring manual editing, and
   `install-service.sh` used `sudo systemctl` (system-wide). Neither were
   usable out of the box.

### What Was Added

**`scripts/install-chromadb-service.sh`** (new)

A setup helper script that mirrors the style of `scripts/check-docker-gpu.sh`:
- Read-only diagnostics by default; `--install` required for any changes
- Detects systemd `--user` session availability; prints manual instructions on
  non-systemd Linux, macOS, and Windows
- Installs `chromadb` globally via `uv tool install` if the `chroma` binary is
  not found (global install, not venv-scoped, so the server runs independently
  of the project venv)
- Fills `@@CHROMA_BIN@@` / `@@DATA_DIR@@` placeholders in `odysseus-chromadb.service`
  and installs to `~/.config/systemd/user/`
- Runs `systemctl --user enable --now odysseus-chromadb` and waits up to 10s
  for port 8100 to open
- `--update-env` flag writes `CHROMADB_HOST` / `CHROMADB_PORT` to `.env` with a
  timestamped backup (same conservative pattern as `--enable-nvidia-overlay` in
  `check-docker-gpu.sh`)
- `--uninstall` cleanly stops and removes the service — safety check ensures it
  only removes a unit that references *this* project's data directory, so it
  never stops a ChromaDB belonging to another application

**`odysseus-chromadb.service`** (new, project root)

A systemd user unit template with `@@CHROMA_BIN@@` and `@@DATA_DIR@@`
placeholders. `Restart=on-failure` keeps the server alive. Sits beside
`odysseus-ui.service` for consistency.

**`scripts/install-odysseus-service.sh`** (new)

Identical structure to `install-chromadb-service.sh`, for Odysseus itself:
- Auto-detects the project venv's `uvicorn` binary (falls back to PATH)
- Reads `APP_PORT` from `.env` if set (defaults to 7000)
- Fills `@@UVICORN_BIN@@` / `@@REPO_ROOT@@` / `@@APP_PORT@@` placeholders in
  `odysseus-ui.service` and installs to `~/.config/systemd/user/`
- Runs `systemctl --user enable --now odysseus-ui` and waits up to 15s for the
  port to open
- `--update-env` flag writes `APP_PORT` to `.env` with a timestamped backup
- `--uninstall` with path-ownership safety check (only removes if the installed
  unit references this project's working directory)

**`odysseus-ui.service`** (rewritten)

Replaced the old template (which had `YOURUSER` placeholders and required manual
editing) with a `@@`-placeholder template that `install-odysseus-service.sh`
fills in automatically. Also updated:
- Switched from `WantedBy=multi-user.target` to `WantedBy=default.target`
  (correct target for systemd user units)
- Added `Wants=odysseus-chromadb.service` and
  `After=network.target odysseus-chromadb.service` so ChromaDB starts first
  when both services are installed
- Added `EnvironmentFile=-@@REPO_ROOT@@/.env` so the service picks up `.env`
  settings on startup
- `Restart=on-failure` with `RestartSec=5`

**`setup.py`** (updated)

Added step 6 at the end of the interactive setup flow. It prompts the user
(Linux + systemd + interactive terminal only) whether they want to install
ChromaDB and/or Odysseus as systemd user services. Non-Linux, non-systemd, and
non-interactive runs skip this step silently — Docker, CI, and Windows are
unaffected. When the user says yes to the Odysseus service and it installs
successfully, the "Start the server with: uvicorn..." hint is suppressed, since
the service is already running.

**`src/chroma_client.py`** (updated)

Two small changes:

1. When ChromaDB is not reachable and the process is not running inside Docker,
   a `logger.warning` is emitted with an **OSC 8 terminal hyperlink** pointing
   to `scripts/install-chromadb-service.sh`. Modern terminals (GNOME Terminal,
   kitty, iTerm2, Windows Terminal) render this as a clickable link. The
   `RuntimeError` message is also updated to mention the native fix alongside
   the existing Docker instruction.

2. A single `# FUTURE(duckdb): swap HttpClient for a DuckDB-based vector backend here`
   comment at the `chromadb.HttpClient()` call site marks the backend-selection
   point for future contributors.

### What Was NOT Changed

- Docker behaviour is unchanged — `docker compose up chromadb` still works as before.
- `requirements.txt` still uses `chromadb-client` (the lightweight HTTP client),
  matching the intended Docker-first architecture. The `uv tool install chromadb`
  in the setup script installs the full server binary *globally*, separate from
  the project venv.
- No code auto-starts either service without user consent.
- The original `install-service.sh` is left in place (it is no longer called by
  `setup.py`, but is not removed in case users have existing scripts referencing it).
- No DuckDB implementation — comment only, marking the spot for a future PR.

---

## Upstream PR Text

Use this text verbatim when submitting to the original repo. Note: the original
repo targets the `dev` branch for PRs.

---

**Title:** `feat: native systemd user service setup for ChromaDB and Odysseus`

**Body:**

### Problem

Native installs (`pip install -r requirements.txt && python setup.py`) had two
gaps that left users worse off than Docker users:

1. `chromadb-client` is installed but no server is started — vector memory and
   Personal Docs RAG silently degrade with no fix path shown.
2. `odysseus-ui.service` had `YOURUSER` placeholders requiring manual editing,
   and `install-service.sh` required `sudo` for a system-wide install — neither
   usable out of the box for a typical single-user native install.

### Solution

Two new setup scripts that mirror the existing `scripts/check-docker-gpu.sh`
conventions (read-only by default, opt-in changes, timestamped `.env` backups,
`--uninstall` with safety checks), plus a rewritten `odysseus-ui.service`
template that fills itself in automatically:

- **`scripts/install-chromadb-service.sh`** — installs `chromadb` via `uv tool`
  (global, not venv-scoped), generates a filled-in systemd user unit, enables
  it. `--uninstall` with data-path ownership check.
- **`odysseus-chromadb.service`** — new unit template with `@@` placeholders.
- **`scripts/install-odysseus-service.sh`** — same structure for Odysseus itself:
  auto-detects venv uvicorn, reads `APP_PORT` from `.env`, fills
  `odysseus-ui.service` placeholders, enables service. `--uninstall` with
  working-directory ownership check.
- **`odysseus-ui.service`** — rewritten: `@@` placeholders, `WantedBy=default.target`,
  `Wants=`/`After=odysseus-chromadb.service`, `EnvironmentFile`, `Restart=on-failure`.
- **`setup.py`** — step 6 prompts (Linux + systemd + interactive only) to run
  either installer; suppresses the manual `uvicorn` start hint when the Odysseus
  service is successfully installed.
- **`src/chroma_client.py`** — OSC 8 terminal hyperlink hint when ChromaDB
  unreachable on a native install; updated `RuntimeError` message;
  `FUTURE(duckdb)` comment at backend selection site.

### Non-goals / out of scope

- No changes to Docker behaviour.
- No auto-start without user consent.
- No macOS launchd or Windows Task Scheduler support (future work).
- No DuckDB implementation (comment only).

### Testing

```bash
# Diagnostics (read-only, safe to run anytime)
scripts/install-chromadb-service.sh
scripts/install-odysseus-service.sh

# Full install (ChromaDB first, then Odysseus)
scripts/install-chromadb-service.sh --install
scripts/install-odysseus-service.sh --install

# Verify both services
systemctl --user status odysseus-chromadb odysseus-ui

# Verify Odysseus connects to ChromaDB
python -c "from src.chroma_client import get_chroma_client; print(get_chroma_client().heartbeat())"

# Or run setup.py interactively and answer y to both prompts
python setup.py

# Uninstall
scripts/install-odysseus-service.sh --uninstall
scripts/install-chromadb-service.sh --uninstall
```

### Checklist

- [x] Read-only by default, no surprises
- [x] Works without sudo (systemd `--user`)
- [x] Skips silently on non-Linux / non-systemd / non-interactive
- [x] Uninstall is safe (path-ownership checks prevent stopping foreign services)
- [x] Docker path unchanged
- [x] No new required dependencies
- [x] Matches `check-docker-gpu.sh` script conventions
- [x] `odysseus-ui.service` now zero-edit for a standard native install

---

*Generated from branch `feat/chromadb-service-setup` on jeunjetta/odysseus.*
