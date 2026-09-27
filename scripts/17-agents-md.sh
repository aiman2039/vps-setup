#!/usr/bin/env bash
# 17-agents-md: link one shared AGENTS.md into every coding agent's home dir.
# Idempotent. Installs the repo AGENTS.md as ~/.AGENTS.md (canonical copy,
# refreshed on re-run), then symlinks each tool's global instructions path
# to it so codex/grok/muse/pi/opencode/claude all read the same file.
#
# Env:
#   AGENTS_USER (NEW_USER)  AGENTS_SOURCE (repo AGENTS.md)
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/00-common.sh"

NEW_USER="${NEW_USER:-$DEFAULT_USER}"
AGENTS_USER="${AGENTS_USER:-$NEW_USER}"
AGENTS_SOURCE="${AGENTS_SOURCE:-$VPS_SETUP_ROOT/AGENTS.md}"

[[ -f "$AGENTS_SOURCE" ]] || die "AGENTS.md source not found: $AGENTS_SOURCE"

require_root
id "$AGENTS_USER" >/dev/null 2>&1 || die "user '$AGENTS_USER' missing; run 01-user.sh first"

home="$(user_home "$AGENTS_USER")"
[[ -n "$home" && -d "$home" ]] || die "home dir missing for '$AGENTS_USER'"

canonical="$home/.AGENTS.md"
if [[ ! -f "$canonical" ]] || ! cmp -s "$AGENTS_SOURCE" "$canonical"; then
  install -o "$AGENTS_USER" -g "$AGENTS_USER" -m 0644 "$AGENTS_SOURCE" "$canonical"
  log "installed canonical $canonical"
fi

# Global instruction paths, relative to $home. .claude/CLAUDE.md and
# .config/opencode/AGENTS.md are the native filenames those tools read;
# everything links to the one canonical file.
targets=(
  .codex/AGENTS.md
  .grok/AGENTS.md
  .muse/AGENTS.md
  .pi/AGENTS.md
  .opencode/AGENTS.md
  .claude/AGENTS.md
  .claude/CLAUDE.md
  .config/opencode/AGENTS.md
)

for rel in "${targets[@]}"; do
  dest="$home/$rel"
  if [[ -L "$dest" && "$(readlink "$dest")" == "$canonical" ]]; then
    continue
  fi
  if [[ -e "$dest" && ! -L "$dest" ]]; then
    if [[ -e "$dest.bak" ]]; then
      rm -rf "$dest"
      warn "replaced $dest (backup already at $dest.bak)"
    else
      mv "$dest" "$dest.bak"
      warn "backed up existing $dest to $dest.bak"
    fi
  fi
  install -o "$AGENTS_USER" -g "$AGENTS_USER" -d "$(dirname "$dest")"
  ln -sfn "$canonical" "$dest"
  chown -h "$AGENTS_USER:$AGENTS_USER" "$dest"
  log "linked $dest -> $canonical"
done
log "agents-md setup done for '$AGENTS_USER' (${#targets[@]} links)"
