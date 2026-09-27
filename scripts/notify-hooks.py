#!/usr/bin/env python3
"""Idempotent config patching for vps-setup scripts/13-notify.sh.

Subcommands (each prints "changed" or "unchanged"):
  json-hooks <file> <command> <event>... [--flavor claude|plain]
      Merge a hook command into a Claude-style hooks JSON file
      (~/.claude/settings.json, ~/.muse/hooks.json). Creates the file when missing.
  codex-notify <config.toml> <command>
      Ensure <command> is in the top-level `notify = [...]` array.
      Creates the file when missing; never touches [table] sections.
  grok-hooks <config.toml> <command>
      Append a [[ui.notifications.hooks]] ntfy block, and set
      [compat.claude] hooks=false so grok doesn't re-fire claude's
      hooks (which would double-ping). Creates the file when missing.
  tmux-block <tmux.conf> <command>
      Ensure a managed bell-hook block exists (replaced in place on re-run).
      The hook runs `<command> --bell #{pane_pid}` so the ping names the
      agent in the window that rang the bell, not the word "tmux".

Exit 0 on success; exit 2 with a stderr message when the existing file
is unsafe to patch (invalid JSON, unexpected shape). Never deletes user data.
"""

import json
import re
import sys


def toml_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def cmd_json_hooks(path, command, events, flavor):
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except FileNotFoundError:
        data = {}
    except (json.JSONDecodeError, UnicodeDecodeError) as e:
        print("refusing to patch %s: invalid JSON (%s)" % (path, e), file=sys.stderr)
        return 2
    if not isinstance(data, dict):
        print("refusing to patch %s: top level is not an object" % path, file=sys.stderr)
        return 2
    hooks = data.get("hooks", {})
    if not isinstance(hooks, dict):
        print("refusing to patch %s: 'hooks' is not an object" % path, file=sys.stderr)
        return 2
    data["hooks"] = hooks
    changed = False
    for event in events:
        entries = hooks.get(event, [])
        if not isinstance(entries, list):
            print("refusing to patch %s: hooks.%s is not a list" % (path, event), file=sys.stderr)
            return 2
        present = any(
            isinstance(e, dict)
            and any(isinstance(h, dict) and h.get("command") == command for h in e.get("hooks", []))
            for e in entries
        )
        if present:
            continue
        if flavor == "Muse":
            entries.append(
                {
                    "matcher": "",
                    "hooks": [{"async": True, "command": command, "type": "command"}],
                }
            )
        else:
            entries.append({"hooks": [{"type": "command", "command": command, "timeout": 10}]})
        hooks[event] = entries
        changed = True
    if changed:
        with open(path, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2)
            f.write("\n")
    print("changed" if changed else "unchanged")
    return 0


def _strip_toml_strings(text):
    # Replace double/single-quoted spans (with backslash escapes) with a
    # placeholder, so bracket counting and empty-array detection ignore them.
    out = []
    i, quote = 0, None
    while i < len(text):
        ch = text[i]
        if quote is not None:
            if ch == "\\":
                i += 2
                continue
            if ch == quote:
                quote = None
                out.append("\x00")
            i += 1
            continue
        if ch in "\"'":
            quote = ch
            i += 1
            continue
        out.append(ch)
        i += 1
    return "".join(out)


def cmd_codex_notify(path, command):
    try:
        with open(path, encoding="utf-8") as f:
            lines = f.readlines()
    except FileNotFoundError:
        lines = []
    # Locate a top-level `notify = ...` (top-level keys precede the first [header]).
    start = end = None
    array_open = False
    for i, line in enumerate(lines):
        if re.match(r"\s*\[", line):
            break
        if re.match(r"\s*notify\s*=", line):
            start = i
            depth = 0
            for j in range(i, len(lines)):
                if j > i and re.match(r"\s*\[", lines[j]):
                    break  # malformed: header before array closed
                bare = _strip_toml_strings(lines[j])
                depth += bare.count("[") - bare.count("]")
                array_open = array_open or "[" in bare
                end = j
                if array_open and depth <= 0:
                    break
            break
    if start is None:
        lines = ["# added by vps-setup (13-notify)\n", "notify = [%s]\n" % toml_str(command)] + lines
        changed = True
    elif not array_open:
        print("refusing to patch %s: 'notify' value is not an array" % path, file=sys.stderr)
        return 2
    else:
        region = "".join(lines[start : end + 1])
        if toml_str(command) in region or "'%s'" % command in region:
            print("unchanged")
            return 0
        if re.search(r"\[\s*\]", _strip_toml_strings(region)):
            lines[start : end + 1] = ["notify = [%s]\n" % toml_str(command)]
        else:
            close = region.rfind("]")
            sep = "" if region[:close].rstrip().endswith(",") else ", "
            new_region = region[:close] + sep + toml_str(command) + region[close:]
            lines[start : end + 1] = [new_region]
        changed = True
    with open(path, "w", encoding="utf-8") as f:
        f.writelines(lines)
    print("changed" if changed else "unchanged")
    return 0


GROK_MARKER = "# vps-setup 13-notify: grok ntfy hooks"


def cmd_grok_hooks(path, command):
    try:
        with open(path, encoding="utf-8") as f:
            content = f.read()
    except FileNotFoundError:
        content = ""
    if GROK_MARKER in content:
        print("unchanged")
        return 0
    lines = content.splitlines(keepends=True)
    compat_at = next((i for i, l in enumerate(lines) if re.match(r"\s*\[compat\.claude\]\s*$", l)), None)
    if compat_at is None:
        lines.append(
            "\n# vps-setup 13-notify: grok must not re-fire claude's hooks (double ping)\n"
            "[compat.claude]\nhooks = false\n"
        )
    else:
        j = compat_at + 1
        while j < len(lines) and not re.match(r"\s*\[", lines[j]):
            j += 1
        section = "".join(lines[compat_at + 1 : j])
        if re.search(r"(?m)^\s*hooks\s*=", section):
            print(
                "warning: [compat.claude] already sets hooks=; leaving it "
                "(grok may double-ping via claude hooks)",
                file=sys.stderr,
            )
        else:
            lines.insert(
                compat_at + 1,
                "hooks = false  # vps-setup 13-notify: don't re-fire claude hooks (double ping)\n",
            )
    if lines and not lines[-1].endswith("\n"):
        lines[-1] += "\n"
    lines.append(
        "\n%s\n[[ui.notifications.hooks]]\ncommand = %s\nevents = [\"turn_complete\", \"approval_required\"]\nonly_unfocused = false\ntimeout_secs = 10\n"
        % (GROK_MARKER, toml_str(command + " grok"))
    )
    with open(path, "w", encoding="utf-8") as f:
        f.writelines(lines)
    print("changed")
    return 0


TMUX_BEGIN = "# >>> vps-setup 13-notify >>>"
TMUX_END = "# <<< vps-setup 13-notify <<<"


def cmd_tmux_block(path, command):
    try:
        with open(path, encoding="utf-8") as f:
            lines = f.readlines()
    except FileNotFoundError:
        lines = []
    block = [
        TMUX_BEGIN + "\n",
        "set -g monitor-bell on\n",
        "set -g bell-action any\n",
        "set-hook -g alert-bell \"run-shell -b '%s --bell #{pane_pid}'\"\n" % command,
        TMUX_END + "\n",
    ]
    try:
        begin = next(i for i, l in enumerate(lines) if l.rstrip("\n") == TMUX_BEGIN)
        end = next(i for i, l in enumerate(lines) if l.rstrip("\n") == TMUX_END)
    except StopIteration:
        begin = end = None
    if begin is not None and end is not None and end > begin:
        if lines[begin : end + 1] == block:
            print("unchanged")
            return 0
        lines[begin : end + 1] = block
    else:
        if lines and not lines[-1].endswith("\n"):
            lines[-1] += "\n"
        if lines and lines[-1].strip():
            lines.append("\n")
        lines.extend(block)
    with open(path, "w", encoding="utf-8") as f:
        f.writelines(lines)
    print("changed")
    return 0


def main(argv):
    if len(argv) < 2 or argv[1] in ("-h", "--help"):
        print(__doc__.strip())
        return 0 if len(argv) >= 2 else 2
    sub, args = argv[1], argv[2:]
    if sub == "json-hooks":
        flavor = "plain"
        rest = []
        for a in args:
            if a.startswith("--flavor="):
                flavor = a.split("=", 1)[1]
            else:
                rest.append(a)
        if len(rest) < 3 or flavor not in ("Muse", "plain"):
            print("usage: json-hooks <file> <command> <event>... [--flavor=claude|plain]", file=sys.stderr)
            return 2
        return cmd_json_hooks(rest[0], rest[1], rest[2:], flavor)
    if sub == "codex-notify" and len(args) == 2:
        return cmd_codex_notify(*args)
    if sub == "grok-hooks" and len(args) == 2:
        return cmd_grok_hooks(*args)
    if sub == "tmux-block" and len(args) == 2:
        return cmd_tmux_block(*args)
    print("unknown subcommand: %s" % sub, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
