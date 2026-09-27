#!/usr/bin/env bash
# ntfy-wait: one-line phone ping for CLI coding agents ("waiting for you").
# Installed by vps-setup scripts/13-notify.sh to ~/.local/bin/ntfy-wait.
#
# Usage:
#   ntfy-wait <agent> [message]
#   ntfy-wait --bell <pane_pid>     # tmux alert-bell: name the agent in that window
#   agent    short name shown in the notification title (claude, codex, ...)
#   message  body; defaults to $GROK_MESSAGE when set (grok hooks), else "needs your attention".
#   --bell   tmux passes the active pane pid. The title becomes the agent running
#            in that window (claude, codex, muse, opencode, grok, pi); the body
#            is the session, window, and directory. Unknown agents fall back to
#            the tmux window name.
#
# Config resolution (env wins, then files written by 13-notify.sh):
#   topic   $NTFY_TOPIC, else ~/.config/ntfy-wait/topic   (empty = silently do nothing)
#   server  $NTFY_SERVER, else ~/.config/ntfy-wait/server (default https://ntfy.sh)
#   auth    $NTFY_TOKEN (bearer), else $NTFY_USER/$NTFY_PASSWORD,
#           else ~/.config/ntfy-wait/auth ("Bearer <token>" or "user:pass")
#   machine $MACHINE_NAME, else ~/.config/ntfy-wait/machine (empty = no tag)
#   click   $NTFY_CLICK_URL, else ~/.config/ntfy-wait/click (empty = no tap action)
#
# Tests inject NTFY_BELL_PANES (list-panes -F records) and NTFY_BELL_PROCS
# (pid, ppid, cmdline rows) so --bell can be checked without tmux or /proc.
set -euo pipefail

SEP=$'\037'

send() {
  local agent="$1" msg="$2"
  local conf topic server machine title click auth
  local -a args

  agent="${agent//$'\r'/}"
  agent="${agent//$'\n'/}"
  [[ -z "$agent" ]] && agent="agent"
  agent="${agent:0:80}"
  msg="${msg:0:200}"

  conf="${XDG_CONFIG_HOME:-$HOME/.config}/ntfy-wait"
  topic="${NTFY_TOPIC:-$(cat "$conf/topic" 2>/dev/null || true)}"
  server="${NTFY_SERVER:-$(cat "$conf/server" 2>/dev/null || true)}"
  server="${server:-https://ntfy.sh}"

  [[ -z "$topic" ]] && return 0

  machine="${MACHINE_NAME:-$(cat "$conf/machine" 2>/dev/null || true)}"
  title="$agent waiting"
  [[ -n "$machine" ]] && title="[$machine] $title"

  args=(-s -o /dev/null --max-time 8
    -H "Title: $title" -H "Tags: robot")
  click="${NTFY_CLICK_URL:-$(cat "$conf/click" 2>/dev/null || true)}"
  click="${click//$'\r'/}"
  click="${click//$'\n'/}"
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
}

# argv0 basename, else a path marker for agents whose process name is node.
match_cmdline() {
  local line="$1" token base
  line="${line#"${line%%[![:space:]]*}"}"
  [[ -z "$line" ]] && return 1
  token="${line%%[[:space:]]*}"
  base="${token##*/}"
  case "$base" in
    claude|claude-code) printf '%s' claude; return 0 ;;
    codex) printf '%s' codex; return 0 ;;
    muse) printf '%s' muse; return 0 ;;
    opencode) printf '%s' opencode; return 0 ;;
    grok) printf '%s' grok; return 0 ;;
    pi) printf '%s' pi; return 0 ;;
  esac
  case "$line" in
    *pi-coding-agent*) printf '%s' pi; return 0 ;;
    *claude-code*) printf '%s' claude; return 0 ;;
    */.opencode/*) printf '%s' opencode; return 0 ;;
  esac
  return 1
}

is_generic() {
  case "$1" in
    bash|zsh|sh|fish|dash|ash|login|tmux|sudo|su|env|node|nodejs|python|python3|ruby|perl|pip|npm|pnpm|yarn)
      return 0 ;;
  esac
  return 1
}

_table_cmdline() {
  local pid="$1" line p rest
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    p="${line%%$'\t'*}"
    [[ "$p" == "$pid" ]] || continue
    rest="${line#*$'\t'}"
    printf '%s\n' "${rest#*$'\t'}"
    return 0
  done <<< "${NTFY_BELL_PROCS:-}"
}

_table_children() {
  local parent="$1" line p rest pp
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    p="${line%%$'\t'*}"
    rest="${line#*$'\t'}"
    pp="${rest%%$'\t'*}"
    [[ "$pp" == "$parent" ]] && printf '%s\n' "$p"
  done <<< "${NTFY_BELL_PROCS:-}"
}

_table_walk() {
  local pid="$1" depth="$2" line c
  [[ "$depth" -gt 6 ]] && return 0
  line="$(_table_cmdline "$pid" || true)"
  [[ -n "$line" ]] && printf '%s\n' "$line"
  while IFS= read -r c; do
    [[ -n "$c" ]] && _table_walk "$c" $((depth + 1))
  done < <(_table_children "$pid")
}

_cmdline_of_proc() {
  local pid="$1" comm="" cmd=""
  if [[ -r "/proc/$pid/status" ]]; then
    comm="$(awk '/^Name:/ {print $2; exit}' "/proc/$pid/status" 2>/dev/null || true)"
  fi
  if [[ -r "/proc/$pid/cmdline" ]]; then
    cmd="$(tr '\0' ' ' < "/proc/$pid/cmdline" || true)"
  fi
  if [[ -n "${cmd// /}" ]]; then
    printf '%s\n' "$cmd"
  elif [[ -n "$comm" ]]; then
    printf '%s\n' "$comm"
  fi
}

_children_proc() {
  local parent="$1" d pid pp
  shopt -s nullglob
  for d in /proc/[0-9]*; do
    pid="${d##*/}"
    [[ -r "$d/status" ]] || continue
    pp="$(awk '/^PPid:/ {print $2; exit}' "$d/status" 2>/dev/null || true)"
    [[ "$pp" == "$parent" ]] && printf '%s\n' "$pid"
  done
  shopt -u nullglob
}

_proc_walk() {
  local pid="$1" depth="$2" line c
  [[ "$depth" -gt 6 ]] && return 0
  line="$(_cmdline_of_proc "$pid" || true)"
  [[ -n "$line" ]] && printf '%s\n' "$line"
  while IFS= read -r c; do
    [[ -n "$c" ]] && _proc_walk "$c" $((depth + 1))
  done < <(_children_proc "$pid")
}

# Parent first, so the agent wins over a tool it spawned.
cmdlines_under() {
  local pid="$1"
  if [[ -n "${NTFY_BELL_PROCS:-}" ]]; then
    _table_walk "$pid" 0
    return 0
  fi
  [[ -d "/proc/$pid" ]] || return 0
  _proc_walk "$pid" 0
}

detect_agent() {
  local pid="$1" line hit
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if hit="$(match_cmdline "$line")"; then
      printf '%s' "$hit"
      return 0
    fi
  done < <(cmdlines_under "$pid" || true)
  return 1
}

pane_lines() {
  local fmt
  if [[ -n "${NTFY_BELL_PANES:-}" ]]; then
    printf '%s\n' "$NTFY_BELL_PANES"
    return 0
  fi
  command -v tmux >/dev/null 2>&1 || return 1
  fmt="#{pane_pid}${SEP}#{session_name}${SEP}#{window_index}${SEP}#{window_name}${SEP}#{pane_index}${SEP}#{pane_current_command}${SEP}#{pane_current_path}${SEP}#{window_id}"
  tmux list-panes -a -F "$fmt" 2>/dev/null || return 1
}

parse_pane() {
  local line="$1"
  local IFS="$SEP"
  p_pid="" p_session="" p_widx="" p_wname="" p_pidx="" p_cmd="" p_path="" p_wid=""
  read -r p_pid p_session p_widx p_wname p_pidx p_cmd p_path p_wid <<< "$line" || true
}

one_line() {
  local s="$1"
  s="${s//$'\r'/}"
  s="${s//$'\n'/}"
  printf '%s' "$s"
}

pane_where() {
  local where base
  where="${p_session}:${p_widx}.${p_pidx}"
  [[ -n "$p_wname" ]] && where="$where $p_wname"
  base="${p_path##*/}"
  if [[ -n "$base" && "$base" != "$p_wname" ]]; then
    where="$where ($base)"
  fi
  one_line "$where"
}

fallback_name() {
  if [[ -n "$p_cmd" ]] && ! is_generic "$p_cmd"; then
    one_line "$p_cmd"
    return 0
  fi
  if [[ -n "$p_wname" ]] && ! is_generic "$p_wname"; then
    one_line "$p_wname"
    return 0
  fi
  printf '%s' tmux
}

bell_send() {
  local pid="$1"
  local panes="" line hook="" wid="" session=""
  local records="" agent="" where="" names="" body="" nrec=0 rec name labeled labeled_first=""

  if [[ ! "$pid" =~ ^[0-9]+$ ]]; then
    send tmux "bell"
    return 0
  fi

  panes="$(pane_lines || true)"
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    parse_pane "$line"
    if [[ "$p_pid" == "$pid" && -z "$hook" ]]; then
      hook="$line"
      wid="$p_wid"
      session="$p_session"
    fi
  done <<< "$panes"

  if [[ -z "$hook" ]]; then
    agent="$(detect_agent "$pid" || true)"
    [[ -z "$agent" ]] && agent="tmux"
    send "$agent" "bell"
    return 0
  fi

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    parse_pane "$line"
    [[ "$p_wid" == "$wid" && "$p_session" == "$session" ]] || continue
    agent="$(detect_agent "$p_pid" || true)"
    [[ -z "$agent" ]] && continue
    where="$(pane_where)"
    records="${records}${agent}"$'\t'"${where}"$'\n'
  done <<< "$panes"

  if [[ -z "$records" ]]; then
    parse_pane "$hook"
    send "$(fallback_name)" "$(pane_where)"
    return 0
  fi

  while IFS= read -r rec; do
    [[ -z "$rec" ]] && continue
    name="${rec%%$'\t'*}"
    where="${rec#*$'\t'}"
    nrec=$((nrec + 1))
    case " $names " in
      *" $name "*) ;;
      *) names="${names:+$names }$name" ;;
    esac
    labeled="$name $where"
    if [[ "$nrec" -eq 1 ]]; then
      body="$where"
    elif [[ "$nrec" -eq 2 ]]; then
      body="$labeled_first; $labeled"
    else
      body="$body; $labeled"
    fi
    labeled_first="$labeled"
  done <<< "$records"

  send "${names// /, }" "$body"
}

if [[ "${1:-}" == "--bell" ]]; then
  bell_send "${2:-}"
  exit 0
fi

send "${1:-agent}" "${2:-${GROK_MESSAGE:-needs your attention}}"
exit 0
