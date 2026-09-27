#!/usr/bin/env bash
# Shared helpers for vps-setup scripts. Source this, do not run directly.
# shellcheck disable=SC2034
set -euo pipefail

VPS_SETUP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VPS_APT_STAMP="/var/lib/vps-setup/apt-updated"

# Default target user: whoever invoked sudo, else "agent".
# (When run as root directly there is no invoking user, so be explicit
# via NEW_USER in that case.)
if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
  DEFAULT_USER="$SUDO_USER"
else
  DEFAULT_USER="agent"
fi

log()  { printf '[vps-setup] %s\n' "$*"; }
warn() { printf '[vps-setup] WARNING: %s\n' "$*" >&2; }
die()  { printf '[vps-setup] ERROR: %s\n' "$*" >&2; exit 1; }

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "run as root (use sudo)"
  fi
}

# apt-get update at most once per hour (idempotent across re-runs).
apt_update_once() {
  local now last
  now=$(date +%s)
  if [[ -f "$VPS_APT_STAMP" ]]; then
    last=$(stat -c %Y "$VPS_APT_STAMP" 2>/dev/null || echo 0)
    if (( now - last < 3600 )); then return 0; fi
  fi
  apt_update_force
}

apt_update_force() {
  log "apt-get update..."
  mkdir -p "$(dirname "$VPS_APT_STAMP")"
  DEBIAN_FRONTEND=noninteractive apt-get update -y
  touch "$VPS_APT_STAMP"
}

apt_install() {
  apt_update_once
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"
}

pkg_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "ok installed"
}

# ensure_ufw_allow <rule...>: add a ufw rule if ufw exists and the rule is missing.
ensure_ufw_allow() {
  if ! command -v ufw >/dev/null 2>&1; then
    log "ufw not installed, skipping firewall rule: $*"
    return 0
  fi
  if ufw status 2>/dev/null | grep -qF "$*"; then
    log "ufw rule already present: $*"
  else
    ufw allow "$@" || warn "ufw allow $* failed"
  fi
}

managed_header() {
  printf '# managed by vps-setup (%s) - safe to re-run, manual edits will be overwritten\n' "$1"
}

user_home() {
  getent passwd "$1" | cut -d: -f6
}

# resolve_vnc_passwd_tool: print the VNC password tool to use (vncpasswd or
# tigervncpasswd); prints nothing and returns 1 when neither is installed.
# (Ubuntu 22.04+/Debian 12+ TigerVNC ships no password tool at all.)
resolve_vnc_passwd_tool() {
  if command -v vncpasswd >/dev/null 2>&1; then printf 'vncpasswd'; return 0; fi
  if command -v tigervncpasswd >/dev/null 2>&1; then printf 'tigervncpasswd'; return 0; fi
  return 1
}

# pin_alternative <link> <path>: force a Debian alternative back to <path>
# when <path> is a registered choice; no-op when the link is unmanaged.
pin_alternative() {
  local link="$1" want="$2" current
  if ! command -v update-alternatives >/dev/null 2>&1; then return 0; fi
  if ! update-alternatives --query "$link" 2>/dev/null | grep -q "^Alternative: $want$"; then return 0; fi
  current="$(update-alternatives --query "$link" 2>/dev/null | sed -n 's/^Value: //p')"
  if [[ "$current" != "$want" ]]; then
    if update-alternatives --set "$link" "$want" >/dev/null 2>&1; then
      log "$link pinned to $want"
    else
      warn "could not pin $link to $want"
    fi
  fi
}
