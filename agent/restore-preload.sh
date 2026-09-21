#!/usr/bin/env bash
# Sourced by non-interactive bash (BASH_ENV, set by libexec/airgap-opencode).
#
# The opencode process runs with LD_PRELOAD neutralized (the RunAI GPU
# interceptors crash it), but every command the agent executes needs the
# original preload back or CUDA breaks. This restores the stash for any bash
# the shell.env plugin does not cover.
#
# No-op unless a stash exists, and idempotent under nesting.

if [ -n "${AIRGAP_ORIG_LD_PRELOAD:-}" ]; then
    export LD_PRELOAD="$AIRGAP_ORIG_LD_PRELOAD"
fi
