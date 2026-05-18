#!/usr/bin/env bash
#
# dev-env-setup.sh
# Personal dev environment bootstrap for sprite.dev sprites.
#
# Target: Ubuntu 25.10 (questing) on a sprite.dev sprite (overlay rootfs, PID 1
# is tini, no systemd). Verified pre-installed by sprite (do NOT reinstall):
#   - languages: node, npm, deno, python3, pip, ruby, gem, rustc, cargo,
#     rustup, elixir, mix, java, javac, bun, go (all under /.sprite/bin/)
#   - CLIs: gh, claude, gemini, codex
#   - classics: git, curl, wget, vim, nano, tmux, jq, htop, tree, dig,
#     bash, zsh, fish, make, pkg-config, rsync, less, man, unzip, zip,
#     tar, xz, iputils-ping, net-tools
#
# Runs OK as either root or the sprite user. Idempotent (sentinel-wrapped
# rc edits, conditional installs). No systemd means service starts are
# skipped during script run; we register a sprite Service for dockerd
# so it comes back on wake.
#
set -euo pipefail

# --- output logging ---------------------------------------------------------
# Mirror all stdout/stderr to a log file with ANSI colors stripped, so the
# log is paste-friendly. The terminal still gets colored output. Override
# via LOG_FILE env var if you want a custom path.
LOG_FILE="${LOG_FILE:-/tmp/dev-env-setup.log}"
exec > >(stdbuf -oL tee >(stdbuf -oL sed 's/\x1B\[[0-9;]*[a-zA-Z]//g' > "$LOG_FILE")) 2>&1
# Single EXIT handler that:
#   1. kills the sudo keepalive (if it was started)
#   2. gives the tee/sed subprocess a beat to flush the last lines to disk.
_finalize() {
  if [[ -n "${SUDO_KEEPALIVE_PID:-}" ]]; then
    kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
  fi
  sleep 0.3
}
trap _finalize EXIT
echo "[Output mirrored to $LOG_FILE — when done, run: cat $LOG_FILE]"
echo

# --- logging ----------------------------------------------------------------
RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
BLUE=$'\033[34m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
log()  { printf "%s%s==>%s %s\n" "$BLUE" "$BOLD" "$RESET" "$*"; }
info() { printf "    %s\n" "$*"; }
warn() { printf "%s!%s %s\n" "$YELLOW" "$RESET" "$*"; }
err()  { printf "%sx%s %s\n" "$RED" "$RESET" "$*" >&2; }
ok()   { printf "%s+%s %s\n" "$GREEN" "$RESET" "$*"; }

# --- preflight --------------------------------------------------------------
# Allow running as root OR a normal user. Wrap privileged calls in $SUDO so
# they work either way without a useless 'sudo sudo'.
if [[ $EUID -eq 0 ]]; then
  SUDO=""
else
  command -v sudo >/dev/null 2>&1 || { err "sudo not found (and not running as root)"; exit 1; }
fi
SUDO="${SUDO-sudo}"

# $USER and $HOME may be unset in containers, chroots, or 'su' sessions.
# Set both defensively so 'set -u' doesn't trip on them later.
: "${USER:=$(id -un)}"
: "${HOME:=$(getent passwd "$USER" | cut -d: -f6)}"
export USER HOME

# Keep sudo alive for the whole run (no-op when running as root).
# Cleanup of SUDO_KEEPALIVE_PID is handled by the _finalize trap above.
if [[ -n "$SUDO" ]]; then
  $SUDO -v
  ( while true; do sudo -n true; sleep 60; kill -0 "$$" 2>/dev/null || exit; done ) 2>/dev/null &
  SUDO_KEEPALIVE_PID=$!
fi

# --- 1. system update -------------------------------------------------------
log "Updating apt and upgrading packages"
$SUDO apt-get update -y
$SUDO DEBIAN_FRONTEND=noninteractive apt-get upgrade -y

# --- 2. core packages -------------------------------------------------------
log "Installing core packages (only things sprite's base image doesn't ship)"
# Verified preinstalled by sprite (do NOT add here): bash, zsh, fish, vim,
# nano, tmux, git, curl, wget, jq, htop, tree, dig, make, pkg-config, rsync,
# less, man, unzip, zip, tar, xz, iputils-ping, net-tools, build-essential,
# ca-certificates, gnupg, plus all the language toolchains and gh CLI.
# Python ships from /.sprite/languages/python/ so we skip python3-pip/venv too.
$SUDO DEBIAN_FRONTEND=noninteractive apt-get install -y \
  apt-transport-https \
  software-properties-common \
  lsb-release \
  shellcheck \
  bat \
  btop \
  direnv \
  fd-find \
  fzf \
  mosh \
  ncdu \
  neovim \
  netcat-openbsd \
  ripgrep \
  traceroute \
  yq
ok "Core packages installed"

# Ubuntu renames bat -> batcat, fd -> fdfind. Symlink to expected names.
mkdir -p "$HOME/.local/bin"
[[ -x /usr/bin/batcat && ! -e "$HOME/.local/bin/bat" ]] && ln -s /usr/bin/batcat "$HOME/.local/bin/bat"
[[ -x /usr/bin/fdfind && ! -e "$HOME/.local/bin/fd"  ]] && ln -s /usr/bin/fdfind  "$HOME/.local/bin/fd"

# --- 3. uv (Astral) ---------------------------------------------------------
log "Installing uv"
if ! command -v uv >/dev/null 2>&1; then
  curl -LsSf https://astral.sh/uv/install.sh | sh
fi
export PATH="$HOME/.local/bin:$PATH"
ok "uv: $("$HOME/.local/bin/uv" --version 2>/dev/null || uv --version || echo installed)"

# --- 4. bun: SKIPPED ---------------------------------------------------------
# Sprite ships bun preinstalled at /.sprite/bin/bun. No install needed.

# --- 5. semgrep via uv ------------------------------------------------------
log "Installing semgrep via uv"
"$HOME/.local/bin/uv" tool install semgrep
ok "semgrep installed"

# --- 6. trufflehog ----------------------------------------------------------
log "Installing trufflehog"
if ! command -v trufflehog >/dev/null 2>&1; then
  curl -sSfL https://raw.githubusercontent.com/trufflesecurity/trufflehog/main/scripts/install.sh \
    | $SUDO sh -s -- -b /usr/local/bin
fi
ok "trufflehog: $(trufflehog --version 2>&1 | head -n1 || echo installed)"

# --- 7. Docker (official repo) ---------------------------------------------
log "Installing Docker Engine (docker-ce + buildx + compose plugins)"
for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
  $SUDO apt-get remove -y "$pkg" >/dev/null 2>&1 || true
done

$SUDO install -m 0755 -d /etc/apt/keyrings
if [[ ! -f /etc/apt/keyrings/docker.asc ]]; then
  $SUDO curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  $SUDO chmod a+r /etc/apt/keyrings/docker.asc
fi

# Docker's apt repo can lag new Ubuntu codenames. Fall back to noble if missing.
UBUNTU_CODENAME="$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")"
if ! curl -fsI "https://download.docker.com/linux/ubuntu/dists/${UBUNTU_CODENAME}/Release" >/dev/null 2>&1; then
  warn "Docker repo has no release for '$UBUNTU_CODENAME' yet, falling back to 'noble'"
  UBUNTU_CODENAME="noble"
fi

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $UBUNTU_CODENAME stable" \
  | $SUDO tee /etc/apt/sources.list.d/docker.list >/dev/null

$SUDO apt-get update -y
$SUDO DEBIAN_FRONTEND=noninteractive apt-get install -y \
  docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin

$SUDO groupadd docker 2>/dev/null || true
$SUDO usermod -aG docker "$USER"
# systemctl may fail in containers/chroots; don't abort the whole run for it.
if pidof systemd >/dev/null 2>&1; then
  $SUDO systemctl enable --now docker     || warn "could not start docker via systemd"
  $SUDO systemctl enable --now containerd || warn "could not start containerd via systemd"
else
  warn "systemd not running (container/chroot?); skipping enable --now for docker/containerd"
fi

# Configurable daemon defaults (log rotation so /var/log doesn't fill up)
if [[ ! -f /etc/docker/daemon.json ]]; then
  $SUDO mkdir -p /etc/docker
  $SUDO tee /etc/docker/daemon.json >/dev/null <<'JSON'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "20m", "max-file": "5" },
  "live-restore": true
}
JSON
  if pidof systemd >/dev/null 2>&1; then
    $SUDO systemctl restart docker || warn "docker restart failed; apply daemon.json manually later"
  fi
fi
ok "Docker installed (re-login or run 'newgrp docker' to use without sudo)"

# --- 7b. sprite Service for dockerd ----------------------------------------
# Sprite has no systemd. Without a Service, dockerd won't come back after a
# wake-from-hibernate. Important wrinkle: sprite Services run as the sprite
# user (uid 1001), but dockerd refuses to run non-root, so we register it
# via 'sudo'. The sprite user has passwordless sudo on these boxes.
if command -v sprite-env >/dev/null 2>&1; then
  log "Registering dockerd as a sprite Service (via sudo)"
  # If a previous run created a broken non-sudo dockerd service, drop it.
  # Try a few likely subcommands; ignore failures (the cli surface may vary).
  if sprite-env services list 2>/dev/null | grep -q '"dockerd"'; then
    warn "existing 'dockerd' service found; attempting to remove and recreate"
    sprite-env services delete  dockerd 2>/dev/null \
      || sprite-env services remove  dockerd 2>/dev/null \
      || sprite-env services destroy dockerd 2>/dev/null \
      || warn "couldn't auto-remove the old dockerd service; remove it by hand if dockerd doesn't come up"
  fi
  if sprite-env services create dockerd --cmd sudo --args "/usr/bin/dockerd" 2>&1; then
    ok "sprite Service 'dockerd' created (sudo /usr/bin/dockerd; auto-starts on wake)"
  else
    warn "could not register dockerd as a sprite Service; start manually with 'sudo dockerd &'"
  fi
else
  warn "sprite-env not on PATH; dockerd won't auto-start on wake. Start it manually with 'sudo dockerd &'."
fi

# --- 8. flyctl --------------------------------------------------------------
log "Installing flyctl"
if ! command -v flyctl >/dev/null 2>&1; then
  # --non-interactive is documented in fly's install.sh: skips the
  # "add to PATH?" prompt AND skips all rc edits. Our RC_BLOCK below adds
  # ~/.fly/bin to BOTH .bashrc and .zshrc, so we don't need fly to do it.
  curl -fsSL https://fly.io/install.sh | sh -s -- --non-interactive
fi
# Make flyctl callable in the rest of this same script run.
export PATH="$HOME/.fly/bin:$PATH"
ok "flyctl installed"

# --- 9. GitHub CLI: SKIPPED -------------------------------------------------
# Sprite ships gh preinstalled at /.sprite/bin/gh. No install needed.

# --- 10. SSH dir + GitHub known_hosts --------------------------------------
log "Adding GitHub host keys to known_hosts"
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
touch "$HOME/.ssh/known_hosts"
chmod 644 "$HOME/.ssh/known_hosts"
if ! ssh-keygen -F github.com -f "$HOME/.ssh/known_hosts" >/dev/null 2>&1; then
  ssh-keyscan -t rsa,ecdsa,ed25519 github.com 2>/dev/null >> "$HOME/.ssh/known_hosts"
  ok "github.com host keys added"
else
  ok "github.com already in known_hosts"
fi

# --- 11. git identity -------------------------------------------------------
log "Configuring git identity"
current_name="$(git config --global user.name || true)"
current_email="$(git config --global user.email || true)"

[[ -n "$current_name"  ]] && info "Existing user.name : $current_name"
read -r -p "Git user.name [${current_name:-required}]: " git_name
git_name="${git_name:-$current_name}"

[[ -n "$current_email" ]] && info "Existing user.email: $current_email"
read -r -p "Git user.email [${current_email:-required}]: " git_email
git_email="${git_email:-$current_email}"

if [[ -z "$git_name" || -z "$git_email" ]]; then
  warn "Skipping git identity (name or email was empty)"
else
  git config --global user.name  "$git_name"
  git config --global user.email "$git_email"
  git config --global init.defaultBranch main
  git config --global pull.rebase true
  git config --global push.autoSetupRemote true
  git config --global rerere.enabled true
  git config --global color.ui auto
  git config --global core.editor "vim"
  git config --global fetch.prune true
  # Handy git aliases (live in gitconfig, complement the shell aliases)
  git config --global alias.lg     "log --oneline --graph --decorate --all"
  git config --global alias.last   "log -1 HEAD"
  git config --global alias.amend  "commit --amend --no-edit"
  git config --global alias.unstage "reset HEAD --"
  git config --global alias.cleanb "!git branch --merged | grep -vE '^\\*|^.\\s*(main|master|develop)$' | xargs -r git branch -d"
  ok "git identity configured for $git_name <$git_email>"
fi

# --- 12. SSH key for GitHub -------------------------------------------------
log "SSH key for GitHub"
SSH_KEY="$HOME/.ssh/id_ed25519"
if [[ -f "$SSH_KEY" ]]; then
  ok "SSH key already exists at $SSH_KEY"
else
  read -r -p "Generate a new ed25519 SSH key for GitHub? [Y/n]: " gen_key
  if [[ ! "$gen_key" =~ ^[Nn]$ ]]; then
    ssh-keygen -t ed25519 -C "${git_email:-$USER@$(hostname)}" -f "$SSH_KEY" -N ""
    eval "$(ssh-agent -s)" >/dev/null
    ssh-add "$SSH_KEY" >/dev/null 2>&1 || true
    ok "SSH key generated"
  fi
fi
if [[ -f "${SSH_KEY}.pub" ]]; then
  echo
  echo "${BOLD}Add this public key to GitHub -> Settings -> SSH and GPG keys:${RESET}"
  echo "${BOLD}https://github.com/settings/ssh/new${RESET}"
  echo
  cat "${SSH_KEY}.pub"
  echo
  read -r -p "Press Enter once you've added the key (or Ctrl-C to skip) " _
  # Verify SSH works
  if ssh -o StrictHostKeyChecking=accept-new -T git@github.com 2>&1 | grep -q "successfully authenticated"; then
    ok "GitHub SSH authentication works"
  else
    warn "GitHub SSH auth not verified (you can retry with: ssh -T git@github.com)"
  fi
fi

# --- 13. GH CLI token -------------------------------------------------------
log "GitHub CLI token"
warn "Plaintext tokens in rc files are convenient but not ideal."
warn "Consider 'gh auth login' (keyring-backed) for a more secure alternative."
read -r -s -p "Paste a GitHub PAT to export as GH_TOKEN (Enter to skip): " gh_token
echo
if [[ -n "$gh_token" ]]; then
  for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
    touch "$rc"
    sed -i '/# >>> dev-env-setup GH_TOKEN >>>/,/# <<< dev-env-setup GH_TOKEN <<</d' "$rc"
    {
      echo ""
      echo "# >>> dev-env-setup GH_TOKEN >>>"
      echo "export GH_TOKEN='${gh_token}'"
      echo 'export GITHUB_TOKEN="$GH_TOKEN"'
      echo "# <<< dev-env-setup GH_TOKEN <<<"
    } >> "$rc"
  done
  chmod 600 "$HOME/.bashrc" "$HOME/.zshrc" 2>/dev/null || true
  ok "GH_TOKEN added to .bashrc and .zshrc (mode 600)"
else
  warn "Skipped GH_TOKEN"
fi

# --- 14. Shell rc additions (PATH + aliases) -------------------------------
log "Adding PATH and aliases to .bashrc and .zshrc"
RC_BLOCK=$(cat <<'EOF'

# >>> dev-env-setup shell additions >>>
# ~/.local/bin holds sprite-installed CLIs (claude, codex, gemini, cursor-agent)
# plus anything 'uv tool install' lands. The uv installer also adds this line
# itself; the duplicate is harmless.
export PATH="$HOME/.local/bin:$PATH"

# flyctl: fly's installer only edits the rc matching $SHELL. Add it here so
# both bash and zsh users see flyctl, regardless of which shell they invoke.
[ -d "$HOME/.fly/bin" ] && export PATH="$HOME/.fly/bin:$PATH"

# direnv hook (auto-detect current shell)
if command -v direnv >/dev/null 2>&1; then
  case "$(basename "${SHELL:-bash}")" in
    bash) eval "$(direnv hook bash)" ;;
    zsh)  eval "$(direnv hook zsh)"  ;;
  esac
fi

# fzf keybindings/completion (if present)
[ -f /usr/share/doc/fzf/examples/key-bindings.bash ] && [ -n "$BASH_VERSION" ] && \
  source /usr/share/doc/fzf/examples/key-bindings.bash
[ -f /usr/share/doc/fzf/examples/key-bindings.zsh ]  && [ -n "$ZSH_VERSION" ]  && \
  source /usr/share/doc/fzf/examples/key-bindings.zsh

# Git aliases
alias g='git'
alias gs='git status'
alias gst='git status'
alias ga='git add'
alias gaa='git add --all'
alias gc='git commit'
alias gcm='git commit -m'
alias gca='git commit --amend'
alias gcan='git commit --amend --no-edit'
alias gco='git checkout'
alias gcb='git checkout -b'
alias gsw='git switch'
alias gswc='git switch -c'
alias gb='git branch'
alias gba='git branch -a'
alias gbd='git branch -d'
alias gd='git diff'
alias gds='git diff --staged'
alias gl='git log --oneline --graph --decorate'
alias gla='git log --oneline --graph --decorate --all'
alias gp='git pull --rebase'
alias gpu='git push'
alias gpf='git push --force-with-lease'
alias gf='git fetch --all --prune'
alias grh='git reset HEAD'
alias grhh='git reset --hard HEAD'
alias gstash='git stash'
alias gpop='git stash pop'
alias gcp='git cherry-pick'
alias gwip='git add -A && git commit -m "wip"'
alias gunwip='git reset HEAD~1'

# Quality of life
alias ll='ls -lah --color=auto'
alias la='ls -A --color=auto'
alias l='ls -CF --color=auto'
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'
alias df='df -h'
alias du='du -h'
alias free='free -h'
alias ports='ss -tulpn'
alias myip='curl -s ifconfig.me'
alias reload='exec $SHELL -l'

# Docker
alias d='docker'
alias dc='docker compose'
alias dps='docker ps'
alias dpsa='docker ps -a'
alias dim='docker images'
alias dprune='docker system prune -af --volumes'

# tmux: re-attach or start
alias t='tmux attach || tmux new'
# <<< dev-env-setup shell additions <<<
EOF
)

for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
  touch "$rc"
  sed -i '/# >>> dev-env-setup shell additions >>>/,/# <<< dev-env-setup shell additions <<</d' "$rc"
  printf "%s\n" "$RC_BLOCK" >> "$rc"
done
ok "PATH + aliases added"

# --- done -------------------------------------------------------------------
echo
log "All done"
info "1. Open a new shell or run: source ~/.bashrc  (or ~/.zshrc)"
info "2. For docker without sudo: log out/in, or run 'newgrp docker'"
info "3. If you skipped the SSH key, add one later with: ssh-keygen -t ed25519"
echo
