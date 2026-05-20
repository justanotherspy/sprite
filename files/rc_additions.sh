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

# zsh completions (managed by sproot zsh_completions phase)
if [ -n "$ZSH_VERSION" ] && [ -d "$HOME/.zsh/completions" ]; then
  fpath=("$HOME/.zsh/completions" $fpath)
  autoload -Uz compinit && compinit -i
fi

# Custom PS1 (managed by sproot ps1 phase)
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
