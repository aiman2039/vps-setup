#!/usr/bin/env bash
# 09-zsh: install zsh + oh-my-zsh, set as default login shell. Idempotent.
# oh-my-zsh theme/plugins apply at install time only; later .zshrc edits are kept.
# Without oh-my-zsh, writes a minimal ~/.zshrc only when none exists.
#
# Env:
#   ZSH_USER (NEW_USER)  ZSH_SET_FOR_ROOT (false)
#   ZSH_CREATE_MINIMAL_ZSHRC (true)
#   ZSH_INSTALL_OHMYZSH (true)  ZSH_OHMYZSH_THEME (robbyrussell)
#   ZSH_OHMYZSH_PLUGINS (git)
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/00-common.sh"

NEW_USER="${NEW_USER:-$DEFAULT_USER}"
ZSH_USER="${ZSH_USER:-$NEW_USER}"
ZSH_SET_FOR_ROOT="${ZSH_SET_FOR_ROOT:-false}"
ZSH_CREATE_MINIMAL_ZSHRC="${ZSH_CREATE_MINIMAL_ZSHRC:-true}"
ZSH_INSTALL_OHMYZSH="${ZSH_INSTALL_OHMYZSH:-true}"
ZSH_OHMYZSH_THEME="${ZSH_OHMYZSH_THEME:-robbyrussell}"
ZSH_OHMYZSH_PLUGINS="${ZSH_OHMYZSH_PLUGINS:-git}"

require_root
id "$ZSH_USER" >/dev/null 2>&1 || die "user '$ZSH_USER' missing; run 01-user.sh first"
apt_install zsh curl ca-certificates git

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

install_ohmyzsh() {
  local user="$1" home zshrc
  home="$(user_home "$user")"
  if [[ -d "$home/.oh-my-zsh" ]]; then
    log "oh-my-zsh already installed for '$user'"
    return 0
  fi
  log "installing oh-my-zsh for '$user'..."
  su -s /bin/bash "$user" -c 'RUNZSH=no CHSH=no sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"'
  zshrc="$home/.zshrc"
  if [[ -f "$zshrc" ]]; then
    sed -i "s/^ZSH_THEME=.*/ZSH_THEME=\"$ZSH_OHMYZSH_THEME\"/" "$zshrc"
    sed -i "s/^plugins=(.*)/plugins=($ZSH_OHMYZSH_PLUGINS)/" "$zshrc"
  fi
  log "oh-my-zsh installed for '$user' (theme=$ZSH_OHMYZSH_THEME plugins=($ZSH_OHMYZSH_PLUGINS))"
}

set_shell "$ZSH_USER"
if [[ "$ZSH_INSTALL_OHMYZSH" == "true" ]]; then install_ohmyzsh "$ZSH_USER"; fi
if [[ "$ZSH_CREATE_MINIMAL_ZSHRC" == "true" ]]; then ensure_zshrc "$ZSH_USER"; fi
if [[ "$ZSH_SET_FOR_ROOT" == "true" ]]; then
  set_shell root
  if [[ "$ZSH_INSTALL_OHMYZSH" == "true" ]]; then install_ohmyzsh root; fi
  if [[ "$ZSH_CREATE_MINIMAL_ZSHRC" == "true" ]]; then ensure_zshrc root; fi
fi
log "zsh ready: $("$zsh_path" --version)"
