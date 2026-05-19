# sprite

Personal dev-environment bootstrap for [sprite.dev](https://sprite.dev) sprites.
Targets Ubuntu 25.10 (questing) on a sprite running with tini as PID 1 (no
systemd). The base sprite image already provides language toolchains and the
sprite CLI; this repo handles everything else: editor tooling, security
scanners, container engine, git/ssh identity, shell rc, and a verify pass.

Maintainer: Daniel Schwartz (`justanotherspy`)

## Quick start

On a fresh sprite, run:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/justanotherspy/sprite/main/setup.sh)
```

Or, after the repo is cloned to `~/repos/sprite`:

```bash
cd ~/repos/sprite
./setup.sh                  # full run (idempotent; safe to re-run)
./setup.sh --force          # redo every phase
./setup.sh --only docker    # run a single phase
./setup.sh --status         # show state file as a table, no work performed
./post.sh                   # standalone verification (same as inline verify)
```

## Entry points

| File | Role |
|------|------|
| `setup.sh` | Phase-based bootstrap. Runs every phase, then a final `verify` phase. |
| `post.sh` | Thin wrapper that sources `_lib_verify.sh` and runs the same verify pass standalone. |
| `_lib_verify.sh` | Sourceable verification library. Used by both `setup.sh` (inline) and `post.sh`. |
| `pre.sh` | Reference-only. Captures the pre-setup state of the sprite for comparison. Not invoked by setup. |

## Phases (in execution order)

The bootstrap runs roughly in dependency order: apt packages, language
toolchains, language-scoped tool installers (uv, corepack), binary releases,
container engine, identity, GitHub, repos, shell rc, and finally verify.

```
apt_core
corepack node_lts go_toolchain rust_toolchain
uv black garlic pre_commit ruff semgrep
cosign trufflehog dive gitleaks hadolint
docker dockerd_service flyctl
claude_upgrade claude_settings
pre_commit_template gitignore_global
ssh_known_hosts git_identity ssh_key
gh_auth gh_upload_keys git_signing
clone_repos garlic_defaults
ps1 zsh_completions rc_additions
verify
```

Two "bracket" phases run outside the main loop and are never aborting:

* `pre_checkpoint` (before the first phase): `sprite-env checkpoints create --comment "pre-setup-<ts>"`
* `post_checkpoint` (after verify):           `sprite-env checkpoints create --comment "post-setup-<ts>"`

If `sprite-env` is missing or the call fails, they log a warning and continue.
sprite-env auto-assigns the checkpoint ID (`v0`, `v1`, `v2`, and so on);
the `--comment` label is how you find the right one in
`sprite-env checkpoints list`.

### What each phase does (compressed)

| Phase | What it installs / configures |
|-------|--------------------------------|
| `apt_core` | All `apt` packages we depend on, plus `bat -> batcat` and `fd -> fdfind` symlinks in `~/.local/bin/`. Uses `tealdeer` for the `tldr` command (the older `tldr` apt package is not in questing). |
| `corepack` | Enables corepack and shims `pnpm` + `yarn` into `~/.local/bin`. |
| `node_lts` | Sources sprite's nvm, runs `nvm install --lts` only if not already on the LTS major (currently 22.x). |
| `go_toolchain` | Trusts the sprite-provided `go` and skips by design. Listed for visibility in `--status`. |
| `rust_toolchain` | Pins `stable` as default, ensures `clippy`, `rustfmt`, `rust-analyzer` are installed. |
| `uv` | Installs Astral's `uv`. |
| `black`, `garlic`, `pre_commit`, `ruff`, `semgrep` | All installed via `uv tool install <pkg>`. |
| `cosign`, `trufflehog`, `dive`, `gitleaks`, `hadolint` | Binary releases from GitHub. `trufflehog` requires `cosign` (signature verification on install). |
| `docker` | Installs Docker CE from the official apt repo, writes `/etc/docker/daemon.json`, adds the user to the `docker` group. |
| `dockerd_service` | Registers `dockerd` as a sprite-env Service so it survives hibernation. |
| `flyctl` | Installs `flyctl` to `~/.fly/bin`. |
| `claude_upgrade` | `claude upgrade`. |
| `claude_settings` | Writes `tui: "fullscreen"` to `~/.claude/settings.json`. |
| `pre_commit_template` | Writes `~/.config/pre-commit/.pre-commit-config.template.yaml` (ruff, black, shellcheck, semgrep, gitleaks, trufflehog). Copy it into a repo and run `pre-commit install`. |
| `gitignore_global` | Writes `~/.gitignore_global` and wires `git config --global core.excludesFile` to it. |
| `ssh_known_hosts` | Pre-loads `github.com` host keys. |
| `git_identity` | Sets `user.name`, `user.email`, `init.defaultBranch`, `pull.rebase`, aliases, and so on. |
| `ssh_key` | Generates an ed25519 key (idempotent; `--force` rotates with a `.bak.<ts>` suffix). |
| `gh_auth` | Authenticates `gh` to github.com with `admin:public_key` + `admin:ssh_signing_key` scopes. Uses `$SPRITE_GH_TOKEN` if set, otherwise device-code flow. |
| `gh_upload_keys` | Uploads the ed25519 pub as both an auth key and a signing key, then retries `ssh -T git@github.com` until propagated. |
| `git_signing` | Configures SSH commit signing using the same key. Writes `~/.ssh/allowed_signers`. |
| `clone_repos` | Clones the four canonical repos under `~/repos/`. |
| `garlic_defaults` | Runs `garlic setup --defaults -y`. Installs Claude hooks, the `/garlic` slash command, the nudge-relay `CLAUDE.md` instruction, and resets garlic's config to defaults. Idempotent. Sentinel: `~/.config/sprite-setup/garlic-defaults.applied`. |
| `ps1` | Writes `~/.local/share/sprite-setup/ps1.sh` (vcs_info prompt, bash + zsh, no external deps). RC_BLOCK sources it. |
| `zsh_completions` | Generates `~/.zsh/completions/_<tool>` for gh, flyctl, uv, cosign, garlic, pre-commit. RC_BLOCK adds the dir to `fpath` and runs `compinit`. |
| `rc_additions` | Writes a single sentinel-delimited block to `~/.bashrc` and `~/.zshrc` (aliases, direnv hook, zoxide init, fzf keybindings, fpath, GH_TOKEN derivation). |
| `verify` | Sources `_lib_verify.sh` in a subshell and runs the same suite as `post.sh`. Fails the run if any check fails. |

## CLI flags

```
./setup.sh [--force] [--only PHASE] [--status] [-h|--help]
```

* `--force`: redo every phase even if its idempotency check passes.
* `--only PHASE`: run a single phase. Useful for debugging a failure.
* `--status`: dump phase state from `$STATE_FILE` as a table and exit (no work performed).
* `-h`, `--help`: print usage.

## State file

`setup.sh` writes a JSON state file at `~/.config/sprite-setup/state.json` after
every phase. Each phase entry records `last_run`, `success`, `did_work`,
`duration_s`, and `rc`. `--status` renders it as a table:

```
PHASE                   LAST RUN                RESULT   DID WORK   DURATION
apt_core                2026-05-19T14:30:00Z    ok       yes        12s
corepack                2026-05-19T14:30:00Z    ok       no         1s
docker                  2026-05-19T14:30:30Z    fail     no         30s
...
```

State is purely informational; phases never read it to decide whether to do
work (each phase has its own idempotency check based on filesystem / command
output / api state).

## Logs

* `LOG_FILE` (default `/tmp/dev-env-setup.log`): the full mirrored output of the run, with ANSI stripped.
* `$PHASE_LOG_DIR` (default `/tmp/dev-env-setup-phases`): one file per `quiet`-wrapped command. When a phase fails, setup.sh prints the last 40 lines from the relevant file and points you at the full path.

## Conventions

* Every phase is named `phase_<name>` and listed in the `PHASES` array.
* Every phase is idempotent: it should be safe to re-run.
* `ok` marks the current phase as having done work (drives the end-of-run summary). `note` records a passive observation without marking work done. `skip` records "already done, nothing to do."
* `quiet <label> <cmd>` runs a command with output captured to a per-label log file. **Always chain `|| return 1` after `quiet` if the command is required to succeed.** See "set -e suppression" below.
* Phases never write outside `$HOME` except where the system requires it (`/etc/docker`, `/etc/apt`).

## Notable design choices

* **Standalone files for ps1 and zsh completions.** `phase_ps1` writes
  `~/.local/share/sprite-setup/ps1.sh`, and `phase_zsh_completions` writes
  `~/.zsh/completions/_<tool>` files. `RC_BLOCK` only sources / fpaths them.
  This keeps the rc block scannable and lets you regenerate prompts or
  completions without touching rc files.

* **Two-file RC drift check.** `setup.sh` defines a `RC_BLOCK` heredoc; the
  verifier in `_lib_verify.sh` keeps a copy in `RC_BLOCK_EXPECTED` and the
  drift check diffs them. They must byte-match (mod the intentional leading
  newline in setup.sh's heredoc). The `REQUIRED_RC_STRINGS` list is a
  belt-and-suspenders presence check for individual load-bearing lines.

* **GH_TOKEN is derived live in rc.** No PAT is ever written to
  `~/.bashrc` / `~/.zshrc`; rc derives it from `gh auth token` at shell
  startup. The security verify step greps the rc files for `ghp_`, `gho_`,
  and so on, and fails the run if a literal token is found.

* **Bracket phases for checkpoints.** Pre/post checkpoint phases run outside
  the main loop and never abort the run on failure, because a sprite-env
  checkpoint outage shouldn't block a setup.

## Adding a new phase

1. Add `phase_<name>` that follows the contract: idempotency check at the top, real work guarded by `--force`, `ok` on a real change, `skip` if already done, `|| return 1` on every `quiet` that matters.
2. Add the phase name to the `PHASES` array in the right group.
3. Add a `run_phase <name> phase_<name>` line in the run section.
4. If the phase installs a tool that `command -v` finds, add it to `SETUP_TOOLS` in `_lib_verify.sh`.
5. If the phase touches rc files, mirror the change into `RC_BLOCK_EXPECTED` and (if load-bearing) `REQUIRED_RC_STRINGS` in `_lib_verify.sh`.
6. If the phase uses a non-standard version flag (cosign-style), add it to `version_args_for` in `_lib_verify.sh`.

## set -e suppression (read this)

`run_phase` invokes phase functions via `if "$fn"; then`. Bash suppresses
errexit for everything inside a function called in a conditional context, so
individual command failures inside a phase do not abort the phase on their
own. Every `quiet ...` call in a phase that is required to succeed must be
followed by an explicit `|| return 1`. The lone exception is informational
calls where you're OK with a soft failure (sprite-env checkpoint, completion
generation), in which case you skip the `|| return 1` deliberately and the
phase continues.

This is what bit Wave A: `tldr` was not in questing's apt, `apt-get install`
returned 100, but the phase still hit `ok "installed ..."` and reported
success. The `tldr -> tealdeer` swap is one fix; the explicit `|| return 1`
pattern across every quiet call is the structural fix.
