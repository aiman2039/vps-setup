#!/usr/bin/env bash
# 15-pi: install Pi coding agent via npm. Idempotent. Needs node from 12-nvm.sh.
#
# Env:
#   PI_USER (NEW_USER)  PI_UPDATE_ON_RERUN (false)
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/00-common.sh"

NEW_USER="${NEW_USER:-$DEFAULT_USER}"
PI_USER="${PI_USER:-$NEW_USER}"
PI_UPDATE_ON_RERUN="${PI_UPDATE_ON_RERUN:-false}"
PI_PACKAGE="@earendil-works/pi-coding-agent"

require_root
id "$PI_USER" >/dev/null 2>&1 || die "user '$PI_USER' missing; run 01-user.sh first"

nvm_env='export NVM_DIR="$HOME/.nvm"; . "$NVM_DIR/nvm.sh"; nvm use default'
if ! su -s /bin/bash "$PI_USER" -c "$nvm_env >/dev/null 2>&1 && command -v npm >/dev/null 2>&1"; then
  die "node/npm not found for '$PI_USER'; run 12-nvm.sh with NVM_NODE_VERSION set"
fi

if su -s /bin/bash "$PI_USER" -c "$nvm_env >/dev/null 2>&1 && pi --version >/dev/null 2>&1"; then
  if [[ "$PI_UPDATE_ON_RERUN" != "true" ]]; then
    log "pi already installed: $(su -s /bin/bash "$PI_USER" -c "$nvm_env >/dev/null 2>&1 && pi --version")"
    exit 0
  fi
  log "updating pi for '$PI_USER'..."
else
  log "installing pi for '$PI_USER'..."
fi

su -s /bin/bash "$PI_USER" -c "$nvm_env >/dev/null 2>&1 && npm install -g --ignore-scripts $PI_PACKAGE"
if ! su -s /bin/bash "$PI_USER" -c "$nvm_env >/dev/null 2>&1 && pi --version"; then
  die "pi install finished but binary does not run"
fi
log "pi setup done for '$PI_USER'"
