#!/usr/bin/env bash
# 07-rust: install Rust via rustup for a user. Idempotent.
#
# Env:
#   RUST_USER (NEW_USER/agent)  RUSTUP_TOOLCHAIN (stable)
#   RUSTUP_PROFILE (default)  RUSTUP_UPDATE_ON_RERUN (false)
#   INSTALL_RUST_FOR_ROOT (false)
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/00-common.sh"

NEW_USER="${NEW_USER:-$DEFAULT_USER}"
RUST_USER="${RUST_USER:-$NEW_USER}"
RUSTUP_TOOLCHAIN="${RUSTUP_TOOLCHAIN:-stable}"
RUSTUP_PROFILE="${RUSTUP_PROFILE:-default}"
RUSTUP_UPDATE_ON_RERUN="${RUSTUP_UPDATE_ON_RERUN:-false}"
INSTALL_RUST_FOR_ROOT="${INSTALL_RUST_FOR_ROOT:-false}"

require_root
id "$RUST_USER" >/dev/null 2>&1 || die "user '$RUST_USER' missing; run 01-user.sh first"
apt_install curl ca-certificates build-essential pkg-config libssl-dev

install_for() {
  local user="$1" home
  home="$(user_home "$user")"
  if [[ -x "$home/.cargo/bin/rustc" ]] \
    && su -s /bin/bash "$user" -c '"$HOME/.cargo/bin/rustc" --version' >/dev/null 2>&1; then
    if [[ "$RUSTUP_UPDATE_ON_RERUN" == "true" ]]; then
      log "rust already installed for '$user'; updating..."
      su -s /bin/bash "$user" -c '"$HOME/.cargo/bin/rustup" update'
    else
      log "rust already installed for '$user': $(su -s /bin/bash "$user" -c '"$HOME/.cargo/bin/rustc" --version')"
    fi
    return 0
  fi
  log "installing rust ($RUSTUP_TOOLCHAIN/$RUSTUP_PROFILE) for '$user'..."
  su -s /bin/bash "$user" -c "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain '$RUSTUP_TOOLCHAIN' --profile '$RUSTUP_PROFILE'"
  su -s /bin/bash "$user" -c '"$HOME/.cargo/bin/rustc" --version && "$HOME/.cargo/bin/cargo" --version'
}

install_for "$RUST_USER"
if [[ "$INSTALL_RUST_FOR_ROOT" == "true" && "$RUST_USER" != "root" ]]; then
  install_for root
fi

# Login-shell PATH fallback (rustup also edits the user's rc files).
tmp=$(mktemp)
{ managed_header "07-rust"; printf 'export PATH="$HOME/.cargo/bin:$PATH"\n'; } > "$tmp"
if [[ -f /etc/profile.d/vps-rust.sh ]] && cmp -s "$tmp" /etc/profile.d/vps-rust.sh; then
  log "/etc/profile.d/vps-rust.sh already up to date"
else
  install -m 644 "$tmp" /etc/profile.d/vps-rust.sh
  log "wrote /etc/profile.d/vps-rust.sh"
fi
rm -f "$tmp"
log "rust setup done"
