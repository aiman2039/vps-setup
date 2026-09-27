#!/usr/bin/env bash
# 02-ssh-only: harden sshd to key-only auth. Idempotent. Run 01-user.sh first.
#
# Env:
#   SSH_PERMIT_ROOT (prohibit-password)  SSH_PASSWORD_AUTH (no)
#   SSH_ALLOW_NO_KEYS (false) - bypass the lockout guard (dangerous)
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/00-common.sh"

SSH_PERMIT_ROOT="${SSH_PERMIT_ROOT:-prohibit-password}"
SSH_PASSWORD_AUTH="${SSH_PASSWORD_AUTH:-no}"
SSH_ALLOW_NO_KEYS="${SSH_ALLOW_NO_KEYS:-false}"

require_root
command -v sshd >/dev/null 2>&1 || apt_install openssh-server

# Lockout guard: require at least one authorized key before disabling passwords.
have_key=false
for f in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; do
  if [[ -s "$f" ]]; then have_key=true; break; fi
done
if [[ "$have_key" != "true" && "$SSH_ALLOW_NO_KEYS" != "true" ]]; then
  die "no authorized_keys found; run 01-user.sh first or set SSH_ALLOW_NO_KEYS=true"
fi

if [[ ! -f /etc/ssh/sshd_config.bak.vps-setup ]]; then
  cp -a /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.vps-setup
  log "backed up sshd_config"
fi

dest=/etc/ssh/sshd_config.d/60-vps-setup.conf
tmp=$(mktemp)
{
  managed_header "02-ssh-only"
  printf 'PubkeyAuthentication yes\n'
  printf 'PasswordAuthentication %s\n' "$SSH_PASSWORD_AUTH"
  printf 'ChallengeResponseAuthentication no\n'
  printf 'PermitRootLogin %s\n' "$SSH_PERMIT_ROOT"
  printf 'PermitEmptyPasswords no\n'
  printf 'X11Forwarding yes\n'
} > "$tmp"
changed=false
if [[ -f "$dest" ]] && cmp -s "$tmp" "$dest"; then
  log "sshd drop-in already up to date"
else
  install -m 644 "$tmp" "$dest"
  changed=true
  log "wrote $dest"
fi
rm -f "$tmp"

sshd -t || die "sshd config invalid; not reloading (check $dest)"

svc=ssh
if ! systemctl list-unit-files "$svc.service" >/dev/null 2>&1; then svc=sshd; fi
if [[ "$changed" == "true" ]]; then
  systemctl reload-or-restart "$svc"
  log "sshd reloaded"
elif ! systemctl is-active --quiet "$svc"; then
  systemctl start "$svc"
fi

ensure_ufw_allow "OpenSSH"
log "effective: $(sshd -T 2>/dev/null | grep -Ei '^(passwordauthentication|permitrootlogin|pubkeyauthentication) ' | tr '\n' ';')"
