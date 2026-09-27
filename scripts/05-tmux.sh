#!/usr/bin/env bash
# 05-tmux: install tmux + managed default config. Idempotent.
#
# Env:
#   TMUX_EXTRA_RGB_TERMS ("") - extra space-separated TERM patterns allowed
#   RGB, e.g. "xterm-256color" for iTerm2/VS Code over direct SSH. Never add
#   terms used over mosh (mosh strips 24-bit color).
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/00-common.sh"

require_root

TMUX_EXTRA_RGB_TERMS="${TMUX_EXTRA_RGB_TERMS:-}"

if pkg_installed tmux; then
  log "tmux already installed: $(dpkg-query -W -f='${Version}' tmux)"
else
  apt_install tmux
fi

dest=/etc/tmux.conf
if [[ -f "$dest" ]] && ! grep -q "managed by vps-setup" "$dest"; then
  warn "$dest exists and is not managed; leaving untouched"
else
  tmp=$(mktemp)
  {
    managed_header "05-tmux"
    cat <<'EOF'
set -g default-terminal "tmux-256color"
# Keep COLORTERM out of panes, including when the server inherited it.
# Use tmux's standard forwarding list without COLORTERM.
set -g update-environment "DISPLAY KRB5CCNAME SSH_ASKPASS SSH_AUTH_SOCK SSH_AGENT_PID SSH_CONNECTION WINDOWID XAUTHORITY"
set-environment -gu COLORTERM
# Clear session values left by earlier configs when clients reconnect.
set-hook -g client-attached 'set-environment -r COLORTERM'
set-hook -g session-created 'set-environment -r COLORTERM'
# Non-RGB features for all clients; RGB only for terminals that really do
# truecolor. Generic xterm* is deliberately excluded: Terminus-over-mosh
# declares xterm, and mosh cannot transport 24-bit color. Direct-SSH users
# with truecolor xterms: set TMUX_EXTRA_RGB_TERMS and re-run (do not
# hand-edit this managed file).
set -ga terminal-features ",*:usstyle:sync:extkeys:focus"
set -ga terminal-features ",xterm-ghostty:RGB"
set -ga terminal-features ",xterm-kitty:RGB"
set -ga terminal-features ",wezterm:RGB"
set -ga terminal-features ",foot:RGB"
EOF
    # Optional extra RGB terms (direct SSH only, never mosh terms). Appended
    # after the built-in allowlist; distinct patterns, same effect.
    if [[ -n "$TMUX_EXTRA_RGB_TERMS" ]]; then
      printf '# Extra RGB terms from TMUX_EXTRA_RGB_TERMS (managed, do not hand-edit)\n'
      # shellcheck disable=SC2086
      for _rgb_term in $TMUX_EXTRA_RGB_TERMS; do
        printf 'set -ga terminal-features ",%s:RGB"\n' "$_rgb_term"
      done
    fi
    cat <<'EOF'
set -s escape-time 0
set -s focus-events on
set -g mouse on
set -g history-limit 50000
set -g base-index 1
setw -g pane-base-index 1
set -g renumber-windows on
# Server option. Pi checks `tmux show -gv extended-keys`. csi-u is tmux 3.5+; -q no-ops on 3.2.
set -s extended-keys on
set -gq extended-keys-format csi-u
set -g mouse on
EOF
  } > "$tmp"
  if [[ -f "$dest" ]] && cmp -s "$tmp" "$dest"; then
    log "tmux config already up to date"
  else
    install -m 644 "$tmp" "$dest"
    log "wrote $dest"
  fi
  rm -f "$tmp"
fi

log "tmux ready: $(tmux -V)"
