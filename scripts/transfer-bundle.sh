#!/usr/bin/env bash
# Transfer bundle: assemble the send set in dist/.
#
#   ./scripts/transfer-bundle.sh
#
# Two directories:
#   build/   plain artifacts, gitignored, kept between runs and guarded by
#            drvPath stamps so a text-only commit rebuilds nothing
#   dist/    the send set: every big artifact inside a .7z container, plus the
#            small text files (docs, setup scripts, repo bundle, MANIFEST,
#            SHA256SUMS)
#
# A closure change ships a small cumulative delta layer against the last full
# ("base") layer; the base is rebuilt only when missing, with SQUASH=1, or
# when the delta has outgrown half of it. The delta is valid only for the base
# in build/, which is the one published at the current VERSION.
#
# UPDATE=1 assembles an update-only bundle: the deltas, the WSL closure delta
# and the text, without the unchanged base layers, the NixOS-WSL root tarball
# or the Windows kit. It needs a prior full transfer (a machine with nothing
# installed still needs those), and it still carries the base when this run
# had to rebuild it.
#
# The pipeline drops big gzip (and rejected its zstd twins), so every big
# artifact crosses inside a 7z container: the inner file stays byte-identical,
# and 7-Zip unpacks it on the far side. A dirty worktree is refused (the
# bundle carries committed history only); ALLOW_DIRTY=1 is the escape hatch.
# The NixOS-WSL tarball is built by the upstream builder under sudo (it
# chroots and bind-mounts).
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
OUT=dist
BUILD=build
VERSION="$(cat VERSION)"
say() { printf '\033[36m==>\033[0m %s\n' "$*"; }

command -v 7z >/dev/null 2>&1 || {
    echo "error: 7z not found -- run inside 'nix develop'" >&2
    exit 1
}

# The bundle carries committed history; the scripts and docs are copied from
# the working tree. Mixing the two ships a set that cannot be reproduced from
# the bundle.
if [ -n "$(git status --porcelain)" ] && [ -z "${ALLOW_DIRTY:-}" ]; then
    echo "error: working tree has uncommitted changes -- commit first" >&2
    echo "       (the bundle ships committed history only), or set ALLOW_DIRTY=1." >&2
    exit 1
fi

# dist is the send set: wipe and rebuild it each run so nothing stale ships.
# build/ keeps the expensive artifacts; a stamp decides what to rebuild.
rm -rf "$OUT"
mkdir -p "$OUT" "$BUILD"

# ── 1. the RunAI layers ───────────────────────────────────────────────────
# A closure change ships a small cumulative delta against the last full
# ("base") layer; the base is rebuilt only when missing, with SQUASH=1, or
# when the delta has outgrown half of it. Store paths are immutable, so the
# delta is purely additive: new paths + the regenerated /opt tree.
want_layers="$(nix eval --raw .#runai-layer.drvPath)
$(nix eval --raw .#runai-layer-nvim.drvPath)"
base_stamp="$(cat "$BUILD/.layerdrv" 2>/dev/null || true)"
delta_stamp="$(cat "$BUILD/.layerdelta" 2>/dev/null || true)"
have_base=""
[ -f "$BUILD/nix-layer.tar.gz" ] && [ -f "$BUILD/nix-layer-nvim.tar.gz" ] && have_base=1
have_delta=""
[ -f "$BUILD/nix-layer-delta.tar.gz" ] && [ -f "$BUILD/nix-layer-delta-nvim.tar.gz" ] && have_delta=1
# Set when a base is (re)built this run: UPDATE mode must then carry it, or
# the delta would target a base the far side does not have.
layers_carried=""

if [ -z "$have_base" ] || [ -z "$base_stamp" ] || [ -n "${SQUASH:-}" ]; then
    say "building the base layers (full closure)"
    ./scripts/build-layers.sh --full "$BUILD" >/dev/null
    printf '%s' "$want_layers" > "$BUILD/.layerdrv"
    rm -f "$BUILD/nix-layer-delta.tar.gz" "$BUILD/nix-layer-delta-nvim.tar.gz" "$BUILD/.layerdelta"
    layers_carried=1
elif [ "$base_stamp" = "$want_layers" ]; then
    # The closure equals the base; no delta belongs beside it.
    rm -f "$BUILD/nix-layer-delta.tar.gz" "$BUILD/nix-layer-delta-nvim.tar.gz" "$BUILD/.layerdelta"
elif [ "$delta_stamp" = "$want_layers" ] && [ -n "$have_delta" ]; then
    say "reusing the built layer delta"
else
    say "closure changed -- building the delta layer"
    ./scripts/build-layers.sh --delta "$BUILD"
    if [ "$(( $(stat -c %s "$BUILD/nix-layer-delta.tar.gz") * 2 ))" \
        -ge "$(stat -c %s "$BUILD/nix-layer.tar.gz")" ]; then
        say "delta is over half the base (nixpkgs bump?) -- rebuilding the base"
        ./scripts/build-layers.sh --full "$BUILD" >/dev/null
        printf '%s' "$want_layers" > "$BUILD/.layerdrv"
        rm -f "$BUILD/nix-layer-delta.tar.gz" "$BUILD/nix-layer-delta-nvim.tar.gz" "$BUILD/.layerdelta"
        layers_carried=1
    else
        printf '%s' "$want_layers" > "$BUILD/.layerdelta"
    fi
fi
# repo-layer.tar is TEXT and changes every commit, so it is rebuilt every run.
LAYER_NIX="$BUILD/nix-layer.tar.gz" LAYER_NIX_DELTA="$BUILD/nix-layer-delta.tar.gz" \
    ./docker/mklayer.sh "$BUILD/repo-layer.tar" >/dev/null

# ── 2. the NixOS-WSL root tarball ─────────────────────────────────────────
# Stamped with .#wsl-tarball.drvPath, which covers the builder AND the
# toplevel it packs. UPDATE bundles skip it: an installed machine takes the
# closure delta, and a fresh install needs a full transfer anyway.
want_wsl="$(nix eval --raw .#wsl-tarball.drvPath)"
if [ -n "${UPDATE:-}" ]; then
    say "UPDATE: keeping the published NixOS-WSL root tarball (not in the bundle)"
elif [ ! -f "$BUILD/nixos-wsl.tar.gz" ] \
    || [ "$(cat "$BUILD/.wlldrv" 2>/dev/null || true)" != "$want_wsl" ]; then
    rm -f "$BUILD/nixos-wsl.tar.gz"
    say "building the NixOS-WSL tarball (upstream builder, under sudo)"
    nix build .#wsl-tarball
    # Real root is required: nixos-install chroots and bind-mounts. No
    # --chown: it runs BEFORE the install (it is for --extra-files) and would
    # fail on the not-yet-existing home; the activation script creates
    # /home/jensen as 1000:100 anyway (isNormalUser defaults createHome=true).
    sudo ./result/bin/nixos-wsl-tarball-builder "$BUILD/nixos-wsl.tar.gz"
    printf '%s' "$want_wsl" > "$BUILD/.wlldrv"
fi

# ── 3. the WSL closure delta ──────────────────────────────────────────────
# The appliance is updated by importing a store delta and switching the
# system profile -- nothing evaluates Nix inside the gap. The base is the
# last shipped system, kept as a GC root (.gcroots/wsl-system) so a garbage
# collection cannot delete it; without one (first transfer, or a far side
# older than the last shipment) the whole closure is exported.
NEW="$(nix build --no-link --print-out-paths .#nixosConfigurations.wsl.config.system.build.toplevel)"
BASE="$(readlink -f .gcroots/wsl-system 2>/dev/null || true)"
[ -e "$BASE" ] || BASE=""
# The stamp records what the NAR was exported from: NEW and the base used
# (empty = full export). Reusing a delta against a different base would ship
# a set the far side cannot import.
want_stamp="$NEW
$BASE"
if [ -f "$BUILD/wsl-update.nar" ] \
    && [ "$(cat "$BUILD/.updatestamp" 2>/dev/null || true)" = "$want_stamp" ]; then
    say "reusing the exported closure delta"
else
    rm -f "$BUILD/wsl-update.nar"
    if [ -n "$BASE" ]; then
        comm -13 <(nix-store -qR "$BASE" | sort) <(nix-store -qR "$NEW" | sort) \
            > "$BUILD/.delta-paths"
        if [ -s "$BUILD/.delta-paths" ]; then
            xargs -r nix-store --export < "$BUILD/.delta-paths" > "$BUILD/wsl-update.nar"
        else
            say "closure unchanged since the last shipment -- no delta"
        fi
        rm -f "$BUILD/.delta-paths"
    else
        nix-store -qR "$NEW" | xargs -r nix-store --export > "$BUILD/wsl-update.nar"
    fi
    printf '%s\n%s\n' "$NEW" "$BASE" > "$BUILD/.updatestamp"
fi
# Only now: a GC root that outruns a failed export would make the next delta
# against a base the far side never received.
mkdir -p .gcroots
nix-store --add-root .gcroots/wsl-system --indirect -r "$NEW" >/dev/null

# ── 4. the Windows kit ────────────────────────────────────────────────────
# One tar.gz: no bare .exe/.msi crosses the gap. Windows extracts it with its
# built-in tar.exe; UNPACK.ps1 does the rest.
say "collecting the windows kit"
KIT="$(nix build .#windows-kit --no-link --print-out-paths)"
KITNAME="$(basename "$KIT")"
KITB="${KITNAME#*-}"
if [ -n "${UPDATE:-}" ]; then
    # MANIFEST still names it for SETUP.ps1's registry fetch.
    say "UPDATE: kit stays as published ($KITB)"
else
    cp -f "$KIT" "$BUILD/$KITB"
fi

# ── 5. the docs + setup scripts ───────────────────────────────────────────
say "carrying the documentation"
mkdir -p "$OUT/docs"
cp README.md ARCHITECTURE.md MANUAL.md "$OUT/docs/"
# The folder opens on instructions, not on a directory listing.
cp README.md "$OUT/README.md"
say "carrying the setup scripts"
cp scripts/windows/UNPACK.ps1 scripts/windows/SETUP.ps1 scripts/setup-wsl.sh "$OUT/"
# The internal CA travels plain when env/ has it: setup-wsl.sh stages it into
# the distro, and SETUP.ps1 pins its own registry fetches with it on a
# Windows machine that does not trust it yet.
if [ -f env/ca-bundle.crt ]; then
    cp env/ca-bundle.crt "$OUT/"
    say "  ca-bundle.crt (distro staging + Windows fetch trust)"
fi
# The text layer travels plain: setup-wsl.sh overlays it onto the distro on
# the first install and on every text-only update.
cp "$BUILD/repo-layer.tar" "$OUT/"

# ── 6. the repo itself, as a git bundle ───────────────────────────────────
# The real history -- commits, diffs, bisect -- not a tar of the working tree.
# --branches --tags, NOT --all: --all also walks refs/remotes and the
# per-worktree refs, and neither belongs in a transfer.
say "bundling the repo"
git bundle create "$OUT/twentyx-airgap.bundle" --branches --tags >/dev/null

# ── 7. transport containers ───────────────────────────────────────────────
# The deltas always go; the base layers only when this run built them (or on
# a full transfer), the root tarball/kit never in an UPDATE bundle. nullglob
# drops what is not there.
say "wrapping the big artifacts"
ABS_OUT="$(pwd)/$OUT"
ARTIFACTS=("$BUILD"/nix-layer-delta.tar.gz "$BUILD"/nix-layer-delta-nvim.tar.gz
    "$BUILD"/wsl-update.nar)
if [ -z "${UPDATE:-}" ] || [ -n "$layers_carried" ]; then
    ARTIFACTS+=("$BUILD"/nix-layer.tar.gz "$BUILD"/nix-layer-nvim.tar.gz)
fi
if [ -z "${UPDATE:-}" ]; then
    ARTIFACTS+=("$BUILD"/windows-kit-*.tar.gz "$BUILD"/nixos-wsl.tar.gz)
fi
shopt -s nullglob
for f in "${ARTIFACTS[@]}"; do
    b="$(basename "$f")"
    # The .tar.gz members are already compressed (-mx1 just stores); the NAR
    # is raw and compresses well.
    case "$b" in *.nar) mx=5 ;; *) mx=1 ;; esac
    # cd first: 7z stores the path as given, so archiving "$BUILD/$b" records
    # "build/<file>" and extracting in the transfer folder would nest it.
    ( cd "$BUILD" && 7z a -bso0 -bsp0 "-mx=$mx" -mmt=on "$ABS_OUT/$b.7z" "$b" )
    say "  $b.7z ($(( $(stat -c %s "$OUT/$b.7z") / 1000000 )) MB)"
done

# ── 8. manifest + checksums ───────────────────────────────────────────────
say "writing MANIFEST.txt + SHA256SUMS"
{
    echo "# twentyx-airgap transfer manifest -- generated by scripts/transfer-bundle.sh"
    echo "# KEY=value lines are shell-sourceable; small-file hashes are in SHA256SUMS."
    echo "VERSION=$VERSION"
    echo "GIT_REV=$(git rev-parse HEAD)"
    echo "WSL_SYSTEM=$NEW"
    echo "WSL_BASE=$BASE"
    echo "WINDOWS_KIT=$KITB"
    echo "NIXPKGS_REV=$(jq -r '.nodes.nixpkgs.locked.rev' flake.lock)"
} > "$OUT/MANIFEST.txt"

# Small files only: the 7z containers carry CRCs and the store is
# content-addressed, so hashing multi-GB artifacts adds nothing.
(
    cd "$OUT"
    find . -type f ! -name '*.7z' ! -name SHA256SUMS -print0 \
        | sort -z | xargs -0 sha256sum
) > "$OUT/SHA256SUMS"

# ── 9. cap check + listing ────────────────────────────────────────────────
# No file in dist may reach the 3072 MB/file transfer cap.
LIMIT_MB=3072
for f in "$OUT"/*; do
    [ -f "$f" ] || continue
    b="$(basename "$f")"
    size="$(( $(stat -c %s "$f") / 1000000 ))"
    if [ "$size" -ge "$LIMIT_MB" ]; then
        printf 'error: %s is %s MB, over the %s MB/file transfer cap -- split the payload\n' \
            "$b" "$size" "$LIMIT_MB" >&2
        exit 1
    fi
done

cd "$OUT"
say "bundle contents:"
du -h ./* 2>/dev/null | sort -k2
