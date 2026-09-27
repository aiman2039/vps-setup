#!/usr/bin/env bash
# 09-zsh: install zsh + set as default login shell. Idempotent.
# Writes a minimal ~/.zshrc only when none exists (never touches custom configs).
#
# Env:
#   ZSH_USER (NEW_USER/agent)  ZSH_SET_FOR_ROOT (false)
#   ZSH_CREATE_MINIMAL_ZSHRC (true)
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/00-common.sh"

NEW_USER="${NEW_USER:-agent}"
ZSH_USER="${ZSH_USER:-$NEW_USER}"
ZSH_SET_FOR_ROOT="${ZSH_SET_FOR_ROOT:-false}"
ZSH_CREATE_MINIMAL_ZSHRC="${ZSH_CREATE_MINIMAL_ZSHRC:-true}"

require_root
id "$ZSH_USER" >/dev/null 2>&1 || die "user '$ZSH_USER' missing; run 01-user.sh first"
apt_install zsh

zsh_path="$(command -v zsh)"
if ! grep -qxF "$zsh_path" /etc/shells; then
  printf '%s\n' "$zsh_path" >> /etc/shells
  log "added $zsh_path to /etc/shells"
fi

set_shell() {
  local user="$1" current
  current="$(getent passwd "$user" | cut -d: -f7)"
  if [[ "$current" == "$zsh_path" ]]; then
    log "shell for '$user' already $zsh_path"
  else
    chsh -s "$zsh_path" "$user"
    log "shell for '$user': $current -> $zsh_path (takes effect on next login)"
  fi
}

ensure_zshrc() {
  local user="$1" home tmp
  home="$(user_home "$user")"
  if [[ -f "$home/.zshrc" ]]; then
    log ".zshrc already present for '$user'"
    return 0
  fi
  tmp=$(mktemp)
  {
    managed_header "09-zsh"
    cat <<'EOF'
HISTFILE=~/.histfile
HISTSIZE=5000
SAVEHIST=5000
setopt appendhistory autocd notify
unsetopt beep
bindkey -e
autoload -Uz compinit promptinit
compinit
promptinit
prompt adam1
export PATH="$HOME/.cargo/bin:$HOME/.local/bin:$PATH"
EOF
  } > "$tmp"
  install -o "$user" -g "$user" -m 644 "$tmp" "$home/.zshrc"
  rm -f "$tmp"
  log "wrote minimal .zshrc for '$user'"
}

set_shell "$ZSH_USER"
if [[ "$ZSH_CREATE_MINIMAL_ZSHRC" == "true" ]]; then ensure_zshrc "$ZSH_USER"; fi
if [[ "$ZSH_SET_FOR_ROOT" == "true" ]]; then
  set_shell root
  if [[ "$ZSH_CREATE_MINIMAL_ZSHRC" == "true" ]]; then ensure_zshrc root; fi
fi
log "zsh ready: $("$zsh_path" --version)"
