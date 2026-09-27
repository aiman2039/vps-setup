#!/usr/bin/env bash
# 00-prep: baseline packages + system upgrade. Idempotent. Runs first.
# Installs ufw but does not enable it (later steps only add rules).
#
# Env:
#   PREP_PACKAGES (default list below) - full override
#   PREP_EXTRA_PACKAGES ("") - appended to the list
#   PREP_UPGRADE (true)
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/00-common.sh"

PREP_PACKAGES="${PREP_PACKAGES:-git curl wget ca-certificates gnupg lsb-release sudo openssh-server software-properties-common unzip ufw dnsutils htop vim}"
PREP_EXTRA_PACKAGES="${PREP_EXTRA_PACKAGES:-}"
PREP_UPGRADE="${PREP_UPGRADE:-true}"

require_root
apt_update_force

if [[ "$PREP_UPGRADE" == "true" ]]; then
  log "upgrading system packages..."
  DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
  if [[ -f /var/run/reboot-required ]]; then
    warn "reboot required to finish upgrade (re-run setup after reboot; it resumes cleanly)"
  fi
fi

# shellcheck disable=SC2206
pkgs=($PREP_PACKAGES $PREP_EXTRA_PACKAGES)
if [[ "${#pkgs[@]}" -gt 0 ]]; then
  apt_install "${pkgs[@]}"
fi

log "prep ready: $(git --version 2>/dev/null || echo 'git MISSING'), $(curl --version 2>/dev/null | head -n1 || echo 'curl MISSING')"
command -v git >/dev/null 2>&1 || die "git install failed"
command -v curl >/dev/null 2>&1 || die "curl install failed"
