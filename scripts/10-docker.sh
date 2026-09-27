#!/usr/bin/env bash
# 10-docker: install Docker Engine from the official repo. Idempotent.
#
# Env:
#   DOCKER_USER (NEW_USER/agent)  DOCKER_ADD_USER_TO_GROUP (true)
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/00-common.sh"

NEW_USER="${NEW_USER:-$DEFAULT_USER}"
DOCKER_USER="${DOCKER_USER:-$NEW_USER}"
DOCKER_ADD_USER_TO_GROUP="${DOCKER_ADD_USER_TO_GROUP:-true}"

require_root
id "$DOCKER_USER" >/dev/null 2>&1 || die "user '$DOCKER_USER' missing; run 01-user.sh first"
apt_install curl ca-certificates gnupg lsb-release

codename="$(lsb_release -cs 2>/dev/null || true)"
if [[ -z "$codename" ]]; then codename="jammy"; warn "could not detect codename, using jammy"; fi

# Remove conflicting distro packages (no-op if absent).
for p in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
  if pkg_installed "$p"; then
    DEBIAN_FRONTEND=noninteractive apt-get remove -y "$p"
    log "removed conflicting package: $p"
  fi
done

install -d -m 0755 /etc/apt/keyrings
keyring=/etc/apt/keyrings/docker.asc
list_file=/etc/apt/sources.list.d/docker.list

repo_changed=false
if [[ -s "$keyring" ]]; then
  log "docker keyring already present"
else
  curl -fsSL --retry 3 https://download.docker.com/linux/ubuntu/gpg -o "$keyring"
  chmod a+r "$keyring"
  repo_changed=true
  log "docker keyring installed"
fi

tmp=$(mktemp)
{
  managed_header "10-docker"
  printf 'deb [arch=%s signed-by=%s] https://download.docker.com/linux/ubuntu %s stable\n' \
    "$(dpkg --print-architecture)" "$keyring" "$codename"
} > "$tmp"
if [[ -f "$list_file" ]] && cmp -s "$tmp" "$list_file"; then
  log "docker apt source already up to date"
else
  install -m 644 "$tmp" "$list_file"
  repo_changed=true
  log "wrote $list_file"
fi
rm -f "$tmp"

if [[ "$repo_changed" == "true" ]]; then
  apt_update_force
else
  apt_update_once
fi
apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

systemctl enable --now containerd
systemctl enable --now docker

if [[ "$DOCKER_ADD_USER_TO_GROUP" == "true" ]]; then
  if id -nG "$DOCKER_USER" | tr ' ' '\n' | grep -qx "docker"; then
    log "'$DOCKER_USER' already in docker group"
  else
    usermod -aG docker "$DOCKER_USER"
    warn "'$DOCKER_USER' added to docker group; re-login before running docker without sudo"
  fi
fi

log "docker ready: $(docker --version); $(docker compose version)"
