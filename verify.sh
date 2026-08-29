#!/usr/bin/env bash
# Verify the ssh-agent fix. Safe to run any time; changes nothing.
set -uo pipefail

sock="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/openssh_agent"
fail=0
ok()   { printf '  \033[32mOK\033[0m    %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=1; }
warn() { printf '  \033[33mWARN\033[0m  %s\n' "$1"; }

echo "ssh-agent fix verification"
echo

echo "socket + agent:"
systemctl --user is-enabled ssh-agent.socket >/dev/null 2>&1 \
  && ok "ssh-agent.socket enabled" || bad "ssh-agent.socket not enabled"
[ -S "$sock" ] && ok "socket exists: $sock" || bad "socket missing: $sock"

echo
echo "this shell:"
if [ "${SSH_AUTH_SOCK:-}" = "$sock" ]; then
  ok "SSH_AUTH_SOCK=$SSH_AUTH_SOCK"
else
  bad "SSH_AUTH_SOCK='${SSH_AUTH_SOCK:-}' (expected $sock)"
  echo "        open a NEW terminal, or: source ~/.bashrc"
fi

if out=$(SSH_AUTH_SOCK="$sock" ssh-add -l 2>&1); then
  ok "agent reachable, keys loaded:"
  printf '        %s\n' "$out"
else
  case "$out" in
    *"no identities"*) warn "agent reachable but holds no keys - run: ssh-add ~/.ssh/id_ed25519" ;;
    *)                 bad "agent not reachable: $out" ;;
  esac
fi

echo
echo "competing agent providers:"
if command -v gsettings >/dev/null 2>&1 && \
   gsettings writable org.cinnamon enable-ssh-agent >/dev/null 2>&1; then
  v=$(gsettings get org.cinnamon enable-ssh-agent 2>/dev/null)
  [ "$v" = "false" ] && ok "org.cinnamon enable-ssh-agent = false" \
                     || bad "org.cinnamon enable-ssh-agent = $v (should be false)"
fi
for u in gcr-ssh-agent.socket gpg-agent-ssh.socket app-gnome-keyring-ssh@autostart.service; do
  if systemctl --user list-unit-files "$u" >/dev/null 2>&1; then
    s=$(systemctl --user is-enabled "$u" 2>/dev/null || true)
    [ "$s" = "masked" ] && ok "$u masked" || warn "$u is '$s' (not masked)"
  fi
done

echo
if [ "$fail" -eq 0 ]; then
  echo "All good."
else
  echo "Some checks failed - see README.md troubleshooting."
fi
exit "$fail"
