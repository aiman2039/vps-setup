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
# --- truecolor sanity -------------------------------------------------
# Minimal clients (Terminus over mosh) declare plain `xterm` while claiming
# COLORTERM=truecolor, which makes full-color apps emit sequences the
# transport mangles. Repair TERM and drop false truecolor claims.
# Only outside tmux/screen: inside, the multiplexer owns TERM.
if [[ -z "${TMUX:-}" && -z "${STY:-}" && "$TERM" == "xterm" ]] \
    && command -v infocmp >/dev/null 2>&1 \
    && infocmp xterm-256color >/dev/null 2>&1; then
  export TERM=xterm-256color
fi

# mosh cannot transport 24-bit color: drop the truecolor claim when the path
# to the screen can't honor it, so apps (pi, opencode, vim) use 256 colors.
if [[ -n "${TMUX:-}" ]] && command -v tmux >/dev/null 2>&1; then
  # Inside tmux: trust tmux's per-client capability detection.
  _tc_features=$(tmux display-message -p '#{client_termfeatures}' 2>/dev/null)
  if [[ -n "$_tc_features" && "$_tc_features" != *RGB* ]]; then
    unset COLORTERM
  fi
  unset _tc_features
else
  # Outside tmux: walk ancestors; mosh-server anywhere above us => no RGB.
  _tc_pid=$$ _tc_mosh=0
  while (( _tc_pid > 1 )); do
    _tc_comm=$(ps -o comm= -p "$_tc_pid" 2>/dev/null) || break
    if [[ "$_tc_comm" == *mosh-server* ]]; then _tc_mosh=1; break; fi
    _tc_pid=$(ps -o ppid= -p "$_tc_pid" 2>/dev/null | tr -d ' ') || break
    [[ -z "$_tc_pid" ]] && break
  done
  (( _tc_mosh )) && unset COLORTERM
  unset _tc_pid _tc_mosh _tc_comm
fi
# --- end truecolor sanity ---------------------------------------------

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
