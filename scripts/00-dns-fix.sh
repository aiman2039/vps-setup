#!/usr/bin/env bash
# 00-dns-fix: ensure working DNS before anything needs the network. Idempotent.
# Repairs unambiguous stale DHCP interface names before applying DNS fixes.
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
# A DNS override cannot repair an interface renamed during a release upgrade.
# Netplan already depends on Python/PyYAML; never install packages to repair
# connectivity. Only touch a single, simple DHCP configuration.
if command -v netplan >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  if ! python3 - <<'PYNETPLAN'
import glob
import ipaddress
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time


def run(*args):
    return subprocess.check_output(args, text=True, timeout=30)


def default_route():
    return any(run("ip", family, "route", "show", "default").strip()
               for family in ("-4", "-6"))


def repair():
    if default_route():
        return
    try:
        import yaml
    except ImportError:
        print("[vps-setup] Cannot inspect Netplan: Python YAML module unavailable")
        return
    # Avoid guessing on multi-NIC servers, layered configs, bridges or static IPs.
    files = [Path(p) for base in ("/etc/netplan", "/run/netplan", "/lib/netplan")
             for p in glob.glob(base + "/*.yaml")]
    nics = [p.name for p in Path("/sys/class/net").iterdir()
            if (p / "device").exists() and (p / "type").read_text().strip() == "1"]
    if len(files) != 1 or len(nics) != 1:
        print("[vps-setup] Skipping automatic Netplan repair: ambiguous configuration/interfaces")
        return
    path, nic = files[0], nics[0]
    if path.parent != Path("/etc/netplan") or path.is_symlink():
        return
    original = path.read_text()
    data = yaml.safe_load(original)
    if not isinstance(data, dict) or set(data) != {"network"}:
        return
    network = data["network"]
    if not isinstance(network, dict) or set(network) - {"version", "renderer", "ethernets"}:
        return
    if network.get("version") != 2:
        return
    ethernets = network.get("ethernets", {})
    if not isinstance(ethernets, dict) or len(ethernets) != 1:
        return
    old, config = next(iter(ethernets.items()))
    if not isinstance(old, str) or not re.fullmatch(r"[A-Za-z0-9_.-]+", old):
        return
    if (Path("/sys/class/net") / old).exists():
        return
    if not isinstance(config, dict) or config.get("dhcp4") is not True:
        return
    if set(config) - {"dhcp4", "dhcp6", "optional"}:
        return
    addresses = json.loads(run("ip", "-j", "addr", "show", "dev", nic))
    if any(a.get("scope") == "global" and not ipaddress.ip_address(a["local"]).is_link_local
           for entry in addresses for a in entry.get("addr_info", [])):
        return
    # Preserve comments and formatting; refuse unusual YAML rather than rewrite it.
    updated, count = re.subn(r"(?m)^( +)" + re.escape(old) + r":([ \t]*(?:#.*)?)$",
                             lambda m: m[1] + nic + ":" + m[2], original)
    if count != 1:
        return
    expected = {"network": dict(network, ethernets={nic: config})}
    if yaml.safe_load(updated) != expected:
        return
    backup_dir = Path("/var/backups/vps-setup")
    backup_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    backup = Path(tempfile.mkdtemp(prefix="netplan-", dir=backup_dir)) / path.name
    shutil.copy2(path, backup)
    print(f"[vps-setup] Repairing Netplan interface {old} -> {nic}; backup: {backup}", flush=True)
    try:
        path.write_text(updated)
        os.chmod(path, 0o600)
        subprocess.run(["netplan", "generate"], check=True, timeout=30)
        subprocess.run(["netplan", "apply"], check=True, timeout=60)
        for _ in range(30):
            if run("ip", "-4", "route", "show", "default", "dev", nic).strip():
                print(f"[vps-setup] DHCP default route restored on {nic}")
                return
            time.sleep(1)
        raise RuntimeError("DHCP did not restore a default route within 30 seconds")
    except Exception:
        shutil.copy2(backup, path)
        print(f"[vps-setup] Repair failed; restored {path} from {backup}", file=sys.stderr)
        subprocess.run(["netplan", "apply"], check=True, timeout=60)
        raise


try:
    repair()
except Exception as error:
    print(f"[vps-setup] Network repair failed: {error}", file=sys.stderr)
    sys.exit(1)
PYNETPLAN
  then
    die "automatic network repair failed; inspect ip -br addr, ip route, and /etc/netplan/*.yaml"
  fi
fi

if command -v ip >/dev/null 2>&1 \
  && [[ -z "$(ip -4 route show default)" && -z "$(ip -6 route show default)" ]]; then
  die "no default route; cannot fix this with DNS servers. Inspect ip -br addr and /etc/netplan/*.yaml"
fi
if [[ "$DNS_FORCE" != "true" ]] && dns_works; then
  log "Network and DNS restored"
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
