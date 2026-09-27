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
expected="00-dns-fix 00-prep 01-user 02-ssh-only 04-mosh 05-tmux 06-vnc 07-rust 08-tailscale 09-zsh 10-docker 11-lockdown 12-nvm 13-notify 14-opencode 15-pi 16-gh"
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

# 5. [root] 00-dns-fix no-op path (only when DNS already works)
if [[ "${EUID:-$(id -u)}" -eq 0 ]] && command -v useradd >/dev/null 2>&1 \
  && getent hosts github.com >/dev/null 2>&1; then
  if bash scripts/00-dns-fix.sh >/dev/null 2>&1; then
    ok "00-dns-fix no-op when DNS works"
  else
    no "00-dns-fix no-op when DNS works"
  fi
else
  sk "00-dns-fix no-op (needs root on Linux with working DNS)"
fi

# 6. default target user follows the sudo-invoking user
if [[ "$(SUDO_USER=bob bash -c 'source scripts/00-common.sh; printf %s "$DEFAULT_USER"')" == "bob" ]] \
  && [[ "$(env -u SUDO_USER bash -c 'source scripts/00-common.sh; printf %s "$DEFAULT_USER"')" == "agent" ]] \
  && [[ "$(SUDO_USER=root bash -c 'source scripts/00-common.sh; printf %s "$DEFAULT_USER"')" == "agent" ]]; then
  ok "DEFAULT_USER from SUDO_USER"
else
  no "DEFAULT_USER from SUDO_USER"
fi

# 7. lockdown is a no-op unless enabled (portable: exits before require_root)
if env -u LOCKDOWN_ENABLE bash scripts/11-lockdown.sh >/dev/null 2>&1; then
  ok "11-lockdown disabled by default"
else
  no "11-lockdown disabled by default"
fi

# 8. 13-notify is a no-op without a topic (portable: exits before require_root)
if env -u NTFY_TOPIC bash scripts/13-notify.sh >/dev/null 2>&1; then
  ok "13-notify skipped without NTFY_TOPIC"
else
  no "13-notify skipped without NTFY_TOPIC"
fi

# 9. notify-hooks.py merges are correct and idempotent (portable: needs python3)
if command -v python3 >/dev/null 2>&1; then
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  hy="$tmp/hooks.json"
  # json-hooks: creates, merges two events, preserves other keys, stable on re-run
  printf '{"other": 1, "hooks": {"Stop": []}}' > "$hy"
  out1="$(python3 scripts/notify-hooks.py json-hooks "$hy" /bin/ntfy-wait Stop PermissionRequest)"
  out2="$(python3 scripts/notify-hooks.py json-hooks "$hy" /bin/ntfy-wait Stop PermissionRequest)"
  if [[ "$out1" == "changed" && "$out2" == "unchanged" ]] \
    && [[ "$(python3 -c "import json;print(json.load(open('$hy'))['other'])")" == "1" ]] \
    && [[ "$(grep -c /bin/ntfy-wait "$hy")" -eq 2 ]]; then
    ok "json-hooks merge idempotent"
  else
    no "json-hooks merge idempotent"
  fi
  # json-hooks: refuses invalid JSON without destroying it
  printf '{oops' > "$hy.bad"
  if ! python3 scripts/notify-hooks.py json-hooks "$hy.bad" /bin/ntfy-wait Stop >/dev/null 2>&1 \
    && [[ "$(cat "$hy.bad")" == "{oops" ]]; then
    ok "json-hooks refuses invalid JSON"
  else
    no "json-hooks refuses invalid JSON"
  fi
  # codex-notify: appends to existing array, keeps tables, stable on re-run
  cx="$tmp/config.toml"
  printf 'model = "x"\nnotify = ["/old.sh"]\n\n[tui]\nnotifications = ["a"]\n' > "$cx"
  out1="$(python3 scripts/notify-hooks.py codex-notify "$cx" /bin/ntfy-wait)"
  out2="$(python3 scripts/notify-hooks.py codex-notify "$cx" /bin/ntfy-wait)"
  if [[ "$out1" == "changed" && "$out2" == "unchanged" ]] \
    && grep -q 'notify = \["/old.sh", "/bin/ntfy-wait"\]' "$cx" \
    && grep -q '^\[tui\]' "$cx"; then
    ok "codex-notify append idempotent"
  else
    no "codex-notify append idempotent"
  fi
  # codex-notify: creates a valid file when missing
  rm -f "$tmp/fresh.toml"
  if python3 scripts/notify-hooks.py codex-notify "$tmp/fresh.toml" /bin/ntfy-wait | grep -q changed \
    && grep -q '^notify = \["/bin/ntfy-wait"\]' "$tmp/fresh.toml"; then
    ok "codex-notify creates file"
  else
    no "codex-notify creates file"
  fi
  # grok-hooks: appends block + compat guard, stable on re-run
  gx="$tmp/grok.toml"
  printf '[ui]\nyolo = false\n' > "$gx"
  out1="$(python3 scripts/notify-hooks.py grok-hooks "$gx" /bin/ntfy-wait)"
  out2="$(python3 scripts/notify-hooks.py grok-hooks "$gx" /bin/ntfy-wait)"
  if [[ "$out1" == "changed" && "$out2" == "unchanged" ]] \
    && [[ "$(grep -c "ui.notifications.hooks" "$gx")" -eq 1 ]] \
    && grep -q 'yolo = false' "$gx" && grep -q 'command = "/bin/ntfy-wait grok"' "$gx"; then
    ok "grok-hooks append idempotent"
  else
    no "grok-hooks append idempotent"
  fi
  # grok-hooks: inserts hooks=false under an existing compat table (no duplicate)
  gx2="$tmp/grok2.toml"
  printf '[compat.%s]\nskills = true\n' "claude" > "$gx2"
  out1="$(python3 scripts/notify-hooks.py grok-hooks "$gx2" /bin/ntfy-wait)"
  out2="$(python3 scripts/notify-hooks.py grok-hooks "$gx2" /bin/ntfy-wait)"
  if [[ "$out1" == "changed" && "$out2" == "unchanged" ]] \
    && [[ "$(grep -c '^\[compat' "$gx2")" -eq 1 ]] \
    && grep -q '^hooks = false' "$gx2"; then
    ok "grok-hooks reuses compat table"
  else
    no "grok-hooks reuses compat table"
  fi
  # codex-notify: multi-line array with trailing comma stays valid
  ml="$tmp/ml.toml"
  printf 'notify = [\n  "/a.sh",\n  "/b.sh",\n]\n' > "$ml"
  out1="$(python3 scripts/notify-hooks.py codex-notify "$ml" /bin/ntfy-wait)"
  out2="$(python3 scripts/notify-hooks.py codex-notify "$ml" /bin/ntfy-wait)"
  if [[ "$out1" == "changed" && "$out2" == "unchanged" ]] \
    && grep -q '"/b.sh"' "$ml" && grep -q '"/bin/ntfy-wait"' "$ml" \
    && ! grep -q '^[[:space:]]*,' "$ml"; then
    ok "codex-notify multi-line append"
  else
    no "codex-notify multi-line append"
  fi
  # merged TOML must actually parse (needs python3.11+ tomllib)
  if python3 -c "import tomllib" >/dev/null 2>&1; then
    if python3 -c "import tomllib,sys; sys.exit(0 if tomllib.load(open('$ml','rb'))['notify'] == ['/a.sh','/b.sh','/bin/ntfy-wait'] else 1)" \
      && python3 -c "import tomllib,sys; d=tomllib.load(open('$gx2','rb')); sys.exit(0 if d['compat']['claude']['hooks'] is False else 1)"; then
      ok "merged TOML parses"
    else
      no "merged TOML parses"
    fi
  else
    sk "merged TOML parses (needs python3.11+)"
  fi
  # tmux-block: appends once, converges on re-run, keeps user lines
  tx="$tmp/tmux.conf"
  printf 'set -g mouse on\n' > "$tx"
  out1="$(python3 scripts/notify-hooks.py tmux-block "$tx" /bin/ntfy-wait)"
  out2="$(python3 scripts/notify-hooks.py tmux-block "$tx" /bin/ntfy-wait)"
  if [[ "$out1" == "changed" && "$out2" == "unchanged" ]] \
    && grep -q 'set -g mouse on' "$tx" \
    && [[ "$(grep -c "alert-bell" "$tx")" -eq 1 ]]; then
    ok "tmux-block append idempotent"
  else
    no "tmux-block append idempotent"
  fi
  rm -rf "$tmp"
  trap - EXIT
else
  sk "notify-hooks.py merges (needs python3)"
fi

# 10. ntfy-wait stays silent without a topic; posts topic+message otherwise
ntmp="$(mktemp -d)"
if HOME="$ntmp" bash scripts/ntfy-wait.sh agent hello >/dev/null 2>&1; then
  ok "ntfy-wait silent without topic"
else
  no "ntfy-wait silent without topic"
fi
if command -v python3 >/dev/null 2>&1 && command -v curl >/dev/null 2>&1; then
  cat > "$ntmp/stub.py" <<'EOF'
import http.server, json, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        with open(sys.argv[2], "w") as f:
            json.dump({"path": self.path, "title": self.headers.get("Title"),
                       "click": self.headers.get("Click"),
                       "body": self.rfile.read(n).decode()}, f)
        self.send_response(200)
        self.end_headers()
    def log_message(self, *a):
        pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
EOF
  port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])' 2>/dev/null)" || port=""
  if [[ -z "$port" ]]; then
    sk "ntfy-wait posts to topic (loopback bind unavailable)"
    sk "ntfy-wait machine tag + click (loopback bind unavailable)"
  else
    python3 "$ntmp/stub.py" "$port" "$ntmp/got.json" & srv=$!
    sleep 1
    HOME="$ntmp" NTFY_SERVER="http://127.0.0.1:$port" NTFY_TOPIC="t-Stub9" \
      bash scripts/ntfy-wait.sh codex "build done" >/dev/null 2>&1
    if [[ -f "$ntmp/got.json" ]] \
      && [[ "$(python3 -c "import json;print(json.load(open('$ntmp/got.json'))['path'])")" == "/t-Stub9" ]] \
      && [[ "$(python3 -c "import json;print(json.load(open('$ntmp/got.json'))['body'])")" == "build done" ]] \
      && [[ "$(python3 -c "import json;print(json.load(open('$ntmp/got.json'))['title'])")" == "codex waiting" ]] \
      && [[ "$(python3 -c "import json;print(json.load(open('$ntmp/got.json'))['click'])")" == "None" ]]; then
      ok "ntfy-wait posts to topic"
    else
      no "ntfy-wait posts to topic"
    fi
    rm -f "$ntmp/got.json"
    HOME="$ntmp" NTFY_SERVER="http://127.0.0.1:$port" NTFY_TOPIC="t-Stub9" \
      MACHINE_NAME="testbox" NTFY_CLICK_URL="ssh://agent@10.0.0.9" \
      bash scripts/ntfy-wait.sh codex "build done" >/dev/null 2>&1
    kill "$srv" 2>/dev/null || true
    wait "$srv" 2>/dev/null || true
    if [[ -f "$ntmp/got.json" ]] \
      && [[ "$(python3 -c "import json;print(json.load(open('$ntmp/got.json'))['title'])")" == "[testbox] codex waiting" ]] \
      && [[ "$(python3 -c "import json;print(json.load(open('$ntmp/got.json'))['click'])")" == "ssh://agent@10.0.0.9" ]]; then
      ok "ntfy-wait machine tag + click"
    else
      no "ntfy-wait machine tag + click"
    fi
  fi
else
  sk "ntfy-wait posts to topic (needs python3 + curl)"
  sk "ntfy-wait machine tag + click (needs python3 + curl)"
fi
rm -rf "$ntmp"

printf 'done: %d pass, %d fail, %d skip\n' "$pass" "$fail" "$skip"
[[ "$fail" -eq 0 ]]
