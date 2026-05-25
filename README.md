# 👾 sprite

Personal dev-environment config repo for [sprite.dev](https://sprite.dev) sprites,
driven by [sproot](https://github.com/justanotherspy/sproot).

This repo is a **sproot config repo**: it holds `sproot.yaml` and the `files/`
directory that sproot reads to provision a sprite. It is not a standalone script.
For the CLI that reads this, see [justanotherspy/sproot](https://github.com/justanotherspy/sproot).

## Quick start

Install sproot on your host machine, configure `~/.sproot/config`, then:

```bash
sproot new my-sprite
```

sproot will create a fresh sprite, inject itself into it, clone this repo as the
config repo, and run `sproot setup` end-to-end.

## Configurations (targets)

`sproot.yaml` defines named **targets** for different scenarios. Pick one with
`--target`; with none, `default` runs.

| Target | What you get |
|--------|--------------|
| `default` | My personal dev sprite: the full toolchain below. |
| `nix` | Everything in `default`, plus the [Nix](https://docs.determinate.systems/) package manager (Determinate Nix, nix-daemon as a sprite service) and a couple of nix-provided tools. `extends: default`. |

```bash
sproot new my-sprite              # default
sproot new my-nix-sprite --target nix
```

`extends` lets the `nix` target inherit every `default` phase verbatim and append
the `nix` module, so the shared toolchain is defined once.

## Config repo layout

```
sproot.yaml                          targets, phase lists, and identity
files/
  statusline.py                      Claude Code status line script
  ps1.sh                             custom bash/zsh prompt
  rc_additions.sh                    shell rc block (aliases, PATH, direnv, etc.)
  gitignore_global                   ~/.gitignore_global content
  pre-commit-config.template.yaml    starter pre-commit config for new repos
  nix-setup.sh                       nix target: flake/home-manager escape hatch
MIGRATION.md                         notes on the conversion from setup.sh
```

## What gets installed

Targets Ubuntu 25.10 (questing) on a sprite.dev sprite. The base image provides
language toolchains (`node`, `go`, `rust`, `python3`, `gh`, `claude`, etc.); this
config handles everything on top:

- **System packages**: shellcheck, bat, btop, direnv, fd, fzf, hyperfine, jq,
  mosh, ncdu, neovim, ripgrep, tealdeer, tmux, zoxide, xclip, and more
- **Language tooling**: corepack (pnpm/yarn), rust stable + components, uv
- **Python tools**: black, pre-commit, ruff, semgrep, garlic
- **Security scanners**: cosign, trufflehog, dive, gitleaks, hadolint
- **Container engine**: docker-ce + daemon.json + dockerd sprite service
- **CLI tools**: flyctl
- **Claude Code**: upgrade to latest, statusline, managed settings
- **Identity**: SSH keypair, GitHub auth, git config, commit signing
- **Shell**: rc block with aliases and prompt, zsh completions
- **Repos**: clones justanotherspy/{garlic,poker,sprite,justanotherspy.com}

## Forking this

This repo is a personal config. To use it as a starting point, fork it and edit:

1. `identity` block in `sproot.yaml` (name, email, GitHub username)
2. `repos` list in the `repo_clone` phase
3. `files/` as needed for your own tooling preferences
