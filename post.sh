#!/usr/bin/env bash
#
# post-setup-check.sh
# READ-ONLY verification AFTER setup.sh has finished.
# Reports versions, rc state, ssh/git state, and runs small smoke tests
# against every tool setup.sh was meant to install. Modifies nothing.
#
# Works as root or as the sprite user.
#
# Usage:
#   chmod +x post-setup-check.sh
#   ./post-setup-check.sh | tee post-check.txt
# Then paste post-check.txt back to me.

set -u
set +e

# --- output logging ---------------------------------------------------------
LOG_FILE="${LOG_FILE:-/tmp/post-setup-check.log}"
exec > >(stdbuf -oL tee >(stdbuf -oL sed 's/\x1B\[[0-9;]*[a-zA-Z]//g' > "$LOG_FILE")) 2>&1
trap 'sleep 0.3' EXIT
echo "[Output mirrored to $LOG_FILE — when done, run: cat $LOG_FILE]"
echo

hdr() { printf "\n\033[1;34m==> %s\033[0m\n" "$*"; }
sub() { printf "\033[1;90m--- %s ---\033[0m\n" "$*"; }

# Make sure setup.sh's installs are visible to THIS script even before login refresh
export PATH="$HOME/.local/bin:$HOME/.bun/bin:$HOME/.fly/bin:/usr/local/bin:$PATH"

hdr "Identity / context"
echo "whoami: $(whoami)"
echo "id    : $(id)"
echo "HOME  : $HOME"
echo "USER  : ${USER:-(unset)}"

hdr "Versions of everything setup.sh was supposed to install"
TOOLS=(
  shellcheck
  uv uvx
  bun
  semgrep
  trufflehog
  docker
  gh
  flyctl
  bat fd rg fzf ncdu mosh nvim btop direnv yq traceroute
)
for cmd in "${TOOLS[@]}"; do
  if command -v "$cmd" >/dev/null 2>&1; then
    path="$(command -v "$cmd")"
    ver="$(timeout 2 "$cmd" --version </dev/null 2>&1 | head -n1)"
    printf -- "+ %-14s  %-40s  %s\n" "$cmd" "$path" "$ver"
  else
    printf -- "- %-14s  NOT FOUND\n" "$cmd"
  fi
done

hdr "Docker"
sub "docker version (client + daemon)"
docker version 2>&1 | head -25
sub "docker info (perms + daemon reachable?)"
docker info 2>&1 | head -25
sub "/etc/docker/daemon.json"
cat /etc/docker/daemon.json 2>/dev/null || echo "(missing)"
sub "docker group membership for $(whoami)"
if id -nG "$(whoami)" | tr ' ' '\n' | grep -qx docker; then
  echo "+ in docker group"
else
  echo "- NOT in docker group (re-login or newgrp docker needed)"
fi
sub "docker service status (if systemd is up)"
if pidof systemd >/dev/null 2>&1; then
  systemctl is-active docker 2>&1
  systemctl is-enabled docker 2>&1
else
  echo "(systemd not running; checking sprite Services instead)"
  if command -v sprite-env >/dev/null 2>&1; then
    sprite-env services list 2>&1
    echo
    echo "(if dockerd Service shows recent 'exit_code: 1', see /.sprite/logs/services/dockerd.log)"
    tail -n 20 /.sprite/logs/services/dockerd.log 2>/dev/null || echo "(no dockerd log)"
  fi
fi

hdr "Git config (global)"
git config --global --list

hdr "SSH state"
ls -la "$HOME/.ssh/" 2>/dev/null
sub "id_ed25519.pub"
[ -f "$HOME/.ssh/id_ed25519.pub" ] && cat "$HOME/.ssh/id_ed25519.pub" || echo "(missing)"
sub "github.com in known_hosts?"
ssh-keygen -F github.com -f "$HOME/.ssh/known_hosts" >/dev/null 2>&1 \
  && echo "+ yes" || echo "- no"

hdr "GitHub SSH auth test (5s timeout, BatchMode)"
ssh -o BatchMode=yes -o ConnectTimeout=5 -T git@github.com 2>&1 | head -3
echo "(if the line above contains 'successfully authenticated', you're good - exit code 1 is normal here)"

hdr "Rc files: state + dev-env-setup sentinels"
for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
  sub "$rc"
  if [ ! -f "$rc" ]; then echo "(missing)"; continue; fi
  echo "mode=$(stat -c '%a' "$rc")  lines=$(wc -l < "$rc")"
  echo
  echo "sentinel lines:"
  grep -nE 'dev-env-setup' "$rc" || echo "(no sentinels found - did setup.sh finish?)"
done

hdr "Duplicate PATH check (what bun/uv/fly installers added vs what setup.sh added)"
for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
  sub "$rc PATH-touching lines"
  [ -f "$rc" ] || { echo "(missing)"; continue; }
  grep -nE 'PATH=|BUN_INSTALL|FLYCTL_INSTALL|\.local/bin|\.bun/bin|\.fly/bin' "$rc"
done

hdr "Aliases registered in .bashrc (grepping file directly - bash -ic is unreliable)"
for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
  sub "$rc"
  [ -f "$rc" ] || { echo "(missing)"; continue; }
  grep -nE "^alias (g[a-z]+|d[a-z]*|ll|la|t|reload|myip|ports|\.\.+)" "$rc" | head -40
done

hdr "PATH after sourcing rc (numbered)"
bash -ic 'echo "$PATH"' 2>/dev/null | tr ':' '\n' | nl

hdr "GH_TOKEN in interactive env"
bash -ic 'if [ -n "${GH_TOKEN:-}" ]; then echo "+ GH_TOKEN set (len=${#GH_TOKEN})"; else echo "- GH_TOKEN unset"; fi' 2>/dev/null

hdr "uv tool list"
uv tool list 2>&1 | head -10

hdr "Disk impact (what setup.sh added)"
df -h /
echo
du -sh "$HOME"/.local "$HOME"/.bun "$HOME"/.fly 2>/dev/null || true

hdr "Functional smoke tests"

sub "shellcheck"
shellcheck --version >/dev/null 2>&1 \
  && echo "+ shellcheck runs" \
  || echo "- shellcheck failed"

sub "bat"
echo "hello" | bat -pp --color=never >/dev/null 2>&1 \
  && echo "+ bat ran" \
  || echo "- bat failed"

sub "rg"
rg --no-messages -c "^root" /etc/passwd >/dev/null 2>&1 \
  && echo "+ rg ran" \
  || echo "- rg failed"

sub "fd"
fd --max-depth=1 . / >/dev/null 2>&1 \
  && echo "+ fd ran" \
  || echo "- fd failed"

sub "uv"
uv --version >/dev/null 2>&1 \
  && echo "+ uv ran" \
  || echo "- uv failed"

sub "bun"
bun --version >/dev/null 2>&1 \
  && echo "+ bun ran" \
  || echo "- bun failed"

sub "trufflehog"
trufflehog --help >/dev/null 2>&1 \
  && echo "+ trufflehog ran" \
  || echo "- trufflehog failed"

sub "semgrep"
semgrep --version >/dev/null 2>&1 \
  && echo "+ semgrep ran" \
  || echo "- semgrep failed"

sub "gh"
gh --version >/dev/null 2>&1 \
  && echo "+ gh ran" \
  || echo "- gh failed"

sub "flyctl"
flyctl version >/dev/null 2>&1 \
  && echo "+ flyctl ran" \
  || echo "- flyctl failed"

sub "docker (perms check only - no pull)"
docker info >/dev/null 2>&1 \
  && echo "+ docker info worked (daemon reachable + perms OK)" \
  || echo "- docker info failed (likely daemon down or group not refreshed)"

hdr "ALL DONE - paste the whole output back"
