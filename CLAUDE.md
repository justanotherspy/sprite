# CLAUDE.md

Notes for Claude (or any future maintainer) when working in this repo. The
goal is to capture the things that are not obvious from reading the code.

## Layout

```
sprite/
├── setup.sh           main entry; runs every phase, then verify
├── post.sh            standalone verifier; thin wrapper over _lib_verify.sh
├── _lib_verify.sh     sourceable verification library (used by both)
├── pre.sh             snapshot of pre-setup sprite state, reference only
├── README.md          user-facing docs
└── CLAUDE.md          this file
```

## Target environment

* Ubuntu 25.10 (questing) on a sprite.dev sprite
* PID 1 is `tini`, no systemd, overlay rootfs
* Daemons run as `sprite-env services` (registered units that survive hibernation)
* Sprite ships a fixed set of pre-installed tools that we never reinstall:
  `node`, `npm`, `bun`, `deno`, `python3`, `go`, `ruby`, `rustc`, `cargo`,
  `elixir`, `java`, `gh`, `claude`, `gemini`, `codex`, `sprite`, `sprite-env`.
  These live under `/.sprite/bin/` (shims) and `/.sprite/languages/` (managers).
* Identity is pinned for this maintainer: `Daniel Schwartz
  <danielschwar@gmail.com>`, github user `justanotherspy`, default branch
  `main`.

## The set -e suppression gotcha (read first)

Phase functions are invoked via `if "$fn"; then ... fi` inside `run_phase`.
Bash suppresses `errexit` for the entire body of a function called in a
conditional context, including any commands it calls and any subshells those
commands run in. This means:

* `set -euo pipefail` at the top of `setup.sh` does **not** save you inside a
  phase.
* A `quiet apt-install ...` call that returns non-zero will be logged by the
  `quiet` helper, but execution continues to the next line. If that next line
  is `ok "installed ..."`, the phase will report success despite the failure.

The rule is: **every `quiet <label> <cmd>` call in a phase must be followed
by `|| return 1`** unless you specifically want a soft failure (the only
places we currently do this are the bracket checkpoint phases and individual
completion generations inside `phase_zsh_completions`).

This was the structural root cause of the Wave A `apt_core` false-positive.
The cosmetic cause (`tldr` not being in questing's apt repository) was a
trigger, but the false success report was the deeper bug.

## Critical invariants

### RC_BLOCK byte-match

`setup.sh:phase_rc_additions` defines a heredoc named `RC_BLOCK`.
`_lib_verify.sh` keeps a copy in `RC_BLOCK_EXPECTED`. The drift check in
`verify_rc_files` diffs the live rc files against `RC_BLOCK_EXPECTED`. If you
change `RC_BLOCK`, you **must** mirror the change into `RC_BLOCK_EXPECTED`,
or the verifier will start failing on every sprite.

A note about whitespace: setup.sh's `RC_BLOCK` heredoc starts with a blank
line (right after `<<'EOF'`) because that produces nice spacing when appended
to an rc file. That leading newline is stripped at use time via
`${RC_BLOCK#$'\n'}`, so the lib's `RC_BLOCK_EXPECTED` should **not** have a
leading blank line. Both should be 79 lines / 3122 bytes after this
strip-then-compare normalization (current numbers as of Wave B).

To verify by hand:

```bash
sed -n "/^  RC_BLOCK=\$(cat <<'EOF'\$/,/^EOF\$/p" setup.sh \
  | sed '1d;$d' | sed '1{/^$/d}'  > /tmp/a
sed -n "/^RC_BLOCK_EXPECTED=\$(cat <<'EOF'\$/,/^EOF\$/p" _lib_verify.sh \
  | sed '1d;$d'                   > /tmp/b
diff -q /tmp/a /tmp/b   # must be silent
```

### REQUIRED_RC_STRINGS

In `_lib_verify.sh`, `REQUIRED_RC_STRINGS` is a belt-and-suspenders presence
check on top of the full byte-diff. It's not redundant: if someone hand-edits
their rc file and removes a load-bearing line but the structural diff still
passes for some reason, the presence check catches it. Add to this list any
new line in `RC_BLOCK` whose absence would silently break shell behavior
(things like the GH_TOKEN export, the direnv hook, the ps1.sh source line).

### SETUP_TOOLS

In `_lib_verify.sh`, `SETUP_TOOLS` is the inventory of binaries the verifier
expects to find on `PATH` after a successful setup. Any phase that installs
a new command-line tool must add the tool name here. `SPRITE_TOOLS` is the
parallel list of pre-installed sprite binaries; missing ones produce a
warning, not a failure (sprite drift is not our problem to fix).

### version_args_for

`check_tool` runs `<cmd> <args>` to harvest a version string for the column
in the verify table. Most tools accept `--version`. Some (`cosign 3.x`,
`go`, `gitleaks`) require a `version` subcommand instead. The lookup table
in `version_args_for` is where you tell the verifier which form a given tool
uses. Adding a tool with the wrong default produces a cosmetic "unknown flag"
in the version column; the verifier still passes.

## Phase contract

A phase is `phase_<name>` and follows this shape:

```bash
phase_example() {
  # 1. Idempotency check first. If --force isn't set and the work is
  #    already done, call skip() and return 0.
  if [[ $FORCE -ne 1 ]] && command -v example >/dev/null 2>&1; then
    skip "example already installed"
    return 0
  fi

  # 2. Real work, guarded with || return 1 on critical commands.
  info "installing example..."
  quiet example-install bash -c 'curl -fsSL ... | sh' || return 1

  # 3. ok() marks the phase as having done real work (drives the
  #    summary buckets at the end of the run).
  ok "example installed"
  return 0
}
```

* `ok` increments `PHASE_DID_WORK` and prints a green check.
* `note` prints a green check but does NOT mark the phase as having done
  work. Use for passive confirmations ("using sprite-provided go").
* `skip` prints a grey dash. Use when the idempotency check passed.
* `warn` prints a yellow bang. Doesn't fail the phase. Use for soft issues.
* `err` prints to stderr with a red x. Doesn't fail the phase on its own;
  combine with `return 1` if you want to abort.

## State file

`~/.config/sprite-setup/state.json` is owned by setup.sh. After every phase,
`state_write_phase NAME RC DID_WORK DURATION_S` records:

```json
{
  "schema_version": 1,
  "last_updated": "2026-05-19T14:30:00Z",
  "phases": {
    "apt_core": {
      "last_run": "2026-05-19T14:30:00Z",
      "did_work": true,
      "success": true,
      "duration_s": 12,
      "rc": 0
    }
  }
}
```

This file is informational. Phases do not consult it when deciding whether
to do work; each phase has its own idempotency check based on the actual
filesystem / command output / api state. The state file is for `--status`
output and for forensics after a failed run.

## Adding a new phase: checklist

1. Write `phase_<name>` per the contract above. Test the idempotency check by mentally walking the second run.
2. Add the name to the `PHASES` array in `setup.sh` (in the right group; ordering is dependency-driven, not alphabetical).
3. Add a `run_phase <name> phase_<name>` line in the run section near the bottom of `setup.sh`.
4. If it installs a tool that `command -v` finds, add it to `SETUP_TOOLS` in `_lib_verify.sh`.
5. If it writes any line into rc files, mirror the change into `RC_BLOCK` in `setup.sh` AND `RC_BLOCK_EXPECTED` in `_lib_verify.sh`. Add the line to `REQUIRED_RC_STRINGS` if it's load-bearing.
6. If the tool uses an unusual `--version` invocation, extend `version_args_for`.
7. Run `bash -n setup.sh && bash -n _lib_verify.sh` and a `shellcheck` pass.
8. Run the byte-match diff from the "RC_BLOCK byte-match" section above.

## Helpers worth knowing about

* `_uv_tool_install TOOL PKG LABEL`: one-liner wrapper used by every uv-installed Python tool (`black`, `pre_commit`, `ruff`, `semgrep`, `garlic`). Add new uv-managed tools by writing a one-line phase that delegates here.
* `gh_latest_tag REPO`: returns the latest release tag for `owner/repo`, stripping any leading `v`. Used by every binary-from-GitHub install.
* `arch_dpkg`: returns `amd64` or `arm64`, fails on other arches. Some tools use different arch strings (gitleaks uses `x64`/`arm64`, hadolint uses `x86_64`/`arm64`). The per-phase code maps from `arch_dpkg` to the tool's naming.
* `bracket_phase NAME FN`: like `run_phase` but does not update the tracking arrays and never aborts the script. Used for the pre/post checkpoint phases.

## History

* **Wave A**: apt core, corepack, uv, semgrep, trufflehog, cosign, docker, dockerd service, flyctl, claude upgrade, claude settings, ssh setup, github auth, signing, repo clones, rc additions, verify. Two bugs surfaced in testing: `tldr` was not in questing's apt, and `set -e` was suppressed inside phases (see above). Both fixed in Wave B.
* **Wave B**: added `node_lts`, `go_toolchain` (no-op by design), `rust_toolchain`, `black`, `garlic`, `pre_commit`, `ruff`, `dive`, `gitleaks`, `hadolint`, `pre_commit_template`, `gitignore_global`, `garlic_defaults`, `ps1`, `zsh_completions`. Added bracket phases (`pre_checkpoint`, `post_checkpoint`). Added state file and `--status` flag. Fixed the Wave A bugs structurally (`tldr` swapped to `tealdeer`, explicit `|| return 1` on every critical `quiet`).
* * **Wave C**: Removed `phase_node_lts` and `phase_go_toolchain`.
  The sprite base image reliably ships LTS node and a current go; the verify
  pass catches drift via `SPRITE_TOOLS`, which is a more honest signal than
  a phase that pretends to manage a version it doesn't actually manage.
  Reworked `phase_corepack` to pre-activate pnpm and yarn (avoids the
  first-use download prompt). Reworked `phase_zsh_completions` to report
  succeeded/failed tools by name. Dropped `gemini` from `SPRITE_TOOLS`
  (we don't use it). Extended `version_args_for` for tmux and xclip; bumped
  the version-harvest timeout from 5s to 10s; filtered node stack frames
  out of version output as defensive coding.
