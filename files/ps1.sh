# Hand-rolled vcs_info prompt. Sourced from rc_additions.sh.
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
