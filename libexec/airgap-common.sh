#!/usr/bin/env bash
# Shared helpers. Sourced, never executed.

AIRGAP_ROOT="${AIRGAP_ROOT:-/opt/airgap}"

say()  { printf '\033[36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33mwarn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
ok()   { printf '  \033[32mok\033[0m   %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; }

# Who are we, for picking a per-user directory on the shared /code PVC?
# Runtime user is `jensen` for everyone, and the workspace name is not stable,
# so fall through a chain of increasingly desperate guesses. A wrong answer is
# cosmetic (state lands in the wrong subdir), never destructive.
# Probe findings: every runtime user is uid 10001/gid 0, so the OS knows nothing
# about who you are. The hostname is `<workspace-name>-<n>-<n>`, which is the
# only platform-provided signal -- but workspace names are not stable across
# sessions, so a stable git identity is preferred when one exists.
#
# `airgap doctor` prints which rule fired, so a surprising answer is visible
# rather than silently misfiling your state.
# Sets AIRGAP_USER_RESOLVED and AIRGAP_USER_SOURCE as a side effect, so callers
# that want the provenance can invoke it WITHOUT a subshell:
#     airgap_user >/dev/null; echo "$AIRGAP_USER_RESOLVED via $AIRGAP_USER_SOURCE"
airgap_user() {
    local u
    if [ -n "${AIRGAP_USER:-}" ]; then
        AIRGAP_USER_SOURCE="AIRGAP_USER"; AIRGAP_USER_RESOLVED="$AIRGAP_USER"
        printf '%s' "$AIRGAP_USER"; return
    fi
    # Stable across sessions and machines; set it once in $AIRGAP_STATE.
    u="$(git config --get user.email 2>/dev/null || true)"
    if [ -n "$u" ]; then
        AIRGAP_USER_SOURCE="git user.email"; AIRGAP_USER_RESOLVED="${u%%@*}"
        printf '%s' "${u%%@*}"; return
    fi
    # Hostname is `<workspace-name>-<n>-<n>`, and workspace names follow a
    # `<username>-<whatever>` convention -- so strip the pod/replica suffix,
    # then take the leading component.
    #
    # This is wrong for any username containing a dash. That is why it sits
    # BELOW git user.email in the chain rather than above it, and why
    # `airgap doctor` prints which rule fired: a surprising answer should be
    # visible, not silently misfile a session's history.
    u="$(hostname 2>/dev/null || true)"
    u="$(printf '%s' "$u" | sed -E 's/(-[0-9]+)+$//')"
    if [ -n "$u" ] && [ "$u" != "$(hostname 2>/dev/null)" ]; then
        AIRGAP_USER_SOURCE="hostname (workspace <username>-<whatever>-<n>-<n>)"
        AIRGAP_USER_RESOLVED="${u%%-*}"
        printf '%s' "${u%%-*}"; return
    fi
    AIRGAP_USER_SOURCE="USERNAME/USER fallback"
    AIRGAP_USER_RESOLVED="${USERNAME:-${USER:-unknown}}"
    printf '%s' "$AIRGAP_USER_RESOLVED"
}

# Persistent state root. $HOME is ephemeral; /code and /data survive.
airgap_state() {
    if [ -n "${AIRGAP_STATE:-}" ]; then printf '%s' "$AIRGAP_STATE"; return; fi
    local base
    for base in /code /data; do
        if [ -d "$base" ] && [ -w "$base" ]; then
            printf '%s/%s/.airgap' "$base" "$(airgap_user)"; return
        fi
    done
    printf '%s/.airgap' "$HOME"   # WSL / local fallback
}

# Link $2 -> $1 idempotently, backing up anything real that is in the way.
link_into() {
    local src="$1" dst="$2"
    [ -e "$src" ] || return 0
    mkdir -p "$(dirname "$dst")"
    if [ -L "$dst" ]; then
        [ "$(readlink "$dst")" = "$src" ] && return 0
        rm -f "$dst"
    elif [ -e "$dst" ]; then
        mv "$dst" "$dst.bak.$(date +%s)"
    fi
    ln -s "$src" "$dst"
}

# Durable $HOME. The pod's real $HOME (/home/jensen) is wiped on every restart,
# and symlinking individual pieces onto the PVC only ever rescues the state we
# remembered to enumerate -- there is always another tool writing a dotfile we
# did not list. So relocate $HOME wholesale onto the PVC and let every tool be
# durable by default.
#
# Deliberately NOT durable: XDG_CACHE_HOME. The PVC is network-backed, and
# nvim, the LSPs and pip on a network filesystem are painfully slow. Cache is
# by definition reconstructible, so it stays on fast ephemeral local disk.
airgap_home() {
    if [ -n "${AIRGAP_HOME:-}" ]; then printf '%s' "$AIRGAP_HOME"; return; fi
    local base
    for base in /data /code; do
        if [ -d "$base" ] && [ -w "$base" ]; then
            printf '%s/%s' "$base" "$(airgap_user)"; return
        fi
    done
    printf '%s' "$HOME"   # WSL / local: $HOME is already durable
}

# True when the PVC is actually mounted. A workspace started without it should
# degrade to an ephemeral session with a loud warning, not silently write a
# session's worth of state into a directory that dies with the pod.
airgap_home_is_durable() {
    # An explicit override is taken at its word: the caller knows where their
    # durable storage is mounted better than this heuristic does.
    [ -n "${AIRGAP_HOME:-}" ] && return 0
    local h; h="$(airgap_home)"
    case "$h" in /data/*|/code/*) [ -d "$(dirname "$h")" ] ;; *) return 1 ;; esac
}
