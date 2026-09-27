#!/usr/bin/env bash
# 04-mosh: install mosh + open its UDP port range. Idempotent.
#
# Env:
#   MOSH_UDP_RANGE (60000:61000)
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/00-common.sh"

MOSH_UDP_RANGE="${MOSH_UDP_RANGE:-60000:61000}"

require_root

if pkg_installed mosh; then
  log "mosh already installed: $(dpkg-query -W -f='${Version}' mosh)"
else
  apt_install mosh
fi
command -v mosh-server >/dev/null 2>&1 || die "mosh installed but mosh-server missing"

ensure_ufw_allow "${MOSH_UDP_RANGE}/udp"
log "mosh ready"
