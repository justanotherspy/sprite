#!/usr/bin/env bash
#
# pre-setup-check.sh
# READ-ONLY inspection of a fresh sprite, BEFORE running setup.sh.
# Captures: OS, pre-installed tools+versions, network egress, rc/git/ssh
# state, apt sources, sprite-env specifics. Modifies nothing.
#
# Works as root or as the sprite user.
#
# Usage:
#   chmod +x pre-setup-check.sh
#   ./pre-setup-check.sh | tee pre-check.txt
# Then paste pre-check.txt back to me.

set -u
set +e   # we WANT to see things that aren't installed

# --- output logging ---------------------------------------------------------
LOG_FILE="${LOG_FILE:-/tmp/pre-setup-check.log}"
exec > >(stdbuf -oL tee >(stdbuf -oL sed 's/\x1B\[[0-9;]*[a-zA-Z]//g' > "$LOG_FILE")) 2>&1
# Give the tee/sed subprocess a beat to flush the last lines into the log
# before this script returns control to the caller.
trap 'sleep 0.3' EXIT
echo "[Output mirrored to $LOG_FILE — when done, run: cat $LOG_FILE]"
echo

hdr() { printf "\n\033[1;34m==> %s\033[0m\n" "$*"; }
sub() { printf "\033[1;90m--- %s ---\033[0m\n" "$*"; }

hdr "Identity"
echo "whoami: $(whoami)"
echo "id    : $(id)"
echo "HOME  : ${HOME:-(unset)}"
echo "USER  : ${USER:-(unset)}"
echo "SHELL : ${SHELL:-(unset)}"
echo "PWD   : $(pwd)"

hdr "Kernel / OS"
uname -a
echo
cat /etc/os-release

hdr "Sprite / Fly / GH env vars (looking for anything pre-set)"
env | grep -iE '^(SPRITE|FLY|GIT_|GH_|GITHUB_|EDITOR|PAGER)=' | sort
echo "(if nothing printed, none are set)"

hdr "Process 1 / systemd state"
ps -p 1 -o pid,comm,args 2>/dev/null
if pidof systemd >/dev/null 2>&1; then
  echo "systemd: running (pid $(pidof systemd))"
else
  echo "systemd: NOT running (expect 'systemctl enable --now' to be skipped)"
fi

hdr "Disk"
df -h / "$HOME" 2>/dev/null

hdr "Tools: presence + version"
TOOLS=(
  # shells / classics
  bash zsh fish make pkg-config rsync less man unzip zip tar xz
  # editors
  vim nvim nano
  # dev classics
  git curl wget jq yq htop btop tree ncdu fzf tmux mosh xclip
  # network
  dig traceroute
  # search / file
  rg fd bat batcat fdfind
  # sec / lint
  shellcheck semgrep trufflehog
  # languages
  node npm pnpm yarn bun deno
  python3 pip pip3 uv uvx pipx
  go gofmt ruby gem rustc cargo rustup
  elixir mix java javac mvn gradle
  # containers
  docker containerd
  # cloud / git CLIs
  gh flyctl fly
  # sprite-preinstalled AI/CLI per docs
  claude gemini codex cursor
  # sprite tooling
  sprite sprite-env
  # misc
  direnv
)
for cmd in "${TOOLS[@]}"; do
  if command -v "$cmd" >/dev/null 2>&1; then
    path="$(command -v "$cmd")"
    # </dev/null prevents tools like nc from waiting on stdin.
    # Tight 2s timeout caps any tool that mishandles --version (e.g. nslookup
    # treating --version as a hostname and doing a DNS lookup).
    ver="$(timeout 2 "$cmd" --version </dev/null 2>&1 | head -n1)"
    # printf -- avoids bash treating a leading '-' in the format as a flag.
    printf -- "+ %-14s  %-40s  %s\n" "$cmd" "$path" "$ver"
  else
    printf -- "- %-14s  (not installed)\n" "$cmd"
  fi
done

hdr "Apt sources"
sub "/etc/apt/sources.list.d/"
ls -la /etc/apt/sources.list.d/ 2>/dev/null
sub "/etc/apt/sources.list (head)"
head -20 /etc/apt/sources.list 2>/dev/null || echo "(missing)"
sub "/etc/apt/keyrings/"
ls -la /etc/apt/keyrings/ 2>/dev/null || echo "(does not exist yet)"

hdr "Git config (global)"
git config --global --list 2>/dev/null || echo "(no global gitconfig)"

hdr "SSH state"
ls -la "$HOME/.ssh" 2>/dev/null || echo "(no $HOME/.ssh)"
for pub in "$HOME"/.ssh/*.pub; do
  [ -f "$pub" ] || continue
  sub "$pub"
  cat "$pub"
done
sub "github.com in known_hosts?"
if [ -f "$HOME/.ssh/known_hosts" ]; then
  ssh-keygen -F github.com -f "$HOME/.ssh/known_hosts" 2>/dev/null \
    && echo "+ present" || echo "- absent"
else
  echo "(no known_hosts file)"
fi

hdr "Shell rc files"
for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile" "$HOME/.zprofile" "$HOME/.bash_profile"; do
  if [ -f "$rc" ]; then
    sub "$rc (lines=$(wc -l < "$rc")  mode=$(stat -c '%a' "$rc"))"
    grep -nE '^(export PATH|export [A-Z_]+_INSTALL|alias |source |\. /|eval )' "$rc" 2>/dev/null | head -30
    grep -n 'dev-env-setup' "$rc" 2>/dev/null && echo "(!) dev-env-setup sentinels already present"
  else
    echo "- $rc absent"
  fi
done

hdr "resolv.conf"
ls -la /etc/resolv.conf
head -10 /etc/resolv.conf 2>/dev/null

hdr "Network egress smoke test (5s timeout each)"
for host in \
  github.com \
  raw.githubusercontent.com \
  download.docker.com \
  cli.github.com \
  astral.sh \
  bun.sh \
  fly.io \
  api.github.com \
  pypi.org \
; do
  if curl -fsI --max-time 5 "https://$host" >/dev/null 2>&1; then
    echo "+ $host"
  else
    echo "- $host  (unreachable or blocked)"
  fi
done

hdr "Useful paths"
sub "/opt"
ls -la /opt/ 2>/dev/null | head -20
sub "$HOME/.local/bin"
ls "$HOME/.local/bin" 2>/dev/null || echo "(missing)"
sub "/usr/local/bin (head)"
ls /usr/local/bin/ 2>/dev/null | head -30

hdr "Sprite services (if sprite-env present)"
if command -v sprite-env >/dev/null 2>&1; then
  sprite-env services list 2>&1 | head -20
else
  echo "(sprite-env not on this side of the connection; that's normal inside the sprite)"
fi

hdr "ALL DONE - paste the whole output back"
