# lmde-ssh-agent-fix

On LMDE / Linux Mint Cinnamon, `ssh` pops a **"enter password to unlock keyring"**
dialog instead of using your loaded key, and a fresh terminal shows:

```console
$ echo $SSH_AUTH_SOCK; ssh-add -l

Could not open a connection to your authentication agent.
```

`SSH_AUTH_SOCK` is empty or points at a dead socket. This repo diagnoses why and fixes
it, idempotently.

## Install

```sh
git clone https://github.com/dnbarnett/lmde-ssh-agent-fix.git
cd lmde-ssh-agent-fix
./install.sh --dry-run    # optional: show what would change
./install.sh
```

Then open a **new terminal** and:

```sh
ssh-add ~/.ssh/id_ed25519   # if no key is loaded yet
./verify.sh
```

Run as your normal user from a graphical login session — never with `sudo`. Re-running
is safe. `./uninstall.sh` reverts everything.

## The actual problem

There is no single misconfigured agent. On a stock LMDE/Cinnamon box **six** different
things each want to provide an ssh-agent socket:

| # | Provider | How it starts |
|---|----------|---------------|
| 1 | Vanilla `ssh-agent` | `/etc/X11/Xsession.d/90x11-common_ssh-agent`, gated by `use-ssh-agent` in `Xsession.options` |
| 2 | gnome-keyring's ssh bridge | `/etc/xdg/autostart/gnome-keyring-ssh.desktop` — nominally `OnlyShowIn=GNOME;Unity;MATE`, but systemd's `xdg-desktop-autostart-generator` **ignores that** and runs it anyway |
| 3 | systemd `ssh-agent.socket` | static/enabled by default; socket-activates OpenSSH's agent at `$XDG_RUNTIME_DIR/openssh_agent` |
| 4 | `gcr-ssh-agent.socket` | GNOME's newer gcr4 replacement |
| 5 | `gpg-agent-ssh.socket` | gpg-agent's ssh emulation |
| 6 | **Cinnamon's own** | `gsettings get org.cinnamon enable-ssh-agent` → `true`. Logs as `SSH agent: enabled` in `~/.xsession-errors`. Easy to miss — it isn't a systemd unit or a `.desktop` file. |

Several run at once, most are never wired to `SSH_AUTH_SOCK`, and they fight.

**The root cause of the empty variable is separate from all six.**
`/etc/pam.d/lightdm` contains:

```
-session optional pam_gnome_keyring.so auto_start
```

That starts `gnome-keyring-daemon` at **PAM session-open time** — before and outside
every systemd unit and autostart entry. Even with `--components=pkcs11,secrets`, it
unconditionally creates an `ssh` socket in `$XDG_RUNTIME_DIR/keyring/`. Later in login,
cinnamon-session's `dbus-update-activation-environment` rediscovers that daemon and
re-exports `SSH_AUTH_SOCK` pointing at it. You can see it happen:

```console
$ grep -n 'discover_other_daemon\|SSH_AUTH_SOCK' ~/.xsession-errors
35:discover_other_daemon: 1GNOME_KEYRING_CONTROL=/run/user/1000/keyring
36:SSH_AUTH_SOCK=/run/user/1000/keyring/ssh
```

This happens *late*, outside anything you can mask — which is why the obvious fixes fail.

## What doesn't work (and why)

Three plausible approaches were tried and verified failing. Skip them:

- **`~/.config/environment.d/ssh-auth-sock.conf`** — read once at systemd `--user`
  manager startup (i.e. first login after boot), not per-login. The manager survives
  logout, so on a second login it is never re-read.
- **A systemd user unit `WantedBy=graphical-session.target`** — that target is **never
  reached** on Cinnamon (`systemctl --user status graphical-session.target` shows
  `inactive (dead)` mid-session). Cinnamon doesn't signal it the way GNOME Shell does,
  so the unit never fires. Also beware: `dbus-update-activation-environment --systemd
  SSH_AUTH_SOCK` with a *bare variable name* reads the value from its own stale
  environment and re-clobbers what you just set — always pass an explicit `VAR=value`.
- **An autostart `.desktop` alone** — this *does* work, but only at session level. It
  fixes GUI apps; the value still does not reach shells spawned by the terminal.

## What works

Set it where the shell actually reads it. `install.sh` appends to `~/.bashrc`:

```sh
export SSH_AUTH_SOCK="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/openssh_agent"
```

Deterministic, needs no logout, and doesn't care which provider wins the login race.
The autostart entry is installed too, since it's the leg that covers **GUI** apps.

**Caveat:** Debian's stock `~/.bashrc` returns early for non-interactive shells
(`case $- in *i*) ;; *) return;; esac`), and the export goes at the end — so this covers
**interactive shells only**. For cron, `ssh host 'cmd'`, or IDE task runners, set it in
that runner's environment too.

## Testing gotcha

**A new terminal window is not always a valid test.** `gnome-terminal-server` is one
long-lived process per session; new windows are children of it and inherit *its*
environment from login. Neither `systemctl --user set-environment` nor
`dbus-update-activation-environment` can push a variable into an already-running
process. To test session-level changes, do a **full logout/login**, or restart the
specific consumer. Shell-level changes (this fix) take effect in any new shell
immediately.

Useful check — compare a process's real environment against your shell's:

```sh
tr '\0' '\n' < /proc/$(pgrep -f gnome-terminal-server | head -1)/environ | grep SSH
```

## Files

| Path | Purpose |
|------|---------|
| `install.sh` | Idempotent installer. `--dry-run` supported. |
| `verify.sh` | Read-only health check; non-zero exit on failure. |
| `uninstall.sh` | Reverts all changes. |
| `files/ssh-auth-sock-fixup.desktop` | Autostart entry for the GUI-app leg. |

Tested on LMDE 7 (gigi) / Cinnamon with lightdm. Most of the diagnosis applies to other
Debian-based Cinnamon and GNOME-adjacent desktops.

## License

MIT — see [LICENSE](LICENSE).
