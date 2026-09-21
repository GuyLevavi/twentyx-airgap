# shellcheck shell=bash

# Shared helpers for tests/. Sourced, never executed. Not part of the image.
# Tests run on a CONNECTED machine (they pull the mock base from docker.io);
# the container they exercise is offline by construction.

PASS=0
FAIL=0

ok()  { printf '  \033[32mok\033[0m   %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

# check "description" 'shell command'
check() {
    if eval "$2" >/dev/null 2>&1; then
        ok "$1"
    else
        bad "$1"
    fi
}

summary() {
    printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
    [ "$FAIL" -eq 0 ]
}

need() {
    command -v "$1" >/dev/null 2>&1 ||
        { printf '%s: need %s -- see AGENTS.md "Verification"\n' "$0" "$1" >&2; exit 2; }
}
