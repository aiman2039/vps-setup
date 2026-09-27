#!/usr/bin/env bash
# 06-vnc: install Xfce + TigerVNC and ensure the systemd service is ready.
# Requires the user from 01-user.sh. Safe to re-run.
# Custom xstartup files and existing passwords are kept unless forced.
#
# Env:
#   VNC_USER (NEW_USER/agent)  VNC_DISPLAY (1)  VNC_GEOMETRY (1920x1080)
#   VNC_DEPTH (24)  VNC_PASSWORD ("")  VNC_UPDATE_PASSWORD (false)
#   VNC_LOCALHOST (no)  VNC_FORCE_XSTARTUP (false)
#   VNC_SESSION (/usr/bin/startxfce4) explicit session binary, e.g. /usr/bin/startxfce4
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/00-common.sh"

NEW_USER="${NEW_USER:-$DEFAULT_USER}"
VNC_USER="${VNC_USER:-$NEW_USER}"
VNC_DISPLAY="${VNC_DISPLAY:-1}"
VNC_GEOMETRY="${VNC_GEOMETRY:-1920x1080}"
VNC_DEPTH="${VNC_DEPTH:-24}"
VNC_PASSWORD="${VNC_PASSWORD:-}"
VNC_UPDATE_PASSWORD="${VNC_UPDATE_PASSWORD:-false}"
VNC_LOCALHOST="${VNC_LOCALHOST:-no}"
VNC_FORCE_XSTARTUP="${VNC_FORCE_XSTARTUP:-false}"

VNC_SESSION="${VNC_SESSION:-/usr/bin/startxfce4}"

require_root
id "$VNC_USER" >/dev/null 2>&1 || die "user '$VNC_USER' missing; run 01-user.sh first"
[[ "$VNC_DISPLAY" =~ ^[0-9]{1,5}$ ]] || die "invalid VNC_DISPLAY='$VNC_DISPLAY'"
VNC_DISPLAY=$((10#$VNC_DISPLAY))
(( VNC_DISPLAY >= 1 && VNC_DISPLAY <= 59635 )) || die "VNC_DISPLAY must be between 1 and 59635"
[[ "$VNC_GEOMETRY" =~ ^[1-9][0-9]{0,4}x[1-9][0-9]{0,4}$ ]] || die "invalid VNC_GEOMETRY"
case "$VNC_DEPTH" in 16|24|32) ;; *) die "VNC_DEPTH must be 16, 24, or 32" ;; esac
case "$VNC_LOCALHOST" in yes|no) ;; *) die "VNC_LOCALHOST must be yes or no" ;; esac
for value in "$VNC_UPDATE_PASSWORD" "$VNC_FORCE_XSTARTUP"; do
  case "$value" in true|false) ;; *) die "password/startup flags must be true or false" ;; esac
done

apt_install xfce4 xfce4-terminal tigervnc-standalone-server tigervnc-common tigervnc-tools dbus-x11

home="$(user_home "$VNC_USER")"
[[ "$home" == /* && -d "$home" ]] || die "missing home directory for '$VNC_USER'"
group="$(id -gn "$VNC_USER")"
install -d -o "$VNC_USER" -g "$group" -m 700 "$home/.vnc"
config_changed=false

if [[ -s "$home/.vnc/passwd" && "$VNC_UPDATE_PASSWORD" != "true" ]]; then
  log "VNC password already set (VNC_UPDATE_PASSWORD=true to change)"
elif [[ -n "$VNC_PASSWORD" ]]; then
  # Compatibility fallback if the packaged TigerVNC password tool is unavailable.
  passwd_tool="$(resolve_vnc_passwd_tool || true)"
  if [[ -z "$passwd_tool" ]]; then
    log "no vncpasswd/tigervncpasswd found; installing tightvncserver for its vncpasswd"
    apt_install tightvncserver
    pin_alternative vncserver /usr/bin/tigervncserver
    pin_alternative vncconfig /usr/bin/tigervncconfig
    pin_alternative Xvnc /usr/bin/Xtigervnc
    passwd_tool="$(resolve_vnc_passwd_tool || true)"
  fi
  [[ -n "$passwd_tool" ]] || die "no VNC password tool available (tried tightvncserver; is the universe repo enabled?)"
  (( ${#VNC_PASSWORD} >= 6 )) || die "VNC_PASSWORD must contain at least 6 characters"
  tmp=$(mktemp "$home/.vnc/.passwd.XXXXXX")
  if ! printf '%s\n' "$VNC_PASSWORD" | "$passwd_tool" -f > "$tmp" || [[ ! -s "$tmp" ]]; then
    rm -f "$tmp"
    die "failed to generate VNC password"
  fi
  if ! cmp -s "$tmp" "$home/.vnc/passwd"; then
    install -o "$VNC_USER" -g "$group" -m 600 "$tmp" "$home/.vnc/passwd"
    config_changed=true
  fi
  rm -f "$tmp"
  log "VNC password set for '$VNC_USER'"
else
  die "set VNC_PASSWORD on the first run (or when VNC_UPDATE_PASSWORD=true)"
fi

chmod 600 "$home/.vnc/passwd"
chown "$VNC_USER:$group" "$home/.vnc/passwd"

if [[ -f "$home/.vnc/xstartup" && "$VNC_FORCE_XSTARTUP" != "true" ]] \
  && ! grep -qF '# managed by vps-setup (06-vnc)' "$home/.vnc/xstartup"; then
  log "xstartup already present"
else
  session="$(detect_vnc_session)"
  log "xstartup session: $session"
  tmp=$(mktemp)
  {
    printf '#!/bin/sh\n'
    managed_header "06-vnc"
    printf 'unset SESSION_MANAGER\nunset DBUS_SESSION_BUS_ADDRESS\n'
    printf "exec /usr/bin/dbus-run-session -- '%s'\n" "${session//\'/\'\\\'\'}"
  } > "$tmp"
  if ! cmp -s "$tmp" "$home/.vnc/xstartup"; then
    install -o "$VNC_USER" -g "$group" -m 755 "$tmp" "$home/.vnc/xstartup"
    config_changed=true
  fi
  rm -f "$tmp"
fi

chmod 755 "$home/.vnc/xstartup"
chown "$VNC_USER:$group" "$home/.vnc/xstartup"

localhost_flag="no"
if [[ "$VNC_LOCALHOST" == "yes" ]]; then localhost_flag="yes"; fi

# Prefer the absolute TigerVNC binary: /usr/bin/vncserver is a Debian
# alternative that other VNC packages (e.g. tightvncserver) can flip.
vnc_server_bin=/usr/bin/vncserver
if [[ -x /usr/bin/tigervncserver ]]; then vnc_server_bin=/usr/bin/tigervncserver; fi

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
WorkingDirectory=${home}
Environment="HOME=${home}"
ExecStartPre=/bin/sh -c '${vnc_server_bin} -kill :%i > /dev/null 2>&1 || :'
ExecStart=${vnc_server_bin} :%i -fg -autokill yes -xstartup "${home}/.vnc/xstartup" -PasswordFile "${home}/.vnc/passwd" -geometry ${VNC_GEOMETRY} -depth ${VNC_DEPTH} -localhost ${localhost_flag}
ExecStop=${vnc_server_bin} -kill :%i
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
if [[ "$VNC_LOCALHOST" == "no" ]]; then ensure_ufw_allow "${port}/tcp"; fi

svc="vncserver@${VNC_DISPLAY}.service"
systemctl enable "$svc"
if [[ "$unit_changed" == "true" || "$config_changed" == "true" ]]; then
  systemctl restart "$svc"
else
  systemctl start "$svc"
fi

# Require a stable service and an RFB greeting, not just a successful start job.
ready=0
for ((attempt = 0; attempt < 30; attempt++)); do
  if systemctl is-active --quiet "$svc" && timeout 2 bash -c '
    exec 3<>/dev/tcp/127.0.0.1/"$1"
    IFS= read -r -N 12 banner <&3
    [[ "$banner" == RFB\ * ]]
  ' _ "$port" 2>/dev/null; then
    ready=$((ready + 1))
    if (( ready >= 5 )); then
      log "VNC ready on :$VNC_DISPLAY (port $port, localhost=$VNC_LOCALHOST)"
      exit 0
    fi
  else
    ready=0
  fi
  sleep 1
done
die "VNC did not become ready; check: journalctl -u $svc -n 50 --no-pager"
