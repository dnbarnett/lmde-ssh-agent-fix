#!/usr/bin/env bash
# Revert everything install.sh did. Leaves ssh-agent.socket enabled.
set -euo pipefail
AUTOSTART="$HOME/.config/autostart"

if [ -f "$HOME/.bashrc" ] && grep -qF '# >>> lmde-ssh-agent-fix >>>' "$HOME/.bashrc"; then
  cp "$HOME/.bashrc" "$HOME/.bashrc.bak-$(date +%Y%m%d-%H%M%S)"
  sed -i '/# >>> lmde-ssh-agent-fix >>>/,/# <<< lmde-ssh-agent-fix <<</d' "$HOME/.bashrc"
  echo "removed .bashrc block (backup kept)"
fi

rm -fv "$AUTOSTART/ssh-auth-sock-fixup.desktop" "$AUTOSTART/gnome-keyring-ssh.desktop"

for u in gcr-ssh-agent.socket gpg-agent-ssh.socket app-gnome-keyring-ssh@autostart.service; do
  systemctl --user list-unit-files "$u" >/dev/null 2>&1 \
    && systemctl --user unmask "$u" 2>/dev/null && echo "unmasked $u" || true
done

command -v gsettings >/dev/null 2>&1 && \
  gsettings writable org.cinnamon enable-ssh-agent >/dev/null 2>&1 && \
  gsettings reset org.cinnamon enable-ssh-agent && echo "reset org.cinnamon enable-ssh-agent" || true

echo "Done - log out and back in for a clean slate."
