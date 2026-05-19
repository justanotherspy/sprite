#!/usr/bin/env bash
#
# post.sh
# READ-ONLY post-install verification for sprite.dev bootstrap.
# (One exception: signing smoke test writes to /tmp/post-sign-* and cleans up.)
#
# Tracks pass/fail/warn counters. Exits 0 if every critical check passes
# (warnings allowed), exits 1 if any critical check fails. Usable as a CI gate.
#
# Owner: Daniel Schwartz <danielschwar@gmail.com> (justanotherspy)
# Target: Ubuntu 25.10 (questing) on a sprite.dev sprite (PID 1 is tini).
#
# All verification logic lives in _lib_verify.sh, which is also sourced by
# setup.sh's phase_verify so the two stay in lockstep.
#
# Works as root or as the sprite user.
#
# Usage:
#   chmod +x post.sh
#   ./post.sh
#
set -u   # NOT -e: every check must run, even after earlier failures.

# ============================================================================
# Pinned identity (must match setup.sh)
# ============================================================================
GIT_USER_NAME="Daniel Schwartz"
GIT_USER_EMAIL="danielschwar@gmail.com"
GIT_DEFAULT_BRANCH="main"
GH_USERNAME="justanotherspy"
export GIT_USER_NAME GIT_USER_EMAIL GIT_DEFAULT_BRANCH GH_USERNAME

# ============================================================================
# Logging (mirror+tee+ANSI-strip pattern)
# ============================================================================
LOG_FILE="${LOG_FILE:-/tmp/post-setup-check.log}"
exec > >(stdbuf -oL tee >(stdbuf -oL sed 's/\x1B\[[0-9;]*[a-zA-Z]//g' > "$LOG_FILE")) 2>&1
trap 'sleep 0.3' EXIT
echo "[Output mirrored to $LOG_FILE]"
echo

# ============================================================================
# Resolve and source _lib_verify.sh
# ============================================================================
# Prefer same-dir lookup. Fall back to download when post.sh was invoked
# via `bash <(curl ...)` (in which case $0 is a /dev/fd path, not a real file).
SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH" 2>/dev/null)" 2>/dev/null && pwd || echo "")"
LIB="$SCRIPT_DIR/_lib_verify.sh"

if [[ ! -f "$LIB" ]]; then
  echo "[fetching _lib_verify.sh (curl mode, no local file)]"
  LIB="$(mktemp -t _lib_verify.XXXXXX.sh)"
  if ! curl -fsSL \
       "https://raw.githubusercontent.com/justanotherspy/sprite/main/_lib_verify.sh" \
       -o "$LIB"; then
    echo "x could not fetch _lib_verify.sh; cannot run verification" >&2
    rm -f "$LIB"
    exit 2
  fi
fi

# shellcheck disable=SC1090
source "$LIB"

# ============================================================================
# Run
# ============================================================================
verify_run_all
verify_print_summary
exit_code=$?
exit "$exit_code"
