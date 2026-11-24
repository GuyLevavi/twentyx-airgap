#!/usr/bin/env bash
# Update this WSL box to a twentyx store release, however many releases behind
# it is. Inner keeps this file as wsl/update.sh.
#
#   ~/twentyx/wsl/update.sh [RELEASE]     as the user; asks for sudo once per apply
#
# RELEASE defaults to the repo's STORE_RELEASE file. Releases come from this
# project's GitLab generic registry (package twentyx-store), or from
# TWENTYX_STORE_URL, a URL whose <RELEASE>/<file> holds the release files
# (file:///mnt/c/twentyx-store for a transfer folder).
#
# A release's delta only needs the paths in its wsl-needs.txt. If this box
# lacks some, update.sh follows BASE_RELEASE back until it finds a release
# the box can take, then applies forward to RELEASE, one apply.sh per step.
# If none in the chain fits, it stops before changing anything and writes the
# box's path list for outside to cut a release against.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
say() { printf '\033[36m==>\033[0m %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
MAX_CHAIN="${TWENTYX_MAX_CHAIN:-12}"

[ $# -le 1 ] || die "usage: update.sh [RELEASE]"
TARGET="${1:-$(cat "$REPO/STORE_RELEASE" 2>/dev/null || true)}"
[ -n "$TARGET" ] || die "no STORE_RELEASE in $REPO (or pass a release id)"

# ── where releases come from ──────────────────────────────────────────────
AUTH=()
if [ -n "${TWENTYX_STORE_URL:-}" ]; then
    BASE_URL="${TWENTYX_STORE_URL%/}"
else
    # GITLAB_URL / GITLAB_PROJECT, else derived from origin
    # (https://host/g/p, ssh://git@host:port/g/p or git@host:g/p; .git optional).
    if [ -z "${GITLAB_URL:-}" ] || [ -z "${GITLAB_PROJECT:-}" ]; then
        origin="$(git -C "$REPO" remote get-url origin)"
        origin="${origin%.git}"
        case "$origin" in
            http*://*) rest="${origin#*://}"; rest="${rest#*@}"; host="${rest%%/*}" ;;
            ssh://*) rest="${origin#ssh://}"; rest="${rest#*@}"; host="${rest%%/*}"; host="${host%%:*}" ;;
            *@*:*) rest="${origin#*@}"; host="${rest%%:*}"; rest="$host/${rest#*:}" ;;
            *) die "cannot derive the registry from origin '$origin' -- set GITLAB_URL and GITLAB_PROJECT" ;;
        esac
        GITLAB_URL="${GITLAB_URL:-https://$host}"
        GITLAB_PROJECT="${GITLAB_PROJECT:-${rest#*/}}"
    fi
    BASE_URL="${GITLAB_URL%/}/api/v4/projects/${GITLAB_PROJECT//\//%2F}/packages/generic/twentyx-store"
    [ -z "${GITLAB_TOKEN:-}" ] || AUTH=(-H "PRIVATE-TOKEN: $GITLAB_TOKEN")
fi
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/twentyx-store"
say "target $TARGET from $BASE_URL"

# fetch RELEASE FILE: into $CACHE/RELEASE/FILE; fails quietly on a 404.
fetch() {
    local dir="$CACHE/$1"
    mkdir -p "$dir"
    [ -s "$dir/$2" ] && return 0
    curl -fsSL --connect-timeout 10 "${AUTH[@]}" -o "$dir/$2.part" "$BASE_URL/$1/$2" 2>/dev/null \
        || { rm -f "$dir/$2.part"; return 1; }
    mv "$dir/$2.part" "$dir/$2"
}
get() { sed -n "s/^$2=//p" "$CACHE/$1/MANIFEST.txt"; }

CURRENT="$(readlink -f /run/current-system)"

# Can this box take RELEASE's delta as it stands? Prints the missing paths.
missing() {
    [ -s "$CACHE/$1/wsl-needs.txt" ] || return 0
    xargs -r nix-store --check-validity --print-invalid < "$CACHE/$1/wsl-needs.txt" 2>/dev/null || true
}

# ── walk back from TARGET until a release fits this box ────────────────────
CHAIN=()           # newest first
rel="$TARGET"
start=""
first_missing=""
for _ in $(seq "$MAX_CHAIN"); do
    fetch "$rel" MANIFEST.txt || { [ "${#CHAIN[@]}" -gt 0 ] || die "release $rel is not in $BASE_URL"; break; }
    [ "$(get "$rel" RELEASE)" = "$rel" ] || die "$CACHE/$rel/MANIFEST.txt is release $(get "$rel" RELEASE), not $rel"
    sys="$(get "$rel" WSL_SYSTEM)"
    # Releases before 20261122 carry no system to switch to: the chain ends.
    [ -n "$sys" ] || break
    if [ "$sys" = "$CURRENT" ]; then
        start="already"
        break
    fi
    CHAIN+=("$rel")
    fetch "$rel" wsl-needs.txt || die "release $rel has MANIFEST.txt but no wsl-needs.txt"
    m="$(missing "$rel")"
    if [ -z "$m" ]; then
        start="$rel"
        break
    fi
    [ -n "$first_missing" ] || first_missing="$rel: $(wc -w <<< "$m") paths"
    rel="$(get "$rel" BASE_RELEASE)"
    [ -n "$rel" ] || break
done

if [ "$start" = already ] && [ "${#CHAIN[@]}" -eq 0 ]; then
    say "already at $TARGET"
    exit 0
fi
if [ -z "$start" ]; then
    out="$HOME/twentyx-baseline-$(date +%Y%m%d).store-paths"
    nix-store -qR "$CURRENT" | sort -u > "$out"
    die "no release between this box and $TARGET can be applied (${first_missing:-no release fits}).
Nothing was changed. Either apply a full release (update.sh <id>-full), or
carry this file outside and ask for a delta cut against it:
  $out"
fi

# ── apply forward, oldest first ───────────────────────────────────────────
PLAN=()
for ((i = ${#CHAIN[@]} - 1; i >= 0; i--)); do
    # With start="already", every release in CHAIN is newer than the box.
    if [ "$start" != already ] && [ "${#PLAN[@]}" -eq 0 ] && [ "${CHAIN[$i]}" != "$start" ]; then
        continue
    fi
    PLAN+=("${CHAIN[$i]}")
done
say "plan: ${PLAN[*]}"

for rel in "${PLAN[@]}"; do
    for f in apply.sh wsl-needs.txt "wsl-$(get "$rel" KIND).nar.tar.gz"; do
        fetch "$rel" "$f" || die "cannot fetch twentyx-store/$rel/$f"
    done
    m="$(missing "$rel")"
    [ -z "$m" ] || die "release $rel still lacks $(wc -w <<< "$m") paths after the steps before it; tell outside"
    say "applying $rel"
    # apply.sh reads the files beside itself.
    sudo bash "$CACHE/$rel/apply.sh"
    rm -f "$CACHE/$rel"/wsl-*.nar.tar.gz
done
say "done: $TARGET. Open a new shell."
