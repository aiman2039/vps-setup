#!/usr/bin/env bash
# 01-user: create/ensure a non-root sudo user. Idempotent: safe to re-run.
#
# Env:
#   NEW_USER (agent)  NEW_USER_SHELL (/bin/bash)  NEW_USER_SUDO (true)
#   SUDO_NOPASSWD (true)  COPY_ROOT_KEYS (true)
#   AUTHORIZED_KEY ("")  AUTHORIZED_KEYS_FILE ("")  USER_PASSWORD ("")
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/00-common.sh"

NEW_USER="${NEW_USER:-$DEFAULT_USER}"
NEW_USER_SHELL="${NEW_USER_SHELL:-/bin/bash}"
NEW_USER_SUDO="${NEW_USER_SUDO:-true}"
SUDO_NOPASSWD="${SUDO_NOPASSWD:-true}"
COPY_ROOT_KEYS="${COPY_ROOT_KEYS:-true}"
AUTHORIZED_KEY="${AUTHORIZED_KEY:-}"
AUTHORIZED_KEYS_FILE="${AUTHORIZED_KEYS_FILE:-}"
USER_PASSWORD="${USER_PASSWORD:-}"

require_root
if ! [[ "$NEW_USER" =~ ^[a-z_][a-z0-9_-]*$ ]]; then die "invalid NEW_USER='$NEW_USER'"; fi
if [[ "$NEW_USER" == "root" ]]; then die "NEW_USER must not be root"; fi
if [[ ! -x "$NEW_USER_SHELL" ]]; then die "shell not executable: $NEW_USER_SHELL"; fi

command -v sudo >/dev/null 2>&1 || apt_install sudo

if id "$NEW_USER" >/dev/null 2>&1; then
  log "user '$NEW_USER' already exists"
  current_shell="$(getent passwd "$NEW_USER" | cut -d: -f7)"
  if [[ "$current_shell" != "$NEW_USER_SHELL" ]]; then
    usermod -s "$NEW_USER_SHELL" "$NEW_USER"
    log "shell set to $NEW_USER_SHELL"
  fi
else
  useradd -m -s "$NEW_USER_SHELL" "$NEW_USER"
  log "user '$NEW_USER' created"
fi

if [[ "$NEW_USER_SUDO" == "true" ]]; then
  if ! id -nG "$NEW_USER" | tr ' ' '\n' | grep -qx "sudo"; then
    usermod -aG sudo "$NEW_USER"
    log "added '$NEW_USER' to sudo group"
  fi
  sudoers_file="/etc/sudoers.d/90-${NEW_USER}"
  if [[ "$SUDO_NOPASSWD" == "true" ]]; then
    printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$NEW_USER" > "$sudoers_file"
    chmod 0440 "$sudoers_file"
    if ! visudo -c -f "$sudoers_file" >/dev/null; then
      rm -f "$sudoers_file"
      die "sudoers validation failed"
    fi
    log "passwordless sudo enabled for '$NEW_USER'"
  elif [[ -f "$sudoers_file" ]]; then
    rm -f "$sudoers_file"
    log "removed passwordless sudo for '$NEW_USER'"
  fi
fi

home="$(user_home "$NEW_USER")"
install -d -o "$NEW_USER" -g "$NEW_USER" -m 700 "$home/.ssh"
touch "$home/.ssh/authorized_keys"
chown "$NEW_USER:$NEW_USER" "$home/.ssh/authorized_keys"
chmod 600 "$home/.ssh/authorized_keys"

add_key() { # $1 = key line
  local key="$1"
  if [[ -z "$key" || "$key" == \#* ]]; then return 0; fi
  if ! grep -qxF "$key" "$home/.ssh/authorized_keys"; then
    printf '%s\n' "$key" >> "$home/.ssh/authorized_keys"
    log "added ssh key (...${key: -16})"
  fi
}

if [[ "$COPY_ROOT_KEYS" == "true" && -f /root/.ssh/authorized_keys ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do add_key "$line"; done < /root/.ssh/authorized_keys
fi
if [[ -n "$AUTHORIZED_KEY" ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do add_key "$line"; done <<<"$AUTHORIZED_KEY"
fi
if [[ -n "$AUTHORIZED_KEYS_FILE" ]]; then
  if [[ ! -f "$AUTHORIZED_KEYS_FILE" ]]; then die "AUTHORIZED_KEYS_FILE not found: $AUTHORIZED_KEYS_FILE"; fi
  while IFS= read -r line || [[ -n "$line" ]]; do add_key "$line"; done < "$AUTHORIZED_KEYS_FILE"
fi

# SSH key step: if no key ended up installed, explain how to add one and
# (on an interactive terminal) offer to paste one right now.
key_count="$(grep -c . "$home/.ssh/authorized_keys" || true)"
if [[ "${key_count:-0}" -eq 0 ]]; then
  warn "no SSH keys installed for '$NEW_USER'."
  cat >&2 <<'EOF'
[vps-setup] To add one, re-run with a key:
[vps-setup]   AUTHORIZED_KEY="$(cat ~/.ssh/id_ed25519.pub)" sudo -E ./scripts/01-user.sh
[vps-setup] or copy a key from your local machine, then re-run
[vps-setup] (01-user.sh copies root's keys to the new user):
[vps-setup]   ssh-keygen -t ed25519            # if you have no key yet
[vps-setup]   ssh-copy-id root@YOUR_VPS
[vps-setup] Note: 02-ssh-only.sh refuses to disable password auth until a key exists.
EOF
  if [[ -t 0 ]]; then
    pasted_key=""
    read -r -p "[vps-setup] Paste an SSH public key now (Enter to skip): " pasted_key || true
    if [[ -n "$pasted_key" ]]; then
      if [[ "$pasted_key" =~ ^(ssh-|ecdsa-|sk-)[a-z0-9-]+[[:space:]]+[A-Za-z0-9+/=]+ ]]; then
        add_key "$pasted_key"
      else
        warn "that does not look like an SSH public key; skipped (re-run to retry)"
      fi
    fi
  fi
fi

if [[ -n "$USER_PASSWORD" ]]; then
  printf '%s:%s' "$NEW_USER" "$USER_PASSWORD" | chpasswd
  log "password set for '$NEW_USER'"
else
  status="$(passwd -S "$NEW_USER" 2>/dev/null | awk '{print $2}')"
  if [[ "$status" == "NP" || "$status" == "L" ]] && [[ "$SUDO_NOPASSWD" != "true" ]]; then
    warn "'$NEW_USER' has no password and no NOPASSWD sudo; set USER_PASSWORD or SUDO_NOPASSWD=true"
  fi
fi

log "user setup done: $(id "$NEW_USER"); keys: $(grep -c . "$home/.ssh/authorized_keys" || true)"
