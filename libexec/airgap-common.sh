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
# shellcheck disable=SC2034  # AIRGAP_USER_SOURCE is read by callers, not here
airgap_user() {
    local u
    if [ -n "${AIRGAP_USER:-}" ]; then
        AIRGAP_USER_SOURCE="AIRGAP_USER"; AIRGAP_USER_RESOLVED="$AIRGAP_USER"
        printf '%s' "$AIRGAP_USER"; return
    fi
    # --global is load-bearing, not decoration. A plain `git config --get`
    # honours a per-REPOSITORY user.email, so the resolved identity -- and
    # therefore $HOME -- would depend on which directory you happened to run
    # from. Working in a repo with its own user.email would silently relocate
    # your state to a different PVC directory, which is precisely the failure
    # this chain exists to avoid.
    #
    # home-manager writes ~/.config/git/config, which git treats as global, so
    # this reads exactly the value Nix set.
    u="$(git config --global --get user.email 2>/dev/null || true)"
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

# ── environment-provided assets ───────────────────────────────────────────
# Things the environment must inject (internal CA bundle, pip.conf, ...) are
# not baked into the image: they differ per cluster and rotate. The contract:
#
#   /opt/airgap-env      ConfigMap/Secret volume, via RunAI pod-template
#                        customization -- platform-idiomatic, updates without
#                        an image or PVC change, wins when both exist
#   /data/.airgap-env    a directory on the shared PVC -- fallback when
#                        mounting is not available, one copy per cluster
#
# Known file names are wired into env vars (below); unknown files are simply
# reachable at their path, which is the extension point for the "stuff nobody
# remembered to enumerate".
# Emit TAB-separated KEY VALUE pairs for every known file that exists.
airgap_injection_exports() {
    local d v
    for d in /opt/airgap-env /data/.airgap-env; do
        [ -d "$d" ] || continue
        printf 'AIRGAP_ENV_DIR\t%s\n' "$d"
        if [ -f "$d/pip.conf" ]; then
            printf 'PIP_CONFIG_FILE\t%s\n' "$d/pip.conf"
        fi
        if [ -f "$d/ca-bundle.crt" ]; then
            # One file, many readers: python ssl, requests, curl, git, the
            # Nix binaries themselves, node.
            for v in SSL_CERT_FILE REQUESTS_CA_BUNDLE CURL_CA_BUNDLE \
                     GIT_SSL_CAINFO NIX_SSL_CERT_FILE NODE_EXTRA_CA_CERTS; do
                printf '%s\t%s\n' "$v" "$d/ca-bundle.crt"
            done
        fi
        return 0
    done
    return 1
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
