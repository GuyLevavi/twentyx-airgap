#!/usr/bin/env bash
# setup-wsl.sh -- one-shot setup/update INSIDE the twentyx distro, as root:
#
#   wsl -d twentyx -u root -- bash /mnt/c/twentyx/setup-wsl.sh
#
# TRANSFER defaults to the directory this script lives in (override with
# TRANSFER=/path). Run it from the checkout and the clone IS the text tree:
# no repo-layer.tar needed, and seed-home prefers it over /opt.
# Steps:
#   1. the text layer -- overlay /opt/twentyx, or use the checkout
#   2. the runtime CA + pip.conf into /var/lib/airgap-env
#   3. the closure delta: carried, or fetched with MANIFEST.txt from the
#      package registry; import, set the system profile, switch
#   4. re-seed $HOME; seed-home prefers the clone when it exists
#
# Rollback: nix-env -p /nix/var/nix/profiles/system --rollback &&
#           /nix/var/nix/profiles/system/bin/switch-to-configuration switch
set -euo pipefail

T="${TRANSFER:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
REPO="$(cd "$T/.." && pwd)"
say() { printf '\033[36m==>\033[0m %s\n' "$*"; }

# A checkout under the WSL filesystem: the clone is the live text tree. A
# path under /mnt comes and goes with the Windows drives; never follow it.
CHECKOUT=no
if [ -d "$REPO/libexec" ] && [ -d "$REPO/dotfiles" ]; then
    case "$REPO" in /mnt/*) ;; *) CHECKOUT=yes ;; esac
fi

[ "$(id -u)" = 0 ] || {
    echo "run me as root: wsl -d twentyx -u root -- bash $T/setup-wsl.sh" >&2
    exit 1
}
[ -d "$T" ] || { echo "transfer dir not found: $T" >&2; exit 1; }
if [ ! -f "$T/repo-layer.tar" ] && [ "$CHECKOUT" = no ]; then
    echo "missing $T/repo-layer.tar (or run scripts/setup-wsl.sh from a checkout)" >&2
    exit 1
fi

# 1. text layer (dotfiles, libexec, agent) -- overlay the opt/ subtree;
# from a checkout there is nothing to overlay, the clone is the tree.
if [ -f "$T/repo-layer.tar" ]; then
    say "overlaying the text layer"
    tar -xf "$T/repo-layer.tar" -C / opt
    . /opt/twentyx/libexec/common.sh
else
    . "$REPO/libexec/common.sh"
    say "checkout mode: the clone is the text layer"
    # The seed-home unit always execs the /opt entry point first; install the
    # clone's copy of it so the unit hands over to the clone (and a fresh
    # install gets its first /opt entry point here).
    install -Dm755 "$REPO/libexec/seed-home" /opt/twentyx/libexec/seed-home
fi

# 2. runtime CA bundle + pip.conf; the oneshot concatenates the CA onto the
# system bundle and the /etc symlinks point at the result. The transfer dir
# wins, then the repo's env/, then the overlaid copy.
CA="$T/ca-bundle.crt"
[ -f "$CA" ] || CA="$REPO/env/ca-bundle.crt"
[ -f "$CA" ] || CA=/opt/twentyx/env/ca-bundle.crt
PIP="$T/pip.conf"
[ -f "$PIP" ] || PIP="$REPO/env/pip.conf"
[ -f "$PIP" ] || PIP=/opt/twentyx/env/pip.conf
install -Dm644 "$CA" /var/lib/airgap-env/ca-bundle.crt 2>/dev/null || true
install -Dm644 "$PIP" /var/lib/airgap-env/pip.conf 2>/dev/null || true
systemctl restart airgap-ca 2>/dev/null || true

# 3. closure delta -- carried, or pulled from the project's package registry
# (GITLAB_URL/GITLAB_PROJECT; GITLAB_TOKEN only for a private project). From a
# checkout there is no MANIFEST.txt, so fetch it first: it names the version,
# the system the delta yields, and the base it needs. A text-only release has
# no nar and a 404 just means text-only; an unreachable registry must not hang
# the setup.
MNF="$T/MANIFEST.txt"
if [ ! -f "$MNF" ] && [ -n "${GITLAB_URL:-}" ] && [ -n "${GITLAB_PROJECT:-}" ]; then
    # pipefail: cat of a missing path must not abort (|| true covers the pipe)
    VER="$(cat "$REPO/VERSION" "$T/VERSION" 2>/dev/null | head -1 || true)"
    if [ -n "$VER" ]; then
        say "fetching MANIFEST.txt from the package registry"
        AUTH=()
        if [ -n "${GITLAB_TOKEN:-}" ]; then AUTH=(-H "PRIVATE-TOKEN: $GITLAB_TOKEN"); fi
        MNF="${TMPDIR:-/tmp}/twentyx-manifest.$$"
        curl -fSL --connect-timeout 10 "${AUTH[@]}" \
            -o "$MNF" \
            "${GITLAB_URL%/}/api/v4/projects/${GITLAB_PROJECT//\//%2F}/packages/generic/twentyx-airgap/$VER/MANIFEST.txt" \
            || { rm -f "$MNF"; MNF=""; }
    fi
fi
if [ ! -f "$T/wsl-update.nar" ] && [ -n "${GITLAB_URL:-}" ] && [ -n "${GITLAB_PROJECT:-}" ] \
    && [ -f "$MNF" ]; then
    VER="$(sed -n 's/^VERSION=//p' "$MNF")"
    if [ -n "$VER" ]; then
        say "fetching wsl-update.nar from the package registry"
        AUTH=()
        if [ -n "${GITLAB_TOKEN:-}" ]; then AUTH=(-H "PRIVATE-TOKEN: $GITLAB_TOKEN"); fi
        curl -fSL --connect-timeout 10 "${AUTH[@]}" \
            -o "$T/wsl-update.nar" \
            "${GITLAB_URL%/}/api/v4/projects/${GITLAB_PROJECT//\//%2F}/packages/generic/twentyx-airgap/$VER/wsl-update.nar" \
            || rm -f "$T/wsl-update.nar"
    fi
fi
if [ -f "$T/wsl-update.nar" ]; then
    [ -f "$MNF" ] || die "wsl-update.nar is here but MANIFEST.txt is not -- carry MANIFEST.txt with it"
    NEW=$(sed -n 's/^WSL_SYSTEM=//p' "$MNF")
    BASE=$(sed -n 's/^WSL_BASE=//p' "$MNF")
    [ -n "$NEW" ] || die "MANIFEST.txt has no WSL_SYSTEM= line"
    # The tarball and the delta are built from the same system, so a fresh
    # import already carries NEW's whole closure and its base may be absent --
    # the delta is then redundant, not broken. Only import it when NEW is not
    # already valid, and only insist on the base then.
    if nix-store --check-validity "$NEW" 2>/dev/null; then
        say "system already in the store (fresh import) -- skipping the delta"
    else
        if [ -n "$BASE" ] && [ ! -e "$BASE" ]; then
            die "this update is a delta against $BASE which is not in the store; carry the full wsl-update.nar instead"
        fi
        say "importing the closure delta"
        nix-store --import < "$T/wsl-update.nar"
        nix-store --check-validity "$NEW"
    fi
    nix-env -p /nix/var/nix/profiles/system --set "$NEW"
    # switch-to-configuration exits 4 when some units failed but the switch
    # itself happened (WSL-generated units, headless user activation). The
    # new system is already active: report and continue rather than abort
    # before step 4. Any other nonzero code is fatal.
    rc=0
    /nix/var/nix/profiles/system/bin/switch-to-configuration switch || rc=$?
    if [ "$rc" = 4 ]; then
        say "switch done, but some units failed (exit 4) -- continuing"
        systemctl --failed --no-pager || true
    elif [ "$rc" != 0 ]; then
        die "switch-to-configuration failed (exit $rc)"
    fi
else
    say "no wsl-update.nar available -- text layer only"
fi

# 4. seed $HOME. seed-home itself prefers a checkout at ~/twentyx over the
# /opt copy, so from the clone the $HOME dotfile links target the clone's
# dotfiles (a config edit or `git pull` is live); the /opt copy stays the
# pod/CI path. Step 1 above installs the entry point the unit execs, so a
# plain `git pull` + this script (or just a seed-home restart) is enough
# after the first run; nothing here writes to /etc.
systemctl restart seed-home 2>/dev/null || true

say "done."
