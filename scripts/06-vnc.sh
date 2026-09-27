#!/usr/bin/env bash
# 06-vnc: install TigerVNC server + systemd service. Idempotent.
# Requires a desktop already installed and user from 01-user.sh.
# Existing ~/.vnc/xstartup and password are kept unless forced.
#
# Env:
#   VNC_USER (NEW_USER/agent)  VNC_DISPLAY (1)  VNC_GEOMETRY (1920x1080)
#   VNC_DEPTH (24)  VNC_PASSWORD ("")  VNC_UPDATE_PASSWORD (false)
#   VNC_LOCALHOST (no)  VNC_FORCE_XSTARTUP (false)
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/00-common.sh"

NEW_USER="${NEW_USER:-agent}"
VNC_USER="${VNC_USER:-$NEW_USER}"
VNC_DISPLAY="${VNC_DISPLAY:-1}"
VNC_GEOMETRY="${VNC_GEOMETRY:-1920x1080}"
VNC_DEPTH="${VNC_DEPTH:-24}"
VNC_PASSWORD="${VNC_PASSWORD:-}"
VNC_UPDATE_PASSWORD="${VNC_UPDATE_PASSWORD:-false}"
VNC_LOCALHOST="${VNC_LOCALHOST:-no}"
VNC_FORCE_XSTARTUP="${VNC_FORCE_XSTARTUP:-false}"

require_root
id "$VNC_USER" >/dev/null 2>&1 || die "user '$VNC_USER' missing; run 01-user.sh first"
if ! [[ "$VNC_DISPLAY" =~ ^[0-9]+$ ]]; then die "invalid VNC_DISPLAY='$VNC_DISPLAY'"; fi

apt_install tigervnc-standalone-server tigervnc-common dbus-x11

home="$(user_home "$VNC_USER")"
install -d -o "$VNC_USER" -g "$VNC_USER" -m 755 "$home/.vnc"

if [[ -f "$home/.vnc/passwd" && "$VNC_UPDATE_PASSWORD" != "true" ]]; then
  log "VNC password already set (VNC_UPDATE_PASSWORD=true to change)"
elif [[ -n "$VNC_PASSWORD" ]]; then
  printf '%s' "$VNC_PASSWORD" | su -s /bin/bash "$VNC_USER" -c 'vncpasswd -f > "$HOME/.vnc/passwd"'
  chmod 600 "$home/.vnc/passwd"
  chown "$VNC_USER:$VNC_USER" "$home/.vnc/passwd"
  log "VNC password set for '$VNC_USER'"
else
  warn "no VNC password: set VNC_PASSWORD and re-run to finish VNC setup"
fi

detect_session() {
  if [[ -x /usr/bin/gnome-session ]]; then printf '/usr/bin/gnome-session'; return; fi
  for s in /usr/bin/mate-session /usr/bin/startxfce4 /usr/bin/lxsession /usr/bin/startlxde /usr/bin/startplasma-x11; do
    if [[ -x "$s" ]]; then printf '%s' "$s"; return; fi
  done
  printf '/usr/bin/xterm'
}

if [[ -f "$home/.vnc/xstartup" && "$VNC_FORCE_XSTARTUP" != "true" ]]; then
  log "xstartup already present"
else
  session="$(detect_session)"
  log "xstartup session: $session"
  tmp=$(mktemp)
  {
    printf '#!/bin/sh\n'
    managed_header "06-vnc"
    printf 'unset SESSION_MANAGER\nunset DBUS_SESSION_BUS_ADDRESS\n'
    printf 'exec %s\n' "$session"
  } > "$tmp"
  install -o "$VNC_USER" -g "$VNC_USER" -m 755 "$tmp" "$home/.vnc/xstartup"
  rm -f "$tmp"
fi

localhost_flag="no"
if [[ "$VNC_LOCALHOST" == "yes" ]]; then localhost_flag="yes"; fi

unit=/etc/systemd/system/vncserver@.service
tmp=$(mktemp)
{
  managed_header "06-vnc"
  cat <<EOF
[Unit]
Description=TigerVNC server on display %i (vps-setup)
After=syslog.target network.target

[Service]
Type=simple
User=${VNC_USER}
PAMName=login
PIDFile=${home}/.vnc/%H:%i.pid
ExecStartPre=/bin/sh -c '/usr/bin/vncserver -kill :%i > /dev/null 2>&1 || :'
ExecStart=/usr/bin/vncserver :%i -geometry ${VNC_GEOMETRY} -depth ${VNC_DEPTH} -localhost ${localhost_flag}
ExecStop=/usr/bin/vncserver -kill :%i
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
} > "$tmp"
unit_changed=false
if [[ -f "$unit" ]] && cmp -s "$tmp" "$unit"; then
  log "systemd unit already up to date"
else
  install -m 644 "$tmp" "$unit"
  systemctl daemon-reload
  unit_changed=true
  log "wrote $unit"
fi
rm -f "$tmp"

port=$((5900 + VNC_DISPLAY))
ensure_ufw_allow "${port}/tcp"

svc="vncserver@${VNC_DISPLAY}.service"
if [[ ! -f "$home/.vnc/passwd" ]]; then
  warn "skipping service start until VNC password is set"
else
  if [[ "$unit_changed" == "true" ]]; then
    systemctl enable --now "$svc"
    systemctl restart "$svc"
  else
    systemctl enable --now "$svc" >/dev/null 2>&1 || systemctl restart "$svc"
  fi
  if systemctl is-active --quiet "$svc"; then
    log "VNC active on :$VNC_DISPLAY (port $port)"
  else
    warn "VNC service not active; check: journalctl -u $svc"
  fi
fi
