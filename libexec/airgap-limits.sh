#!/usr/bin/env bash
# Thread caps sized to the pod's CPU quota. Sourced, never executed: by the
# entrypoint (so code-server and everything under it inherit them) and by
# every bash, which is the login shell `runai exec` starts. fish carries a
# copy of the same few lines in nix/modules/shell.nix.
#
# Why: OpenMP, MKL, OpenBLAS and torch size their pools from the HOST's core
# count, not the cgroup's. A 16-CPU pod on a 128-core node gets 128 threads per
# process, then the same again in every worker. Every thread is a PID in the
# pids cgroup, and once pids.max is reached nothing can fork or spawn a thread,
# not even a shell: "Resource temporarily unavailable (os error 11)". Long
# before that, oversubscription is what makes CFS throttle the pod.
#
# Only fills what is unset, so an explicit `export OMP_NUM_THREADS=...` wins.
# AIRGAP_THREADS overrides the computed value for all of them at once.
#
# Fork-free on purpose: this runs when the pod may already be out of PIDs.

__airgap_quota_cpus() {
    local q p
    if [ -r /sys/fs/cgroup/cpu.max ]; then
        read -r q p < /sys/fs/cgroup/cpu.max || return 1
        [ "$q" = max ] && return 1
    elif [ -r /sys/fs/cgroup/cpu/cpu.cfs_quota_us ]; then
        read -r q < /sys/fs/cgroup/cpu/cpu.cfs_quota_us || return 1
        read -r p < /sys/fs/cgroup/cpu/cpu.cfs_period_us || return 1
        [ "$q" -gt 0 ] 2>/dev/null || return 1
    else
        return 1
    fi
    AIRGAP_CPUS=$(( (q + p - 1) / p ))
    [ "$AIRGAP_CPUS" -ge 1 ] || AIRGAP_CPUS=1
}

if [ -n "${AIRGAP_THREADS:-}" ] || __airgap_quota_cpus; then
    AIRGAP_CPUS="${AIRGAP_THREADS:-$AIRGAP_CPUS}"
    export AIRGAP_CPUS
    # GOMAXPROCS: Go only reads the cgroup quota itself from 1.25 on, and
    # binaries you did not build (the runai CLI) may be older.
    for __v in OMP_NUM_THREADS MKL_NUM_THREADS OPENBLAS_NUM_THREADS \
               NUMEXPR_NUM_THREADS NUMEXPR_MAX_THREADS RAYON_NUM_THREADS \
               GOMAXPROCS; do
        [ -n "${!__v:-}" ] || export "$__v=$AIRGAP_CPUS"
    done
    unset __v
fi
unset -f __airgap_quota_cpus

# Read pids.current and pids.max into AIRGAP_PIDS_CUR / AIRGAP_PIDS_MAX.
# Returns 1 when there is no pids controller or no limit.
# shellcheck disable=SC2034  # both globals are read by the caller
airgap_pids_usage() {
    local d
    for d in /sys/fs/cgroup /sys/fs/cgroup/pids; do
        [ -r "$d/pids.max" ] || continue
        read -r AIRGAP_PIDS_MAX < "$d/pids.max" || return 1
        read -r AIRGAP_PIDS_CUR < "$d/pids.current" || return 1
        [ "$AIRGAP_PIDS_MAX" != max ]
        return
    done
    return 1
}
