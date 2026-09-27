#!/usr/bin/env bash
# Shared helpers for vps-setup scripts. Source this, do not run directly.
# shellcheck disable=SC2034
set -euo pipefail

VPS_SETUP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VPS_APT_STAMP="/var/lib/vps-setup/apt-updated"

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
