#!/usr/bin/env bash
# 11-lockdown: restrict all access to the Tailscale network. Idempotent.
# OFF by default (LOCKDOWN_ENABLE=true to apply). Refuses to run unless
# Tailscale is up. Verify tailnet access from another device BEFORE enabling,
# and keep your current session open while you do.
#
# Env:
#   LOCKDOWN_ENABLE (false)  LOCKDOWN_ALLOW_SSH_PUBLIC (false)
#   LOCKDOWN_PUBLIC_TCP_PORTS ("") - e.g. "80,443"
#   VNC_DISPLAY (1)  MOSH_UDP_RANGE (60000:61000)
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/00-common.sh"

LOCKDOWN_ENABLE="${LOCKDOWN_ENABLE:-false}"
LOCKDOWN_ALLOW_SSH_PUBLIC="${LOCKDOWN_ALLOW_SSH_PUBLIC:-false}"
LOCKDOWN_PUBLIC_TCP_PORTS="${LOCKDOWN_PUBLIC_TCP_PORTS:-}"
VNC_DISPLAY="${VNC_DISPLAY:-1}"
MOSH_UDP_RANGE="${MOSH_UDP_RANGE:-60000:61000}"

if [[ "$LOCKDOWN_ENABLE" != "true" ]]; then
  log "LOCKDOWN_ENABLE != true; skipping"
  exit 0
fi

require_root
command -v tailscale >/dev/null 2>&1 || die "tailscale not installed; run 08-tailscale.sh first"
tail_ip="$(tailscale ip -4 2>/dev/null | head -n1)"
if [[ -z "$tail_ip" ]]; then
  die "tailscale is not up (no IPv4); run 'tailscale up' first - refusing to lock down"
fi
log "tailscale up: $tail_ip"

if ! pkg_installed ufw; then apt_install ufw; fi

# 1. full access from the tailnet
if ufw status 2>/dev/null | grep -q "on tailscale0"; then
  log "ufw: tailnet rule already present"
else
  ufw allow in on tailscale0
  log "ufw: allowed all incoming on tailscale0"
fi

# 2. drop public allows added by earlier steps (unless explicitly kept)
vnc_port=$((5900 + VNC_DISPLAY))
drop_public() { # $1 = rule spec as added (e.g. OpenSSH, 5901/tcp)
  if ufw status 2>/dev/null | grep -qF "$1"; then
    ufw --force delete allow "$1" || warn "could not delete ufw rule: $1"
  fi
}
if [[ "$LOCKDOWN_ALLOW_SSH_PUBLIC" == "true" ]]; then
  ensure_ufw_allow "OpenSSH"
else
  drop_public "OpenSSH"
fi
drop_public "${MOSH_UDP_RANGE}/udp"
drop_public "${vnc_port}/tcp"

# 3. optional extra public ports
if [[ -n "$LOCKDOWN_PUBLIC_TCP_PORTS" ]]; then
  # shellcheck disable=SC2086
  for p in ${LOCKDOWN_PUBLIC_TCP_PORTS//,/ }; do
    ensure_ufw_allow "$p/tcp"
  done
fi

# 4. defaults + enable
ufw default deny incoming
ufw default allow outgoing
if ufw status 2>/dev/null | head -n1 | grep -q "inactive"; then
  ufw --force enable
  log "ufw enabled"
else
  log "ufw already active"
fi

# 5. verify no unintended public allows remain
fail=false
check_closed() { # $1 = regex, $2 = label
  if ufw status 2>/dev/null | grep -Eq "$1"; then
    warn "still publicly reachable: $2"
    fail=true
  fi
}
if [[ "$LOCKDOWN_ALLOW_SSH_PUBLIC" != "true" ]]; then
  check_closed '^(OpenSSH|22(/tcp)?)( \(v6\))? ' "ssh"
fi
check_closed "^${vnc_port}/tcp" "vnc"
check_closed "^${MOSH_UDP_RANGE}/udp" "mosh"
if [[ "$fail" == "true" ]]; then
  die "public rules remain; remove them manually (ufw status numbered; ufw delete N)"
fi

if command -v docker >/dev/null 2>&1; then
  warn "docker bypasses ufw; bind published ports to $tail_ip (e.g. -p $tail_ip:8080:80)"
fi
ufw status verbose
log "lockdown active: connect via tailnet IP $tail_ip"
