#!/usr/bin/env bash
# Top-level VPS setup: runs all component scripts in safe dependency order.
# Idempotent: every step is safe to re-run; re-running converges to same state.
#
# Usage:
#   sudo ./setup.sh [--only a,b] [--skip c] [--dry-run] [--list]
# Step names accept short (user,ssh-only,...) or full (01-user,...) form.
# Env vars can be passed inline or via a .env file next to this script.
set -euo pipefail
cd "$(dirname "$0")"

STEPS=(00-dns-fix 00-prep 01-user 02-ssh-only 04-mosh 05-tmux 06-vnc 07-rust 08-tailscale 09-zsh 10-docker 11-lockdown)

usage() {
  cat <<EOF
Usage: sudo ./setup.sh [--only a,b] [--skip c] [--dry-run] [--list]

Steps (run in this order):
  ${STEPS[*]}

Options:
  --only a,b    run only these steps (short or full names)
  --skip c      skip these steps
  --dry-run     print selected steps without running
  --list        print all steps and exit
  -h, --help    this help

Examples:
  sudo ./setup.sh
  sudo ./setup.sh --only user,tmux
  sudo ./setup.sh --skip vnc,tailscale
  NEW_USER=agent VNC_PASSWORD=secret sudo -E ./setup.sh
EOF
}

short() { # normalize "scripts/01-user.sh" -> "user"
  local s="$1"
  s="${s%.sh}"; s="${s#scripts/}"
  if [[ "$s" =~ ^[0-9][0-9]-(.+)$ ]]; then s="${BASH_REMATCH[1]}"; fi
  printf '%s' "$s"
}

norm_list() { # csv -> " item1 item2 " (normalized, for matching)
  local csv="$1," out=" " item
  while [[ "$csv" == *","* ]]; do
    item="${csv%%,*}"; csv="${csv#*,}"
    if [[ -n "$item" ]]; then out+="$(short "$item") "; fi
  done
  printf '%s' "$out"
}

ONLY_CSV=""; SKIP_CSV=""; DRY_RUN=false; LIST_ONLY=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --only)   ONLY_CSV="${2:?--only needs a comma-separated list}"; shift 2 ;;
    --only=*) ONLY_CSV="${1#--only=}"; shift ;;
    --skip)   SKIP_CSV="${2:?--skip needs a comma-separated list}"; shift 2 ;;
    --skip=*) SKIP_CSV="${1#--skip=}"; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --list) LIST_ONLY=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; usage; exit 1 ;;
  esac
done

source scripts/00-common.sh

if [[ "$LIST_ONLY" == "true" ]]; then
  printf '%s\n' "${STEPS[@]}"
  exit 0
fi

if [[ -f .env ]]; then
  log "loading .env"
  set -a; source .env; set +a
fi

ONLY_NORM="$(norm_list "$ONLY_CSV")"
SKIP_NORM="$(norm_list "$SKIP_CSV")"
selected=()
for s in "${STEPS[@]}"; do
  n="$(short "$s")"
  if [[ -n "$ONLY_CSV" ]] && [[ "$ONLY_NORM" != *" $n "* ]]; then
    log "skip $s (--only)"
    continue
  fi
  if [[ -n "$SKIP_CSV" ]] && [[ "$SKIP_NORM" == *" $n "* ]]; then
    log "skip $s (--skip)"
    continue
  fi
  selected+=("$s")
done

if [[ "$DRY_RUN" == "true" ]]; then
  printf '%s\n' "${selected[@]}"
  exit 0
fi

require_root

log "target user: ${NEW_USER:-$DEFAULT_USER}"
failed=()
for s in "${selected[@]}"; do
  log "=== step $s ==="
  if bash "scripts/${s}.sh"; then
    log "=== $s OK ==="
  else
    warn "=== $s FAILED ==="
    failed+=("$s")
  fi
done

if [[ "${#failed[@]}" -gt 0 ]]; then
  die "failed steps: ${failed[*]}"
fi
log "all steps done: ${selected[*]}"
