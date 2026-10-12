#!/usr/bin/env bash
# Update the WSL distro to the store release this repo pins.
#
#   ~/twentyx/wsl/update.sh [release]       as the user; sudo for apply.sh
#
# Downloads MANIFEST.txt, apply.sh and wsl-<KIND>.nar of STORE_RELEASE (or
# [release]) from this project's GitLab generic package registry, then runs
# apply.sh as root: import, root the base, set the system profile, switch.
# The registry is the one `origin` points at; GITLAB_URL + GITLAB_PROJECT
# override it, GITLAB_TOKEN is only for a private project. A transfer folder
# needs none of this: run its apply.sh directly.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
say() { printf '\033[36m==>\033[0m %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

RELEASE="${1:-$(cat "$REPO/STORE_RELEASE" 2>/dev/null || true)}"
[ -n "$RELEASE" ] || die "no STORE_RELEASE in $REPO (or pass a release id)"

# origin: https://host/group/project(.git) or git@host:group/project(.git)
if [ -z "${GITLAB_URL:-}" ] || [ -z "${GITLAB_PROJECT:-}" ]; then
    origin="$(git -C "$REPO" remote get-url origin)"
    origin="${origin%.git}"
    case "$origin" in
        https://*) rest="${origin#https://}"; rest="${rest#*@}"; host="${rest%%/*}"; GITLAB_PROJECT="${rest#*/}" ;;
        *@*:*) rest="${origin#*@}"; host="${rest%%:*}"; GITLAB_PROJECT="${rest#*:}" ;;
        *) die "cannot derive the registry from origin '$origin' -- set GITLAB_URL and GITLAB_PROJECT" ;;
    esac
    GITLAB_URL="https://$host"
fi
API="${GITLAB_URL%/}/api/v4/projects/${GITLAB_PROJECT//\//%2F}/packages/generic/twentyx-store/$RELEASE"
AUTH=()
[ -z "${GITLAB_TOKEN:-}" ] || AUTH=(-H "PRIVATE-TOKEN: $GITLAB_TOKEN")

DIR="${XDG_CACHE_HOME:-$HOME/.cache}/twentyx-store/$RELEASE"
mkdir -p "$DIR"
fetch() {
    [ -f "$DIR/$1" ] && return
    say "fetching $1"
    curl -fSL --connect-timeout 10 "${AUTH[@]}" -o "$DIR/$1.part" "$API/$1" \
        || die "cannot fetch twentyx-store/$RELEASE/$1"
    mv "$DIR/$1.part" "$DIR/$1"
}

fetch MANIFEST.txt
get() { sed -n "s/^$1=//p" "$DIR/MANIFEST.txt"; }
[ "$(get RELEASE)" = "$RELEASE" ] || die "$DIR/MANIFEST.txt is release $(get RELEASE), not $RELEASE"
if [ "$(readlink -f /run/current-system)" = "$(get WSL_SYSTEM)" ]; then
    say "already at $RELEASE"
    exit 0
fi
fetch apply.sh
fetch "wsl-$(get KIND).nar"

sudo bash "$DIR/apply.sh" "$DIR"
rm -rf "$DIR"
