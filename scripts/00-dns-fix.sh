#!/usr/bin/env bash
# 00-dns-fix: ensure working DNS before anything needs the network. Idempotent.
# No-op when resolution already works. Otherwise sets fallback DNS servers,
# durably via systemd-resolved when present, else in /etc/resolv.conf.
#
# Env:
#   DNS_SERVERS (1.1.1.1 8.8.8.8) - space-separated
#   DNS_TEST_HOSTS (archive.ubuntu.com github.com) - must all resolve
#   DNS_FORCE (false) - apply fix even if resolution currently works
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/00-common.sh"

DNS_SERVERS="${DNS_SERVERS:-1.1.1.1 8.8.8.8}"
DNS_TEST_HOSTS="${DNS_TEST_HOSTS:-archive.ubuntu.com github.com}"
DNS_FORCE="${DNS_FORCE:-false}"

require_root

dns_works() {
  local h
  # shellcheck disable=SC2086
  for h in $DNS_TEST_HOSTS; do
    if ! getent hosts "$h" >/dev/null 2>&1; then return 1; fi
  done
  return 0
}

if [[ "$DNS_FORCE" != "true" ]] && dns_works; then
  log "DNS already works; nothing to do"
  exit 0
fi
warn "DNS resolution failing; applying fallback DNS ($DNS_SERVERS)"

if systemctl is-active --quiet systemd-resolved 2>/dev/null && [[ -L /etc/resolv.conf ]]; then
  # Durable fix: resolved drop-in (writing the stub file directly would be lost).
  dest=/etc/systemd/resolved.conf.d/00-vps-setup.conf
  tmp=$(mktemp)
  {
    managed_header "00-dns-fix"
    printf '[Resolve]\nDNS=%s\n' "$DNS_SERVERS"
  } > "$tmp"
  if [[ -f "$dest" ]] && cmp -s "$tmp" "$dest"; then
    log "resolved drop-in already up to date"
  else
    mkdir -p "$(dirname "$dest")"
    install -m 644 "$tmp" "$dest"
    systemctl restart systemd-resolved
    log "wrote $dest and restarted systemd-resolved"
  fi
  rm -f "$tmp"
else
  # No systemd-resolved: static /etc/resolv.conf (convert symlink if needed).
  if [[ -L /etc/resolv.conf ]]; then
    rm -f /etc/resolv.conf
    printf '# managed by vps-setup (00-dns-fix)\n' > /etc/resolv.conf
  fi
  if [[ ! -f /etc/resolv.conf.bak.vps-setup ]]; then
    cp -a /etc/resolv.conf /etc/resolv.conf.bak.vps-setup
  fi
  # shellcheck disable=SC2086
  for ns in $DNS_SERVERS; do
    if ! grep -Eq "^nameserver[[:space:]]+$ns([[:space:]]|$)" /etc/resolv.conf; then
      printf 'nameserver %s\n' "$ns" >> /etc/resolv.conf
      log "added nameserver $ns"
    fi
  done
fi

if dns_works; then
  log "DNS fixed"
else
  die "DNS still failing after fix; check connectivity (ip route; ping -c2 8.8.8.8)"
fi
