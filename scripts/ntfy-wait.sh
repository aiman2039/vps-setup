#!/usr/bin/env bash
# ntfy-wait: one-line phone ping for CLI coding agents ("waiting for you").
# Installed by vps-setup scripts/13-notify.sh to ~/.local/bin/ntfy-wait.
#
# Usage: ntfy-wait <agent> [message]
#   agent    short name shown in the notification title (claude, codex, ...)
#   message  body; defaults to $GROK_MESSAGE when set (grok hooks), else "needs your attention".
#
# Config resolution (env wins, then files written by 13-notify.sh):
#   topic   $NTFY_TOPIC, else ~/.config/ntfy-wait/topic   (empty = silently do nothing)
#   server  $NTFY_SERVER, else ~/.config/ntfy-wait/server (default https://ntfy.sh)
#   auth    $NTFY_TOKEN (bearer), else $NTFY_USER/$NTFY_PASSWORD,
#           else ~/.config/ntfy-wait/auth ("Bearer <token>" or "user:pass")
#   machine $MACHINE_NAME, else ~/.config/ntfy-wait/machine (empty = no tag)
#   click   $NTFY_CLICK_URL, else ~/.config/ntfy-wait/click (empty = no tap action)
set -euo pipefail

agent="${1:-agent}"
msg="${2:-${GROK_MESSAGE:-needs your attention}}"
msg="${msg:0:200}" # push-sized; grok messages can be long

conf="${XDG_CONFIG_HOME:-$HOME/.config}/ntfy-wait"
topic="${NTFY_TOPIC:-$(cat "$conf/topic" 2>/dev/null || true)}"
server="${NTFY_SERVER:-$(cat "$conf/server" 2>/dev/null || true)}"
server="${server:-https://ntfy.sh}"

[[ -z "$topic" ]] && exit 0 # not configured; stay silent so hooks never fail

machine="${MACHINE_NAME:-$(cat "$conf/machine" 2>/dev/null || true)}"
title="$agent waiting"
[[ -n "$machine" ]] && title="[$machine] $agent waiting"

args=(-s -o /dev/null --max-time 8
  -H "Title: $title" -H "Tags: robot")
click="${NTFY_CLICK_URL:-$(cat "$conf/click" 2>/dev/null || true)}"
click="${click//$'\r'/}"
click="${click//$'\n'/}" # header-safe: strip CR/LF
if [[ -z "$click" ]]; then
  :
elif [[ "$click" == *"://"* ]]; then
  args+=(-H "Click: $click")
else
  printf 'ntfy-wait: ignoring malformed NTFY_CLICK_URL (want scheme://...)\n' >&2
fi
if [[ -n "${NTFY_TOKEN:-}" ]]; then
  args+=(-H "Authorization: Bearer $NTFY_TOKEN")
elif [[ -n "${NTFY_USER:-}" && -n "${NTFY_PASSWORD:-}" ]]; then
  args+=(-u "$NTFY_USER:$NTFY_PASSWORD")
elif [[ -f "$conf/auth" ]]; then
  auth="$(cat "$conf/auth")"
  if [[ "$auth" == Bearer\ * ]]; then
    args+=(-H "Authorization: $auth")
  elif [[ -n "$auth" ]]; then
    args+=(-u "$auth")
  fi
fi

curl "${args[@]}" -d "$msg" "$server/$topic" || true
exit 0
