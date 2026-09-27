# vps-setup

Idempotent setup scripts for an Ubuntu 22.04 VPS (AI agent box with desktop).
Each script is safe to re-run; re-running converges to the same state.

## Quickstart

```sh
scp -r . root@YOUR_VPS:/root/vps-setup
ssh root@YOUR_VPS
cd /root/vps-setup
cp .env.example .env   # set VNC_PASSWORD, TAILSCALE_AUTH_KEY, ...
sudo ./setup.sh
```

Run one step: `sudo ./scripts/01-user.sh`.
Partial runs: `sudo ./setup.sh --only user,tmux`, `sudo ./setup.sh --skip vnc`.
Tests: `./tests/run.sh` (portable checks always run; user/key checks need root on Linux).
Preview: `./setup.sh --dry-run --only user,vnc`. List: `./setup.sh --list`.

## Steps (run order)

| Step | Script | What it does |
|------|--------|--------------|
| 00-dns-fix | DNS repair | no-op if resolution works, else sets fallback DNS (1.1.1.1, 8.8.8.8) |
| 00-prep | base packages + upgrade | git, curl, sudo, ssh server, ufw (installed, not enabled), dns/htop/vim basics |
| 01-user | non-root user + sudo + ssh keys | ensures `$NEW_USER` (default: current sudo user), copies root keys, optional `AUTHORIZED_KEY` |
| 02-ssh-only | key-only sshd | disables password auth (lockout guard: needs an authorized key first) |
| 04-mosh | mosh | installs mosh, opens UDP `60000:61000` in ufw |
| 05-tmux | tmux | installs tmux + managed `/etc/tmux.conf` |
| 06-vnc | TigerVNC | installs server, `~/.vnc/xstartup` (auto-detects desktop), `vncserver@:1` service |
| 07-rust | Rust via rustup | installs stable toolchain for `$RUST_USER` |
| 08-tailscale | Tailscale | official apt repo, install, optional `tailscale up` |
| 09-zsh | zsh + oh-my-zsh | installs zsh, sets login shell, oh-my-zsh with theme/plugins (minimal `~/.zshrc` fallback) |
| 10-docker | Docker Engine | official apt repo, engine + compose plugins, user in `docker` group |
| 11-lockdown | tailnet-only firewall | off by default; ufw allows tailscale0, denies public (needs `tailscale up`) |
| 12-nvm | nvm + Node.js | installs nvm for user, Node LTS, loader in `.zshrc`/`.bashrc` |
| 14-opencode | opencode agent | standalone binary via official installer (`~/.opencode/bin`) |
| 15-pi | Pi agent | npm global install (needs node from step 12) |
| 16-gh | GitHub CLI | official repo, token auth, `gh auth setup-git` so git reuses the token |
| 13-notify | ntfy agent pings | skipped unless `NTFY_TOPIC` set; hooks claude/codex/muse/opencode/grok/pi/tmux to ping your phone when waiting |

Order matters: user is created before sshd is hardened, so you can't lock
yourself out. All config defaults live in [.env.example](.env.example).

## Notes

- VNC: set `VNC_PASSWORD` on first run (display `:1` = port `5901`).
  Existing `~/.vnc/xstartup` and password are kept on re-runs.
- Tailscale: set `TAILSCALE_AUTH_KEY` (ephemeral, reusable) or run
  `tailscale up` manually afterwards.
