#!/usr/bin/env bash
# 14-opencode: install opencode AI coding agent (standalone binary). Idempotent.
# Installer manages ~/.opencode/bin and shell PATH itself.
#
# Env:
#   OPENCODE_USER (NEW_USER)  OPENCODE_VERSION ("") - e.g. 1.0.180, "" = latest
#   OPENCODE_UPDATE_ON_RERUN (false)
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/00-common.sh"

NEW_USER="${NEW_USER:-$DEFAULT_USER}"
OPENCODE_USER="${OPENCODE_USER:-$NEW_USER}"
OPENCODE_VERSION="${OPENCODE_VERSION:-}"
OPENCODE_UPDATE_ON_RERUN="${OPENCODE_UPDATE_ON_RERUN:-false}"

require_root
id "$OPENCODE_USER" >/dev/null 2>&1 || die "user '$OPENCODE_USER' missing; run 01-user.sh first"
apt_install curl ca-certificates
if [[ -n "$OPENCODE_VERSION" ]] && ! [[ "$OPENCODE_VERSION" =~ ^[0-9][0-9A-Za-z._-]*$ ]]; then
  die "invalid OPENCODE_VERSION='$OPENCODE_VERSION'"
fi

home="$(user_home "$OPENCODE_USER")"
if [[ -x "$home/.opencode/bin/opencode" ]] \
  && su -s /bin/bash "$OPENCODE_USER" -c '"$HOME/.opencode/bin/opencode" --version' >/dev/null 2>&1; then
  if [[ "$OPENCODE_UPDATE_ON_RERUN" != "true" ]]; then
    log "opencode already installed: $(su -s /bin/bash "$OPENCODE_USER" -c '"$HOME/.opencode/bin/opencode" --version')"
    exit 0
  fi
  log "updating opencode for '$OPENCODE_USER'..."
fi

if [[ -n "$OPENCODE_VERSION" ]]; then
  log "installing opencode $OPENCODE_VERSION for '$OPENCODE_USER'..."
  su -s /bin/bash "$OPENCODE_USER" -c "curl -fsSL https://opencode.ai/install | bash -s -- --version '$OPENCODE_VERSION'"
else
  log "installing opencode (latest) for '$OPENCODE_USER'..."
  su -s /bin/bash "$OPENCODE_USER" -c 'curl -fsSL https://opencode.ai/install | bash'
fi

if ! su -s /bin/bash "$OPENCODE_USER" -c '"$HOME/.opencode/bin/opencode" --version'; then
  die "opencode install finished but binary does not run"
fi
log "opencode setup done for '$OPENCODE_USER'"
