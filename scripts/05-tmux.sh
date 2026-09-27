#!/usr/bin/env bash
# 05-tmux: install tmux + managed default config. Idempotent.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/00-common.sh"

require_root

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
# Pi enables truecolor inside tmux only when COLORTERM is truecolor/24bit.
set-environment -g COLORTERM truecolor
set -ga terminal-features ",*:RGB:usstyle:sync:extkeys:focus"
set -ga terminal-overrides ",*:Tc"
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
