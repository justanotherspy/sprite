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
#
set -euo pipefail

# ============================================================================
# Pinned identity (FrootLoops / Daniel Schwartz)
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
# `ok` now also marks the current phase as having done real work.
ok() {
  PHASE_DID_WORK=1
  printf "%s+%s %s\n" "$GREEN" "$RESET" "$*"
}
# Like ok() but for verifications/passive checks — does NOT mark the phase
# as having done work. Use when the phase only confirmed something, not
# changed something.
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
# the command's exit code.
quiet() {
  local label="$1"; shift
  local log="$PHASE_LOG_DIR/${label}.log"
  if "$@" >"$log" 2>&1; then
    return 0
  fi
  local rc=$?
  err "$label failed (rc=$rc); last 40 lines below (full log: $log):"
  tail -n 40 "$log" 2>/dev/null | sed 's/^/    /' >&2 || true
  return $rc
}

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
# Phase-result tracking (drives the end-of-run summary)
# ============================================================================
PHASES_RAN=()        # did real work this run
PHASES_SKIPPED=()    # all idempotency checks passed
PHASES_FAILED=()     # something blew up
PHASE_DID_WORK=0     # toggled to 1 by ok() inside a phase

# ============================================================================
# CLI flags
# ============================================================================
FORCE=0
ONLY_PHASE=""
PHASES=(
  apt_core corepack uv semgrep trufflehog
  docker dockerd_service flyctl
  ssh_known_hosts git_identity ssh_key
  gh_auth gh_upload_keys git_signing
  rc_additions
)
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE=1; shift ;;
    --only)  ONLY_PHASE="${2:-}"; shift 2 ;;
    -h|--help)
      cat <<HELP
Usage: ./setup.sh [--force] [--only PHASE]

Phases (in order): ${PHASES[*]}

  --force        Redo every phase even if it looks already done.
  --only PHASE   Only run the named phase.

Env:
  SPRITE_GH_TOKEN   one-shot PAT for gh auth (used once, never persisted).
                    If unset, falls back to 'gh auth login --web' (device flow).
HELP
      exit 0 ;;
    *) err "unknown flag: $1 (try --help)"; exit 2 ;;
  esac
done

# `run_phase` reads PHASE_DID_WORK after the function returns to decide
# which bucket to put the phase in.
run_phase() {
  local name="$1" fn="$2"
  if [[ -n "$ONLY_PHASE" && "$ONLY_PHASE" != "$name" ]]; then return 0; fi
  local t0 t1 elapsed
  t0=$(date +%s)
  PHASE_DID_WORK=0
  log "Phase: $name"
  if "$fn"; then
    t1=$(date +%s); elapsed=$((t1 - t0))
    if [[ $PHASE_DID_WORK -eq 1 ]]; then
      PHASES_RAN+=("$name (${elapsed}s)")
    else
      PHASES_SKIPPED+=("$name")
    fi
    # raw printf so this trailing OK doesn't also toggle PHASE_DID_WORK
    printf "%s+%s phase '%s' done (%ss)\n" "$GREEN" "$RESET" "$name" "$elapsed"
  else
    local rc=$?
    PHASES_FAILED+=("$name (rc=$rc)")
    err "phase '$name' failed (rc=$rc)"
    return $rc
  fi
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
export PATH="$HOME/.local/bin:$HOME/.fly/bin:$PATH"

# ============================================================================
# Phases
# ============================================================================

phase_apt_core() {
  local needed=(
    apt-transport-https software-properties-common lsb-release
    shellcheck bat btop direnv fd-find fzf mosh ncdu neovim
    netcat-openbsd ripgrep traceroute yq xclip
  )
  local missing=()
  for pkg in "${needed[@]}"; do
    dpkg -s "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
  done

  if [[ ${#missing[@]} -eq 0 && $FORCE -ne 1 ]]; then
    skip "all core packages already present"
  else
    info "installing ${#missing[@]} apt package(s)..."
    quiet apt-update  $SUDO apt-get update -y
    quiet apt-install $SUDO DEBIAN_FRONTEND=noninteractive \
                         apt-get install -y "${needed[@]}"
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

phase_uv() {
  if [[ $FORCE -ne 1 ]] && command -v uv >/dev/null 2>&1; then
    skip "uv $(uv --version 2>&1 | awk '{print $2}') already installed"
    return 0
  fi
  info "installing uv (Astral)..."
  quiet uv-install bash -c 'curl -LsSf https://astral.sh/uv/install.sh | sh'
  export PATH="$HOME/.local/bin:$PATH"
  ok "uv installed"
  return 0
}

phase_semgrep() {
  if [[ $FORCE -ne 1 ]] && command -v semgrep >/dev/null 2>&1; then
    skip "semgrep already installed"
    return 0
  fi
  info "installing semgrep via uv..."
  quiet semgrep "$HOME/.local/bin/uv" tool install semgrep
  ok "semgrep installed"
  return 0
}

phase_trufflehog() {
  if [[ $FORCE -ne 1 ]] && command -v trufflehog >/dev/null 2>&1; then
    skip "trufflehog already installed"
    return 0
  fi
  info "installing trufflehog..."
  quiet trufflehog bash -c \
    'curl -sSfL https://raw.githubusercontent.com/trufflesecurity/trufflehog/main/scripts/install.sh \
       | '"$SUDO"' sh -s -- -b /usr/local/bin'
  ok "trufflehog installed"
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
  # Filter the JSON event stream to lifecycle markers; full stream lands in
  # /.sprite/logs/services/dockerd.log. PIPESTATUS keeps real failures visible.
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
  return 0
}

phase_flyctl() {
  if [[ $FORCE -ne 1 ]] && command -v flyctl >/dev/null 2>&1; then
    skip "flyctl already installed"
    return 0
  fi
  info "installing flyctl..."
  quiet flyctl bash -c 'curl -fsSL https://fly.io/install.sh | sh -s -- --non-interactive'
  export PATH="$HOME/.fly/bin:$PATH"
  ok "flyctl installed"
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
      # Check existing token actually has the scopes we need.
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
  # that may leak across stdout/stderr. Requires admin:public_key /
  # admin:ssh_signing_key (granted by phase_gh_auth).
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

  # GitHub takes a moment to propagate newly uploaded keys to the SSH layer.
  # Some runs need >30s. Retry with backoff and capture the last error.
  local last_output="" total=0 wait=3
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

# direnv (auto-detect current shell)
if command -v direnv >/dev/null 2>&1; then
  case "$(basename "${SHELL:-bash}")" in
    bash) eval "$(direnv hook bash)" ;;
    zsh)  eval "$(direnv hook zsh)"  ;;
  esac
fi

# fzf keybindings (if present)
[ -f /usr/share/doc/fzf/examples/key-bindings.bash ] && [ -n "$BASH_VERSION" ] && \
  source /usr/share/doc/fzf/examples/key-bindings.bash
[ -f /usr/share/doc/fzf/examples/key-bindings.zsh ]  && [ -n "$ZSH_VERSION" ]  && \
  source /usr/share/doc/fzf/examples/key-bindings.zsh

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
# <<< dev-env-setup shell additions <
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
# Run
# ============================================================================
START_TIME=$(date +%s)

run_phase apt_core         phase_apt_core
run_phase corepack         phase_corepack
run_phase uv               phase_uv
run_phase semgrep          phase_semgrep
run_phase trufflehog       phase_trufflehog
run_phase docker           phase_docker
run_phase dockerd_service  phase_dockerd_service
run_phase flyctl           phase_flyctl
run_phase ssh_known_hosts  phase_ssh_known_hosts
run_phase git_identity     phase_git_identity
run_phase ssh_key          phase_ssh_key
run_phase gh_auth          phase_gh_auth
run_phase gh_upload_keys   phase_gh_upload_keys
run_phase git_signing      phase_git_signing
run_phase rc_additions     phase_rc_additions

ELAPSED=$(( $(date +%s) - START_TIME ))
echo
print_summary
echo
log "All done (${ELAPSED}s)"

# Tell the user about their actual shell, not "bash or zsh".
case "$(basename "${SHELL:-bash}")" in
  zsh)  RC_FILE="$HOME/.zshrc"  ;;
  bash) RC_FILE="$HOME/.bashrc" ;;
  fish) RC_FILE="$HOME/.config/fish/config.fish"
        warn "fish detected; rc additions were written to .bashrc/.zshrc only" ;;
  *)    RC_FILE="$HOME/.bashrc" ;;
esac
info "1. Open a new shell or run: source $RC_FILE"
info "2. For docker without sudo: log out/in, or run 'newgrp docker'"
info "3. Per-phase logs (if you want to inspect): $PHASE_LOG_DIR/"
info "4. Verify with: ./post.sh"
echo
