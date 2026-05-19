# sprite-setup

Bootstrap and verification scripts for [sprites.dev](https://sprites.dev) — stateful, hardware-isolated Linux sandboxes built on Fly.io.

## What's in here

| Script | Purpose |
|---|---|
| `pre.sh` | Read-only preflight inspection — run **before** `setup.sh` |
| `setup.sh` | Full dev-environment bootstrap — run **once** on a fresh sprite |
| `post.sh` | Read-only post-install verification — run **after** `setup.sh` |

## Quick start

```bash
curl -fsSL https://raw.githubusercontent.com/justanotherspy/sprite/main/setup.sh | bash
```

## What `setup.sh` installs

- **System tools**: shellcheck, bat, btop, direnv, fd, fzf, mosh, ncdu, neovim, ripgrep, yq, traceroute
- **Python toolchain**: [uv](https://astral.sh/uv) + semgrep (via `uv tool install`)
- **Security**: [trufflehog](https://github.com/trufflesecurity/trufflehog) secrets scanner
- **Docker**: docker-ce + buildx + compose plugins, with log-rotation config and a sprite Service to survive hibernation/wake cycles
- **Fly.io CLI**: flyctl
- **Shell config**: PATH, git aliases, Docker aliases, quality-of-life aliases — written idempotently to `.bashrc` and `.zshrc`
- **Git**: identity, recommended global settings, handy aliases
- **SSH**: GitHub known_hosts, optional key generation

Sprites already ship with `node`, `npm`, `bun`, `deno`, `python3`, `go`, `ruby`, `rustc`, `cargo`, `elixir`, `java`, `gh`, `claude`, `gemini`, and `codex` — the scripts don't reinstall those.

## Requirements

- A [sprites.dev](https://sprites.dev) sprite running Ubuntu 25.x
- Network access from the sprite (the scripts pull packages from apt, GitHub, Astral, Docker, and fly.io)

## MCP integration

This repo ships a `.mcp.json` that wires up the [sprites.dev MCP server](https://fly.io/blog/unfortunately-mcp/) so Claude Code can manage sprites directly. Open the project in Claude Code and authenticate when prompted.

```bash
# Or add manually:
claude mcp add --transport http sprites https://sprites.dev/mcp
```


## Notes

- **`setup.sh` is idempotent** — safe to re-run if it's interrupted.
- **No systemd** — sprites use `tini` as PID 1; Docker is kept alive via a sprite Service.
- Logs are written to `/tmp/*.log` and printed to stdout with ANSI colours stripped in the log copy.

## Documentation

Spites docs are here: https://github.com/superfly/sprites-docs/tree/main/src/content/docs
