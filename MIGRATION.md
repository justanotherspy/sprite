# Migration: setup.sh to sproot config repo

This repo was converted from a standalone bash bootstrap (`setup.sh`) into a
sproot config repo. The `sproot` CLI (justanotherspy/sproot) reads `sproot.yaml`
and the `files/` directory to provision a sprite.dev sprite.

## What changed

| Old file | New equivalent |
|---|---|
| `setup.sh` | `sproot.yaml` + `files/` |
| `statusline.py` (root) | `files/statusline.py` |
| `phase_ps1` heredoc | `files/ps1.sh` |
| `RC_BLOCK` heredoc | `files/rc_additions.sh` |
| `phase_gitignore_global` heredoc | `files/gitignore_global` |
| `phase_pre_commit_template` heredoc | `files/pre-commit-config.template.yaml` |
| `post.sh` / `_lib_verify.sh` | sproot built-in verify phase |
| `pre.sh` | reference only; not ported |

## Intentional divergences from setup.sh

| Feature | setup.sh | sproot.yaml |
|---|---|---|
| RC sentinels | `# >>> dev-env-setup shell additions >>>` | `# BEGIN SPROOT MANAGED BLOCK` |
| State file | `~/.config/sprite-setup/state.json` | `~/.config/sproot/state.json` |
| garlic sentinel | `~/.config/sprite-setup/garlic-defaults.applied` | `~/.config/sproot/garlic-defaults.applied` |
| `ssh_known_hosts` + `ssh_key` + `gh_upload_keys` | three separate phases | unified `ssh_setup` phase |
| `git_identity` + `git_signing` | two separate phases | unified `git_identity` phase |
| `claude upgrade` | skips if claude not on PATH | always attempts (exits 0 if up to date) |

## Known cmd workarounds (planned for sproot improvements)

Several phases use raw `cmd` blocks due to gaps in sproot's typed modules.
These are tracked for upstream fixes in justanotherspy/sproot:

- **bat/fd symlinks**: `apt` module installs packages but doesn't create shims;
  needs an `apt.symlinks` field
- **uv auto-bootstrap**: `uv_tool` requires uv on PATH; needs auto-install when
  uv is absent
- **garlic package/binary mismatch**: `uv_tool` assumes package name = binary name;
  needs a `pkg` field
- **binary_release arch naming**: gitleaks uses `x64`, hadolint uses `x86_64`;
  needs `{x64_arch}` and `{x86_64_arch}` template variables
- **docker daemon.json**: `docker` module installs Docker but doesn't write
  `/etc/docker/daemon.json`; needs a `daemon_json` config field
