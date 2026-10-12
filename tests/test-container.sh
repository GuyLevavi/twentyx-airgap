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
#   TEST_STORE_DIR=<extracted dist/> ./tests/test-container.sh   (a real release)
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
. tests/lib.sh

# podman must come from the host; the rest can be pulled from nixpkgs on the
# fly, which keeps the test runnable outside a nix develop shell.
if ! command -v crane >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1 || ! command -v gcc >/dev/null 2>&1; then
    exec nix shell nixpkgs#go-containerregistry nixpkgs#jq nixpkgs#gcc -c bash "$0" "$@"
fi
need podman

REG_PORT="${TEST_REGISTRY_PORT:-5597}"
REG="127.0.0.1:$REG_PORT"
REG_NAME="test-registry-$$"
WORK="$(mktemp -d /tmp/test-XXXXXX)"
# TEST_KEEP=1 leaves the registry up for debugging (rm it by hand).
trap 'chmod -R u+w "$WORK" >/dev/null 2>&1; if [ -z "${TEST_KEEP:-}" ]; then podman rm -f "$REG_NAME" >/dev/null 2>&1; fi; rm -rf "$WORK"' EXIT

say() { printf '\033[36m==>\033[0m %s\n' "$*"; }

# Assertions run commands as direct arguments -- no eval, no quoting hell.
# expect_ok <desc> <cmd...>
expect_ok() {
    local desc="$1"
    shift
    if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi
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
podman pull -q docker.io/library/ubuntu:24.04
podman push --tls-verify=false -q docker.io/library/ubuntu:24.04 "$REG/base-slim:latest"

# ── layers ────────────────────────────────────────────────────────────────
say "layers"
# A store release directory, as CI sees it: MANIFEST.txt + pod tars. Without
# TEST_STORE_DIR, a full release of this checkout (what --rebase ships).
STORE="$WORK/store"
mkdir -p "$STORE"
if [ -n "${TEST_STORE_DIR:-}" ]; then
    cp "${TEST_STORE_DIR:?}"/MANIFEST.txt "${TEST_STORE_DIR}"/pod-*.tar.gz "$STORE/"
else
    OPT="$(nix build .#pod-opt --no-link --print-out-paths)"
    ./scripts/pod-tar.sh "$OPT" "$OPT/opt/twentyx/store-paths" "$STORE/pod-full.tar.gz"
    printf 'RELEASE=test\nBASE_RELEASE=test\nKIND=full\n' > "$STORE/MANIFEST.txt"
    # The layer is deterministic too: the registry dedupes it across rebuilds.
    ./scripts/pod-tar.sh "$OPT" "$OPT/opt/twentyx/store-paths" "$WORK/pod-full2.tar.gz"
    if cmp -s "$STORE/pod-full.tar.gz" "$WORK/pod-full2.tar.gz"; then
        ok "store layer is deterministic"
    else
        bad "store layer is deterministic"
    fi
    rm -f "$WORK/pod-full2.tar.gz"
fi
RELEASE="$(sed -n 's/^RELEASE=//p' "$STORE/MANIFEST.txt")"
KIND="$(sed -n 's/^KIND=//p' "$STORE/MANIFEST.txt")"
./docker/mklayer.sh "$WORK/repo-layer.tar" >/dev/null

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
asm() {
    env IMAGE_REGISTRY="$REG" BASE_REGISTRY="$REG" IMAGE_VARIANTS="base-slim" \
        STORE_DIR="$STORE" STORE_RELEASE="$RELEASE" LAYER_REPO="$WORK/repo-layer.tar" \
        ./docker/assemble.sh "$@"
}
asm test
IMAGE="$REG/workspace:test-base-slim"

# A config commit must not need the store layers: the store image for this
# release and base is reused, so CI downloads nothing big.
mkdir -p "$WORK/held"
mv "$STORE"/pod-*.tar.gz "$WORK/held/"
if asm test2 >/dev/null 2>&1; then
    ok "second commit reuses the store image (no store layers needed)"
else
    bad "second commit reuses the store image (no store layers needed)"
fi
mv "$WORK/held"/pod-*.tar.gz "$STORE/"

# run_ic: the problematic pod shape, verbatim: arbitrary UID with no passwd
# entry, gid 0, writable PVC-style /data, extra mounts/env per caller.
# --pull=always: the tag is reused across runs; without this podman would
# silently run a cached image from before the layers changed.
run_ic() {
    podman run --rm --pull=always --tls-verify=false --user 10001:0 --tmpfs /data \
        -e SESSION_USER=jensen \
        --mount "type=bind,src=$WORK/hostile.so,dst=/tmp/hostile.so,ro" \
        --mount "type=bind,src=$WORK/env,dst=/opt/airgap-env,ro" \
        "$IMAGE" "$@"
}

say "pod simulation (uid 10001, gid 0)"
# Warm the pull once; every run_ic after this reuses podman's layer cache.
podman pull -q --tls-verify=false "$IMAGE"
expect_ok "runtime HOME=/ is overridden with the PVC home" \
    run_ic bash -c 'test "$HOME" = /data/jensen'
DOCTOR_OUT="$(run_ic /opt/twentyx/libexec/doctor 2>&1 || true)"
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
# Image ENV names store paths outside the profile (locales, terminfo, the
# LazyVim tree); each must have shipped, or ENV points into nothing.
expect_ok "every store path in session-env is in the image" \
    run_ic bash -c 'for p in $(grep -o "/nix/store/[^/:]*" /opt/twentyx/session-env); do [ -e "$p" ] || exit 1; done'
# BASE_ENTRYPOINT carries the base's ENTRYPOINT + CMD. A CMD left in the image
# would arrive as our entrypoint's arguments and run instead of the base's
# ENTRYPOINT (code-server on the vscode-* bases).
expect_grep "image CMD is cleared (BASE_ENTRYPOINT hands over)" '^null$' \
    bash -c "crane config '$IMAGE' | jq -c '.config.Cmd'"
if [ "$KIND" = delta ]; then
    # The delta's opt/ tree must win: the merged /opt/twentyx/profile has to
    # be the one the delta carries, not the full layer's.
    want_profile="$(LC_ALL=C tar -tzvf "$STORE/pod-delta.tar.gz" \
        --occurrence=1 opt/twentyx/profile | awk '{print $NF}')"
    expect_ok "delta profile symlink wins over the base" \
        run_ic bash -c "[ \"\$(readlink /opt/twentyx/profile)\" = '$want_profile' ]"
fi

say "LD_PRELOAD split (hostile preloader)"
# The agent binary's own signal handlers may turn SIGABRT into SIGSEGV; any
# signal death (>= 128, and not podman's own 125) is a faithful repro.
repro_rc=0
run_ic bash -c 'LD_PRELOAD=/tmp/hostile.so /opt/twentyx/profile/bin/opencode --version' >/dev/null 2>&1 || repro_rc=$?
if [ "$repro_rc" -ge 128 ] && [ "$repro_rc" -ne 125 ]; then
    ok "repro: hostile preloader kills the agent binary (exit $repro_rc)"
else
    bad "repro: hostile preloader kills the agent binary (exit $repro_rc)"
fi
expect_grep "launcher: opencode survives the hostile preloader" "[0-9]*\.[0-9]*" \
    run_ic -e LD_PRELOAD=/tmp/hostile.so -e PRELOAD_PATTERN=hostile \
        bash -c '/opt/twentyx/libexec/run-opencode --version'
expect_ok "children: BASH_ENV restores the original preload" \
    run_ic bash -c 'PRELOAD_ORIGINAL=/tmp/hostile.so BASH_ENV=/opt/twentyx/agent/restore-preload.sh /bin/bash -c "test \"\$LD_PRELOAD\" = /tmp/hostile.so"'

say "bun-compiled agent binary (kernel<=6.6 layout)"
# The first WSL session's `SIGSEGV (address bounding error)`: nixpkgs'
# patchelf'd bun template makes `bun build --compile` list the highest-vaddr
# PT_LOAD first, so Linux <= 6.6 never maps the BSS and ld.so dies before
# main. postFixup reorders (nix/scripts/fix-phdr-order.py); this asserts the
# shipped binary, and pipefail makes a missing readelf a failure, not a pass.
expect_ok "opencode PT_LOADs are address-ascending" \
    run_ic bash -c 'set -o pipefail; prev=; readelf -lW /opt/twentyx/profile/bin/.opencode-wrapped | while read -r t rest; do
        [ "$t" = LOAD ] || continue; set -- $rest; v=$(( $2 ));
        [ -n "$prev" ] && [ "$v" -lt "$prev" ] && exit 1; prev=$v;
    done'

say "packaged defaults + dotfiles + env injection"
# Defaults are ours: store symlinks, refreshed every start.
expect_ok "opencode preload plugin linked from the store" \
    run_ic bash -c 'test -L /data/jensen/.config/opencode/plugins/preload.ts'
expect_ok "code-server opencode extension linked from the store" \
    run_ic bash -c 'test -L /data/jensen/.local/share/code-server/extensions/sst-dev.opencode'
# Dotfiles are ours: symlinks into the toolchain tree, so a text-layer update
# renews them with no reseed.
expect_ok "fish config linked into the toolchain tree" \
    run_ic bash -c 'd=/data/jensen/.config/fish/config.fish; test -L "$d" && [ "$(readlink "$d")" = /opt/twentyx/dotfiles/.config/fish/config.fish ]'
expect_ok "zed settings linked into the toolchain tree" \
    run_ic bash -c 'd=/data/jensen/.config/zed/settings.json; test -L "$d" && [ "$(readlink "$d")" = /opt/twentyx/dotfiles/.config/zed/settings.json ]'
# Migration: an unmodified real copy becomes a link, an edited one stays.
expect_ok "unmodified real copy is adopted as a symlink" \
    run_ic bash -c 'd=/data/jensen/.config/tmux/tmux.conf; rm -f "$d"; cp /opt/twentyx/dotfiles/.config/tmux/tmux.conf "$d"; /opt/twentyx/libexec/seed-home >/dev/null 2>&1; [ -L "$d" ]'
expect_ok "edited real copy is left alone" \
    run_ic bash -c 'd=/data/jensen/.config/btop/btop.conf; rm -f "$d"; { cat /opt/twentyx/dotfiles/.config/btop/btop.conf; echo "# mine"; } > "$d"; /opt/twentyx/libexec/seed-home >/dev/null 2>&1; [ -f "$d" ] && [ ! -L "$d" ]'
expect_ok "zed agent_servers default seeded" \
    run_ic bash -c 'grep -q opencode /data/jensen/.config/zed/settings.json'
# The pins are stable /opt paths now: a store path here would go stale on the
# next transfer.
expect_ok "zed LSP pins point at the stable tool path" \
    run_ic bash -c 'grep -q "/opt/twentyx/profile/bin/nixd" /data/jensen/.config/zed/settings.json'
expect_ok "zed remote server shipped as a packaged default" \
    run_ic bash -c 'ls /data/jensen/.zed_server | grep -q zed-remote-server'
expect_ok "zed remote client-version shim shipped (full-version spelling)" \
    run_ic bash -c 'f=/data/jensen/.zed_server/zed-remote-server-stable-*+stable.*; [ -x $f ]'
expect_ok "env injection: pip.conf wired" \
    run_ic bash -c 'test "$PIP_CONFIG_FILE" = /opt/airgap-env/pip.conf'
expect_ok "env injection: CA bundle wired" \
    run_ic bash -c 'test "$SSL_CERT_FILE" = /opt/airgap-env/ca-bundle.crt'
if grep -q "env injection" <<<"$DOCTOR_OUT" && grep -q "ca-bundle readable" <<<"$DOCTOR_OUT"; then
    ok "env injection: doctor reports the source"
else
    bad "env injection: doctor reports the source"
fi

say "bootstrap env + fish config"
# The seeded fish config must PARSE: an earlier revision embedded a bash
# heredoc inside a generated drop-in, fish refused the whole file and no PATH
# or env var reached the interactive shell.
expect_ok "seeded fish config parses (fish -n)" \
    run_ic bash -c 'fish -n /data/jensen/.config/fish/config.fish'
expect_ok "runtime env generated outside \$HOME" \
    run_ic bash -c 'fish -n /opt/twentyx/etc/env.fish'
expect_grep "podman storage.conf written (vfs)" 'driver = "vfs"' \
    run_ic bash -c 'cat /tmp/twentyx-cache-$(id -u)/containers/storage.conf'

say "root for the runtime user"
expect_ok "sudoers grants gid 0 passwordless sudo" \
    run_ic bash -c 'grep -q "%#0" /etc/sudoers'
expect_ok "setuid sudo binary present (4555)" \
    run_ic bash -c 'test "$(stat -c %a /opt/twentyx/bin/sudo)" = 4555'
expect_ok "nginx present in the closure" \
    run_ic bash -c 'command -v nginx'

if summary; then exit 0; else exit 1; fi
