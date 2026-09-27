#!/usr/bin/env bash
# 16-gh: install GitHub CLI, optional token auth + git credential helper.
# Idempotent: skips install/auth when already done.
#
# Env:
#   GH_USER (NEW_USER)  GH_TOKEN ("") - PAT with repo access
#   GH_FORCE_AUTH (false) - re-login even if already authenticated
#   GH_SETUP_GIT (true) - gh auth setup-git so git uses the gh token
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/00-common.sh"

NEW_USER="${NEW_USER:-$DEFAULT_USER}"
GH_USER="${GH_USER:-$NEW_USER}"
GH_TOKEN="${GH_TOKEN:-}"
GH_FORCE_AUTH="${GH_FORCE_AUTH:-false}"
GH_SETUP_GIT="${GH_SETUP_GIT:-true}"

require_root
id "$GH_USER" >/dev/null 2>&1 || die "user '$GH_USER' missing; run 01-user.sh first"
apt_install curl ca-certificates gnupg

keyring=/usr/share/keyrings/githubcli-archive-keyring.gpg
list_file=/etc/apt/sources.list.d/github-cli.list

repo_changed=false
if [[ -s "$keyring" ]]; then
  log "gh keyring already present"
else
  curl -fsSL --retry 3 https://cli.github.com/packages/githubcli-archive-keyring.gpg -o "$keyring"
  chmod go+r "$keyring"
  repo_changed=true
  log "gh keyring installed"
fi

tmp=$(mktemp)
{
  managed_header "16-gh"
  printf 'deb [arch=%s signed-by=%s] https://cli.github.com/packages stable main\n' \
    "$(dpkg --print-architecture)" "$keyring"
} > "$tmp"
if [[ -f "$list_file" ]] && cmp -s "$tmp" "$list_file"; then
  log "gh apt source already up to date"
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
if pkg_installed gh; then
  log "gh already installed: $(dpkg-query -W -f='${Version}' gh)"
else
  apt_install gh
fi

as_user() { su -s /bin/bash "$GH_USER" -c "$1"; }

authed=false
if as_user 'gh auth status >/dev/null 2>&1'; then authed=true; fi

if [[ "$authed" == "true" && "$GH_FORCE_AUTH" != "true" ]]; then
  log "gh already authenticated for '$GH_USER'"
elif [[ -n "$GH_TOKEN" ]]; then
  log "logging into gh for '$GH_USER' via token..."
  printf '%s' "$GH_TOKEN" | su -s /bin/bash "$GH_USER" -c 'gh auth login --with-token'
  as_user 'gh auth status >/dev/null 2>&1' || die "gh login failed; check GH_TOKEN scopes"
  authed=true
  log "gh authenticated for '$GH_USER'"
else
  warn "gh installed but not logged in; re-run with GH_TOKEN or run 'gh auth login' as $GH_USER"
fi

if [[ "$authed" == "true" && "$GH_SETUP_GIT" == "true" ]]; then
  as_user 'gh auth setup-git'
  log "git configured to use gh credentials for github.com"
fi

log "gh ready: $(gh --version | head -n1)"
