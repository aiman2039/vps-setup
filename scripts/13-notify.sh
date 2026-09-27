#!/usr/bin/env bash
# 13-notify: ntfy "agent waiting for you" phone pings for CLI coding agents.
# Idempotent: re-running converges (managed files overwritten, hooks merged once).
# No-op with a warning unless NTFY_TOPIC is set.
#
# Installs ~/.local/bin/ntfy-wait plus one hook per tool:
#   claude   ~/.claude/settings.json      (Stop, PermissionRequest)
#   codex    ~/.codex/config.toml         (notify array: turn-complete, approval)
#   muse     ~/.muse/hooks.json           (Stop, PermissionRequest)
#   opencode ~/.config/opencode/plugins/ntfy-wait.js (idle, permission, question)
#   grok     ~/.grok/config.toml          ([[ui.notifications.hooks]])
#   pi       ~/.pi/agent/extensions/ntfy-wait.ts (agent_end, approval, prompt)
#   tmux     ~/.tmux.conf                 (alert-bell: names the agent in that window)
# (Terminator is macOS-only and already tracks waiting state in its own UI;
# it needs no hook on the VPS.)
#
# Env:
#   NTFY_TOPIC (required; unset/empty = step is skipped)
#   NTFY_SERVER (https://ntfy.sh)
#   NTFY_TOKEN (optional bearer token) or NTFY_USER + NTFY_PASSWORD
#   MACHINE_NAME ("" = no tag; e.g. vps1) -> "[vps1] codex waiting" titles
#   NTFY_CLICK_URL ("" = no tap action; e.g. ssh://agent@100.x.y.z opens Termius)
#   NOTIFY_USER (NEW_USER)  NOTIFY_TOOLS (all, or csv subset of the list above)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/00-common.sh"

# Load repo .env for direct runs (setup.sh already loads it when run that
# way; sourcing twice is harmless since these are plain assignments).
if [[ -f "$VPS_SETUP_ROOT/.env" ]]; then
  set -a; source "$VPS_SETUP_ROOT/.env"; set +a
fi

NEW_USER="${NEW_USER:-$DEFAULT_USER}"
NOTIFY_USER="${NOTIFY_USER:-$NEW_USER}"
NOTIFY_TOOLS="${NOTIFY_TOOLS:-all}"
NTFY_TOPIC="${NTFY_TOPIC:-}"
NTFY_SERVER="${NTFY_SERVER:-https://ntfy.sh}"
MACHINE_NAME="${MACHINE_NAME:-}"
NTFY_CLICK_URL="${NTFY_CLICK_URL:-}"

if [[ -z "$NTFY_TOPIC" ]]; then
  warn "NTFY_TOPIC not set; skipping (set NTFY_TOPIC in .env next to setup.sh)"
  exit 0
fi

require_root
command -v python3 >/dev/null 2>&1 || die "python3 missing (needed to merge hook configs)"
command -v curl >/dev/null 2>&1 || die "curl missing; run 00-prep.sh first"
id "$NOTIFY_USER" >/dev/null 2>&1 || die "user '$NOTIFY_USER' missing; run 01-user.sh first"

HELPER="$SCRIPT_DIR/notify-hooks.py"
home="$(user_home "$NOTIFY_USER")"
bin="$home/.local/bin/ntfy-wait"

wanted() { # wanted <tool>: true when NOTIFY_TOOLS=all or lists <tool>
  [[ ",$NOTIFY_TOOLS," == *",all,"* || ",$NOTIFY_TOOLS," == *",$1,"* ]]
}

as_user_file() { # chown a helper-created file back to the target user
  chown "$NOTIFY_USER:$NOTIFY_USER" "$1"
}

install_managed() { # install_managed <src> <dest> <mode>: copy only when changed
  local src="$1" dest="$2" mode="$3"
  install -d -o "$NOTIFY_USER" -g "$NOTIFY_USER" "$(dirname "$dest")"
  if [[ -f "$dest" ]] && cmp -s "$src" "$dest"; then
    log "$(basename "$dest") already up to date"
  else
    install -o "$NOTIFY_USER" -g "$NOTIFY_USER" -m "$mode" "$src" "$dest"
    log "wrote $dest"
  fi
}

merge() { # merge <label> <helper args...>: run notify-hooks.py, track failures
  local label="$1"; shift
  local out rc
  set +e
  out="$("$HELPER" "$@" 2>&1)"
  rc=$?
  set -e
  if [[ "$rc" -eq 0 ]]; then
    log "$label: $out"
  else
    warn "$label failed: $out"
    FAILED+=("$label")
  fi
}

FAILED=()

install_managed "$SCRIPT_DIR/ntfy-wait.sh" "$bin" 755

conf="$home/.config/ntfy-wait"
install -d -o "$NOTIFY_USER" -g "$NOTIFY_USER" -m 700 "$conf"
printf '%s' "$NTFY_TOPIC" > "$conf/topic.tmp"
printf '%s' "$NTFY_SERVER" > "$conf/server.tmp"
install -o "$NOTIFY_USER" -g "$NOTIFY_USER" -m 644 "$conf/topic.tmp" "$conf/topic"
install -o "$NOTIFY_USER" -g "$NOTIFY_USER" -m 644 "$conf/server.tmp" "$conf/server"
rm -f "$conf/topic.tmp" "$conf/server.tmp"
if [[ -n "${NTFY_TOKEN:-}" ]]; then
  printf 'Bearer %s' "$NTFY_TOKEN" > "$conf/auth.tmp"
  install -o "$NOTIFY_USER" -g "$NOTIFY_USER" -m 600 "$conf/auth.tmp" "$conf/auth"
  rm -f "$conf/auth.tmp"
elif [[ -n "${NTFY_USER:-}" && -n "${NTFY_PASSWORD:-}" ]]; then
  printf '%s:%s' "$NTFY_USER" "$NTFY_PASSWORD" > "$conf/auth.tmp"
  install -o "$NOTIFY_USER" -g "$NOTIFY_USER" -m 600 "$conf/auth.tmp" "$conf/auth"
  rm -f "$conf/auth.tmp"
elif [[ -f "$conf/auth" ]]; then
  rm -f "$conf/auth" # creds removed from env: converge, don't linger
  log "removed stale $conf/auth"
fi
conf_value() { # conf_value <name> <value>: write file, or remove when unset
  local name="$1" value="$2"
  if [[ -n "$value" ]]; then
    printf '%s' "$value" > "$conf/$name.tmp"
    install -o "$NOTIFY_USER" -g "$NOTIFY_USER" -m 644 "$conf/$name.tmp" "$conf/$name"
    rm -f "$conf/$name.tmp"
  elif [[ -f "$conf/$name" ]]; then
    rm -f "$conf/$name"
    log "removed stale $conf/$name"
  fi
}
conf_value machine "$MACHINE_NAME"
conf_value click "$NTFY_CLICK_URL"
log "ntfy target: $NTFY_SERVER/$NTFY_TOPIC"

if wanted claude; then
  f="$home/.claude/settings.json"
  install -d -o "$NOTIFY_USER" -g "$NOTIFY_USER" "$home/.claude"
  merge "claude hooks" json-hooks "$f" "$bin" Stop PermissionRequest --flavor=Muse
  [[ -f "$f" ]] && as_user_file "$f"
fi

if wanted codex; then
  f="$home/.codex/config.toml"
  install -d -o "$NOTIFY_USER" -g "$NOTIFY_USER" "$home/.codex"
  merge "codex notify" codex-notify "$f" "$bin"
  [[ -f "$f" ]] && as_user_file "$f"
fi

if wanted muse; then
  f="$home/.muse/hooks.json"
  install -d -o "$NOTIFY_USER" -g "$NOTIFY_USER" "$home/.muse"
  merge "muse hooks" json-hooks "$f" "$bin" Stop PermissionRequest
  [[ -f "$f" ]] && as_user_file "$f"
fi

if wanted opencode; then
  install_managed "$SCRIPT_DIR/notify-opencode-plugin.js" \
    "$home/.config/opencode/plugins/ntfy-wait.js" 644
fi

if wanted grok; then
  f="$home/.grok/config.toml"
  install -d -o "$NOTIFY_USER" -g "$NOTIFY_USER" "$home/.grok"
  merge "grok hooks" grok-hooks "$f" "$bin"
  [[ -f "$f" ]] && as_user_file "$f"
fi

if wanted pi; then
  install_managed "$SCRIPT_DIR/notify-pi-extension.ts" \
    "$home/.pi/agent/extensions/ntfy-wait.ts" 644
fi

if wanted tmux; then
  merge "tmux bell hook" tmux-block "$home/.tmux.conf" "$bin"
  [[ -f "$home/.tmux.conf" ]] && as_user_file "$home/.tmux.conf"
  log "tmux: restart the server or run 'tmux source-file ~/.tmux.conf'"
fi

if [[ "${#FAILED[@]}" -gt 0 ]]; then
  die "notification wiring incomplete: ${FAILED[*]}"
fi
log "notify ready: test with: su -s /bin/sh $NOTIFY_USER -c '$bin test \"hello phone\"'"
