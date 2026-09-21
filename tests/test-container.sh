#!/usr/bin/env bash
# Container integration test: assemble the image exactly as CI does, then run
# it under a simulated OpenShift pod (arbitrary UID 10001, gid 0, tmpfs PVC,
# hostile LD_PRELOAD, ConfigMap-style env-injection mount) and assert the
# behaviors that broke before:
#
#   - $HOME relocation for an arbitrary UID (the runtime sets HOME=/)
#   - closure integrity after crane append
#   - the LD_PRELOAD split: hostile preloader kills the agent binary, the
#     launcher survives it, children get the original preload back
#   - packaged defaults seeding (opencode plugin, Zed settings)
#   - env-injection contract (pip.conf, ca-bundle.crt -> env vars)
#   - sudoers shipped, setuid sudo present
#   - repo-layer determinism
#
# Needs: podman, crane, jq, gcc, nix (or prebuilt layers via env). Runs on a
# connected machine; pulls ubuntu:24.04 once as the mock base.
#
#   ./tests/test-container.sh
#   AIRGAP_TEST_NIX_LAYER=/path/nix-layer.tar.gz ./tests/test-container.sh
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
. tests/lib.sh

# podman must come from the host; the rest can be pulled from nixpkgs on the
# fly, which keeps the test runnable outside a nix develop shell.
if ! command -v crane >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1 || ! command -v gcc >/dev/null 2>&1; then
    exec nix shell nixpkgs#go-containerregistry nixpkgs#jq nixpkgs#gcc -c bash "$0" "$@"
fi
need podman

REG_PORT="${AIRGAP_TEST_PORT:-5597}"
REG="127.0.0.1:$REG_PORT"
REG_NAME="airgap-test-registry-$$"
WORK="$(mktemp -d /tmp/airgap-test-XXXXXX)"
# Persistent throwaway store: first run pays the build, reruns are fast.
# Wipe it (rm -rf) if it ever looks wedged; it caches nothing but store paths.
TEST_STORE="${AIRGAP_TEST_STORE:-/tmp/airgap-test-store}"
# The throwaway nix chroot store (if used) is read-only; neutralize before rm.
# AIRGAP_TEST_KEEP=1 leaves the registry up for debugging (rm it by hand).
trap 'chmod -R u+w "$WORK" >/dev/null 2>&1; if [ -z "${AIRGAP_TEST_KEEP:-}" ]; then podman rm -f "$REG_NAME" >/dev/null 2>&1; fi; rm -rf "$WORK"' EXIT

say() { printf '\033[36m==>\033[0m %s\n' "$*"; }

# Assertions run commands as direct arguments -- no eval, no quoting hell.
# expect_ok <desc> <cmd...>
expect_ok() {
    local desc="$1"
    shift
    if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi
}
# expect_rc <expected-exit> <desc> <cmd...>
expect_rc() {
    local want="$1" desc="$2" got=0
    shift 2
    "$@" >/dev/null 2>&1 || got=$?
    if [ "$got" -eq "$want" ]; then ok "$desc"; else bad "$desc (exit $got, want $want)"; fi
}
# expect_grep <desc> <pattern> <cmd...>
# Captures first, greps second: grep -q closing the pipe early gives the
# writer SIGPIPE -> 141, which pipefail turns into a false negative.
expect_grep() {
    local desc="$1" pat="$2" out
    shift 2
    out="$("$@" 2>&1 || true)"
    if grep -q "$pat" <<<"$out"; then ok "$desc"; else bad "$desc"; fi
}

# ── registry + mock base ──────────────────────────────────────────────────
say "local registry on $REG"
podman run -d --name "$REG_NAME" -p "127.0.0.1:$REG_PORT:5000" \
    docker.io/library/registry:2 >/dev/null
for _ in $(seq 1 20); do
    curl -sf "http://$REG/v2/" >/dev/null 2>&1 && break
    sleep 0.5
done
curl -sf "http://$REG/v2/" >/dev/null || { echo "registry did not start" >&2; exit 1; }

say "mock base: ubuntu:24.04 -> $REG/base-slim"
podman pull -q docker.io/library/ubuntu:24.04 >/dev/null
podman push --tls-verify=false -q docker.io/library/ubuntu:24.04 "$REG/base-slim:latest" >/dev/null

# ── layers ────────────────────────────────────────────────────────────────
say "layers"
if [ -n "${AIRGAP_TEST_NIX_LAYER:-}" ]; then
    cp "${AIRGAP_TEST_NIX_LAYER:?}" "$WORK/nix-layer.tar.gz"
else
    # A chroot store prints logical /nix/store paths but materializes them
    # under its own root -- hence the "$TEST_STORE$P" copy source.
    P="$(nix build --store "$TEST_STORE" .#runai-layer --no-link --print-out-paths | tail -1)"
    cp "$TEST_STORE$P" "$WORK/nix-layer.tar.gz"
fi
AIRGAP_LAYER_NIX="$WORK/nix-layer.tar.gz" ./docker/mklayer.sh "$WORK/repo-layer.tar" >/dev/null

# Determinism: identical inputs -> byte-identical blob, or every rebuild
# invalidates the registry cache for nothing.
./docker/mklayer.sh "$WORK/repo-layer2.tar" >/dev/null
h1="$(sha256sum "$WORK/repo-layer.tar" | cut -d' ' -f1)"
h2="$(sha256sum "$WORK/repo-layer2.tar" | cut -d' ' -f1)"
if [ "$h1" = "$h2" ]; then ok "repo layer is deterministic"; else bad "repo layer is deterministic"; fi

# ── hostile preloader ─────────────────────────────────────────────────────
gcc -shared -fPIC -o "$WORK/hostile.so" tests/hostile-preloader.c

# ── env-injection mount (ConfigMap stand-in) ──────────────────────────────
mkdir -p "$WORK/env"
printf '[global]\nindex-url = https://artifactory.internal/api/pypi/pypi/simple\n' > "$WORK/env/pip.conf"
printf -- '-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n' > "$WORK/env/ca-bundle.crt"

say "assembling"
AIRGAP_REGISTRY="$REG" AIRGAP_BASE_REGISTRY="$REG" AIRGAP_VARIANTS="base-slim" \
    AIRGAP_LAYER_NIX="$WORK/nix-layer.tar.gz" AIRGAP_LAYER_REPO="$WORK/repo-layer.tar" \
    ./docker/assemble.sh test >/dev/null
IMAGE="$REG/workspace:test-base-slim"

# run_ic: the problematic pod shape, verbatim: arbitrary UID with no passwd
# entry, gid 0, writable PVC-style /data, extra mounts/env per caller.
# --pull=always: the tag is reused across runs; without this podman would
# silently run a cached image from before the layers changed.
run_ic() {
    podman run --rm --pull=always --tls-verify=false --user 10001:0 --tmpfs /data \
        -e AIRGAP_USER=jensen \
        --mount "type=bind,src=$WORK/hostile.so,dst=/tmp/hostile.so,ro" \
        --mount "type=bind,src=$WORK/env,dst=/opt/airgap-env,ro" \
        "$IMAGE" "$@"
}

say "pod simulation (uid 10001, gid 0)"
expect_ok "runtime HOME=/ is overridden with the PVC home" \
    run_ic bash -c 'test "$HOME" = /data/jensen'
DOCTOR_OUT="$(run_ic /opt/airgap/libexec/airgap-doctor 2>&1 || true)"
if grep -q "store paths present" <<<"$DOCTOR_OUT" && ! grep -q "absent:" <<<"$DOCTOR_OUT"; then
    ok "closure intact after crane append"
else
    bad "closure intact after crane append"
fi
if grep -q "defaults are linked" <<<"$DOCTOR_OUT"; then
    ok "defaults linked into PVC home"
else
    bad "defaults linked into PVC home"
fi

say "LD_PRELOAD split (hostile preloader)"
# The agent binary's own signal handlers may turn SIGABRT into SIGSEGV; any
# signal death (>= 128, and not podman's own 125) is a faithful repro.
repro_rc=0
run_ic bash -c 'LD_PRELOAD=/tmp/hostile.so /opt/airgap/profile/bin/opencode --version' >/dev/null 2>&1 || repro_rc=$?
if [ "$repro_rc" -ge 128 ] && [ "$repro_rc" -ne 125 ]; then
    ok "repro: hostile preloader kills the agent binary (exit $repro_rc)"
else
    bad "repro: hostile preloader kills the agent binary (exit $repro_rc)"
fi
expect_grep "launcher: opencode survives the hostile preloader" "[0-9]*\.[0-9]*" \
    run_ic -e LD_PRELOAD=/tmp/hostile.so -e AIRGAP_PRELOAD_PATTERN=hostile \
        bash -c '/opt/airgap/libexec/airgap-opencode --version'
expect_ok "children: BASH_ENV restores the original preload" \
    run_ic bash -c 'AIRGAP_ORIG_LD_PRELOAD=/tmp/hostile.so BASH_ENV=/opt/airgap/agent/restore-preload.sh /bin/bash -c "test \"\$LD_PRELOAD\" = /tmp/hostile.so"'

say "packaged defaults + env injection"
expect_ok "opencode preload plugin seeded" \
    run_ic bash -c 'test -f /data/jensen/.config/opencode/plugins/airgap-preload.ts'
expect_ok "zed agent_servers default seeded" \
    run_ic bash -c 'grep -q opencode /data/jensen/.config/zed/settings.json'
expect_ok "env injection: pip.conf wired" \
    run_ic bash -c 'test "$PIP_CONFIG_FILE" = /opt/airgap-env/pip.conf'
expect_ok "env injection: CA bundle wired" \
    run_ic bash -c 'test "$SSL_CERT_FILE" = /opt/airgap-env/ca-bundle.crt'
if grep -q "env injection" <<<"$DOCTOR_OUT" && grep -q "ca-bundle readable" <<<"$DOCTOR_OUT"; then
    ok "env injection: doctor reports the source"
else
    bad "env injection: doctor reports the source"
fi

say "root for the runtime user"
expect_ok "sudoers grants gid 0 passwordless sudo" \
    run_ic bash -c 'grep -q "%#0" /etc/sudoers'
expect_ok "setuid sudo binary present (4555)" \
    run_ic bash -c 'test "$(stat -c %a /opt/airgap/bin/sudo)" = 4555'
expect_ok "nginx present in the closure" \
    run_ic bash -c 'command -v nginx'

if summary; then exit 0; else exit 1; fi
