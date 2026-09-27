#!/usr/bin/env bash
# Focused tests for vps-setup. Portable checks always run;
# [root] checks run only as root on Linux, else skipped.
set -euo pipefail
cd "$(dirname "$0")/.."

pass=0; fail=0; skip=0
ok() { pass=$((pass + 1)); printf 'PASS %s\n' "$1"; }
no() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }
sk() { skip=$((skip + 1)); printf 'SKIP %s\n' "$1"; }

# 1. syntax
syntax_ok=true
for f in setup.sh scripts/*.sh tests/run.sh; do
  if ! bash -n "$f"; then syntax_ok=false; no "bash -n $f"; fi
done
if [[ "$syntax_ok" == "true" ]]; then ok "bash -n all scripts"; fi

# 2. shellcheck (when available)
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck -S warning setup.sh scripts/*.sh tests/run.sh; then
    ok "shellcheck"
  else
    no "shellcheck"
  fi
else
  sk "shellcheck (not installed)"
fi

# 3. step selection wiring
expected="00-prep 01-user 02-ssh-only 03-termius 04-mosh 05-tmux 06-vnc 07-rust 08-tailscale 09-zsh 10-docker"
if [[ "$(./setup.sh --list | tr '\n' ' ' | sed 's/ $//')" == "$expected" ]]; then
  ok "--list order"
else
  no "--list order"
fi
got="$(./setup.sh --dry-run --only zsh,docker 2>/dev/null | grep -E '^[0-9]{2}-[a-z-]+$' | tr '\n' ' ')"
if [[ "$got" == "09-zsh 10-docker " ]]; then
  ok "--only short names"
else
  no "--only short names"
fi

# 4. [root] 01-user ssh-key step
if [[ "${EUID:-$(id -u)}" -ne 0 ]] || ! command -v useradd >/dev/null 2>&1; then
  sk "01-user key step (needs root on Linux)"
else
  tuser="vpstest$$"
  tkey="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKeyForVpsSetup test@local"
  cleanup() { userdel -r "$tuser" 2>/dev/null || true; }
  trap cleanup EXIT
  # empty-key path: warns, exits 0, paste prompt skipped (stdin not a tty)
  set +e
  out="$(NEW_USER="$tuser" COPY_ROOT_KEYS=false bash scripts/01-user.sh </dev/null 2>&1)"
  rc=$?
  set -e
  if [[ "$rc" -eq 0 ]]; then ok "01-user exits 0 without keys"; else no "01-user exits 0 without keys"; fi
  if [[ "$out" == *"no SSH keys installed"* ]]; then ok "01-user warns without keys"; else no "01-user warns without keys"; fi
  # install path: key present after run
  NEW_USER="$tuser" COPY_ROOT_KEYS=false AUTHORIZED_KEY="$tkey" bash scripts/01-user.sh </dev/null >/dev/null 2>&1
  home="$(getent passwd "$tuser" | cut -d: -f6)"
  if grep -qxF "$tkey" "$home/.ssh/authorized_keys"; then ok "01-user installs AUTHORIZED_KEY"; else no "01-user installs AUTHORIZED_KEY"; fi
  # idempotency: re-run keeps exactly one copy
  NEW_USER="$tuser" COPY_ROOT_KEYS=false AUTHORIZED_KEY="$tkey" bash scripts/01-user.sh </dev/null >/dev/null 2>&1
  if [[ "$(grep -c . "$home/.ssh/authorized_keys")" -eq 1 ]]; then ok "01-user key install idempotent"; else no "01-user key install idempotent"; fi
  cleanup
  trap - EXIT
fi

printf 'done: %d pass, %d fail, %d skip\n' "$pass" "$fail" "$skip"
[[ "$fail" -eq 0 ]]
