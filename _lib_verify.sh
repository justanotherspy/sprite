#!/usr/bin/env bash
#
# _lib_verify.sh
# Post-install verification logic for sprite.dev bootstrap, in a sourceable form.
#
# Sourced by:
#   - post.sh             (standalone health-check entry point)
#   - setup.sh phase_verify (runs inline at the end of bootstrap)
#
# Owner: Daniel Schwartz <danielschwar@gmail.com> (justanotherspy)
#
# This file defines: helper functions, verification sections (verify_*),
# verify_run_all (executes every section), and verify_print_summary
# (prints PASS/WARN/FAIL counts and returns 0 or 1).
#
# The caller is responsible for:
#   - Setting the four identity variables before sourcing:
#       GIT_USER_NAME, GIT_USER_EMAIL, GIT_DEFAULT_BRANCH, GH_USERNAME
#   - Configuring any output-mirroring redirection it wants (LOG_FILE).
#   - Calling verify_run_all (no args) and then verify_print_summary.
#
# Sourcing this file inside setup.sh's phase_verify should happen inside
# a `( ... )` subshell so this lib's helper definitions do not shadow
# setup.sh's helpers for the rest of the run.

# ============================================================================
# Required globals (fail fast if caller forgot)
# ============================================================================
: "${GIT_USER_NAME:?_lib_verify.sh requires GIT_USER_NAME to be set}"
: "${GIT_USER_EMAIL:?_lib_verify.sh requires GIT_USER_EMAIL to be set}"
: "${GIT_DEFAULT_BRANCH:?_lib_verify.sh requires GIT_DEFAULT_BRANCH to be set}"
: "${GH_USERNAME:?_lib_verify.sh requires GH_USERNAME to be set}"

# Ensure HOSTNAME is set (not always exported in non-interactive bash).
: "${HOSTNAME:=$(hostname)}"
export HOSTNAME

# Make setup.sh's installs visible even before login refresh.
export PATH="$HOME/.local/bin:$HOME/.fly/bin:/usr/local/bin:$PATH"

# ============================================================================
# Colors (define only if caller didn't)
# ============================================================================
: "${RED:=$'\033[31m'}"
: "${GREEN:=$'\033[32m'}"
: "${YELLOW:=$'\033[33m'}"
: "${BLUE:=$'\033[34m'}"
: "${GREY:=$'\033[90m'}"
: "${BOLD:=$'\033[1m'}"
: "${RESET:=$'\033[0m'}"

# ============================================================================
# Counters + failure buffer (scoped to the sourcing shell)
# ============================================================================
PASS=0
FAIL=0
WARN=0
FAILURES=()   # each entry: "title" + newline + indented diag block

# ============================================================================
# Helper functions
# ============================================================================
log()  { printf "\n%s%s==>%s %s\n" "$BLUE" "$BOLD" "$RESET" "$*"; }
sub()  { printf "%s--- %s ---%s\n" "$GREY" "$*" "$RESET"; }
info() { printf "    %s\n" "$*"; }
ok()   { PASS=$((PASS+1)); printf "%s+%s %s\n" "$GREEN" "$RESET" "$*"; }
note() {                   printf "%s+%s %s\n" "$GREEN" "$RESET" "$*"; }   # passive
warn() { WARN=$((WARN+1)); printf "%s!%s %s\n" "$YELLOW" "$RESET" "$*"; }
skip() {                   printf "%s-%s %s%s%s\n" "$GREY" "$RESET" "$GREY" "$*" "$RESET"; }

# record_fail TITLE [DIAG_TEXT]
# Prints the failure inline (red x) with diag indented, appends to FAILURES.
record_fail() {
  local title="$1"
  local diag="${2:-}"
  FAIL=$((FAIL+1))
  printf "%sx%s %s\n" "$RED" "$RESET" "$title"
  if [[ -n "$diag" ]]; then
    printf "%s\n" "$diag" | sed 's/^/    /'
    FAILURES+=("$(printf '%s\n%s' "$title" "$diag")")
  else
    FAILURES+=("$title")
  fi
}

# kv KEY VALUE — fixed-width "key : value" line for diagnostic blocks.
kv() { printf "%-32s : %s\n" "$1" "$2"; }

# ============================================================================
# Per-tool --version invocation. Some CLIs reject `--version` (cosign 3.x
# uses the `version` subcommand, go uses `version`, gitleaks too). Returning
# from a lookup table keeps the version column readable instead of showing
# "Error: unknown flag: --version".
# ============================================================================
version_args_for() {
  case "$1" in
    cosign|gitleaks|go) printf 'version' ;;
    tmux)               printf '%s' '-V' ;;
    xclip)              printf '%s' '-version' ;;
    *)                  printf '%s' '--version' ;;
  esac
}

# ============================================================================
# RC sentinels + expected block (must byte-match setup.sh's RC_BLOCK heredoc)
# ============================================================================
RC_OPEN_SENTINEL="# >>> dev-env-setup shell additions >>>"
RC_CLOSE_SENTINEL="# <<< dev-env-setup shell additions <<<"
RC_LEGACY_OPEN="# >>> dev-env-setup GH_TOKEN >>>"

# If you change setup.sh's RC_BLOCK, change this too. The diff in the
# failure diagnostic is what tells you whether rc files match.
RC_BLOCK_EXPECTED=$(cat <<'EOF'
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

# Presence-check strings inside the rc sentinel block (load-bearing only).
# shellcheck disable=SC2016  # literal patterns to grep for, must NOT expand
REQUIRED_RC_STRINGS=(
  'export PATH="$HOME/.local/bin:$PATH"'
  '$HOME/.fly/bin'
  'export GH_TOKEN="$(gh auth token 2>/dev/null)"'
  'export GITHUB_TOKEN="$GH_TOKEN"'
  '$BASH_VERSION'
  '$ZSH_VERSION'
  'eval "$(direnv hook bash)"'
  'eval "$(direnv hook zsh)"'
  'eval "$(zoxide init bash)"'
  'eval "$(zoxide init zsh)"'
  '/usr/share/doc/fzf/examples/key-bindings.bash'
  '/usr/share/doc/fzf/examples/key-bindings.zsh'
  '$HOME/.zsh/completions'
  'autoload -Uz compinit && compinit -i'
  '$HOME/.local/share/sprite-setup/ps1.sh'
  "alias gl='git log --oneline --graph --decorate'"
  "alias gp='git pull --rebase'"
  "alias d='docker'"
  "alias dc='docker compose'"
  "alias t='tmux attach || tmux new'"
)

extract_rc_block() {
  local rc="$1"
  sed -n "/${RC_OPEN_SENTINEL}/,/${RC_CLOSE_SENTINEL}/p" "$rc" 2>/dev/null
}

# ============================================================================
# Tool inventory
# ============================================================================
# Binaries setup.sh is responsible for. Missing here = critical fail.
# Wave A additions: tmux, tldr, hyperfine, zoxide (tldr provided by tealdeer).
# Wave B additions: hadolint, dive, gitleaks, ruff, black, pre-commit.
SETUP_TOOLS=(
  shellcheck bat fd rg fzf jq ncdu mosh nvim btop direnv yq traceroute xclip
  tmux tldr hyperfine zoxide
  uv uvx semgrep trufflehog cosign garlic
  black pre-commit ruff
  dive gitleaks hadolint
  docker
  flyctl
  pnpm yarn
)

# Pre-installed by the sprite base image. Missing here = warn (the sprite
# itself drifted, not setup.sh).
SPRITE_TOOLS=(
  gh node npm bun deno python3 pip go ruby rustc cargo elixir java
  claude
  sprite sprite-env
)

check_tool() {
  local cmd="$1" criticality="$2"   # criticality: critical | sprite
  if command -v "$cmd" >/dev/null 2>&1; then
    local p v ver_args
    p="$(command -v "$cmd")"
    ver_args="$(version_args_for "$cmd")"
    # 10s timeout: semgrep's Python import path can exceed 5s on first run.
    # Filter lines that look like node stack frames so a broken JS tool can't
    # corrupt the version column. grep -m1 '[0-9]' then picks the first real
    # version line (skips banners, blank lines, etc).
    # shellcheck disable=SC2086  # ver_args is a single word; intentional split
    v="$(timeout 10 "$cmd" $ver_args </dev/null 2>&1 \
      | grep -vE '^\s+at\s|\(node:[0-9]+:' \
      | grep -m1 -E '[0-9]' || true)"
    [[ -z "$v" ]] && v="(version unavailable)"
    ok "$(printf '%-12s %-45s %s' "$cmd" "$p" "$v")"
    return
  fi
  local parent diag
  parent="$(dirname "$(command -v "$cmd" 2>/dev/null || echo "$HOME/.local/bin/$cmd")")"
  diag="$(
    kv "command"          "$cmd"
    kv "expected on PATH" "yes"
    kv "result"           "not found"
    echo
    echo "Current PATH (one per line):"
    echo "$PATH" | tr ':' '\n' | sed 's/^/  /'
    echo
    echo "ls -la $parent:"
    ls -la "$parent" 2>&1 | sed 's/^/  /'
  )"
  if [[ "$criticality" == "critical" ]]; then
    record_fail "tool missing: $cmd" "$diag"
  else
    warn "sprite-provided tool missing: $cmd (sprite base image may have drifted)"
  fi
}

# ============================================================================
# 1. Identity
# ============================================================================
verify_identity() {
  log "Identity"
  note "whoami : $(whoami)"
  note "id     : $(id)"
  note "HOME   : ${HOME:-(unset)}"
  note "USER   : ${USER:-(unset)}"
  note "SHELL  : ${SHELL:-(unset)}"
  note "HOST   : $HOSTNAME"
}

# ============================================================================
# 2. Tool versions
# ============================================================================
verify_tool_versions() {
  log "Tool versions"
  sub "Installed by setup.sh"
  local t
  for t in "${SETUP_TOOLS[@]}"; do check_tool "$t" critical; done

  sub "Pre-installed by the sprite (presence only)"
  for t in "${SPRITE_TOOLS[@]}"; do check_tool "$t" sprite; done

  sub "Symlinks (bat -> batcat, fd -> fdfind)"
  local pair name target link actual
  for pair in "bat:/usr/bin/batcat" "fd:/usr/bin/fdfind"; do
    name="${pair%%:*}"; target="${pair##*:}"
    link="$HOME/.local/bin/$name"
    if [[ -L "$link" ]]; then
      actual="$(readlink "$link")"
      if [[ "$actual" == "$target" ]]; then
        ok "$link -> $target"
      else
        record_fail "symlink $link points to wrong target" "$(
          kv "link"            "$link"
          kv "expected target" "$target"
          kv "actual target"   "$actual"
          ls -la "$link" 2>&1
        )"
      fi
    else
      record_fail "symlink missing: $link -> $target" "$(
        kv "expected"          "$link -> $target"
        ls -la "$HOME/.local/bin/" 2>&1 | sed 's/^/  /'
      )"
    fi
  done

  sub "claude settings + statusline"
  local cfg="$HOME/.claude/settings.json"
  local sl="$HOME/.claude/statusline.py"
  local expected_cmd="python3 $HOME/.claude/statusline.py"

  if [[ -f "$cfg" ]]; then
    # Each pair is "jq-path|expected" so the loop stays generic.
    local pair path expected actual mismatches=()
    for pair in \
      '.tui|fullscreen' \
      '.theme|dark' \
      '.skipDangerousModePermissionPrompt|true' \
      '.permissions.defaultMode|bypassPermissions' \
      '.statusLine.type|command' \
      ".statusLine.command|$expected_cmd" \
    ; do
      path="${pair%%|*}"
      expected="${pair#*|}"
      actual="$(jq -r "$path // \"\"" "$cfg" 2>/dev/null)"
      if [[ "$actual" == "$expected" ]]; then
        ok "settings.json $path = $expected"
      else
        mismatches+=("$path  expected=$expected  actual=${actual:-(unset)}")
      fi
    done
    if [[ ${#mismatches[@]} -gt 0 ]]; then
      record_fail "settings.json missing or wrong key(s)" "$(
        local m
        for m in "${mismatches[@]}"; do printf "  %s\n" "$m"; done
        echo
        echo "Current settings.json:"
        sed 's/^/  /' "$cfg"
      )"
    fi
  else
    record_fail "~/.claude/settings.json missing" ""
  fi

  if [[ -f "$sl" ]]; then
    local mode
    mode="$(stat -c '%a' "$sl")"
    if [[ "$mode" == "755" ]]; then
      ok "$sl mode=755"
    else
      record_fail "$sl wrong mode: $mode (expected 755)" ""
    fi
    if python3 -c "import py_compile; py_compile.compile('$sl', doraise=True)" >/dev/null 2>&1; then
      ok "$sl parses as Python"
    else
      record_fail "$sl does not parse as Python" "$(
        python3 -c "import py_compile; py_compile.compile('$sl', doraise=True)" 2>&1 | sed 's/^/  /'
      )"
    fi
  else
    record_fail "$sl missing" ""
  fi

  sub "cloned repos in ~/repos"
  local repo
  for repo in garlic poker sprite justanotherspy.com; do
    if [[ -d "$HOME/repos/$repo/.git" ]]; then
      ok "$HOME/repos/$repo present"
    else
      record_fail "$HOME/repos/$repo missing" "$(
        kv "expected" "$HOME/repos/$repo/.git"
        ls -la "$HOME/repos/" 2>&1 | sed 's/^/  /'
      )"
    fi
  done
}

# ============================================================================
# 3. Docker
# ============================================================================
verify_docker() {
  log "Docker"

  dockerd_diag() {
    kv "id"                "$(id)"
    kv "/var/run/docker.sock"  "$(ls -la /var/run/docker.sock 2>&1 || echo '(absent)')"
    echo
    echo "docker version:"
    docker version 2>&1 | sed 's/^/  /'
    echo
    echo "docker info:"
    docker info 2>&1 | sed 's/^/  /'
    echo
    echo "/etc/docker/daemon.json:"
    if [[ -f /etc/docker/daemon.json ]]; then
      sed 's/^/  /' /etc/docker/daemon.json
    else
      echo "  (missing)"
    fi
    echo
    echo "sprite-env services list:"
    if command -v sprite-env >/dev/null 2>&1; then
      sprite-env services list 2>&1 | sed 's/^/  /'
    else
      echo "  (sprite-env not on PATH)"
    fi
    echo
    echo "Last 30 lines of /.sprite/logs/services/dockerd.log:"
    tail -n 30 /.sprite/logs/services/dockerd.log 2>&1 | sed 's/^/  /'
  }

  sub "daemon reachable as $(whoami)"
  if docker info >/dev/null 2>&1; then
    ok "docker info succeeded (no sudo)"
  else
    record_fail "docker daemon not reachable" "$(dockerd_diag)"
  fi

  sub "/etc/docker/daemon.json"
  if [[ -f /etc/docker/daemon.json ]]; then
    ok "/etc/docker/daemon.json exists"
    local log_driver max_size max_file live_restore
    if command -v yq >/dev/null 2>&1; then
      log_driver="$(yq -r '.["log-driver"] // ""' /etc/docker/daemon.json 2>/dev/null)"
      max_size="$(yq -r '.["log-opts"]["max-size"] // ""' /etc/docker/daemon.json 2>/dev/null)"
      max_file="$(yq -r '.["log-opts"]["max-file"] // ""' /etc/docker/daemon.json 2>/dev/null)"
      live_restore="$(yq -r '.["live-restore"] // ""' /etc/docker/daemon.json 2>/dev/null)"
    else
      log_driver="$(grep -oE '"log-driver"[^,}]*' /etc/docker/daemon.json | head -1 | sed 's/.*: *"//; s/".*//')"
      max_size="$(grep -oE '"max-size"[^,}]*' /etc/docker/daemon.json | head -1 | sed 's/.*: *"//; s/".*//')"
      max_file="$(grep -oE '"max-file"[^,}]*' /etc/docker/daemon.json | head -1 | sed 's/.*: *"//; s/".*//')"
      live_restore="$(grep -oE '"live-restore"[^,}]*' /etc/docker/daemon.json | head -1 | sed 's/.*: *//')"
    fi
    local daemon_check_failed=0
    [[ "$log_driver"   == "json-file" ]] || daemon_check_failed=1
    [[ "$max_size"     == "20m"       ]] || daemon_check_failed=1
    [[ "$max_file"     == "5"         ]] || daemon_check_failed=1
    [[ "$live_restore" == "true"      ]] || daemon_check_failed=1
    if [[ $daemon_check_failed -eq 0 ]]; then
      ok "daemon.json: log-driver=json-file, max-size=20m, max-file=5, live-restore=true"
    else
      record_fail "daemon.json values not what setup.sh writes" "$(
        kv "log-driver   (expected json-file)" "${log_driver:-(unset)}"
        kv "max-size     (expected 20m)"       "${max_size:-(unset)}"
        kv "max-file     (expected 5)"         "${max_file:-(unset)}"
        kv "live-restore (expected true)"      "${live_restore:-(unset)}"
        echo
        echo "raw daemon.json:"
        sed 's/^/  /' /etc/docker/daemon.json
      )"
    fi
  else
    record_fail "/etc/docker/daemon.json missing" "$(dockerd_diag)"
  fi

  sub "docker group membership"
  if id -nG "$(whoami)" | tr ' ' '\n' | grep -qx docker; then
    ok "$(whoami) is in 'docker' group"
  else
    record_fail "$(whoami) not in 'docker' group" "$(
      kv "id"     "$(id)"
      kv "groups" "$(id -nG)"
      echo "(fix: sudo usermod -aG docker $(whoami) && newgrp docker, or re-login)"
    )"
  fi

  sub "dockerd sprite Service"
  if command -v sprite-env >/dev/null 2>&1; then
    if sprite-env services list 2>/dev/null | grep -q '"dockerd"'; then
      ok "dockerd Service registered with sprite-env"
    else
      record_fail "dockerd Service not registered (won't survive sprite hibernation)" "$(
        echo "sprite-env services list:"
        sprite-env services list 2>&1 | sed 's/^/  /'
      )"
    fi
  else
    record_fail "sprite-env not on PATH; cannot verify dockerd Service" "$(
      kv "PATH" "$PATH"
      echo
      echo "Expected sprite-env under /.sprite/bin/. Contents of /.sprite/bin/:"
      ls -la /.sprite/bin/ 2>&1 | sed 's/^/  /'
    )"
  fi

  sub "/.sprite/logs/services/dockerd.log"
  if [[ -f /.sprite/logs/services/dockerd.log ]]; then
    ok "dockerd.log present ($(wc -l < /.sprite/logs/services/dockerd.log) lines)"
  else
    warn "/.sprite/logs/services/dockerd.log missing (Service may not have started yet)"
  fi

  # Hello-world end-to-end check (soft-fail on egress block; some sprite
  # network policies don't reach Docker Hub).
  sub "docker run --rm hello-world (end-to-end smoke)"
  if docker info >/dev/null 2>&1; then
    local hw_out hw_rc
    hw_out="$(docker run --rm hello-world 2>&1)"
    hw_rc=$?
    if [[ $hw_rc -eq 0 ]] && echo "$hw_out" | grep -q "Hello from Docker"; then
      ok "hello-world ran cleanly"
    else
      warn "hello-world failed (likely registry egress blocked; not a setup.sh issue)"
      printf "    %s\n" "rc=$hw_rc"
      echo "$hw_out" | head -n 8 | sed 's/^/    /'
    fi
  else
    skip "skipping hello-world (docker not reachable)"
  fi
}

# ============================================================================
# 4. SSH
# ============================================================================
verify_ssh() {
  log "SSH"

  local ssh_dir="$HOME/.ssh"
  local priv="$ssh_dir/id_ed25519"
  local pub="$priv.pub"
  local signers="$ssh_dir/allowed_signers"
  local known="$ssh_dir/known_hosts"

  ssh_diag() {
    kv "ssh dir"   "$ssh_dir ($(stat -c '%a' "$ssh_dir" 2>/dev/null || echo '(absent)'))"
    echo
    echo "ls -la $ssh_dir:"
    ls -la "$ssh_dir" 2>&1 | sed 's/^/  /'
  }

  local mode
  sub "directory mode (expected 700)"
  if [[ -d "$ssh_dir" ]]; then
    mode="$(stat -c '%a' "$ssh_dir")"
    if [[ "$mode" == "700" ]]; then
      ok "$ssh_dir mode=700"
    else
      record_fail "$ssh_dir wrong mode: $mode (expected 700)" "$(ssh_diag)"
    fi
  else
    record_fail "$ssh_dir does not exist" "$(ssh_diag)"
  fi

  sub "known_hosts (github.com, expected mode 644)"
  if [[ ! -f "$known" ]]; then
    record_fail "$known missing" "$(ssh_diag)"
  else
    mode="$(stat -c '%a' "$known")"
    if [[ "$mode" == "644" ]]; then
      ok "$known mode=644"
    else
      record_fail "$known wrong mode: $mode (expected 644)" "$(ssh_diag)"
    fi
    if ssh-keygen -F github.com -f "$known" >/dev/null 2>&1; then
      ok "github.com host key in $known"
    else
      record_fail "github.com missing from known_hosts" "$(
        kv "known_hosts" "$known (mode=$mode)"
        echo
        echo "ssh-keygen -F github.com:"
        ssh-keygen -F github.com -f "$known" 2>&1 | sed 's/^/  /'
      )"
    fi
  fi

  sub "id_ed25519 (private; expected mode 600)"
  if [[ -f "$priv" ]]; then
    mode="$(stat -c '%a' "$priv")"
    if [[ "$mode" == "600" ]]; then
      ok "$priv mode=600"
    else
      record_fail "$priv wrong mode: $mode (expected 600)" "$(ssh_diag)"
    fi
  else
    record_fail "$priv missing" "$(ssh_diag)"
  fi

  sub "id_ed25519.pub (expected mode 644)"
  if [[ -f "$pub" ]]; then
    mode="$(stat -c '%a' "$pub")"
    if [[ "$mode" == "644" ]]; then
      ok "$pub mode=644"
    else
      record_fail "$pub wrong mode: $mode (expected 644)" "$(ssh_diag)"
    fi
  else
    record_fail "$pub missing" "$(ssh_diag)"
  fi

  sub "allowed_signers (expected mode 644)"
  if [[ ! -f "$signers" ]]; then
    record_fail "$signers missing" "$(ssh_diag)"
  else
    mode="$(stat -c '%a' "$signers")"
    if [[ "$mode" == "644" ]]; then
      ok "$signers mode=644"
    else
      record_fail "$signers wrong mode: $mode (expected 644)" "$(ssh_diag)"
    fi
    if [[ -f "$pub" ]] && grep -qF "$(cat "$pub")" "$signers" 2>/dev/null \
       && grep -qE "^${GIT_USER_EMAIL//./\\.}[[:space:]]+namespaces=\"git\"[[:space:]]+ssh-ed25519[[:space:]]+" "$signers"; then
      ok "$signers contains a 'namespaces=\"git\" ssh-ed25519 ...' line matching id_ed25519.pub"
    else
      record_fail "$signers does not contain the expected entry" "$(
        kv "expected pattern" "${GIT_USER_EMAIL} namespaces=\"git\" ssh-ed25519 <body>"
        kv "signers mode"     "$mode"
        echo
        echo "First line of allowed_signers:"
        head -n1 "$signers" 2>&1 | sed 's/^/  /'
        echo
        echo "id_ed25519.pub body:"
        [[ -f "$pub" ]] && sed 's/^/  /' "$pub" || echo "  (missing)"
        echo
        echo "ssh-keygen -y -f $priv (does the private key derive a usable public?):"
        ssh-keygen -y -f "$priv" 2>&1 | sed 's/^/  /'
      )"
    fi
  fi

  sub "ssh -T git@github.com (authenticated end-to-end)"
  local ssh_auth_ok=0 ssh_last="" total=0 wait=3 attempt
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    ssh_last="$(ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes \
                    -o ConnectTimeout=5 -T git@github.com 2>&1 || true)"
    if echo "$ssh_last" | grep -q "successfully authenticated"; then
      ssh_auth_ok=1
      break
    fi
    sleep "$wait"
    total=$((total + wait))
    (( attempt >= 4 )) && wait=5
  done
  if [[ $ssh_auth_ok -eq 1 ]]; then
    ok "github SSH auth verified (attempt=$attempt, ${total}s waited)"
  else
    record_fail "github SSH auth failed after ${total}s" "$(
      echo "Last ssh output:"
      echo "$ssh_last" | sed 's/^/  /'
      echo
      echo "ssh -vT git@github.com (verbose):"
      ssh -o BatchMode=yes -o ConnectTimeout=5 -vT git@github.com 2>&1 | sed 's/^/  /'
      echo
      echo "ssh-add -l:"
      ssh-add -l 2>&1 | sed 's/^/  /'
      echo
      echo "ls -la $ssh_dir:"
      ls -la "$ssh_dir" 2>&1 | sed 's/^/  /'
      echo
      echo "ssh-keygen -F github.com -f $known:"
      ssh-keygen -F github.com -f "$known" 2>&1 | sed 's/^/  /'
    )"
  fi
}

# ============================================================================
# 5. gh CLI
# ============================================================================
verify_gh() {
  log "gh CLI"

  local gh_status_out=""
  if command -v gh >/dev/null 2>&1; then
    gh_status_out="$(gh auth status -h github.com 2>&1 || true)"
  fi

  gh_diag() {
    echo "gh auth status -h github.com:"
    echo "$gh_status_out" | sed 's/^/  /'
    echo
    echo "gh api user --jq .login:"
    gh api user --jq .login 2>&1 | sed 's/^/  /'
    echo
    echo "$HOME/.config/gh/hosts.yml:"
    if [[ -f "$HOME/.config/gh/hosts.yml" ]]; then
      kv "  mode" "$(stat -c '%a' "$HOME/.config/gh/hosts.yml")"
      sed 's/^/  /' "$HOME/.config/gh/hosts.yml"
    else
      echo "  (absent)"
    fi
  }

  sub "gh auth status"
  if [[ -z "$gh_status_out" ]]; then
    record_fail "gh not installed or not on PATH" "$(
      kv "command -v gh" "$(command -v gh 2>&1 || echo 'not found')"
      kv "PATH"          "$PATH"
    )"
  elif echo "$gh_status_out" | grep -q "Logged in to github.com"; then
    ok "gh authenticated to github.com"
  else
    record_fail "gh not authenticated to github.com" "$(gh_diag)"
  fi

  sub "gh api user --jq .login (expected $GH_USERNAME)"
  local who
  who="$(gh api user --jq .login 2>/dev/null || echo "")"
  if [[ "$who" == "$GH_USERNAME" ]]; then
    ok "gh api user = $who"
  else
    record_fail "gh user mismatch: got '$who', expected '$GH_USERNAME'" "$(gh_diag)"
  fi

  sub "token scopes (expected admin:public_key AND admin:ssh_signing_key)"
  local has_public_key=0 has_signing_key=0
  echo "$gh_status_out" | grep -q "admin:public_key"      && has_public_key=1
  echo "$gh_status_out" | grep -q "admin:ssh_signing_key" && has_signing_key=1
  if [[ $has_public_key -eq 1 && $has_signing_key -eq 1 ]]; then
    ok "token has admin:public_key + admin:ssh_signing_key"
  else
    record_fail "token missing required scope(s)" "$(
      kv "admin:public_key"      "$( [[ $has_public_key  -eq 1 ]] && echo present || echo MISSING)"
      kv "admin:ssh_signing_key" "$( [[ $has_signing_key -eq 1 ]] && echo present || echo MISSING)"
      echo
      echo "Full gh auth status:"
      echo "$gh_status_out" | sed 's/^/  /'
      echo "(fix: gh auth refresh -h github.com -s admin:public_key,admin:ssh_signing_key)"
    )"
  fi

  sub "key uploads on github (sprite-${HOSTNAME}-auth / -signing)"
  local title_auth="sprite-${HOSTNAME}-auth"
  local title_sign="sprite-${HOSTNAME}-signing"
  local auth_titles sign_titles
  auth_titles="$(gh api user/keys --jq '.[].title' 2>/dev/null || true)"
  sign_titles="$(gh api user/ssh_signing_keys --jq '.[].title' 2>/dev/null || true)"

  if grep -qFx "$title_auth" <<<"$auth_titles"; then
    ok "auth key '$title_auth' present on github"
  else
    record_fail "auth key '$title_auth' missing on github" "$(
      kv "endpoint"   "user/keys"
      echo
      echo "Existing auth-key titles:"
      printf '%s\n' "$auth_titles" | sed 's/^/  /'
    )"
  fi

  if grep -qFx "$title_sign" <<<"$sign_titles"; then
    ok "signing key '$title_sign' present on github"
  else
    record_fail "signing key '$title_sign' missing on github" "$(
      kv "endpoint"   "user/ssh_signing_keys"
      echo
      echo "Existing signing-key titles:"
      printf '%s\n' "$sign_titles" | sed 's/^/  /'
    )"
  fi

  # Fingerprint compare: local pub vs whatever GitHub has under our titles.
  local pub="$HOME/.ssh/id_ed25519.pub"
  if [[ -f "$pub" ]]; then
    local local_fp
    local_fp="$(ssh-keygen -lf "$pub" 2>/dev/null | awk '{print $2}')"
    gh_fp_for() {
      local title="$1" endpoint="$2"
      local body
      body="$(gh api "$endpoint" --jq ".[] | select(.title==\"$title\") | .key" 2>/dev/null | head -1)"
      [[ -z "$body" ]] && return 1
      printf '%s\n' "$body" | ssh-keygen -lf - 2>/dev/null | awk '{print $2}'
    }
    local pair kind title endpoint gh_fp
    for pair in "auth:$title_auth:user/keys" "signing:$title_sign:user/ssh_signing_keys"; do
      kind="${pair%%:*}"
      title="$(echo "$pair" | cut -d: -f2)"
      endpoint="$(echo "$pair" | cut -d: -f3)"
      if [[ "$kind" == "auth"    ]] && ! grep -qFx "$title" <<<"$auth_titles"; then continue; fi
      if [[ "$kind" == "signing" ]] && ! grep -qFx "$title" <<<"$sign_titles"; then continue; fi
      gh_fp="$(gh_fp_for "$title" "$endpoint" || true)"
      if [[ -z "$gh_fp" ]]; then
        record_fail "could not fetch github $kind key body for '$title'" "$(
          kv "title"    "$title"
          kv "endpoint" "$endpoint"
        )"
      elif [[ "$gh_fp" == "$local_fp" ]]; then
        ok "$kind key on github ($title) matches local pub ($local_fp)"
      else
        record_fail "$kind key on github does NOT match local id_ed25519.pub" "$(
          kv "title"             "$title"
          kv "local fingerprint" "$local_fp"
          kv "github fingerprint" "$gh_fp"
          echo
          echo "(fix: remove stale key from GitHub and re-run setup.sh --only gh_upload_keys --force)"
        )"
      fi
    done
  fi
}

# ============================================================================
# 6. Git config
# ============================================================================
verify_git_config() {
  log "Git config"

  git_diag_for() {
    local key="$1" expected="$2" actual="$3"
    kv "key"        "$key"
    kv "expected"   "$expected"
    kv "actual"     "${actual:-(unset)}"
    echo
    echo "git config --global --list:"
    git config --global --list 2>&1 | sed 's/^/  /'
    echo
    echo "potential override sources:"
    if [[ -f /etc/gitconfig ]]; then
      echo "  /etc/gitconfig EXISTS (could override):"
      sed 's/^/    /' /etc/gitconfig
    else
      echo "  /etc/gitconfig absent"
    fi
    if [[ -f "$HOME/.config/git/config" ]]; then
      echo "  ~/.config/git/config EXISTS (could override):"
      sed 's/^/    /' "$HOME/.config/git/config"
    else
      echo "  ~/.config/git/config absent"
    fi
  }

  check_git_config() {
    local key="$1" expected="$2" actual
    actual="$(git config --global "$key" 2>/dev/null || true)"
    if [[ "$actual" == "$expected" ]]; then
      ok "$key = $expected"
    else
      record_fail "git config $key wrong" "$(git_diag_for "$key" "$expected" "$actual")"
    fi
  }

  sub "overriding gitconfig sources"
  local override_problems=() override_warnings=() src key val expected_val
  for src in "/etc/gitconfig" "$HOME/.config/git/config"; do
    [[ -f "$src" ]] || continue
    for key in user.name user.email; do
      val="$(git config --file "$src" --get "$key" 2>/dev/null || true)"
      [[ -z "$val" ]] && continue
      expected_val="$GIT_USER_NAME"
      [[ "$key" == "user.email" ]] && expected_val="$GIT_USER_EMAIL"
      if [[ "$val" != "$expected_val" ]]; then
        override_problems+=("$src sets $key=$val (expected: $expected_val)")
      else
        override_warnings+=("$src sets $key=$val (matches; remove for clarity)")
      fi
    done
  done
  if [[ ${#override_problems[@]} -gt 0 ]]; then
    local diag=""
    local p w
    for p in "${override_problems[@]}"; do diag+="$p"$'\n'; done
    diag+=$'\n'"resolved value (what git actually uses):"$'\n'
    diag+="  user.name  = $(git config --get user.name)"$'\n'
    diag+="  user.email = $(git config --get user.email)"$'\n'
    diag+=$'\n'"(fix: remove user.* from /etc/gitconfig and ~/.config/git/config so ~/.gitconfig is the only source)"
    record_fail "non-global gitconfig sets a conflicting user.*" "$diag"
  elif [[ ${#override_warnings[@]} -gt 0 ]]; then
    warn "non-global gitconfig also sets user.* (matches expected, but is a future-trap):"
    for w in "${override_warnings[@]}"; do printf "    %s\n" "$w"; done
  else
    ok "no overriding gitconfig sets user.name or user.email"
  fi

  sub "identity + defaults"
  check_git_config user.name            "$GIT_USER_NAME"
  check_git_config user.email           "$GIT_USER_EMAIL"
  check_git_config init.defaultBranch   "$GIT_DEFAULT_BRANCH"
  check_git_config pull.rebase          "true"
  check_git_config push.autoSetupRemote "true"
  check_git_config rerere.enabled       "true"
  check_git_config fetch.prune          "true"
  check_git_config core.editor          "vim"
  check_git_config core.excludesFile    "$HOME/.gitignore_global"

  sub "aliases"
  local EXPECTED_ALIASES=(lg last amend unstage cleanb) a v
  for a in "${EXPECTED_ALIASES[@]}"; do
    v="$(git config --global "alias.$a" 2>/dev/null || true)"
    if [[ -n "$v" ]]; then
      ok "alias.$a is set"
    else
      record_fail "git alias.$a not set" "$(
        kv "key" "alias.$a"
        echo
        echo "git config --global --get-regexp '^alias\\.' output:"
        git config --global --get-regexp '^alias\.' 2>&1 | sed 's/^/  /'
      )"
    fi
  done
}

# ============================================================================
# 7. Git signing
# ============================================================================
verify_git_signing() {
  log "Git signing"

  local priv="$HOME/.ssh/id_ed25519"
  local pub="$priv.pub"
  local signers="$HOME/.ssh/allowed_signers"

  signing_diag() {
    echo "git config keys under gpg.* / commit.* / tag.* / user.signingkey:"
    local k
    for k in gpg.format user.signingkey commit.gpgsign tag.gpgsign gpg.ssh.allowedSignersFile; do
      printf "  %-32s = %s\n" "$k" "$(git config --global "$k" 2>/dev/null || echo '(unset)')"
    done
    echo
    if [[ -f "$signers" ]]; then
      echo "allowed_signers ($signers, mode=$(stat -c '%a' "$signers")):"
      head -n1 "$signers" 2>&1 | sed 's/^/  /'
    else
      echo "allowed_signers ($signers): (absent)"
    fi
    echo
    echo "ssh-keygen -y -f $priv (does the private key derive a usable public?):"
    ssh-keygen -y -f "$priv" 2>&1 | sed 's/^/  /'
  }

  check_git_signing_config() {
    local key="$1" expected="$2" actual
    actual="$(git config --global "$key" 2>/dev/null || true)"
    if [[ "$actual" == "$expected" ]]; then
      ok "$key = $expected"
    else
      record_fail "git config $key wrong" "$(
        kv "key"      "$key"
        kv "expected" "$expected"
        kv "actual"   "${actual:-(unset)}"
        echo
        signing_diag
      )"
    fi
  }

  sub "signing config"
  check_git_signing_config gpg.format                   "ssh"
  check_git_signing_config user.signingkey              "$pub"
  check_git_signing_config commit.gpgsign               "true"
  check_git_signing_config tag.gpgsign                  "true"
  check_git_signing_config gpg.ssh.allowedSignersFile   "$signers"
}

# ============================================================================
# 8. Rc files
# ============================================================================
verify_rc_files() {
  log "Rc files"

  local rc mode lines has_open has_close has_legacy block missing_strings s
  for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
    sub "$rc"

    if [[ ! -f "$rc" ]]; then
      record_fail "$rc missing" "$(
        kv "expected"          "regular file, mode 644"
        echo
        echo "rc-related files in HOME:"
        local f
        for f in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile" "$HOME/.zprofile" "$HOME/.bash_profile"; do
          if [[ -f "$f" ]]; then
            printf "  %s  mode=%s  lines=%s\n" "$f" "$(stat -c '%a' "$f")" "$(wc -l <"$f")"
          else
            printf "  %s  (absent)\n" "$f"
          fi
        done
      )"
      continue
    fi

    mode="$(stat -c '%a' "$rc")"
    lines="$(wc -l < "$rc")"
    note "mode=$mode  lines=$lines"

    has_open=0; has_close=0; has_legacy=0
    grep -qF "$RC_OPEN_SENTINEL"   "$rc" && has_open=1
    grep -qF "$RC_CLOSE_SENTINEL"  "$rc" && has_close=1
    grep -qF "$RC_LEGACY_OPEN"     "$rc" && has_legacy=1

    if [[ $has_open -eq 1 && $has_close -eq 1 ]]; then
      ok "sentinel block present"
    else
      record_fail "$rc missing dev-env-setup sentinel block" "$(
        kv "open sentinel  ($RC_OPEN_SENTINEL)"  "$( [[ $has_open  -eq 1 ]] && echo present || echo MISSING)"
        kv "close sentinel ($RC_CLOSE_SENTINEL)" "$( [[ $has_close -eq 1 ]] && echo present || echo MISSING)"
        kv "mode"  "$mode"
        kv "lines" "$lines"
        echo
        echo "First 40 lines of $rc:"
        head -n 40 "$rc" 2>&1 | sed 's/^/  /'
      )"
      continue
    fi

    if [[ $has_legacy -eq 1 ]]; then
      record_fail "$rc contains the legacy GH_TOKEN sentinel block (older setup.sh leftover)" "$(
        echo "Legacy block (rotate any token that was in here):"
        sed -n "/${RC_LEGACY_OPEN}/,/<<< dev-env-setup GH_TOKEN/p" "$rc" 2>&1 | sed 's/^/  /'
      )"
    else
      ok "no legacy GH_TOKEN block"
    fi

    block="$(extract_rc_block "$rc")"
    missing_strings=()
    for s in "${REQUIRED_RC_STRINGS[@]}"; do
      grep -qF -- "$s" <<<"$block" || missing_strings+=("$s")
    done

    if [[ ${#missing_strings[@]} -eq 0 ]]; then
      ok "all required content strings present in sentinel block"
    else
      local tmp_a tmp_b
      tmp_a="$(mktemp -t post-rc-actual.XXXXXX)"
      tmp_b="$(mktemp -t post-rc-expected.XXXXXX)"
      printf "%s\n" "$block"               > "$tmp_a"
      printf "%s\n" "$RC_BLOCK_EXPECTED"   > "$tmp_b"
      record_fail "$rc sentinel block content drifted from setup.sh's RC_BLOCK" "$(
        echo "Missing required strings:"
        for s in "${missing_strings[@]}"; do printf "  - %q\n" "$s"; done
        echo
        echo "Unified diff (actual vs expected):"
        diff -u "$tmp_a" "$tmp_b" 2>&1 | sed 's/^/  /'
      )"
      rm -f "$tmp_a" "$tmp_b"
    fi
  done

  sub "GH_TOKEN derivation (bash -ic 'echo \$GH_TOKEN')"
  if command -v gh >/dev/null 2>&1; then
    local rc_token gh_token
    rc_token="$(bash -ic 'printf "%s" "${GH_TOKEN:-}"' 2>/dev/null || true)"
    gh_token="$(gh auth token 2>/dev/null || true)"
    if [[ -n "$rc_token" && "$rc_token" == "$gh_token" ]]; then
      ok "GH_TOKEN sourced from rc matches 'gh auth token' (len=${#rc_token})"
    elif [[ -z "$rc_token" ]]; then
      record_fail "GH_TOKEN not exported after sourcing .bashrc" "$(
        kv "gh auth token length" "${#gh_token}"
        echo
        echo "bash -ic 'env | grep -E ^GH_TOKEN' output:"
        bash -ic 'env | grep -E "^GH_TOKEN"' 2>&1 | sed 's/^/  /'
      )"
    else
      record_fail "GH_TOKEN in rc does NOT match 'gh auth token'" "$(
        kv "rc-derived length"    "${#rc_token}"
        kv "gh auth token length" "${#gh_token}"
        echo "(this means rc has a stale or hardcoded token; should be derived live)"
      )"
    fi
  else
    warn "gh not installed; skipping GH_TOKEN derivation check"
  fi
}

# ============================================================================
# 9. Dotfiles managed by Wave B phases
# ============================================================================
verify_dotfiles() {
  log "Dotfiles (Wave B)"

  sub "~/.gitignore_global"
  local gi="$HOME/.gitignore_global"
  if [[ -f "$gi" ]]; then
    local mode
    mode="$(stat -c '%a' "$gi")"
    if [[ "$mode" == "644" ]]; then
      ok "$gi present (mode=644, $(wc -l < "$gi") lines)"
    else
      record_fail "$gi wrong mode: $mode (expected 644)" ""
    fi
    local s
    for s in node_modules __pycache__ .DS_Store '.venv/' '.idea/'; do
      if grep -qF "$s" "$gi"; then
        ok "$gi contains '$s'"
      else
        record_fail "$gi missing entry: $s" ""
      fi
    done
  else
    record_fail "$gi missing" "$(
      kv "expected" "$gi (mode 644)"
      ls -la "$HOME/" 2>&1 | grep -E '\.gitignore' | sed 's/^/  /' || echo "  (no .gitignore* files in HOME)"
    )"
  fi

  sub "pre-commit template"
  local tmpl="$HOME/.config/pre-commit/.pre-commit-config.template.yaml"
  if [[ -f "$tmpl" ]]; then
    ok "$tmpl present"
    local hook
    for hook in ruff black shellcheck-precommit semgrep gitleaks trufflehog; do
      if grep -qF "$hook" "$tmpl"; then
        ok "template references '$hook'"
      else
        record_fail "template missing reference to '$hook'" ""
      fi
    done
  else
    record_fail "$tmpl missing" ""
  fi

  sub "PS1 file"
  local ps1="$HOME/.local/share/sprite-setup/ps1.sh"
  if [[ -f "$ps1" ]]; then
    ok "$ps1 present"
    if grep -qF '__sprite_git_prompt' "$ps1"; then
      ok "ps1.sh defines __sprite_git_prompt"
    else
      record_fail "ps1.sh present but missing __sprite_git_prompt function" "$(
        echo "first 20 lines:"; head -n 20 "$ps1" | sed 's/^/  /'
      )"
    fi
  else
    record_fail "$ps1 missing" ""
  fi

  sub "zsh completions dir"
  local cdir="$HOME/.zsh/completions"
  if [[ -d "$cdir" ]]; then
    local n
    n="$(find "$cdir" -maxdepth 1 -type f -name '_*' 2>/dev/null | wc -l)"
    if [[ "$n" -gt 0 ]]; then
      ok "$cdir has $n completion file(s)"
    else
      warn "$cdir present but empty (no tool emitted a completion script)"
    fi
  else
    record_fail "$cdir missing" ""
  fi
}

# ============================================================================
# 10. Security: scan rc files for plaintext PATs
# ============================================================================
verify_security() {
  log "Security (plaintext PAT scan)"

  local PAT_PATTERNS=(
    'ghp_[A-Za-z0-9]{16,}'
    'gho_[A-Za-z0-9]{16,}'
    'ghu_[A-Za-z0-9]{16,}'
    'ghs_[A-Za-z0-9]{16,}'
    'ghr_[A-Za-z0-9]{16,}'
    'github_pat_[A-Za-z0-9_]{16,}'
  )

  local found_pat=0 rc pat matches m line_no
  for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
    [[ -f "$rc" ]] || continue
    for pat in "${PAT_PATTERNS[@]}"; do
      matches="$(grep -nE "$pat" "$rc" 2>/dev/null || true)"
      if [[ -n "$matches" ]]; then
        found_pat=1
        while IFS= read -r m; do
          line_no="${m%%:*}"
          record_fail "plaintext PAT detected in $rc:$line_no" "$(
            kv "file"            "$rc"
            kv "line"            "$line_no"
            kv "matched pattern" "$pat"
            echo
            echo "ROTATE THIS PAT IMMEDIATELY at github.com/settings/tokens"
            echo "(the matched line text is NOT printed here to avoid logging the token)"
          )"
        done <<<"$matches"
      fi
    done
  done
  if [[ $found_pat -eq 0 ]]; then
    ok "no plaintext PATs found in .bashrc or .zshrc"
  fi
}

# ============================================================================
# 11. End-to-end signing smoke test
# ============================================================================
verify_signing_smoke() {
  log "Signing smoke test"

  local priv="$HOME/.ssh/id_ed25519"
  local pub="$priv.pub"
  local signers="$HOME/.ssh/allowed_signers"

  if command -v git >/dev/null 2>&1 \
     && [[ -f "$priv" && -f "$pub" && -f "$signers" ]] \
     && [[ "$(git config --global commit.gpgsign 2>/dev/null)" == "true" ]]; then

    local scratch
    scratch="$(mktemp -d -t post-sign-XXXXXX)"
    smoke_diag() {
      echo "scratch dir: $scratch"
      echo
      echo "git log --show-signature -1 (in scratch):"
      git -C "$scratch" log --show-signature -1 2>&1 | sed 's/^/  /' || true
    }

    (
      cd "$scratch" || exit 1
      git init -q
      git -c commit.gpgsign=true commit --allow-empty -m "post.sh signing smoke test" -q 2>&1
    ) >"$scratch/.init.log" 2>&1
    local init_rc=$?

    if [[ $init_rc -ne 0 ]]; then
      record_fail "smoke test: scratch repo init/commit failed" "$(
        echo "rc=$init_rc"
        echo
        echo "init log:"
        sed 's/^/  /' "$scratch/.init.log"
        smoke_diag
      )"
    else
      local verify_out
      verify_out="$(git -C "$scratch" verify-commit HEAD 2>&1 || true)"
      if echo "$verify_out" | grep -qiE "good.*signature.*${GIT_USER_EMAIL//./\\.}"; then
        ok "git verify-commit HEAD reports Good signature for $GIT_USER_EMAIL"
      elif echo "$verify_out" | grep -qi "good.*signature"; then
        record_fail "smoke test: signature good but identity does not match $GIT_USER_EMAIL" "$(
          echo "verify-commit output:"
          echo "$verify_out" | sed 's/^/  /'
          smoke_diag
        )"
      else
        record_fail "smoke test: git verify-commit HEAD did not report a good signature" "$(
          echo "verify-commit output:"
          echo "$verify_out" | sed 's/^/  /'
          smoke_diag
        )"
      fi
    fi

    rm -rf "$scratch"
  else
    warn "skipping signing smoke test (prerequisites not met; see earlier failures)"
  fi
}

# ============================================================================
# 12. Disk
# ============================================================================
verify_disk() {
  log "Disk"

  local root_pct_raw df_line
  root_pct_raw="$(df --output=pcent / 2>/dev/null | tail -1 | tr -dc '0-9')"
  if [[ -z "$root_pct_raw" ]]; then
    warn "could not parse df output for /"
    df -h / 2>&1 | sed 's/^/    /'
  else
    df_line="$(df -h / | tail -1 | tr -s ' ')"
    if   (( root_pct_raw >= 95 )); then
      record_fail "/ is ${root_pct_raw}% full (>= 95%; setup.sh re-runs may fail)" "$(df -h / 2>&1)"
    elif (( root_pct_raw >= 80 )); then
      warn "/ is ${root_pct_raw}% full (>= 80%; clean up before next setup.sh re-run)"
      printf "    %s\n" "$df_line"
    else
      ok "/ at ${root_pct_raw}% ($df_line)"
    fi
  fi
}

# ============================================================================
# Orchestration + summary
# ============================================================================
# verify_run_all — executes every verification section in order.
verify_run_all() {
  verify_identity
  verify_tool_versions
  verify_docker
  verify_ssh
  verify_gh
  verify_git_config
  verify_git_signing
  verify_rc_files
  verify_dotfiles
  verify_security
  verify_signing_smoke
  verify_disk
}

# verify_print_summary — prints PASS/WARN/FAIL counts plus failure dump.
# Returns 0 if FAIL==0, 1 otherwise. Caller decides whether to `exit` on it.
verify_print_summary() {
  log "Summary"
  printf "    %s+%s pass : %d\n" "$GREEN"  "$RESET" "$PASS"
  printf "    %s!%s warn : %d\n" "$YELLOW" "$RESET" "$WARN"
  printf "    %sx%s fail : %d\n" "$RED"    "$RESET" "$FAIL"

  if [[ $FAIL -gt 0 ]]; then
    log "Failures (with diagnostic context)"
    local i=0 f
    for f in "${FAILURES[@]}"; do
      i=$((i+1))
      printf "\n%s[%d]%s %s\n" "$RED$BOLD" "$i" "$RESET" "${f%%$'\n'*}"
      if [[ "$f" == *$'\n'* ]]; then
        printf "%s\n" "${f#*$'\n'}" | sed 's/^/      /'
      fi
    done
    echo
    printf "%s%sx%s verify: %d critical failure(s)%s\n" "$RED" "$BOLD" "$RESET" "$FAIL" ""
    echo
    return 1
  fi

  echo
  printf "%s%s+%s verify: all critical checks passed%s%s\n" \
         "$GREEN" "$BOLD" "$RESET" \
         "$( [[ $WARN -gt 0 ]] && echo " ($WARN warning(s))" )" ""
  echo
  return 0
}
