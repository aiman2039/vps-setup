#!/usr/bin/env bash
# 03-termius: install Termius SSH client (snap or .deb). Idempotent.
#
# Env:
#   TERMIUS_METHOD (snap) - snap or deb
#   TERMIUS_SNAP_CHANNEL (stable)
#   TERMIUS_DEB_URL (https://www.termius.com/download/linux/Termius.deb)
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/00-common.sh"

TERMIUS_METHOD="${TERMIUS_METHOD:-snap}"
TERMIUS_SNAP_CHANNEL="${TERMIUS_SNAP_CHANNEL:-stable}"
TERMIUS_DEB_URL="${TERMIUS_DEB_URL:-https://www.termius.com/download/linux/Termius.deb}"

require_root

install_snap() {
  command -v snap >/dev/null 2>&1 || apt_install snapd
  systemctl enable --now snapd >/dev/null 2>&1 || systemctl start snapd
  # Wait for snapd to be ready (bounded).
  for _ in $(seq 1 30); do
    if snap list >/dev/null 2>&1; then break; fi
    sleep 2
  done

  if snap list termius-app >/dev/null 2>&1; then
    log "termius-app snap already installed: $(snap list termius-app | awk 'NR==2{print $2, $3}')"
    return 0
  fi
  log "installing termius-app snap (channel $TERMIUS_SNAP_CHANNEL)..."
  if ! snap install termius-app "--channel=$TERMIUS_SNAP_CHANNEL"; then
    log "retrying with --classic..."
    snap install termius-app "--channel=$TERMIUS_SNAP_CHANNEL" --classic
  fi
  snap list termius-app | awk 'NR==2{print "termius-app " $2 " (" $3 ")"}'
}

fix_sandbox() {
  # Known issue: chrome-sandbox loses its SUID bit; Termius won't start without it.
  local sb=/opt/Termius/chrome-sandbox
  if [[ -f "$sb" ]]; then
    chown root:root "$sb"
    chmod 4755 "$sb"
    log "fixed chrome-sandbox permissions"
  fi
}

install_deb() {
  command -v curl >/dev/null 2>&1 || apt_install curl ca-certificates
  local pkg=""
  if pkg_installed termius-app; then pkg=termius-app
  elif pkg_installed termius; then pkg=termius
  fi
  if [[ -n "$pkg" ]]; then
    log "$pkg already installed: $(dpkg-query -W -f='${Version}' "$pkg")"
    fix_sandbox
    return 0
  fi

  local deb=/tmp/Termius.deb
  log "downloading $TERMIUS_DEB_URL"
  curl -fSL --retry 3 -o "$deb" "$TERMIUS_DEB_URL"
  if ! dpkg-deb --info "$deb" >/dev/null 2>&1; then
    rm -f "$deb"
    die "downloaded file is not a valid deb"
  fi
  log "installing Termius .deb"
  if ! DEBIAN_FRONTEND=noninteractive apt-get install -y "$deb"; then
    DEBIAN_FRONTEND=noninteractive apt-get install -f -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$deb"
  fi
  rm -f "$deb"
  fix_sandbox
  if command -v termius-app >/dev/null 2>&1; then
    log "termius installed (termius-app)"
  elif command -v termius >/dev/null 2>&1; then
    log "termius installed (termius)"
  else
    die "termius install finished but binary not found"
  fi
}

case "$TERMIUS_METHOD" in
  snap) install_snap ;;
  deb) install_deb ;;
  *) die "invalid TERMIUS_METHOD='$TERMIUS_METHOD' (want snap or deb)" ;;
esac
