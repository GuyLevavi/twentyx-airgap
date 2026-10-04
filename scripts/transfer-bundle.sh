#!/usr/bin/env bash
# Transfer bundle: one flat directory with zstd transport twins for the big
# artifacts, everything that crosses the gap.
#
#   ./scripts/transfer-bundle.sh            # assembles/refreshes dist/
#
# Layout when done (flat -- SETUP.ps1/UNPACK.ps1 expect artifacts at the top):
#
#   dist/
#     README.md                        the page for other users
#     MANIFEST.txt                     versions + build identity (sourceable)
#     SHA256SUMS                       `sha256sum -c` compatible
#     nix-layer.tar.gz                 RunAI pod toolchain closure (plain)
#     nix-layer-nvim.tar.gz            same + nvim flavor
#     repo-layer.tar                   this repo's text layer
#     nixos-wsl.tar.gz                 the NixOS-WSL rootfs for wsl --import
#     wsl-rebuild.tar.gz               delta cache for an EXISTING distro
#     windows-kit-<zedVer>.tar.gz      Zed + VS Code + WSL2 MSI, themes,
#                                      client templates (extract on Windows)
#     twentyx-airgap.bundle            the repo as a git bundle (real history)
#     SETUP.ps1 / UNPACK.ps1           Windows one-shot / kit unpacker
#     setup-wsl.sh                     Linux-side one-shot (SETUP.ps1 runs it)
#     docs/                            user-facing docs
#
#   ...plus a .7z transport container around EVERY big artifact (both layers,
#   the kit, the WSL image, the rebuild delta): the transfer pipeline drops
#   big gzip and did not pass their zstd twins, but 7-Zip containers pass.
#   Unpacked with 7-Zip before use, transport only: the inner .tar.gz stays
#   byte-identical. dist IS the send set -- the plain twins are removed once
#   wrapped, and SHA256SUMS lists them for the far side, after the unpack.
#
# Generation consistency: the artifacts only work together (repo bundle at
# HEAD + image/delta from the same closure). dist/.complete is written LAST
# by a successful run; a dist without it is a partial set from an interrupted
# run and is wiped on the next start. Between runs, closure artifacts are
# guarded by derivation paths, not mtimes: dist/.wlldrv and dist/.layerdrv
# record what each was built from, so a closure change rebuilds exactly that
# artifact and a text-only commit rebuilds none. repo-layer.tar is the
# exception -- it is text and is rebuilt every run. The definitive reset is
# still one line:
#
#   rm -rf dist && ./scripts/transfer-bundle.sh
#
# A dirty worktree is refused (the bundle carries committed history only);
# ALLOW_DIRTY=1 is the escape hatch. Nothing needs root anywhere in this
# script: the NixOS-WSL tarball builder self-elevates via a user namespace
# and the output is owned by whoever runs it. SKIP_CACHE=1 skips the
# (deliberately always-run) delta export.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
OUT=dist
VERSION="$(cat VERSION)"
say() { printf '\033[36m==>\033[0m %s\n' "$*"; }

# ── 0. one generation or nothing ──────────────────────────────────────────
# A partial dist is worse than none: the bundle at HEAD with an image/delta
# from an older closure makes the far side's rebuild name store paths that
# exist nowhere, and Nix then tries to build (and fetch) them. .complete is
# written LAST by a successful run -- no marker means interrupted, wipe it.
# The marker is removed up front so THIS run can never inherit a stale one.
if [ -d "$OUT" ] && [ ! -f "$OUT/.complete" ] && [ -n "$(find "$OUT" -maxdepth 1 -type f ! -name '.*' -print -quit)" ]; then
    say "wiping partial $OUT (no .complete marker)"
    rm -rf "$OUT"
fi
rm -f "$OUT/.complete"
mkdir -p "$OUT"

# The bundle carries committed history; the scripts and docs are copied from
# the working tree. Mixing the two ships a set that cannot be reproduced from
# the bundle. Refuse it -- ALLOW_DIRTY=1 is the escape hatch.
if [ -n "$(git status --porcelain)" ] && [ -z "${ALLOW_DIRTY:-}" ]; then
    echo "error: working tree has uncommitted changes -- commit first" >&2
    echo "       (the bundle ships committed history only), or set ALLOW_DIRTY=1." >&2
    exit 1
fi

# ── 1. the RunAI layers ───────────────────────────────────────────────────
# Both flavors, rebuilt together when either closure changes. build-layers.sh
# builds in the default store and falls back to the chroot store (NOTES §9).
want_layers="$(nix eval --raw .#runai-layer.drvPath)
$(nix eval --raw .#runai-layer-nvim.drvPath)"
if [ ! -f "$OUT/nix-layer.tar.gz" ] || [ ! -f "$OUT/nix-layer-nvim.tar.gz" ] \
    || [ "$(cat "$OUT/.layerdrv" 2>/dev/null || true)" != "$want_layers" ]; then
    ./scripts/build-layers.sh "$OUT"
    printf '%s' "$want_layers" > "$OUT/.layerdrv"
fi
# repo-layer.tar is TEXT: it changes every commit (libexec/, agent/) and is
# NOT covered by the closure stamp above, so it is rebuilt every run rather
# than reusing what the last closure build left here. mklayer.sh is also what
# CI runs per commit, so the two shapes stay identical.
./docker/mklayer.sh "$OUT/repo-layer.tar" >/dev/null

# ── 2. the NixOS-WSL root tarball ─────────────────────────────────────────
# Two guards, because existence alone is not enough: the content probe (a
# healthy tarball always carries the init shim; a stale pre-activation one
# does not) and the drvPath stamp (a closure change must rebuild it even
# though the old file is a valid tarball).
#
# The `{ ... || true; }` group is load-bearing, the same SIGPIPE trap as
# libexec/run-opencode: `grep -m1 -q` exits on first match, tar dies of
# SIGPIPE (141), and pipefail turns a healthy probe into "stale" — which
# rebuilt the 1.3 GB tarball on every run. The guard absorbs the producer's
# 141; the decision stays with grep's own status.
want_wsl="$(nix eval --raw .#nixosConfigurations.wsl.config.system.build.toplevel.drvPath)"
if [ ! -f "$OUT/nixos-wsl.tar.gz" ] \
    || [ "$(cat "$OUT/.wlldrv" 2>/dev/null || true)" != "$want_wsl" ] \
    || ! { tar -tzf "$OUT/nixos-wsl.tar.gz" 2>/dev/null || true; } | grep -m1 -q '^\./bin/init$'; then
    rm -f "$OUT/nixos-wsl.tar.gz"
    say "building the NixOS-WSL tarball"
    # No --no-link here: the builder is invoked THROUGH ./result below, and a
    # stale result/ from an earlier build would ship the wrong system.
    nix build .#wsl-tarball
    # The builder self-elevates via a user namespace — no sudo, and the
    # output file is owned by the invoking user. -f in case the target
    # exists (stale or root-owned from older runs).
    ./result/bin/nixos-wsl-tarball-builder "$OUT/nixos-wsl.tar.gz"
    printf '%s' "$want_wsl" > "$OUT/.wlldrv"
fi

# ── 3. the offline rebuild delta ──────────────────────────────────────────
# ALWAYS regenerated: the earlier shape kept a stale one (it only rebuilt
# artifacts when missing), and a delta that lags the closure is worse than
# no delta — it makes a rolling update fail halfway. SKIP_CACHE=1 is the
# deliberate escape hatch; see export-rebuild-cache.sh for the root policy.
if [ -z "${SKIP_CACHE:-}" ]; then
    say "exporting the offline rebuild cache"
    ./scripts/export-rebuild-cache.sh
fi

# ── 4. the Windows kit ────────────────────────────────────────────────────
say "collecting the windows kit"
# One tar.gz: no bare .exe/.msi crosses the gap (email filters, USB scanners,
# transfer policies). Windows extracts it with its built-in tar.exe.
KIT="$(nix build .#windows-kit --no-link --print-out-paths)"
KITNAME="$(basename "$KIT")"
# Strip the store-hash prefix and copy FLAT: the old nested windows-kit/ dir
# is what made UNPACK.ps1's lookup half-work.
cp -f "$KIT" "$OUT/${KITNAME#*-}"

# ── 5. the user-facing docs + the short page ──────────────────────────────
# User-facing only: NOTES.md/TODO.md are machine-specific internals (store
# repair, cluster placeholders, next steps) and do not cross the gap.
say "carrying the documentation"
# Wiped first: a shipped copy from an older run must never survive (NOTES.md/
# TODO.md used to be in here), the same always-regenerate rule as README.md.
rm -rf "$OUT/docs"
mkdir -p "$OUT/docs"
cp README.md ARCHITECTURE.md MANUAL.md "$OUT/docs/"
# docs/ is shipped wholesale (INNER-CONFIG.md lives there); the per-tree
# readmes get flattened names so Windows tooling cannot trip on the tree.
cp docs/*.md "$OUT/docs/"
cp wsl/README.md "$OUT/docs/wsl-README.md"
cp wsl/FIRST-BOOT.md "$OUT/docs/wsl-FIRST-BOOT.md"
cp wsl/SMOKE-TEST.md "$OUT/docs/wsl-SMOKE-TEST.md"
# The pod image pipeline docs travel with the layers they describe.
mkdir -p "$OUT/docs/docker"
cp docker/README.md docker/BASE-IMAGES.md "$OUT/docs/docker/"

# The short page: a repo file, not a heredoc, so it is reviewable and
# diffable like everything else. Copied to dist/README.md so the folder and
# the carry tar open on instructions, not on a directory listing.
cp wsl/dist-readme.md "$OUT/README.md"

# ── 6. the one-shot setup scripts ─────────────────────────────────────────
# Idempotent and non-destructive: SETUP.ps1 drives the Windows side (import +
# UNPACK.ps1) and then setup-wsl.sh inside the distro (clone the bundle,
# import the cache, rebuild). See MANUAL.md.
say "carrying the setup scripts"
cp scripts/windows/UNPACK.ps1 scripts/windows/SETUP.ps1 scripts/setup-wsl.sh "$OUT/"

# ── 7. the repo itself, as a git bundle ───────────────────────────────────
# The WSL side clones this (`git clone /mnt/c/twentyx/twentyx-airgap.bundle`)
# and has the real history -- commits, diffs, bisect -- not a tar of the
# working tree. Committed state only, text only, a few hundred KB.
#
# --branches --tags, NOT --all: --all also walks refs/remotes and the
# per-worktree refs under .git/worktrees (a scratch worktree's detached HEAD
# shipped in the bundle that way), and neither belongs in a transfer.
say "bundling the repo"
git bundle create "$OUT/twentyx-airgap.bundle" --branches --tags >/dev/null

# ── 8. manifest + checksums ───────────────────────────────────────────────
# The manifest is shell-sourceable (setup-wsl.sh may use VSCODE_COMMIT etc.);
# the checksums are in a second file so `sha256sum -c SHA256SUMS` stays exact.
say "writing MANIFEST.txt + SHA256SUMS"
META="$(nix eval --json --impure --expr "$(cat <<'EXPR'
let
  f = builtins.getFlake (toString ./.);
  pkgs = import "${f.inputs.nixpkgs}" { };
  vscode = import (toString ./. + "/nix/vscode-version.nix") { inherit pkgs; };
in {
  opencode = pkgs.opencode.version;
  vscode = vscode.version;
  vscodeCommit = vscode.commit;
  zed = pkgs.zed-editor.version;
}
EXPR
)")"
{
    echo "# twentyx-airgap transfer manifest -- generated by scripts/transfer-bundle.sh"
    echo "# KEY=value lines are shell-sourceable; file hashes are in SHA256SUMS."
    echo "VERSION=$VERSION"
    echo "OPENCODE_VERSION=$(jq -r .opencode <<<"$META")"
    echo "VSCODE_VERSION=$(jq -r .vscode <<<"$META")"
    echo "VSCODE_COMMIT=$(jq -r .vscodeCommit <<<"$META")"
    echo "ZED_VERSION=$(jq -r .zed <<<"$META")"
    echo "NIXPKGS_REV=$(jq -r '.nodes.nixpkgs.locked.rev' flake.lock)"
    echo "GIT_REV=$(git rev-parse HEAD)"
    echo "GIT_BRANCH=$(git rev-parse --abbrev-ref HEAD)"
    echo "GIT_DIRTY=$([ -n "$(git status --porcelain)" ] && echo yes || echo no)"
    echo "BUILT_UTC=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
} > "$OUT/MANIFEST.txt"

# Everything except the stamps, the 7z transport containers (which wrap the
# files below, so hashing them is redundant and would make a re-run of this
# script hash its own outputs) and SHA256SUMS itself; hidden files are
# internal build stamps and do not ship.
(
    cd "$OUT"
    find . -type f ! -name '.*' ! -name SHA256SUMS ! -name '*.7z' -print0 \
        | sort -z | xargs -0 sha256sum
) > "$OUT/SHA256SUMS"

# ── 9. transport containers for the big artifacts ─────────────────────────
# Measured on the wire: the pipeline drops the big gzip files and did not
# pass their zstd twins either (including the 1.5 GB WSL image) -- but 7-Zip
# containers pass. Every big artifact gets one. Transport only: the inner
# .tar.gz stays byte-identical, so SHA256SUMS still verifies after the
# unpack. dist IS the send set -- the plain files are removed once wrapped.
say "wrapping the big artifacts for the transfer"
rm -f "$OUT"/twentyx-airgap-*.tar.gz
BIG=(
    "nix-layer.tar.gz"
    "nix-layer-nvim.tar.gz"
    "${KITNAME#*-}"
    "nixos-wsl.tar.gz"
    # Absent when SKIP_CACHE=1 skipped the delta export.
    "wsl-rebuild.tar.gz"
)
for f in "${BIG[@]}"; do
    [ -f "$OUT/$f" ] || continue
    nix shell nixpkgs#p7zip -c 7z a -bso0 -bsp0 -mx1 -mmt=on "$OUT/$f.7z" "$OUT/$f"
    say "  $f.7z ($(( $(stat -c %s "$OUT/$f.7z") / 1000000 )) MB)"
    rm -f "$OUT/$f"
done

# No file in dist may reach the 3072 MB/file transfer cap -- a future
# closure can outgrow a layer.
LIMIT_MB=3072
for f in "$OUT"/*; do
    [ -f "$f" ] || continue
    b="$(basename "$f")"
    case "$b" in .*) continue ;; esac
    size="$(( $(stat -c %s "$f") / 1000000 ))"
    if [ "$size" -ge "$LIMIT_MB" ]; then
        printf 'error: %s is %s MB, over the %s MB/file transfer cap -- split the payload\n' \
            "$b" "$size" "$LIMIT_MB" >&2
        exit 1
    fi
done

# ── 10. the bundle at a glance ────────────────────────────────────────────
cd "$OUT"
say "bundle contents:"
du -h ./* 2>/dev/null | sort -k2

# LAST: the set is complete and internally consistent. Anything that ships
# it looks for this marker first (step 0 wipes a dist that lacks it).
: > .complete
