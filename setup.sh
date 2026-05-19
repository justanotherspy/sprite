#!/usr/bin/env bash
#
# dev-env-setup.sh
# Personal dev environment bootstrap for sprite.dev sprites.
# Owner: Daniel Schwartz <danielschwar@gmail.com> (justanotherspy)
#
# Target: Ubuntu 25.10 (questing) on a sprite.dev sprite.
# (overlay rootfs, PID 1 is tini, no systemd)
#
# Idempotent: safe to re-run. Each phase self-checks before doing work.
#   --force         redo every phase even if it looks already done
#   --only PHASE    run a single phase (see --help for the list)
#   --status        dump phase state from $STATE_FILE and exit
#
# NOTE on set -e: phases are invoked via `if "$fn"; then` (see run_phase),
# which puts the function in a conditional context. bash suppresses errexit
# for everything inside a function called that way, so individual quiet()
# failures do NOT abort the phase on their own. Critical commands must
# therefore use explicit `|| return 1` to propagate failure. This is why
# every `quiet ...` call below is followed by `|| return 1`.
#
set -euo pipefail

# ============================================================================
# Pinned identity (justanotherspy / Daniel Schwartz)
# ============================================================================
GIT_USER_NAME="Daniel Schwartz"
GIT_USER_EMAIL="danielschwar@gmail.com"
GIT_DEFAULT_BRANCH="main"
GH_USERNAME="justanotherspy"

# ============================================================================
# Logging
# ============================================================================
LOG_FILE="${LOG_FILE:-/tmp/dev-env-setup.log}"
exec > >(stdbuf -oL tee >(stdbuf -oL sed 's/\x1B\[[0-9;]*[a-zA-Z]//g' > "$LOG_FILE")) 2>&1
_finalize() {
  [[ -n "${SUDO_KEEPALIVE_PID:-}" ]] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
  sleep 0.3
}
trap _finalize EXIT
echo "[Output mirrored to $LOG_FILE]"
echo

RED=$'\033[31m';  GREEN=$'\033[32m'; YELLOW=$'\033[33m'
BLUE=$'\033[34m'; GREY=$'\033[90m';  BOLD=$'\033[1m'; RESET=$'\033[0m'
log()  { printf "\n%s%s==>%s %s\n" "$BLUE" "$BOLD" "$RESET" "$*"; }
info() { printf "    %s\n" "$*"; }
warn() { printf "%s!%s %s\n" "$YELLOW" "$RESET" "$*"; }
err()  { printf "%sx%s %s\n" "$RED" "$RESET" "$*" >&2; }
# `ok` also marks the current phase as having done real work.
ok() {
  PHASE_DID_WORK=1
  printf "%s+%s %s\n" "$GREEN" "$RESET" "$*"
}
# Like ok() but for verifications/passive checks; does NOT mark the phase
# as having done work. Use when the phase only confirmed something.
note() {
  printf "%s+%s %s\n" "$GREEN" "$RESET" "$*"
}
skip() { printf "%s-%s %s%s%s\n" "$GREY" "$RESET" "$GREY" "$*" "$RESET"; }

# ============================================================================
# Per-phase command logs (used by quiet wrapper)
# ============================================================================
PHASE_LOG_DIR="${PHASE_LOG_DIR:-/tmp/dev-env-setup-phases}"
mkdir -p "$PHASE_LOG_DIR"

# quiet <label> <command> [args...]
# Run a command with stdout+stderr redirected to a per-label log file.
# Silent on success; on failure prints the last 40 lines and returns
# the command's exit code. Callers should chain `|| return 1` after this
# because set -e is suppressed inside phases (see file-level note above).
quiet() {
  local label="$1"; shift
  local log="$PHASE_LOG_DIR/${label}.log"
  local rc=0
  "$@" >"$log" 2>&1 || rc=$?
  if [[ $rc -eq 0 ]]; then
    return 0
  fi
  err "$label failed (rc=$rc); last 40 lines below (full log: $log):"
  tail -n 40 "$log" 2>/dev/null | sed 's/^/    /' >&2 || true
  return "$rc"
}

# ============================================================================
# State file (~/.config/sprite-setup/state.json)
# ============================================================================
STATE_DIR="$HOME/.config/sprite-setup"
STATE_FILE="$STATE_DIR/state.json"

# state_init — make sure $STATE_FILE exists and is well-formed JSON.
state_init() {
  mkdir -p "$STATE_DIR"
  if [[ ! -s "$STATE_FILE" ]] || ! jq -e . "$STATE_FILE" >/dev/null 2>&1; then
    printf '{"schema_version":1,"last_updated":null,"phases":{}}\n' > "$STATE_FILE"
  fi
}

# state_write_phase NAME RC DID_WORK DURATION_S
# Records the most recent run of a phase. Safe to call from anywhere
# after state_init has been invoked at least once this run.
state_write_phase() {
  local name="$1" rc="$2" did_work="$3" duration="$4"
  local now success bool_did_work
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if [[ "$rc" -eq 0 ]]; then success="true"; else success="false"; fi
  if [[ "$did_work" -eq 1 ]]; then bool_did_work="true"; else bool_did_work="false"; fi
  local tmp
  tmp="$(mktemp)"
  jq --arg name "$name" \
     --arg ts   "$now" \
     --argjson success  "$success" \
     --argjson did_work "$bool_did_work" \
     --argjson duration "$duration" \
     '.last_updated = $ts
      | .phases[$name] = {
          "last_run":   $ts,
          "did_work":   $did_work,
          "success":    $success,
          "duration_s": $duration,
          "rc":         '"$rc"'
        }' \
     "$STATE_FILE" > "$tmp" 2>/dev/null && mv "$tmp" "$STATE_FILE" || rm -f "$tmp"
}

# state_dump — render the state file as a table and exit. Driven by --status.
state_dump() {
  if [[ ! -s "$STATE_FILE" ]]; then
    echo "no state file at $STATE_FILE (setup.sh hasn't been run yet)"
    return 0
  fi
  echo "state file: $STATE_FILE"
  echo "last updated: $(jq -r '.last_updated // "(never)"' "$STATE_FILE")"
  echo
  printf "%-22s  %-22s  %-7s  %-9s  %-10s\n" "PHASE" "LAST RUN" "RESULT" "DID WORK" "DURATION"
  printf "%-22s  %-22s  %-7s  %-9s  %-10s\n" "----------------------" "----------------------" "-------" "---------" "----------"
  jq -r '
    .phases
    | to_entries
    | sort_by(.key)
    | .[]
    | [
        .key,
        (.value.last_run // "-"),
        (if .value.success then "ok" else "fail" end),
        (if .value.did_work then "yes" else "no" end),
        (((.value.duration_s // 0) | tostring) + "s")
      ]
    | @tsv
  ' "$STATE_FILE" \
    | awk -F '\t' '{ printf "%-22s  %-22s  %-7s  %-9s  %-10s\n", $1, $2, $3, $4, $5 }'
}

# ============================================================================
# Phase-result tracking (drives the end-of-run summary)
# ============================================================================
PHASES_RAN=()        # did real work this run
PHASES_SKIPPED=()    # all idempotency checks passed
PHASES_FAILED=()     # something blew up
PHASE_DID_WORK=0     # toggled to 1 by ok() inside a phase

print_summary() {
  log "Summary"
  if [[ ${#PHASES_RAN[@]} -gt 0 ]]; then
    printf "    Ran (%d):\n" "${#PHASES_RAN[@]}"
    for p in "${PHASES_RAN[@]}"; do
      printf "      %s+%s %s\n" "$GREEN" "$RESET" "$p"
    done
  fi
  if [[ ${#PHASES_SKIPPED[@]} -gt 0 ]]; then
    printf "    Already done (%d):\n" "${#PHASES_SKIPPED[@]}"
    for p in "${PHASES_SKIPPED[@]}"; do
      printf "      %s-%s %s%s%s\n" "$GREY" "$RESET" "$GREY" "$p" "$RESET"
    done
  fi
  if [[ ${#PHASES_FAILED[@]} -gt 0 ]]; then
    printf "    Failed (%d):\n" "${#PHASES_FAILED[@]}"
    for p in "${PHASES_FAILED[@]}"; do
      printf "      %sx%s %s\n" "$RED" "$RESET" "$p"
    done
  fi
}

# ============================================================================
# CLI flags
# ============================================================================
FORCE=0
ONLY_PHASE=""
DO_STATUS=0
PHASES=(
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
)
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force)  FORCE=1; shift ;;
    --only)   ONLY_PHASE="${2:-}"; shift 2 ;;
    --status) DO_STATUS=1; shift ;;
    -h|--help)
      cat <<HELP
Usage: ./setup.sh [--force] [--only PHASE] [--status]

Phases (in order): ${PHASES[*]}

  --force        Redo every phase even if it looks already done.
  --only PHASE   Only run the named phase.
  --status       Dump phase state from $STATE_FILE and exit.

Env:
  SPRITE_GH_TOKEN   one-shot PAT for gh auth (used once, never persisted).
                    If unset, falls back to 'gh auth login --web' (device flow).
HELP
      exit 0 ;;
    *) err "unknown flag: $1 (try --help)"; exit 2 ;;
  esac
done

# Handle --status before any other work.
if [[ $DO_STATUS -eq 1 ]]; then
  state_dump
  exit 0
fi

# `run_phase` reads PHASE_DID_WORK after the function returns to decide
# which bucket to put the phase in. NOTE: invoking via `if "$fn"; then`
# suppresses set -e inside the phase; phases must use explicit `|| return 1`
# on critical commands. See file-level note above quiet().
run_phase() {
  local name="$1" fn="$2"
  if [[ -n "$ONLY_PHASE" && "$ONLY_PHASE" != "$name" ]]; then return 0; fi
  local t0 t1 elapsed rc=0
  t0=$(date +%s)
  PHASE_DID_WORK=0
  log "Phase: $name"
  if "$fn"; then
    rc=0
  else
    rc=$?
  fi
  t1=$(date +%s); elapsed=$((t1 - t0))
  state_write_phase "$name" "$rc" "$PHASE_DID_WORK" "$elapsed"
  if [[ $rc -eq 0 ]]; then
    if [[ $PHASE_DID_WORK -eq 1 ]]; then
      PHASES_RAN+=("$name (${elapsed}s)")
    else
      PHASES_SKIPPED+=("$name")
    fi
    printf "%s+%s phase '%s' done (%ss)\n" "$GREEN" "$RESET" "$name" "$elapsed"
  else
    PHASES_FAILED+=("$name (rc=$rc)")
    err "phase '$name' failed (rc=$rc)"
    return "$rc"
  fi
}

# `bracket_phase` is like run_phase but doesn't update the regular tracking
# arrays and never aborts the script on failure. Used for the pre/post
# checkpoint phases that run outside the main PHASES loop.
bracket_phase() {
  local name="$1" fn="$2"
  local t0 t1 elapsed rc=0
  t0=$(date +%s)
  PHASE_DID_WORK=0
  log "Phase: $name (bracket)"
  if "$fn"; then
    rc=0
  else
    rc=$?
  fi
  t1=$(date +%s); elapsed=$((t1 - t0))
  state_write_phase "$name" "$rc" "$PHASE_DID_WORK" "$elapsed"
  if [[ $rc -eq 0 ]]; then
    printf "%s+%s bracket '%s' done (%ss)\n" "$GREEN" "$RESET" "$name" "$elapsed"
  else
    warn "bracket '$name' returned rc=$rc; continuing"
  fi
  return 0
}

# ============================================================================
# Preflight
# ============================================================================
if [[ $EUID -eq 0 ]]; then
  SUDO=""
else
  command -v sudo >/dev/null 2>&1 || { err "sudo not found (and not running as root)"; exit 1; }
fi
SUDO="${SUDO-sudo}"

: "${USER:=$(id -un)}"
: "${HOME:=$(getent passwd "$USER" | cut -d: -f6)}"
: "${HOSTNAME:=$(hostname)}"
export USER HOME HOSTNAME

if [[ -n "$SUDO" ]]; then
  $SUDO -v
  ( while true; do sudo -n true; sleep 60; kill -0 "$$" 2>/dev/null || exit; done ) 2>/dev/null &
  SUDO_KEEPALIVE_PID=$!
fi

# Make tools installed in previous phases (or previous runs) visible to this run.
export PATH="$HOME/.local/bin:$HOME/.fly/bin:/usr/local/bin:$PATH"

state_init

# ============================================================================
# Helpers shared by binary-install phases
# ============================================================================

# arch_dpkg — print amd64/arm64 or fail.
arch_dpkg() {
  case "$(dpkg --print-architecture)" in
    amd64) echo amd64 ;;
    arm64) echo arm64 ;;
    *)     return 1 ;;
  esac
}

# gh_latest_tag REPO — print the latest release tag for owner/repo via the
# GitHub API, stripping any leading "v". Returns 1 if the API call fails
# or the tag can't be parsed.
gh_latest_tag() {
  local repo="$1" api_json tag
  api_json="$(curl -fsSL "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null)" || return 1
  tag="$(printf '%s\n' "$api_json" | grep -m1 '"tag_name"' | cut -d'"' -f4 | sed 's/^v//')"
  [[ -n "$tag" ]] || return 1
  printf '%s\n' "$tag"
}

# ============================================================================
# Bracket phases (NOT in the main PHASES array)
# ============================================================================

phase_pre_checkpoint() {
  if ! command -v sprite-env >/dev/null 2>&1; then
    skip "sprite-env not on PATH; skipping pre-setup checkpoint"
    return 0
  fi
  # sprite-env auto-assigns checkpoint IDs (v0, v1, v2 ...); --comment attaches
  # a human-readable label so we can find it in `sprite-env checkpoints list`.
  local label
  label="pre-setup-$(date +%s)"
  info "creating sprite checkpoint (--comment '$label')..."
  if quiet pre-checkpoint sprite-env checkpoints create --comment "$label"; then
    ok "pre-setup checkpoint created (label: $label)"
  else
    warn "pre-setup checkpoint failed (continuing anyway)"
  fi
  return 0
}

phase_post_checkpoint() {
  if ! command -v sprite-env >/dev/null 2>&1; then
    skip "sprite-env not on PATH; skipping post-setup checkpoint"
    return 0
  fi
  local label
  label="post-setup-$(date +%s)"
  info "creating sprite checkpoint (--comment '$label')..."
  if quiet post-checkpoint sprite-env checkpoints create --comment "$label"; then
    ok "post-setup checkpoint created (label: $label)"
  else
    warn "post-setup checkpoint failed (continuing anyway)"
  fi
  return 0
}

# ============================================================================
# Phases
# ============================================================================

phase_apt_core() {
  # NOTE: tealdeer (Rust impl of tldr) provides the `tldr` command and IS in
  # Ubuntu's archive; the older `tldr` package (Node client) is not available
  # on questing, which is what broke Wave A. tealdeer ships the `tldr` binary
  # natively so no symlink is needed.
  local needed=(
    apt-transport-https software-properties-common lsb-release
    shellcheck bat btop direnv fd-find fzf hyperfine jq mosh ncdu neovim
    netcat-openbsd ripgrep tealdeer tmux traceroute yq zoxide xclip
  )
  local missing=()
  for pkg in "${needed[@]}"; do
    dpkg -s "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
  done

  if [[ ${#missing[@]} -eq 0 && $FORCE -ne 1 ]]; then
    skip "all core packages already present"
  else
    info "installing ${#missing[@]} apt package(s)..."
    quiet apt-update  $SUDO apt-get update -y || return 1
    quiet apt-install $SUDO DEBIAN_FRONTEND=noninteractive \
                         apt-get install -y "${needed[@]}" || return 1
    ok "installed ${#missing[@]} package(s)"
  fi

  mkdir -p "$HOME/.local/bin"
  if [[ -x /usr/bin/batcat && ! -e "$HOME/.local/bin/bat" ]]; then
    ln -s /usr/bin/batcat "$HOME/.local/bin/bat"
  fi
  if [[ -x /usr/bin/fdfind && ! -e "$HOME/.local/bin/fd" ]]; then
    ln -s /usr/bin/fdfind "$HOME/.local/bin/fd"
  fi
  return 0
}

phase_corepack() {
  if ! command -v corepack >/dev/null 2>&1; then
    warn "corepack not found (node missing?); skipping"
    return 0
  fi
  if [[ $FORCE -ne 1 ]] && command -v pnpm >/dev/null 2>&1 && command -v yarn >/dev/null 2>&1; then
    skip "pnpm and yarn already shimmed at $(dirname "$(command -v pnpm)")"
    return 0
  fi
  info "enabling corepack (pnpm + yarn shims into ~/.local/bin)..."
  mkdir -p "$HOME/.local/bin"
  quiet corepack corepack enable --install-directory "$HOME/.local/bin" \
    || warn "corepack enable failed (non-fatal)"
  if command -v pnpm >/dev/null 2>&1 && command -v yarn >/dev/null 2>&1; then
    ok "corepack enabled (pnpm + yarn on PATH)"
  else
    warn "corepack enable returned 0 but shims still missing; check $PHASE_LOG_DIR/corepack.log"
  fi
  return 0
}

# phase_node_lts — ensure node is on the current LTS major via nvm.
# The sprite ships node 22.x (LTS at time of writing); if that's already
# the case we skip. Otherwise we source nvm and install --lts.
phase_node_lts() {
  local nvm_sh="/.sprite/languages/node/nvm/nvm.sh"
  if [[ ! -f "$nvm_sh" ]]; then
    warn "nvm not found at $nvm_sh; skipping (sprite base image may have drifted)"
    return 0
  fi
  if ! command -v node >/dev/null 2>&1; then
    warn "node not on PATH; skipping (sprite base image issue)"
    return 0
  fi

  # Current LTS major. Hard-coded conservatively; bump when LTS rolls over.
  local lts_major=22
  local cur_major
  cur_major="$(node --version 2>/dev/null | sed 's/^v//' | cut -d. -f1)"

  if [[ "$cur_major" == "$lts_major" && $FORCE -ne 1 ]]; then
    skip "node already on LTS major (v${cur_major}.x); nothing to do"
    return 0
  fi

  info "installing node --lts via nvm (current major: ${cur_major:-unknown}, target: $lts_major)..."
  # nvm.sh expects bash; source in a subshell-style block to avoid leaking vars.
  # shellcheck disable=SC1090
  if quiet node-lts bash -c "set -e; source '$nvm_sh'; nvm install --lts && nvm alias default 'lts/*'"; then
    ok "node LTS installed/updated"
  else
    return 1
  fi
  return 0
}

# phase_go_toolchain — trust the sprite-provided go.
# Rationale: the sprite ships a recent stable go under /.sprite/bin/go, and
# the sprite docs explicitly say not to reinstall pre-installed toolchains.
# This phase exists for symmetry/visibility in --status output and does NOT
# touch the go install. If you need a different go version, use sprite-env
# to manage it, not this script.
phase_go_toolchain() {
  if ! command -v go >/dev/null 2>&1; then
    warn "go not on PATH; expected sprite-provided go under /.sprite/bin/"
    return 0
  fi
  local v
  v="$(go version 2>/dev/null | awk '{print $3}' || echo unknown)"
  note "using sprite-provided go ($v); skipping reinstall by design"
  return 0
}

# phase_rust_toolchain — pin stable + common components.
# Idempotent: parses `rustup show active-toolchain` and checks installed
# components before doing anything.
phase_rust_toolchain() {
  if ! command -v rustup >/dev/null 2>&1; then
    warn "rustup not on PATH; expected sprite-provided rustup under /.sprite/bin/"
    return 0
  fi

  local active
  active="$(rustup show active-toolchain 2>/dev/null | awk '{print $1}' || echo "")"
  local need_stable=1
  if [[ "$active" == stable-* ]]; then need_stable=0; fi

  local installed_components
  installed_components="$(rustup component list --installed 2>/dev/null || echo "")"
  local want_components=(clippy rustfmt rust-analyzer)
  local missing_components=()
  local c
  for c in "${want_components[@]}"; do
    grep -q "^$c-" <<<"$installed_components" || missing_components+=("$c")
  done

  if [[ $need_stable -eq 0 && ${#missing_components[@]} -eq 0 && $FORCE -ne 1 ]]; then
    skip "rust stable active ($active); all components present"
    return 0
  fi

  if [[ $need_stable -eq 1 ]]; then
    info "setting rust default to stable..."
    quiet rust-default rustup default stable || return 1
  fi
  if [[ ${#missing_components[@]} -gt 0 ]]; then
    info "installing missing components: ${missing_components[*]}"
    quiet rust-components rustup component add "${missing_components[@]}" || return 1
  fi
  ok "rust stable pinned with clippy/rustfmt/rust-analyzer"
  return 0
}

phase_uv() {
  if [[ $FORCE -ne 1 ]] && command -v uv >/dev/null 2>&1; then
    skip "uv $(uv --version 2>&1 | awk '{print $2}') already installed"
    return 0
  fi
  info "installing uv (Astral)..."
  quiet uv-install bash -c 'curl -LsSf https://astral.sh/uv/install.sh | sh' || return 1
  export PATH="$HOME/.local/bin:$PATH"
  ok "uv installed"
  return 0
}

# Generic "install a Python tool via `uv tool install`" wrapper.
# Used by phase_black, phase_pre_commit, phase_ruff, phase_semgrep, phase_garlic.
# Each phase passes its own (tool, install_name, label) tuple.
_uv_tool_install() {
  local tool="$1" install_name="$2" label="$3"
  if [[ $FORCE -ne 1 ]] && command -v "$tool" >/dev/null 2>&1; then
    skip "$tool already installed"
    return 0
  fi
  if [[ ! -x "$HOME/.local/bin/uv" ]]; then
    err "uv not installed; run --only uv first (or unrestricted)"
    return 1
  fi
  info "installing $tool via uv (package: $install_name)..."
  quiet "$label" "$HOME/.local/bin/uv" tool install "$install_name" || return 1
  ok "$tool installed"
  return 0
}

phase_semgrep()    { _uv_tool_install semgrep     semgrep     semgrep; }
phase_garlic()     { _uv_tool_install garlic      garlic-cli  garlic;  }
phase_black()      { _uv_tool_install black       black       black;   }
phase_pre_commit() { _uv_tool_install pre-commit  pre-commit  pre-commit; }
phase_ruff()       { _uv_tool_install ruff        ruff        ruff;    }

# phase_cosign — binary release via .deb from sigstore/cosign.
phase_cosign() {
  if [[ $FORCE -ne 1 ]] && command -v cosign >/dev/null 2>&1; then
    skip "cosign already installed ($(cosign version 2>&1 | head -1))"
    return 0
  fi

  info "resolving latest cosign release tag..."
  local latest_version arch
  latest_version="$(gh_latest_tag sigstore/cosign)" || { err "could not resolve cosign latest tag"; return 1; }
  arch="$(arch_dpkg)" || { err "unsupported arch: $(dpkg --print-architecture)"; return 1; }

  local tmpdir deb url
  tmpdir="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmpdir'" RETURN
  deb="cosign_${latest_version}_${arch}.deb"
  url="https://github.com/sigstore/cosign/releases/download/v${latest_version}/${deb}"

  info "installing cosign ${latest_version} (${arch})..."
  quiet cosign-download curl -fsSL -o "$tmpdir/$deb" "$url" || return 1
  quiet cosign-install  $SUDO dpkg -i "$tmpdir/$deb" || return 1
  ok "cosign ${latest_version} installed"
  return 0
}

phase_trufflehog() {
  if [[ $FORCE -ne 1 ]] && command -v trufflehog >/dev/null 2>&1; then
    skip "trufflehog already installed"
    return 0
  fi
  if ! command -v cosign >/dev/null 2>&1; then
    err "cosign must be installed before trufflehog (-v requires it for signature verification)"
    err "run: ./setup.sh --only cosign"
    return 1
  fi
  info "installing trufflehog (with cosign signature verification)..."
  quiet trufflehog bash -c \
    'curl -sSfL https://raw.githubusercontent.com/trufflesecurity/trufflehog/main/scripts/install.sh \
       | '"$SUDO"' sh -s -- -v -b /usr/local/bin' || return 1
  ok "trufflehog installed"
  return 0
}

# phase_dive — .deb release from wagoodman/dive.
phase_dive() {
  if [[ $FORCE -ne 1 ]] && command -v dive >/dev/null 2>&1; then
    skip "dive already installed ($(dive --version 2>&1 | head -1))"
    return 0
  fi

  info "resolving latest dive release tag..."
  local latest arch
  latest="$(gh_latest_tag wagoodman/dive)" || { err "could not resolve dive latest tag"; return 1; }
  arch="$(arch_dpkg)" || { err "unsupported arch: $(dpkg --print-architecture)"; return 1; }

  local tmpdir deb url
  tmpdir="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmpdir'" RETURN
  deb="dive_${latest}_linux_${arch}.deb"
  url="https://github.com/wagoodman/dive/releases/download/v${latest}/${deb}"

  info "installing dive ${latest} (${arch})..."
  quiet dive-download curl -fsSL -o "$tmpdir/$deb" "$url" || return 1
  quiet dive-install  $SUDO dpkg -i "$tmpdir/$deb" || return 1
  ok "dive ${latest} installed"
  return 0
}

# phase_gitleaks — tarball release from gitleaks/gitleaks.
phase_gitleaks() {
  if [[ $FORCE -ne 1 ]] && command -v gitleaks >/dev/null 2>&1; then
    skip "gitleaks already installed ($(gitleaks version 2>&1 | head -1))"
    return 0
  fi

  info "resolving latest gitleaks release tag..."
  local latest arch
  latest="$(gh_latest_tag gitleaks/gitleaks)" || { err "could not resolve gitleaks latest tag"; return 1; }
  arch="$(arch_dpkg)" || { err "unsupported arch: $(dpkg --print-architecture)"; return 1; }
  # gitleaks tarballs are named with x64/arm64 (not amd64).
  local gl_arch
  case "$arch" in
    amd64) gl_arch=x64 ;;
    arm64) gl_arch=arm64 ;;
  esac

  local tmpdir tarball url
  tmpdir="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmpdir'" RETURN
  tarball="gitleaks_${latest}_linux_${gl_arch}.tar.gz"
  url="https://github.com/gitleaks/gitleaks/releases/download/v${latest}/${tarball}"

  info "installing gitleaks ${latest} (${gl_arch})..."
  quiet gitleaks-download curl -fsSL -o "$tmpdir/$tarball" "$url" || return 1
  quiet gitleaks-extract  tar -xzf "$tmpdir/$tarball" -C "$tmpdir" gitleaks || return 1
  quiet gitleaks-install  $SUDO install -m 0755 "$tmpdir/gitleaks" /usr/local/bin/gitleaks || return 1
  ok "gitleaks ${latest} installed"
  return 0
}

# phase_hadolint — static binary from hadolint/hadolint.
phase_hadolint() {
  if [[ $FORCE -ne 1 ]] && command -v hadolint >/dev/null 2>&1; then
    skip "hadolint already installed ($(hadolint --version 2>&1 | head -1))"
    return 0
  fi

  info "resolving latest hadolint release tag..."
  local latest dpkg_arch hadolint_arch
  latest="$(gh_latest_tag hadolint/hadolint)" || { err "could not resolve hadolint latest tag"; return 1; }
  dpkg_arch="$(arch_dpkg)" || { err "unsupported arch: $(dpkg --print-architecture)"; return 1; }
  case "$dpkg_arch" in
    amd64) hadolint_arch="x86_64" ;;
    arm64) hadolint_arch="arm64" ;;
  esac

  local tmpdir bin url
  tmpdir="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmpdir'" RETURN
  bin="hadolint-Linux-${hadolint_arch}"
  url="https://github.com/hadolint/hadolint/releases/download/v${latest}/${bin}"

  info "installing hadolint ${latest} (${hadolint_arch})..."
  quiet hadolint-download curl -fsSL -o "$tmpdir/hadolint" "$url" || return 1
  quiet hadolint-install  $SUDO install -m 0755 "$tmpdir/hadolint" /usr/local/bin/hadolint || return 1
  ok "hadolint ${latest} installed"
  return 0
}

phase_docker() {
  if [[ $FORCE -ne 1 ]] && command -v docker >/dev/null 2>&1 && [[ -f /etc/docker/daemon.json ]]; then
    skip "docker present; daemon.json present"
    return 0
  fi

  info "installing docker engine (apt repo + plugins)..."
  local log="$PHASE_LOG_DIR/docker.log"
  if ! {
    for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
      $SUDO apt-get remove -y "$pkg" || true
    done
    $SUDO install -m 0755 -d /etc/apt/keyrings
    if [[ ! -f /etc/apt/keyrings/docker.asc ]]; then
      $SUDO curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
      $SUDO chmod a+r /etc/apt/keyrings/docker.asc
    fi
    local codename
    codename="$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")"
    if ! curl -fsI "https://download.docker.com/linux/ubuntu/dists/${codename}/Release" >/dev/null 2>&1; then
      codename="noble"
    fi
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $codename stable" \
      | $SUDO tee /etc/apt/sources.list.d/docker.list >/dev/null
    $SUDO apt-get update -y
    $SUDO DEBIAN_FRONTEND=noninteractive apt-get install -y \
      docker-ce docker-ce-cli containerd.io \
      docker-buildx-plugin docker-compose-plugin
    $SUDO groupadd docker 2>/dev/null || true
    $SUDO usermod -aG docker "$USER"
    if [[ ! -f /etc/docker/daemon.json ]]; then
      $SUDO mkdir -p /etc/docker
      $SUDO tee /etc/docker/daemon.json >/dev/null <<'JSON'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "20m", "max-file": "5" },
  "live-restore": true
}
JSON
    fi
  } >"$log" 2>&1; then
    err "docker install failed; last 40 lines below (full log: $log):"
    tail -n 40 "$log" | sed 's/^/    /' >&2 || true
    return 1
  fi
  ok "docker installed"
  return 0
}

phase_dockerd_service() {
  if ! command -v sprite-env >/dev/null 2>&1; then
    warn "sprite-env not on PATH; dockerd won't auto-start on wake"
    return 0
  fi
  if [[ $FORCE -ne 1 ]] && sprite-env services list 2>/dev/null | grep -q '"dockerd"'; then
    skip "dockerd sprite Service already registered"
    return 0
  fi
  if sprite-env services list 2>/dev/null | grep -q '"dockerd"'; then
    warn "removing existing 'dockerd' service before recreating"
    sprite-env services delete  dockerd 2>/dev/null \
      || sprite-env services remove  dockerd 2>/dev/null \
      || sprite-env services destroy dockerd 2>/dev/null \
      || true
  fi

  info "registering dockerd Service (boot events stream for ~5s)"
  set +o pipefail
  sprite-env services create dockerd --cmd sudo --args "/usr/bin/dockerd" 2>&1 \
    | grep --line-buffered -E '"type":"(started|complete|error)"' \
    || true
  local rc=${PIPESTATUS[0]}
  set -o pipefail
  if [[ $rc -ne 0 ]]; then
    err "sprite-env services create exited with $rc"
    return 1
  fi
  ok "dockerd Service registered"
  return 0
}

phase_flyctl() {
  if [[ $FORCE -ne 1 ]] && command -v flyctl >/dev/null 2>&1; then
    skip "flyctl already installed"
    return 0
  fi
  info "installing flyctl..."
  quiet flyctl bash -c 'curl -fsSL https://fly.io/install.sh | sh -s -- --non-interactive' || return 1
  export PATH="$HOME/.fly/bin:$PATH"
  ok "flyctl installed"
  return 0
}

phase_claude_upgrade() {
  if ! command -v claude >/dev/null 2>&1; then
    warn "claude CLI not found on sprite base image; skipping"
    return 0
  fi
  info "upgrading claude CLI..."
  if quiet claude-upgrade claude upgrade; then
    ok "claude upgraded ($(claude --version 2>&1 | head -1))"
  else
    err "claude upgrade failed (see $PHASE_LOG_DIR/claude-upgrade.log)"
    return 1
  fi
  return 0
}

phase_claude_settings() {
  local settings_dir="$HOME/.claude"
  local settings_file="$settings_dir/settings.json"
  mkdir -p "$settings_dir"

  if [[ -f "$settings_file" && $FORCE -ne 1 ]]; then
    if [[ "$(jq -r '.tui // ""' "$settings_file" 2>/dev/null)" == "fullscreen" ]]; then
      skip "$settings_file already has tui=fullscreen"
      return 0
    fi
  fi

  local tmp
  tmp="$(mktemp)"
  if [[ -f "$settings_file" && -s "$settings_file" ]]; then
    jq '. + {tui: "fullscreen"}' "$settings_file" > "$tmp"
  else
    printf '{"tui":"fullscreen"}\n' | jq . > "$tmp"
  fi
  mv "$tmp" "$settings_file"
  chmod 644 "$settings_file"
  ok "set tui=fullscreen in $settings_file"
  return 0
}

# phase_pre_commit_template — writes a starter .pre-commit-config.yaml that
# users can copy into a new repo. Stored under ~/.config/pre-commit/ so it
# doesn't conflict with any repo's actual config.
phase_pre_commit_template() {
  local dest_dir="$HOME/.config/pre-commit"
  local dest="$dest_dir/.pre-commit-config.template.yaml"
  mkdir -p "$dest_dir"

  if [[ -f "$dest" && $FORCE -ne 1 ]]; then
    skip "$dest already present"
    return 0
  fi

  cat > "$dest" <<'YAML'
# Starter pre-commit config installed by sprite-setup.
# Copy to your repo as .pre-commit-config.yaml, then run `pre-commit install`.
default_language_version:
  python: python3
repos:
  - repo: https://github.com/pre-commit/pre-commit-hooks
    rev: v5.0.0
    hooks:
      - id: trailing-whitespace
      - id: end-of-file-fixer
      - id: check-yaml
      - id: check-json
      - id: check-added-large-files
        args: [--maxkb=1024]
      - id: check-merge-conflict
      - id: detect-private-key
  - repo: https://github.com/astral-sh/ruff-pre-commit
    rev: v0.8.6
    hooks:
      - id: ruff
        args: [--fix]
      - id: ruff-format
  - repo: https://github.com/psf/black-pre-commit-mirror
    rev: 24.10.0
    hooks:
      - id: black
  - repo: https://github.com/koalaman/shellcheck-precommit
    rev: v0.10.0
    hooks:
      - id: shellcheck
  - repo: https://github.com/semgrep/semgrep
    rev: v1.96.0
    hooks:
      - id: semgrep
        args: [--config=auto, --error, --skip-unknown-extensions]
  - repo: https://github.com/gitleaks/gitleaks
    rev: v8.21.2
    hooks:
      - id: gitleaks
  - repo: local
    hooks:
      - id: trufflehog
        name: trufflehog
        entry: trufflehog --no-update --fail filesystem .
        language: system
        pass_filenames: false
YAML
  chmod 644 "$dest"
  ok "wrote pre-commit template to $dest"
  return 0
}

# phase_gitignore_global — sensible default ~/.gitignore_global and wires
# core.excludesFile to it.
phase_gitignore_global() {
  local dest="$HOME/.gitignore_global"

  local desired
  desired=$(cat <<'GIT'
# Global ignore patterns. Managed by sprite-setup.
# OS
.DS_Store
Thumbs.db
ehthumbs.db
Desktop.ini
# Editors
*.swp
*.swo
*~
.idea/
.vscode/
.fleet/
.zed/
# Direnv / envrc
.envrc.local
.direnv/
# Python
.venv/
__pycache__/
*.py[cod]
*.egg-info/
.pytest_cache/
.mypy_cache/
.ruff_cache/
# Node
node_modules/
.npm/
.pnpm-store/
.yarn/
.next/
# Rust
target/
# Go
*.test
*.out
# Misc tooling
.cache/
.coverage
.DS_Store?
GIT
)

  local need_write=1
  if [[ -f "$dest" ]]; then
    local current
    current="$(cat "$dest")"
    if [[ "$current" == "$desired" && $FORCE -ne 1 ]]; then
      need_write=0
    fi
  fi
  if [[ $need_write -eq 1 ]]; then
    printf "%s\n" "$desired" > "$dest"
    chmod 644 "$dest"
    ok "wrote $dest"
  else
    skip "$dest already current"
  fi

  local cur_exc
  cur_exc="$(git config --global core.excludesFile 2>/dev/null || echo "")"
  if [[ "$cur_exc" != "$dest" ]]; then
    git config --global core.excludesFile "$dest"
    ok "git core.excludesFile = $dest"
  else
    skip "git core.excludesFile already $dest"
  fi
  return 0
}

phase_ssh_known_hosts() {
  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"
  touch "$HOME/.ssh/known_hosts"
  chmod 644 "$HOME/.ssh/known_hosts"
  if [[ $FORCE -ne 1 ]] && ssh-keygen -F github.com -f "$HOME/.ssh/known_hosts" >/dev/null 2>&1; then
    skip "github.com already in known_hosts"
    return 0
  fi
  ssh-keyscan -t rsa,ecdsa,ed25519 github.com 2>/dev/null >> "$HOME/.ssh/known_hosts"
  ok "github.com host keys added"
  return 0
}

phase_git_identity() {
  local cur_name cur_email cur_branch
  cur_name="$(git config --global user.name           || true)"
  cur_email="$(git config --global user.email         || true)"
  cur_branch="$(git config --global init.defaultBranch || true)"

  # Treat the sprite placeholder identity as unset.
  if [[ "$cur_email" == "noreply@sprites.dev" ]]; then
    info "found sprite placeholder identity; replacing"
    cur_name=""; cur_email=""
  fi

  local need=0
  [[ "$cur_name"   != "$GIT_USER_NAME"      ]] && need=1
  [[ "$cur_email"  != "$GIT_USER_EMAIL"     ]] && need=1
  [[ "$cur_branch" != "$GIT_DEFAULT_BRANCH" ]] && need=1

  if [[ $need -eq 0 && $FORCE -ne 1 ]]; then
    skip "identity already pinned to $GIT_USER_NAME <$GIT_USER_EMAIL>"
  else
    git config --global user.name          "$GIT_USER_NAME"
    git config --global user.email         "$GIT_USER_EMAIL"
    git config --global init.defaultBranch "$GIT_DEFAULT_BRANCH"
    ok "identity set to $GIT_USER_NAME <$GIT_USER_EMAIL> (default branch $GIT_DEFAULT_BRANCH)"
  fi

  # These are always safe to (re-)apply.
  git config --global pull.rebase          true
  git config --global push.autoSetupRemote true
  git config --global rerere.enabled       true
  git config --global color.ui             auto
  git config --global core.editor          vim
  git config --global fetch.prune          true

  git config --global alias.lg      "log --oneline --graph --decorate --all"
  git config --global alias.last    "log -1 HEAD"
  git config --global alias.amend   "commit --amend --no-edit"
  git config --global alias.unstage "reset HEAD --"
  git config --global alias.cleanb  "!git branch --merged | grep -vE '^\\*|^.\\s*(main|master|develop)$' | xargs -r git branch -d"
  return 0
}

phase_ssh_key() {
  local key="$HOME/.ssh/id_ed25519"
  if [[ -f "$key" && $FORCE -ne 1 ]]; then
    skip "SSH key already at $key (rotate with: --only ssh_key --force)"
    return 0
  fi
  if [[ -f "$key" ]]; then
    local ts; ts=$(date +%s)
    info "rotating existing key (backup suffix: .bak.$ts)"
    mv "$key"     "${key}.bak.${ts}"
    [[ -f "${key}.pub" ]] && mv "${key}.pub" "${key}.pub.bak.${ts}"
  fi
  ssh-keygen -t ed25519 \
    -C "${GIT_USER_EMAIL} (sprite:${HOSTNAME})" \
    -f "$key" -N ""
  eval "$(ssh-agent -s)" >/dev/null
  ssh-add "$key" >/dev/null 2>&1 || true
  ok "ed25519 key generated"
  return 0
}

phase_gh_auth() {
  # Both scopes needed: admin:public_key for SSH auth keys (read + write),
  # admin:ssh_signing_key for SSH commit-signing keys (read + write).
  local needed_scopes="admin:public_key,admin:ssh_signing_key"

  if [[ $FORCE -ne 1 ]] && gh auth status -h github.com >/dev/null 2>&1; then
    local who; who="$(gh api user --jq .login 2>/dev/null || echo unknown)"
    if [[ "$who" == "$GH_USERNAME" ]]; then
      local status_out; status_out="$(gh auth status -h github.com 2>&1)"
      if echo "$status_out" | grep -q "admin:public_key" \
         && echo "$status_out" | grep -q "admin:ssh_signing_key"; then
        skip "gh already authenticated as $who with required scopes"
        return 0
      fi
      info "gh authenticated as $who but missing SSH key scopes; refreshing"
      gh auth refresh -h github.com -s "$needed_scopes"
      ok "scopes refreshed"
      return 0
    fi
    warn "gh authenticated as '$who' but expected '$GH_USERNAME'; re-authenticating"
    gh auth logout -h github.com 2>/dev/null || true
  fi

  if [[ -n "${SPRITE_GH_TOKEN:-}" ]]; then
    info "using SPRITE_GH_TOKEN from env (one-shot, not persisted)"
    info "(PAT must include scopes: $needed_scopes)"
    printf '%s' "$SPRITE_GH_TOKEN" | gh auth login \
      --hostname github.com --git-protocol ssh --with-token
    unset SPRITE_GH_TOKEN
  else
    info "starting device-code login (open the printed URL in any browser)"
    info "requesting scopes: $needed_scopes"
    gh auth login --hostname github.com --git-protocol ssh --web \
      --scopes "$needed_scopes"
  fi

  local who; who="$(gh api user --jq .login 2>/dev/null || echo unknown)"
  if [[ "$who" != "$GH_USERNAME" ]]; then
    err "logged in as '$who' but expected '$GH_USERNAME' (aborting)"
    return 1
  fi
  ok "gh authenticated as $who"
  return 0
}

phase_gh_upload_keys() {
  local pub="$HOME/.ssh/id_ed25519.pub"
  [[ -f "$pub" ]] || { err "public key missing at $pub (run --only ssh_key first)"; return 1; }

  local title_auth="sprite-${HOSTNAME}-auth"
  local title_sign="sprite-${HOSTNAME}-signing"

  # Use gh api directly so we get clean JSON instead of human-formatted output
  # that may leak across stdout/stderr.
  local existing_auth existing_sign
  existing_auth="$(gh api user/keys --jq '.[].title' 2>/dev/null || true)"
  existing_sign="$(gh api user/ssh_signing_keys --jq '.[].title' 2>/dev/null || true)"

  if [[ $FORCE -ne 1 ]] && grep -qFx "$title_auth" <<<"$existing_auth"; then
    skip "auth key '$title_auth' already on github"
  else
    gh ssh-key add "$pub" --title "$title_auth" --type authentication
    ok "uploaded auth key '$title_auth'"
  fi

  if [[ $FORCE -ne 1 ]] && grep -qFx "$title_sign" <<<"$existing_sign"; then
    skip "signing key '$title_sign' already on github"
  else
    gh ssh-key add "$pub" --title "$title_sign" --type signing
    ok "uploaded signing key '$title_sign'"
  fi

  # GitHub can take >30s to propagate freshly uploaded keys. Retry with backoff.
  local last_output="" total=0 wait=3 attempt
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    last_output="$(ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes \
                       -T git@github.com 2>&1)"
    if echo "$last_output" | grep -q "successfully authenticated"; then
      note "github SSH auth verified (attempt $attempt, ${total}s)"
      return 0
    fi
    sleep "$wait"
    total=$((total + wait))
    (( attempt >= 4 )) && wait=5
  done
  warn "github SSH auth not verified after ${total}s; last ssh output:"
  echo "$last_output" | sed 's/^/    /' >&2
  warn "retry manually: ssh -T git@github.com"
  return 0
}

phase_git_signing() {
  local pub="$HOME/.ssh/id_ed25519.pub"
  local signers="$HOME/.ssh/allowed_signers"
  [[ -f "$pub" ]] || { err "pub key missing at $pub"; return 1; }

  git config --global gpg.format                ssh
  git config --global user.signingkey           "$pub"
  git config --global commit.gpgsign            true
  git config --global tag.gpgsign               true
  git config --global gpg.ssh.allowedSignersFile "$signers"

  if [[ -f "$signers" ]] && grep -qF "$(cat "$pub")" "$signers" 2>/dev/null && [[ $FORCE -ne 1 ]]; then
    skip "$signers already lists this key"
  else
    echo "${GIT_USER_EMAIL} namespaces=\"git\" $(cat "$pub")" >> "$signers"
    chmod 644 "$signers"
    ok "wrote $signers"
  fi
  return 0
}

phase_clone_repos() {
  local repos_dir="$HOME/repos"
  mkdir -p "$repos_dir"

  local repos=(
    "justanotherspy/garlic"
    "justanotherspy/poker"
    "justanotherspy/sprite"
    "justanotherspy/justanotherspy.com"
  )

  local cloned=0 already=0 failed=0
  for repo in "${repos[@]}"; do
    local name="${repo#*/}"
    local dest="$repos_dir/$name"
    if [[ -d "$dest/.git" && $FORCE -ne 1 ]]; then
      already=$((already + 1))
      continue
    fi
    info "cloning $repo -> $dest"
    if quiet "clone-$name" git clone "git@github.com:${repo}.git" "$dest"; then
      cloned=$((cloned + 1))
    else
      err "failed to clone $repo (continuing)"
      failed=$((failed + 1))
    fi
  done

  if [[ $cloned -gt 0 ]]; then
    ok "cloned $cloned repo(s); $already already present; $failed failed"
  elif [[ $already -eq ${#repos[@]} ]]; then
    skip "all ${#repos[@]} repos already present in $repos_dir"
  fi

  [[ $failed -gt 0 ]] && return 1
  return 0
}

# phase_garlic_defaults — apply garlic's built-in defaults non-interactively.
# `garlic setup --defaults -y` installs Claude hooks, the /garlic slash
# command, the nudge-relay CLAUDE.md instruction, and resets garlic's config
# to defaults. Idempotent (running again just resets the same files).
phase_garlic_defaults() {
  if ! command -v garlic >/dev/null 2>&1; then
    warn "garlic not on PATH; run --only garlic first"
    return 0
  fi
  local sentinel="$STATE_DIR/garlic-defaults.applied"
  if [[ -f "$sentinel" && $FORCE -ne 1 ]]; then
    skip "garlic defaults already applied (sentinel: $sentinel; --force to reapply)"
    return 0
  fi
  info "running 'garlic setup --defaults -y'..."
  if quiet garlic-defaults garlic setup --defaults -y; then
    date -u +%Y-%m-%dT%H:%M:%SZ > "$sentinel"
    ok "garlic defaults applied (hooks + /garlic command + CLAUDE.md instruction)"
  else
    return 1
  fi
  return 0
}

# phase_ps1 — write a hand-rolled vcs_info prompt to a standalone file that
# RC_BLOCK sources. Bash + zsh variants, branch + dirty marker + short pwd,
# zero external dependencies (plain `git status --porcelain`).
phase_ps1() {
  local dest_dir="$HOME/.local/share/sprite-setup"
  local dest="$dest_dir/ps1.sh"
  mkdir -p "$dest_dir"

  local desired
  desired=$(cat <<'PS1SH'
# Hand-rolled vcs_info prompt. Sourced from RC_BLOCK in setup.sh.
# Shows: user@host short-pwd (branch[*+]) $
#   *  = unstaged changes
#   +  = staged changes
# Uses plain git plumbing; no external dependencies.

__sprite_git_prompt() {
  # Stay silent outside a git work tree.
  local branch
  branch="$(git symbolic-ref --quiet --short HEAD 2>/dev/null \
            || git rev-parse --short HEAD 2>/dev/null)" || return 0
  [ -z "$branch" ] && return 0
  local status
  status="$(git status --porcelain 2>/dev/null)"
  local mark=""
  # Staged: index column (col 1) is non-space and not '?'.
  # Unstaged: worktree column (col 2) is non-space and not '?'.
  if printf '%s\n' "$status" | grep -qE '^[^ ?]' 2>/dev/null; then mark+="+"; fi
  if printf '%s\n' "$status" | grep -qE '^.[^ ?]' 2>/dev/null; then mark+="*"; fi
  printf ' (%s%s)' "$branch" "$mark"
}

if [ -n "$BASH_VERSION" ]; then
  PROMPT_COMMAND='__SPRITE_GP="$(__sprite_git_prompt)"; '"${PROMPT_COMMAND:-}"
  # \[ \] wrap non-printing sequences so bash measures line width right.
  PS1='\[\e[32m\]\u@\h\[\e[0m\] \[\e[34m\]\w\[\e[33m\]${__SPRITE_GP}\[\e[0m\] \$ '
elif [ -n "$ZSH_VERSION" ]; then
  # zsh: re-evaluate the function on every prompt via prompt_subst.
  setopt prompt_subst
  PROMPT='%F{green}%n@%m%f %F{blue}%~%F{yellow}$(__sprite_git_prompt)%f %# '
fi
PS1SH
)

  if [[ -f "$dest" && "$(cat "$dest")" == "$desired" && $FORCE -ne 1 ]]; then
    skip "$dest already current"
    return 0
  fi
  printf "%s\n" "$desired" > "$dest"
  chmod 644 "$dest"
  ok "wrote $dest"
  return 0
}

# phase_zsh_completions — generate zsh completion files for tools that
# support `<tool> completion zsh`. Drop them into ~/.zsh/completions/.
# RC_BLOCK adds that dir to fpath and runs compinit.
phase_zsh_completions() {
  local comp_dir="$HOME/.zsh/completions"
  mkdir -p "$comp_dir"

  # tool name -> command to emit zsh completion script on stdout.
  # Each line: "tool|cmd args..." (pipe separator to keep parsing simple).
  local entries=(
    "gh|gh completion -s zsh"
    "flyctl|flyctl completion zsh"
    "uv|uv generate-shell-completion zsh"
    "cosign|cosign completion zsh"
    "garlic|garlic --completion zsh"
    "pre-commit|pre-commit completion zsh"
  )

  local wrote=0 skipped=0 unsupported=0
  local entry tool cmd dest
  for entry in "${entries[@]}"; do
    tool="${entry%%|*}"
    cmd="${entry#*|}"
    dest="$comp_dir/_${tool}"

    if ! command -v "${cmd%% *}" >/dev/null 2>&1; then
      unsupported=$((unsupported + 1))
      continue
    fi
    if [[ -f "$dest" && $FORCE -ne 1 ]]; then
      skipped=$((skipped + 1))
      continue
    fi
    # Try to capture completion output; some tools return non-zero or
    # print errors when they don't support zsh completion. Soft-fail.
    if eval "$cmd" > "$dest.tmp" 2>"$PHASE_LOG_DIR/comp-$tool.log" && [[ -s "$dest.tmp" ]]; then
      mv "$dest.tmp" "$dest"
      chmod 644 "$dest"
      wrote=$((wrote + 1))
    else
      rm -f "$dest.tmp"
      unsupported=$((unsupported + 1))
    fi
  done

  if [[ $wrote -gt 0 ]]; then
    ok "wrote $wrote zsh completion file(s); $skipped already current; $unsupported not generated"
  else
    skip "no new zsh completion files (already current: $skipped; not generated: $unsupported)"
  fi
  return 0
}

phase_rc_additions() {
  RC_BLOCK=$(cat <<'EOF'

# >>> dev-env-setup shell additions >>>
export PATH="$HOME/.local/bin:$PATH"
[ -d "$HOME/.fly/bin" ] && export PATH="$HOME/.fly/bin:$PATH"

# GH_TOKEN/GITHUB_TOKEN derived live from gh's secure store.
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  export GH_TOKEN="$(gh auth token 2>/dev/null)"
  export GITHUB_TOKEN="$GH_TOKEN"
fi

# direnv: detect the actual interpreter via BASH_VERSION / ZSH_VERSION,
# not $SHELL (which sticks around as your login shell even when newgrp,
# sudo -s, or a script-invoked bash gives you a different interpreter).
if command -v direnv >/dev/null 2>&1; then
  if [ -n "$BASH_VERSION" ]; then
    eval "$(direnv hook bash)"
  elif [ -n "$ZSH_VERSION" ]; then
    eval "$(direnv hook zsh)"
  fi
fi

# zoxide: smart cd
if command -v zoxide >/dev/null 2>&1; then
  if [ -n "$BASH_VERSION" ]; then
    eval "$(zoxide init bash)"
  elif [ -n "$ZSH_VERSION" ]; then
    eval "$(zoxide init zsh)"
  fi
fi

# fzf keybindings (if present)
[ -f /usr/share/doc/fzf/examples/key-bindings.bash ] && [ -n "$BASH_VERSION" ] && \
  source /usr/share/doc/fzf/examples/key-bindings.bash
[ -f /usr/share/doc/fzf/examples/key-bindings.zsh ]  && [ -n "$ZSH_VERSION" ]  && \
  source /usr/share/doc/fzf/examples/key-bindings.zsh

# zsh completions (managed by phase_zsh_completions)
if [ -n "$ZSH_VERSION" ] && [ -d "$HOME/.zsh/completions" ]; then
  fpath=("$HOME/.zsh/completions" $fpath)
  autoload -Uz compinit && compinit -i
fi

# Custom PS1 (managed by phase_ps1)
[ -f "$HOME/.local/share/sprite-setup/ps1.sh" ] && source "$HOME/.local/share/sprite-setup/ps1.sh"

# Git aliases
alias g='git'; alias gs='git status'; alias gst='git status'
alias ga='git add'; alias gaa='git add --all'
alias gc='git commit'; alias gcm='git commit -m'
alias gca='git commit --amend'; alias gcan='git commit --amend --no-edit'
alias gco='git checkout'; alias gcb='git checkout -b'
alias gsw='git switch'; alias gswc='git switch -c'
alias gb='git branch'; alias gba='git branch -a'; alias gbd='git branch -d'
alias gd='git diff'; alias gds='git diff --staged'
alias gl='git log --oneline --graph --decorate'
alias gla='git log --oneline --graph --decorate --all'
alias gp='git pull --rebase'; alias gpu='git push'; alias gpf='git push --force-with-lease'
alias gf='git fetch --all --prune'
alias grh='git reset HEAD'; alias grhh='git reset --hard HEAD'
alias gstash='git stash'; alias gpop='git stash pop'
alias gcp='git cherry-pick'
alias gwip='git add -A && git commit -m "wip"'; alias gunwip='git reset HEAD~1'

# Quality of life
alias ll='ls -lah --color=auto'; alias la='ls -A --color=auto'; alias l='ls -CF --color=auto'
alias ..='cd ..'; alias ...='cd ../..'; alias ....='cd ../../..'
alias df='df -h'; alias du='du -h'; alias free='free -h'
alias ports='ss -tulpn'; alias myip='curl -s ifconfig.me'
alias reload='exec $SHELL -l'

# Docker
alias d='docker'; alias dc='docker compose'
alias dps='docker ps'; alias dpsa='docker ps -a'
alias dim='docker images'
alias dprune='docker system prune -af --volumes'

# tmux
alias t='tmux attach || tmux new'
# <<< dev-env-setup shell additions <<<
EOF
)

  # Strip the leading newline from the heredoc so we can compare cleanly
  # against what sed extracts (which has no leading newline).
  local expected="${RC_BLOCK#$'\n'}"

  local needs_write=0
  for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
    if [[ ! -f "$rc" ]]; then needs_write=1; break; fi
    # Stale legacy block from older setup versions should always trigger a rewrite
    if grep -q '# >>> dev-env-setup GH_TOKEN >>>' "$rc"; then needs_write=1; break; fi
    local current
    current="$(sed -n '/# >>> dev-env-setup shell additions >>>/,/# <<< dev-env-setup shell additions <<</p' "$rc")"
    if [[ "$current" != "$expected" ]]; then needs_write=1; break; fi
  done

  if [[ $needs_write -eq 0 && $FORCE -ne 1 ]]; then
    skip "rc additions already current in .bashrc and .zshrc"
    return 0
  fi

  for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
    touch "$rc"
    sed -i '/# >>> dev-env-setup shell additions >>>/,/# <<< dev-env-setup shell additions <<</d' "$rc"
    sed -i '/# >>> dev-env-setup GH_TOKEN >>>/,/# <<< dev-env-setup GH_TOKEN <<</d' "$rc"
    printf "%s\n" "$RC_BLOCK" >> "$rc"
  done
  chmod 644 "$HOME/.bashrc" "$HOME/.zshrc" 2>/dev/null || true
  ok "rc additions written"
  return 0
}

# ============================================================================
# phase_verify
# Runs the post-install verification suite inline at the end of setup.sh.
# Sources _lib_verify.sh inside a subshell so the lib's helper definitions
# don't shadow setup.sh's helpers (log/ok/warn/note/skip behave differently
# in the lib: they track PASS/FAIL/WARN counters).
#
# This is the same logic post.sh uses as a standalone script. If verify
# reports failures, this phase fails (rc=1); earlier phases are unaffected.
# ============================================================================
phase_verify() {
  # Resolve the lib path. Prefer same-dir lookup. Fall back to a curl-mode
  # download when setup.sh was invoked via `bash <(curl ...)` (in which case
  # $0 is a /dev/fd path, not a real file).
  local script_path script_dir lib
  script_path="${BASH_SOURCE[0]:-$0}"
  script_dir="$(cd "$(dirname "$script_path" 2>/dev/null)" 2>/dev/null && pwd || echo "")"
  lib="$script_dir/_lib_verify.sh"

  local cleanup_lib=""
  if [[ ! -f "$lib" ]]; then
    info "_lib_verify.sh not found locally; fetching for inline verify"
    lib="$(mktemp -t _lib_verify.XXXXXX.sh)"
    cleanup_lib="$lib"
    if ! curl -fsSL \
         "https://raw.githubusercontent.com/justanotherspy/sprite/main/_lib_verify.sh" \
         -o "$lib"; then
      err "could not fetch _lib_verify.sh; skipping inline verification"
      rm -f "$cleanup_lib"
      return 1
    fi
  fi

  info "running inline post-install verification (same checks as post.sh)"

  # Run the verify pass in a subshell so the lib's helper definitions
  # (log, ok, warn, note, skip, record_fail, etc.) don't leak into the
  # rest of setup.sh. The subshell's exit code IS the verify result.
  set +e
  (
    set +e
    # Pass identity through so the lib can validate user.name etc.
    export GIT_USER_NAME GIT_USER_EMAIL GIT_DEFAULT_BRANCH GH_USERNAME
    # shellcheck disable=SC1090
    source "$lib"
    verify_run_all
    verify_print_summary
  )
  local verify_rc=$?
  set -e

  [[ -n "$cleanup_lib" ]] && rm -f "$cleanup_lib"

  if [[ $verify_rc -ne 0 ]]; then
    err "post-install verification reported failures (see above)"
    return 1
  fi
  ok "post-install verification passed"
  return 0
}

# ============================================================================
# Run
# ============================================================================
START_TIME=$(date +%s)

# Bracket: pre-setup checkpoint (best-effort, never aborts the run).
[[ -z "$ONLY_PHASE" ]] && bracket_phase pre_checkpoint phase_pre_checkpoint

run_phase apt_core             phase_apt_core
run_phase corepack             phase_corepack
run_phase node_lts             phase_node_lts
run_phase go_toolchain         phase_go_toolchain
run_phase rust_toolchain       phase_rust_toolchain
run_phase uv                   phase_uv
run_phase black                phase_black
run_phase garlic               phase_garlic
run_phase pre_commit           phase_pre_commit
run_phase ruff                 phase_ruff
run_phase semgrep              phase_semgrep
run_phase cosign               phase_cosign
run_phase trufflehog           phase_trufflehog
run_phase dive                 phase_dive
run_phase gitleaks             phase_gitleaks
run_phase hadolint             phase_hadolint
run_phase docker               phase_docker
run_phase dockerd_service      phase_dockerd_service
run_phase flyctl               phase_flyctl
run_phase claude_upgrade       phase_claude_upgrade
run_phase claude_settings      phase_claude_settings
run_phase pre_commit_template  phase_pre_commit_template
run_phase gitignore_global     phase_gitignore_global
run_phase ssh_known_hosts      phase_ssh_known_hosts
run_phase git_identity         phase_git_identity
run_phase ssh_key              phase_ssh_key
run_phase gh_auth              phase_gh_auth
run_phase gh_upload_keys       phase_gh_upload_keys
run_phase git_signing          phase_git_signing
run_phase clone_repos          phase_clone_repos
run_phase garlic_defaults      phase_garlic_defaults
run_phase ps1                  phase_ps1
run_phase zsh_completions      phase_zsh_completions
run_phase rc_additions         phase_rc_additions
run_phase verify               phase_verify

# Bracket: post-setup checkpoint (only if main loop completed; if verify
# failed, run_phase would have already exited non-zero by here).
[[ -z "$ONLY_PHASE" ]] && bracket_phase post_checkpoint phase_post_checkpoint

ELAPSED=$(( $(date +%s) - START_TIME ))
echo
print_summary
echo
log "All done (${ELAPSED}s)"

# Detect the shell that invoked us (more reliable than $SHELL, which is
# the login shell from /etc/passwd and may not match the user's actual
# interactive shell).
detect_invoking_shell() {
  local parent
  parent="$(ps -p "$PPID" -o comm= 2>/dev/null | tr -d ' ' | sed 's/^-//')"
  case "$parent" in
    zsh|bash|fish) echo "$parent"; return ;;
  esac
  basename "${SHELL:-bash}"
}

case "$(detect_invoking_shell)" in
  zsh)  RC_FILE="$HOME/.zshrc"  ;;
  bash) RC_FILE="$HOME/.bashrc" ;;
  fish) RC_FILE="$HOME/.config/fish/config.fish"
        warn "fish detected; rc additions were written to .bashrc/.zshrc only" ;;
  *)    RC_FILE="$HOME/.bashrc" ;;
esac
info "1. Open a new shell or run: source $RC_FILE"
info "2. For docker without sudo: log out/in, or run 'newgrp docker'"
info "3. Per-phase logs (if you want to inspect): $PHASE_LOG_DIR/"
info "4. Re-run verify standalone with: ./post.sh"
info "5. Phase state: ./setup.sh --status   (file: $STATE_FILE)"
echo
