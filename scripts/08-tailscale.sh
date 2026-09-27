#!/usr/bin/env bash
# 08-tailscale: install Tailscale from the official repo, optionally tailscale up.
# Idempotent: skips install/login when already done.
#
# Env:
#   TAILSCALE_AUTH_KEY ("") - ephemeral reusable key recommended
#   TAILSCALE_HOSTNAME ("")  TAILSCALE_EXTRA_ARGS ("")
#   TAILSCALE_ENABLE_SSH (true)  TAILSCALE_FORCE_UP (false)
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/00-common.sh"

TAILSCALE_AUTH_KEY="${TAILSCALE_AUTH_KEY:-}"
TAILSCALE_HOSTNAME="${TAILSCALE_HOSTNAME:-}"
TAILSCALE_EXTRA_ARGS="${TAILSCALE_EXTRA_ARGS:-}"
TAILSCALE_ENABLE_SSH="${TAILSCALE_ENABLE_SSH:-true}"
TAILSCALE_FORCE_UP="${TAILSCALE_FORCE_UP:-false}"

require_root
apt_install curl ca-certificates gnupg lsb-release

codename="$(lsb_release -cs 2>/dev/null || true)"
if [[ -z "$codename" ]]; then codename="jammy"; warn "could not detect codename, using jammy"; fi
keyring=/usr/share/keyrings/tailscale-archive-keyring.gpg
list_file=/etc/apt/sources.list.d/tailscale.list

repo_changed=false
if [[ -s "$keyring" ]]; then
  log "tailscale keyring already present"
else
  curl -fsSL --retry 3 "https://pkgs.tailscale.com/stable/ubuntu/${codename}.noarmor.gpg" -o "$keyring"
  chmod 644 "$keyring"
  repo_changed=true
  log "tailscale keyring installed"
fi

tmp=$(mktemp)
{
  managed_header "08-tailscale"
  printf 'deb [signed-by=%s arch=%s] https://pkgs.tailscale.com/stable/ubuntu %s main\n' \
    "$keyring" "$(dpkg --print-architecture)" "$codename"
} > "$tmp"
if [[ -f "$list_file" ]] && cmp -s "$tmp" "$list_file"; then
  log "tailscale apt source already up to date"
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
if pkg_installed tailscale; then
  log "tailscale already installed: $(dpkg-query -W -f='${Version}' tailscale)"
else
  apt_install tailscale
fi
systemctl enable --now tailscaled

online=false
if tailscale ip -4 >/dev/null 2>&1; then online=true; fi

if [[ "$online" == "true" && "$TAILSCALE_FORCE_UP" != "true" ]]; then
  log "tailscale already up: $(tailscale ip -4 | tr '\n' ' ')"
elif [[ -n "$TAILSCALE_AUTH_KEY" ]]; then
  args=(up "--auth-key=$TAILSCALE_AUTH_KEY")
  if [[ -n "$TAILSCALE_HOSTNAME" ]]; then args+=("--hostname=$TAILSCALE_HOSTNAME"); fi
  if [[ "$TAILSCALE_ENABLE_SSH" == "true" ]]; then args+=(--ssh); fi
  if [[ -n "$TAILSCALE_EXTRA_ARGS" ]]; then
    # shellcheck disable=SC2206
    extra=($TAILSCALE_EXTRA_ARGS)
    args+=("${extra[@]}")
  fi
  log "running tailscale up (hostname=${TAILSCALE_HOSTNAME:-unchanged}, ssh=${TAILSCALE_ENABLE_SSH})..."
  tailscale "${args[@]}"
  log "tailscale up: $(tailscale ip -4 | tr '\n' ' ')"
else
  warn "tailscale installed but not logged in; run 'tailscale up' or re-run with TAILSCALE_AUTH_KEY"
fi
