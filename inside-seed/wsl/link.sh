#!/usr/bin/env bash
# Link this repo's dotfiles into $HOME on WSL, and stage the internal CA.
#
#   ~/twentyx/wsl/link.sh          as the user; SETUP.ps1 runs it on install
#
# Run it again after a `git pull` that adds or removes files; a pull that only
# edits files is live without it. The linking is pod/link-home, the same
# script a pod's entrypoint runs.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
say() { printf '\033[36m==>\033[0m %s\n' "$*"; }

say "linking $REPO/dotfiles into $HOME"
"$REPO/pod/link-home" "$REPO/dotfiles"

# The internal CA and pip.conf: never baked into the closure (they rotate and
# differ per cluster). airgap-ca rebuilds the system bundle from them.
if [ -f "$REPO/env/ca-bundle.crt" ] || [ -f "$REPO/env/pip.conf" ]; then
    say "staging env/ into /var/lib/airgap-env"
    for f in ca-bundle.crt pip.conf; do
        [ ! -f "$REPO/env/$f" ] || sudo install -Dm644 "$REPO/env/$f" "/var/lib/airgap-env/$f"
    done
    sudo systemctl restart airgap-ca
fi
say "done."
