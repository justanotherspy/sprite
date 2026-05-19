# Sprite Setup Scripts — CLAUDE.md

This repository contains bootstrap and verification scripts for [sprites.dev](https://sprites.dev) — stateful, hardware-isolated Linux sandboxes built on Fly.io. The scripts provision a fresh sprite into a fully configured development environment.

## Repository layout

```
setup.sh   — main bootstrap (run once on a fresh sprite)
pre.sh     — read-only preflight inspection (run BEFORE setup.sh)
post.sh    — read-only post-install verification (run AFTER setup.sh)
```

## What the scripts do

### `pre.sh`
Non-destructive snapshot of the sprite before any changes. Captures OS info, pre-installed tool versions, network egress reachability, rc files, SSH/git state, and sprite Services. Safe to run any number of times.

### `setup.sh`
Idempotent bootstrap that installs and configures:
- **APT packages**: shellcheck, bat, btop, direnv, fd-find, fzf, jq, mosh, ncdu, neovim, netcat-openbsd, ripgrep, traceroute, yq, xclip
- **uv** (Astral Python toolchain manager)
- **semgrep** (via `uv tool install`)
- **trufflehog** (secrets scanner)
- **Docker Engine** (docker-ce + buildx + compose plugins) + log-rotation daemon.json
- **dockerd sprite Service** (keeps Docker alive across sprite hibernation/wake cycles)
- **flyctl** (Fly.io CLI)
- SSH known_hosts for GitHub, optional SSH key generation
- Git global config (identity, aliases, sensible defaults)
- GitHub PAT as `GH_TOKEN` / `GITHUB_TOKEN` in shell rc files
- Shell PATH + alias block written idempotently to `.bashrc` and `.zshrc`

Sprites pre-install: `node`, `npm`, `deno`, `python3`, `bun`, `go`, `ruby`, `rustc`, `cargo`, `elixir`, `java`, `gh`, `claude`, `gemini`, `codex` — **do not reinstall these**.

### `post.sh`
Verification-only script that checks versions of everything `setup.sh` was supposed to install, runs functional smoke tests, and reports Docker daemon state, git config, SSH auth, rc file sentinels, and disk usage.

## Platform notes

- **No systemd**: sprites run under `tini` (PID 1). `systemctl enable --now` is skipped; Docker is kept alive via a sprite Service instead.
- **Overlay rootfs**: all installs persist on the sprite's filesystem across hibernation.
- **Pre-installed paths**: sprite toolchains live under `/.sprite/bin/` and `/.sprite/languages/`. Never shadow or reinstall them.
- **Script idempotency**: `setup.sh` is safe to re-run. APT steps are conditional; rc edits use sentinel markers to avoid duplication.

## Common tasks

- **Bootstrap a new sprite**: run `pre.sh` first to capture baseline, then `setup.sh`, then `post.sh` to verify.
- **Update the tool list**: edit the `apt-get install -y` block in `setup.sh` (section 2).
- **Add a new shell alias**: add it inside the `RC_BLOCK` heredoc in `setup.sh` (section 14).
- **Change the Docker daemon config**: edit the `daemon.json` heredoc in section 7 of `setup.sh`.
- **Add a sprite Service**: follow the pattern in section 7b of `setup.sh`.
- **Extend post-check smoke tests**: add a `sub` + command pair in `post.sh`.

