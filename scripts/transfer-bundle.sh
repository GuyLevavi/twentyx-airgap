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
#   ...plus a transport twin of the big artifacts: .zst for both nix layers
#   and the Windows kit, .7z for the WSL image (the pipeline drops big gzip
#   and did not pass even its zstd twin). Unpacked with 7-Zip before use,
#   transport only: the inner .tar.gz stays byte-identical. dist IS the send
#   set -- the plain twins are removed once wrapped, and SHA256SUMS lists
#   them for the far side, after the unpack.
#
# Staleness is guarded by derivation paths, not mtimes: dist/.wlldrv and
# dist/.layerdrv record what each big artifact was built from, so a closure
# change rebuilds exactly that artifact and a text-only commit rebuilds none.
# The definitive reset is still one line:
#
#   rm -rf dist && ./scripts/transfer-bundle.sh
#
# Nothing needs root anywhere in this script: the NixOS-WSL tarball builder
# self-elevates via a user namespace and the output is owned by whoever runs
# it. SKIP_CACHE=1 skips the (deliberately always-run) delta export.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
OUT=dist
VERSION="$(cat VERSION)"
say() { printf '\033[36m==>\033[0m %s\n' "$*"; }
mkdir -p "$OUT"

# ── 1. the RunAI layers ───────────────────────────────────────────────────
# Both flavors, rebuilt together when either closure changes. build-layers.sh
# builds in the persistent chroot store when it exists (NOTES.md §9).
want_layers="$(nix eval --raw .#runai-layer.drvPath)
$(nix eval --raw .#runai-layer-nvim.drvPath)"
if [ ! -f "$OUT/nix-layer.tar.gz" ] || [ ! -f "$OUT/nix-layer-nvim.tar.gz" ] \
    || [ "$(cat "$OUT/.layerdrv" 2>/dev/null || true)" != "$want_layers" ]; then
    ./scripts/build-layers.sh "$OUT"
    printf '%s' "$want_layers" > "$OUT/.layerdrv"
fi

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

# Everything except the stamps, the zstd transport twins (which wrap the
# files below, so hashing them is redundant and would make a re-run of this
# script hash its own outputs) and SHA256SUMS itself; hidden files are
# internal build stamps and do not ship.
(
    cd "$OUT"
    find . -type f ! -name '.*' ! -name SHA256SUMS ! -name '*.zst' ! -name '*.7z' -print0 \
        | sort -z | xargs -0 sha256sum
) > "$OUT/SHA256SUMS"

# ── 9. transport twins for the big artifacts ──────────────────────────────
# Measured on the wire: the pipeline drops the big gzip files, passes zstd,
# and did NOT pass the 1.5 GB WSL image even as zstd -- but 7-Zip containers
# passed. So the layers and the kit get a .zst twin, the WSL image a .7z
# one. Transport only: the inner .tar.gz stays byte-identical. dist IS the
# send set -- the plain twins are removed once wrapped, and SHA256SUMS
# lists them for the far side, after the unpack.
say "wrapping the big artifacts for the transfer"
rm -f "$OUT"/twentyx-airgap-*.tar.gz
ZST=("nix-layer.tar.gz" "nix-layer-nvim.tar.gz" "${KITNAME#*-}")
SEVENZ=("nixos-wsl.tar.gz")
for f in "${ZST[@]}"; do
    nix shell nixpkgs#zstd -c zstd -3 -T0 -q -f "$OUT/$f" -o "$OUT/$f.zst"
    say "  $f.zst ($(( $(stat -c %s "$OUT/$f.zst") / 1000000 )) MB)"
    rm -f "$OUT/$f"
done
for f in "${SEVENZ[@]}"; do
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
