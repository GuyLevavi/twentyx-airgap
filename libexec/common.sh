#!/usr/bin/env bash
# Shared helpers. Sourced, never executed.

TOOLCHAIN_ROOT="${TOOLCHAIN_ROOT:-/opt/twentyx}"

say()  { printf '\033[36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33mwarn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
ok()   { printf '  \033[32mok\033[0m   %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; }

# Who are we, for picking a per-user directory on the shared /code PVC?
# The runtime user is a fixed generic name (e.g. `jensen`) for everyone, and
# the toolchain is distributed to a whole team -- so identity must come from
# something the PLATFORM gives per user, not from anything baked into the
# image (a baked identity would file every teammate's state into one person's
# directory).
#
# Probe findings: every runtime user is uid 10001/gid 0, so the OS knows
# nothing about who you are. The hostname is `<workspace-name>-<n>-<n>`, and
# workspace names follow a `<username>-<whatever>` convention -- that is the
# per-user signal, and it is the default. Its instability (renamed workspaces)
# and its dash-blindness (first dash-component only) are accepted, documented
# tradeoffs; the explicit override is the escape hatch.
#
# `doctor` prints which rule fired, so a surprising answer is visible
# rather than silently misfiling your state.
# Sets SESSION_USER_RESOLVED and SESSION_USER_SOURCE as a side effect, so
# callers that want the provenance can invoke it WITHOUT a subshell:
#     session_user >/dev/null; echo "$SESSION_USER_RESOLVED via $SESSION_USER_SOURCE"
# shellcheck disable=SC2034  # SESSION_USER_SOURCE is read by callers, not here
session_user() {
    local u
    if [ -n "${SESSION_USER:-}" ]; then
        SESSION_USER_SOURCE="SESSION_USER"; SESSION_USER_RESOLVED="$SESSION_USER"
        printf '%s' "$SESSION_USER"; return
    fi
    # Hostname is `<workspace-name>-<n>-<n>`; workspace names follow a
    # `<username>-<whatever>` convention -- so strip the pod/replica suffix,
    # then take the leading component. This is what keeps teammates' state in
    # their own PVC directories without anyone configuring anything.
    #
    # It is wrong for any username containing a dash, and it changes if the
    # workspace is renamed. Both are why the explicit override exists above
    # and why `doctor` prints which rule fired: a surprising answer
    # should be visible, not silently misfile a session's history.
    u="$(hostname 2>/dev/null || true)"
    u="$(printf '%s' "$u" | sed -E 's/(-[0-9]+)+$//')"
    if [ -n "$u" ] && [ "$u" != "$(hostname 2>/dev/null)" ]; then
        SESSION_USER_SOURCE="hostname (workspace <username>-<whatever>-<n>-<n>)"
        SESSION_USER_RESOLVED="${u%%-*}"
        printf '%s' "${u%%-*}"; return
    fi
    # Your own git identity, set once per user on the durable PVC with
    # `git config --global user.email`. It sits BELOW the workspace rule so a
    # later `git config` can never silently relocate an existing directory,
    # and it only fires when the workspace name gave us nothing at all.
    u="$(git config --global --get user.email 2>/dev/null || true)"
    if [ -n "$u" ]; then
        SESSION_USER_SOURCE="git user.email"; SESSION_USER_RESOLVED="${u%%@*}"
        printf '%s' "${u%%@*}"; return
    fi
    SESSION_USER_SOURCE="USERNAME/USER fallback"
    SESSION_USER_RESOLVED="${USERNAME:-${USER:-unknown}}"
    printf '%s' "$SESSION_USER_RESOLVED"
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
injection_exports() {
    local d v
    for d in /opt/airgap-env /data/.airgap-env; do
        [ -d "$d" ] || continue
        printf 'ENV_INJECTION_DIR\t%s\n' "$d"
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
session_home() {
    if [ -n "${SESSION_HOME:-}" ]; then printf '%s' "$SESSION_HOME"; return; fi
    local base
    for base in /data /code; do
        if [ -d "$base" ] && [ -w "$base" ]; then
            printf '%s/%s' "$base" "$(session_user)"; return
        fi
    done
    printf '%s' "$HOME"   # WSL / local: $HOME is already durable
}

# True when the PVC is actually mounted. A workspace started without it should
# degrade to an ephemeral session with a loud warning, not silently write a
# session's worth of state into a directory that dies with the pod.
session_home_is_durable() {
    # An explicit override is taken at its word: the caller knows where their
    # durable storage is mounted better than this heuristic does.
    [ -n "${SESSION_HOME:-}" ] && return 0
    local h; h="$(session_home)"
    case "$h" in /data/*|/code/*) [ -d "$(dirname "$h")" ] ;; *) return 1 ;; esac
}
