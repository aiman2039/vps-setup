#!/usr/bin/env bash
# 12-nvm: install nvm (Node Version Manager) + optional Node.js. Idempotent.
# Appends loader lines to the user's .zshrc/.bashrc based on login shell.
#
# Env:
#   NVM_USER (NEW_USER)  NVM_VERSION (latest) - tag, e.g. v0.40.3
#   NVM_NODE_VERSION (lts/*) - "" to skip Node install
#   NVM_REINSTALL (false) - re-run installer even if present
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/00-common.sh"

NEW_USER="${NEW_USER:-$DEFAULT_USER}"
NVM_USER="${NVM_USER:-$NEW_USER}"
NVM_VERSION="${NVM_VERSION:-latest}"
NVM_NODE_VERSION="${NVM_NODE_VERSION:-lts/*}"
NVM_REINSTALL="${NVM_REINSTALL:-false}"

require_root
id "$NVM_USER" >/dev/null 2>&1 || die "user '$NVM_USER' missing; run 01-user.sh first"
apt_install curl ca-certificates git

if [[ "$NVM_VERSION" == "latest" ]]; then
  NVM_VERSION="$(curl -fsSL https://api.github.com/repos/nvm-sh/nvm/releases/latest \
    | grep -m1 '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/')"
  if [[ -z "$NVM_VERSION" ]]; then die "could not resolve latest nvm version"; fi
  log "latest nvm version: $NVM_VERSION"
fi
if [[ "$NVM_VERSION" != v* ]]; then NVM_VERSION="v$NVM_VERSION"; fi
if ! [[ "$NVM_VERSION" =~ ^v[0-9][0-9A-Za-z._-]*$ ]]; then die "invalid NVM_VERSION='$NVM_VERSION'"; fi
if [[ "$NVM_NODE_VERSION" == *"'"* ]]; then die "invalid NVM_NODE_VERSION='$NVM_NODE_VERSION'"; fi

home="$(user_home "$NVM_USER")"
if [[ -s "$home/.nvm/nvm.sh" && "$NVM_REINSTALL" != "true" ]]; then
  log "nvm already installed for '$NVM_USER'"
else
  login_shell="$(getent passwd "$NVM_USER" | cut -d: -f7)"
  case "$login_shell" in
    */zsh) profile=.zshrc ;;
    *) profile=.bashrc ;;
  esac
  url="https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh"
  log "installing nvm $NVM_VERSION for '$NVM_USER' (profile ~/$profile)..."
  su -s /bin/bash "$NVM_USER" -c "export PROFILE=\"\$HOME/$profile\"; curl -o- '$url' | bash"
  if [[ ! -s "$home/.nvm/nvm.sh" ]]; then die "nvm install failed"; fi
fi

if [[ -n "$NVM_NODE_VERSION" ]]; then
  if su -s /bin/bash "$NVM_USER" -c '[ -n "$(ls -A "$HOME/.nvm/versions/node" 2>/dev/null)" ]'; then
    log "node already installed for '$NVM_USER'"
  else
    log "installing node $NVM_NODE_VERSION for '$NVM_USER'..."
    su -s /bin/bash "$NVM_USER" -c "export NVM_DIR=\"\$HOME/.nvm\"; . \"\$NVM_DIR/nvm.sh\"; nvm install '$NVM_NODE_VERSION' && nvm alias default '$NVM_NODE_VERSION'"
  fi
fi

su -s /bin/bash "$NVM_USER" -c 'export NVM_DIR="$HOME/.nvm"; . "$NVM_DIR/nvm.sh"; nvm --version'
log "nvm setup done for '$NVM_USER'"
