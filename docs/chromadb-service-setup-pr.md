# ChromaDB Native Service Setup — PR Description

> This file documents the changes made in this branch for your review.
> When you are ready to submit upstream, use the **Upstream PR Text** section below.

---

## Summary of Changes

### Problem

The native (non-Docker) install path had a gap: `requirements.txt` installs
`chromadb-client` (the HTTP-only client), but nothing tells users to also run a
ChromaDB server. Docker users get ChromaDB for free from Compose; native users
silently lose vector memory and Personal Docs RAG with no clear fix path.

The README troubleshooting section mentions the `chromadb-client` / `chromadb`
conflict but doesn't close the loop — it doesn't tell native users *how* to
start a server.

### What Was Added

**`scripts/install-chromadb-service.sh`** (new)

A setup helper script that mirrors the style of `scripts/check-docker-gpu.sh`:
- Read-only diagnostics by default; `--install` required for any changes
- Detects systemd `--user` session availability; prints manual instructions on
  non-systemd Linux, macOS, and Windows
- Installs `chromadb` globally via `uv tool install` if the `chroma` binary is
  not found (global install, not venv-scoped, so the server runs independently)
- Fills `@@CHROMA_BIN@@` / `@@DATA_DIR@@` placeholders in the unit template and
  installs to `~/.config/systemd/user/odysseus-chromadb.service`
- Runs `systemctl --user enable --now odysseus-chromadb` and waits up to 10s
  for port 8100 to open
- `--update-env` flag writes `CHROMADB_HOST` / `CHROMADB_PORT` to `.env` with a
  timestamped backup (same conservative pattern as `--enable-nvidia-overlay`)
- `--uninstall` cleanly stops and removes the service — with a safety check that
  the installed unit references *this* project's data directory, so it never
  stops a ChromaDB belonging to another application

**`odysseus-chromadb.service`** (new, project root)

A systemd user unit template sitting beside the existing `odysseus-ui.service`.
`Restart=on-failure` keeps the server alive. The install script fills in the
binary and data-directory paths before writing it to the user's systemd directory.

**`odysseus-ui.service`** (updated)

Added `Wants=odysseus-chromadb.service` and
`After=network.target odysseus-chromadb.service` so that when both services are
installed, ChromaDB starts first and Odysseus comes up after it.

**`setup.py`** (updated)

Added step 6 at the end of the interactive setup flow. It prompts the user
(Linux + systemd + interactive terminal only) whether they want to install
ChromaDB and/or Odysseus as systemd user services. Non-Linux, non-systemd, and
non-interactive runs skip this step silently — Docker, CI, and Windows setups
are unaffected.

**`src/chroma_client.py`** (updated)

Two small changes:

1. When ChromaDB is not reachable and the process is not running inside Docker,
   a `logger.warning` is emitted with an **OSC 8 terminal hyperlink** pointing
   to `scripts/install-chromadb-service.sh`. Modern terminals (GNOME Terminal,
   kitty, iTerm2, Windows Terminal) render this as a clickable link. The
   `RuntimeError` message is also updated to mention the native fix alongside
   the existing Docker instruction.

2. A single `# FUTURE(duckdb): swap HttpClient for a DuckDB-based vector backend here`
   comment is placed at the `chromadb.HttpClient()` call site to mark the
   backend-selection point for future contributors.

### What Was NOT Changed

- Docker behaviour is unchanged — `docker compose up chromadb` still works as before.
- `requirements.txt` still uses `chromadb-client` (the lightweight HTTP client),
  matching the intended Docker-first architecture. The `uv tool install chromadb`
  in the setup script installs the full server binary *globally*, separate from
  the project venv.
- No code auto-starts ChromaDB without user consent. The service is only
  installed if the user explicitly runs `install-chromadb-service.sh --install`
  or answers `y` to the `setup.py` prompt.
- No DuckDB implementation — comment only, marking the spot for a future PR.

---

## Upstream PR Text

Use this text verbatim when submitting to the original repo:

---

**Title:** `feat: native ChromaDB service setup for non-Docker installs`

**Body:**

### Problem

Native installs (`pip install -r requirements.txt && python setup.py`) install
`chromadb-client` but provide no guidance on running the ChromaDB server itself.
Docker users get ChromaDB from Compose; native users silently lose vector memory
and Personal Docs RAG with no clear fix path.

The README troubleshooting section mentions the `chromadb-client` / `chromadb`
conflict but does not close the loop — it doesn't tell native users how to start
a server.

### Solution

A minimal, opt-in setup path for native installs that mirrors the existing
`scripts/check-docker-gpu.sh` conventions:

- **`scripts/install-chromadb-service.sh`** — installs `chromadb` via `uv tool`
  (global, not venv-scoped), generates a filled-in systemd user unit, and enables
  it. Read-only diagnostics by default; `--install` required to make changes.
  `--uninstall` for clean removal (path-ownership safety check included).
  `--update-env` (with timestamped backup) writes `CHROMADB_HOST`/`CHROMADB_PORT`
  to `.env`.
- **`odysseus-chromadb.service`** — unit template beside `odysseus-ui.service`.
- **`odysseus-ui.service`** — adds `Wants=` / `After=odysseus-chromadb.service`
  so both services start together when Odysseus is installed as a service.
- **`setup.py`** — step 6 prompts (Linux + systemd + interactive only) to run
  either installer. Skipped silently elsewhere.
- **`src/chroma_client.py`** — OSC 8 terminal hyperlink hint in the warning when
  ChromaDB is unreachable on a native install; updated `RuntimeError` message;
  single `FUTURE(duckdb)` comment at the backend selection site.

### Non-goals / out of scope

- No changes to Docker behaviour.
- No auto-start of ChromaDB without user consent.
- No macOS launchd or Windows Task Scheduler support (logged as future work).
- No DuckDB implementation (comment only).

### Testing

```bash
# Diagnostics (read-only, safe to run anytime)
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
- [x] Works without sudo (systemd `--user`)
- [x] Skips silently on non-Linux / non-systemd / non-interactive
- [x] Uninstall is safe (path-ownership check prevents stopping foreign ChromaDB)
- [x] Docker path unchanged
- [x] No new required dependencies
- [x] Matches `check-docker-gpu.sh` script conventions

---

*Generated from branch on jeunjetta/odysseus. Original changes by @jeunjetta.*
