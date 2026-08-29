#!/usr/bin/env bash
# Idempotent installer for the LMDE/Cinnamon ssh-agent fix. Run as your normal
# user (never root/sudo), from a graphical login session. Re-runnable safely.
set -euo pipefail

MARKER='# >>> lmde-ssh-agent-fix >>>'
RUNTIME="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
SOCK="$RUNTIME/openssh_agent"
AUTOSTART="$HOME/.config/autostart"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

say()  { printf '\n\033[1m%s\033[0m\n' "$1"; }
do_()  { if [ "$DRY" -eq 1 ]; then printf '  would: %s\n' "$*"; else "$@"; fi; }
note() { printf '  %s\n' "$1"; }

[ "$(id -u)" -ne 0 ] || { echo "Run as your normal user, not root." >&2; exit 1; }
systemctl --user show-environment >/dev/null 2>&1 \
  || { echo "No systemd --user session found." >&2; exit 1; }
[ "$DRY" -eq 1 ] && echo "DRY RUN - nothing will be changed."

# 1. The agent itself -------------------------------------------------------
say "1. systemd ssh-agent.socket"
if systemctl --user list-unit-files ssh-agent.socket >/dev/null 2>&1; then
  do_ systemctl --user enable --now ssh-agent.socket
  note "enabled + started (socket: $SOCK)"
else
  echo "  ssh-agent.socket not found - install openssh-client." >&2; exit 1
fi

# 2. The fix that actually reaches shells -----------------------------------
say "2. SSH_AUTH_SOCK export in ~/.bashrc"
if grep -qF "$MARKER" "$HOME/.bashrc" 2>/dev/null; then
  note "already present, leaving alone"
else
  [ -f "$HOME/.bashrc" ] && do_ cp "$HOME/.bashrc" "$HOME/.bashrc.bak-$(date +%Y%m%d-%H%M%S)"
  if [ "$DRY" -eq 1 ]; then
    note "would append export block to ~/.bashrc"
  else
    cat >> "$HOME/.bashrc" <<'EOF'

# >>> lmde-ssh-agent-fix >>>
# gnome-keyring (via pam_gnome_keyring in /etc/pam.d/lightdm) clobbers
# SSH_AUTH_SOCK late in login, outside every systemd unit and autostart entry,
# so set it here where the shell will actually read it. Interactive shells only.
export SSH_AUTH_SOCK="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/openssh_agent"
# <<< lmde-ssh-agent-fix <<<
EOF
    note "appended (backup of previous .bashrc kept)"
  fi
fi

# 3. GUI apps ---------------------------------------------------------------
say "3. autostart entry for GUI apps"
do_ mkdir -p "$AUTOSTART"
do_ install -m 0644 "$HERE/files/ssh-auth-sock-fixup.desktop" \
                    "$AUTOSTART/ssh-auth-sock-fixup.desktop"
note "installed $AUTOSTART/ssh-auth-sock-fixup.desktop"

# 4. Silence the competing providers ----------------------------------------
say "4. competing ssh-agent providers"
SYS_KEYRING=/etc/xdg/autostart/gnome-keyring-ssh.desktop
if [ -f "$SYS_KEYRING" ] && [ ! -f "$AUTOSTART/gnome-keyring-ssh.desktop" ]; then
  if [ "$DRY" -eq 1 ]; then
    note "would hide gnome-keyring-ssh autostart"
  else
    { cat "$SYS_KEYRING"; echo "Hidden=true"; } > "$AUTOSTART/gnome-keyring-ssh.desktop"
    note "hid gnome-keyring-ssh autostart (it ignores OnlyShowIn here)"
  fi
else
  note "gnome-keyring-ssh autostart already handled or absent"
fi

for u in gcr-ssh-agent.socket gpg-agent-ssh.socket app-gnome-keyring-ssh@autostart.service; do
  if systemctl --user list-unit-files "$u" >/dev/null 2>&1; then
    if [ "$(systemctl --user is-enabled "$u" 2>/dev/null || true)" = "masked" ]; then
      note "$u already masked"
    else
      do_ systemctl --user stop "$u" 2>/dev/null || true
      do_ systemctl --user mask "$u"
      note "masked $u"
    fi
  fi
done

# Cinnamon ships its own ssh-agent too - the easiest one to miss.
if command -v gsettings >/dev/null 2>&1 && \
   gsettings writable org.cinnamon enable-ssh-agent >/dev/null 2>&1; then
  if [ "$(gsettings get org.cinnamon enable-ssh-agent)" = "false" ]; then
    note "org.cinnamon enable-ssh-agent already false"
  else
    do_ gsettings set org.cinnamon enable-ssh-agent false
    note "set org.cinnamon enable-ssh-agent = false (applies next login)"
  fi
fi

say "Done."
cat <<EOF
  Next:
    1. open a NEW terminal (or: source ~/.bashrc)
    2. ssh-add ~/.ssh/id_ed25519      # if no key is loaded yet
    3. ./verify.sh

  A full logout/login is not required for shells, but is needed for the
  Cinnamon setting in step 4 to stop its agent in this session.
EOF
