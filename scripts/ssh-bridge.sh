#!/usr/bin/env bash
# Client side (WSL): bridge Zed/SSH to a RunAI workload that exposes no SSH
# port. A local socat listener forwards each TCP connection into
# `runai exec -i`, whose stdin/stdout IS the SSH protocol (sshd -i, server
# side: libexec/airgap-sshd-inetd). Every connection gets its own exec.
#
#   ./scripts/ssh-bridge.sh <runai-workload> [port]        port default 2222
#
# Then point Zed (or ssh) at localhost:<port>. Windows clients reach the WSL
# listener directly: WSL2 forwards localhost automatically.
#
# One-time setup: put your pubkey in the pod's durable home,
#   $HOME/.ssh/authorized_keys   (on the PVC)
# and accept the ephemeral host key on first connect (accept-new).
#
# ~/.ssh/config on the client:
#
#   Host runai-workspace
#       HostName 127.0.0.1
#       Port 2222
#       User jensen
#       StrictHostKeyChecking accept-new
#
# Zed remote: "Connect to Remote Server" -> ssh://runai-workspace (or the
# localhost:port form). Zed will try to download its matching remote-server
# binary, which cannot work in the airgap -- see NOTES.md for the pre-seed
# procedure. The OpenCode integration needs none of that: it runs
# `opencode acp` locally (see the packaged Zed settings default).
set -euo pipefail

WORKLOAD="${1:?usage: ssh-bridge.sh <runai-workload> [port]}"
PORT="${2:-2222}"

say() { printf '\033[36m==>\033[0m %s\n' "$*"; }
die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

command -v socat >/dev/null 2>&1 || die "socat missing (nix shell nixpkgs#socat)"
command -v runai >/dev/null 2>&1 || die "runai CLI missing (uv tool install runai, inside the gap)"

say "localhost:$PORT -> runai exec $WORKLOAD -> sshd -i   (Ctrl-C to stop)"
say "connect with: ssh -p $PORT jensen@127.0.0.1"

# fork: one runai exec per connection. No pty anywhere on this path -- a pty
# would corrupt the binary SSH protocol with echo/CRLF translation.
exec socat "TCP-LISTEN:$PORT,bind=127.0.0.1,reuseaddr,fork" \
    "EXEC:runai exec -i $WORKLOAD -- sudo /opt/airgap/libexec/airgap-sshd-inetd"
