#!/usr/bin/env bash
# Transfer bundle: one directory, everything that crosses the gap.
#
#   ./scripts/transfer-bundle.sh            # assembles/refreshes dist/
#
# Layout when done:
#
#   dist/
#     nix-layer.tar.gz                  RunAI pod toolchain closure (plain)
#     nix-layer-nvim.tar.gz             same + nvim flavor
#     repo-layer.tar                    this repo's text layer
#     nixos-wsl.tar.gz                  the NixOS-WSL rootfs for wsl --import
#     windows-kit/windows-kit-*.tar.gz  one archive: Zed + WSL2 MSI, themes,
#                                       client templates (Zed settings, WezTerm)
#     twentyx-airgap.bundle             the repo as a git bundle: the WSL side
#                                       clones it and has the real history
#     UNPACK.ps1 / setup-wsl.sh         one-shot, idempotent setup: Windows
#                                       side / inside the distro as root
#     docs/                             user-facing docs (README, ARCHITECTURE,
#                                       MANUAL, wsl/*, docker/*)
#     START-HERE.txt                    the short page for other users
#
# Nothing needs root anywhere in this script: the NixOS-WSL tarball builder
# self-elevates via a user namespace and the output is owned by whoever runs
# it.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
OUT=dist
mkdir -p "$OUT"

say() { printf '\033[36m==>\033[0m %s\n' "$*"; }

# ── 1. the RunAI layers ───────────────────────────────────────────────────
if [ ! -f "$OUT/nix-layer.tar.gz" ]; then
    ./scripts/build-layers.sh "$OUT"
fi

# ── 2. the NixOS-WSL root tarball ─────────────────────────────────────────
# An existing tarball is not enough: if it predates a builder change it
# must be rebuilt. The content probe is the guard — a healthy tarball
# always carries the init shim; a stale one (pre-activation) does not.
#
# The `{ ... || true; }` group is load-bearing, the same SIGPIPE trap as
# libexec/run-opencode: `grep -m1 -q` exits on first match, tar dies of
# SIGPIPE (141), and pipefail turns a healthy probe into "stale" — which
# rebuilt the 1.1 GB tarball on every run. The guard absorbs the producer's
# 141; the decision stays with grep's own status.
if [ ! -f "$OUT/nixos-wsl.tar.gz" ] || ! { tar -tzf "$OUT/nixos-wsl.tar.gz" 2>/dev/null || true; } | grep -m1 -q '^\./bin/init$'; then
    rm -f "$OUT/nixos-wsl.tar.gz"
    say "building the NixOS-WSL tarball"
    # No --no-link here: the builder is invoked THROUGH ./result below, and a
    # stale result/ from an earlier build would ship the wrong system.
    nix build .#wsl-tarball
    # The builder self-elevates via a user namespace — no sudo, and the
    # output file is owned by the invoking user. -f in case the target
    # exists (stale or root-owned from older runs).
    ./result/bin/nixos-wsl-tarball-builder "$OUT/nixos-wsl.tar.gz"
fi

# ── 3. the Windows kit ────────────────────────────────────────────────────
say "collecting the windows kit"
# One tar.gz: no bare .exe/.msi crosses the gap (email filters, USB scanners,
# transfer policies). Windows extracts it with its built-in tar.exe.
KIT="$(nix build .#windows-kit --no-link --print-out-paths)"
mkdir -p "$OUT/windows-kit"
# strip the store-hash prefix: ship it as a clean windows-kit-<ver>.tar.gz
KITNAME="$(basename "$KIT")"
cp -f "$KIT" "$OUT/windows-kit/${KITNAME#*-}"

# ── 4. the user-facing docs + the short one ───────────────────────────────
# User-facing only: NOTES.md/TODO.md are machine-specific internals (store
# repair, cluster placeholders, next steps) and do not cross the gap.
say "carrying the documentation"
mkdir -p "$OUT/docs"
cp README.md ARCHITECTURE.md MANUAL.md "$OUT/docs/"
# The wsl/ tree is part of the WSL story; the pod tree gets its own.
cp wsl/README.md "$OUT/docs/wsl-README.md"
cp wsl/FIRST-BOOT.md "$OUT/docs/wsl-FIRST-BOOT.md"
cp wsl/SMOKE-TEST.md "$OUT/docs/wsl-SMOKE-TEST.md"
# The pod image pipeline docs travel with the layers they describe.
mkdir -p "$OUT/docs/docker"
cp docker/README.md docker/BASE-IMAGES.md "$OUT/docs/docker/"

# Always regenerated: a shipped copy from an older run must never survive an
# image/doc change. `if [ ! -f ]` here shipped stale instructions forever.
cat > "$OUT/START-HERE.txt" <<'EOF'
START HERE — the airgap toolchain, in one page
==============================================

What you got: a Linux workstation (NixOS inside WSL2) and the pod image
for the RunAI GPU cluster, built to work with the network unplugged.
Nothing in here downloads anything at runtime — everything needed was
pinned and verified before crossing the gap.

────────────────────────────────────────────────────────────────────
FRESH START  (recommended — this folder is a complete, current bundle)
────────────────────────────────────────────────────────────────────

Everything below assumes C:\twentyx. A fresh import WIPES the old distro's
home — that is the point: the packaged defaults (Zed LSP pins, btop theme,
WezTerm/kit settings) get applied cleanly instead of being shadowed by
half-configured leftovers.

PowerShell (Administrator):

  wsl --unregister twentyx
  wsl --import twentyx C:\wsl\nixos nixos-wsl.tar.gz --version 2
  wsl -d twentyx --cd /

Two idempotent scripts do the mechanical parts (neither overwrites a
personal file; details in docs\MANUAL.md):

  # Windows side: extract the kit, install Zed themes + client templates
  powershell -ExecutionPolicy Bypass -File C:\twentyx\UNPACK.ps1

  # Linux side, as root: clone the repo bundle into /home/jensen, import the
  # offline rebuild cache, run the first nixos-rebuild (a no-op switch)
  wsl -d twentyx -u root -- bash /mnt/c/twentyx/setup-wsl.sh

Verify the repo landed (inside, as jensen):

  cd ~/twentyx-airgap && git log --oneline -3

Windows-side installs (windows-kit\windows-kit\, if UNPACK.ps1 did not):
  Zed-x86_64-*-setup.exe     pinned to the closure's remote server
  themes\*.json              copy into %APPDATA%\Zed\themes\
  zed-client-settings.json   copy/merge into %APPDATA%\Zed\settings.json
  wezterm.lua                copy to %USERPROFILE%\.wezterm.lua
  wsl.*.x64.msi              only if WSL2 is missing (DISM lines + reboot)
  (VS Code is NOT in the kit any more — Zed's WSL remote covers editing;
   removing it cut ~500 MB from the image and ~220 MB from the kit.)

EVERYDAY LOOP (after the one-time steps):

  # edit/commit in ~/twentyx-airgap — the flake reads the GIT TREE, so
  # `git add` new files before rebuilding
  wsl -d twentyx -u root -- nixos-rebuild switch --flake /home/jensen/twentyx-airgap#wsl

No re-import, no transfer — confirm the offline promise once with the
no-WWW rehearsal in docs\wsl-README.md.

IF THE REBUILD FAILS
  It names a missing store path. Send that exact path: it gets added to
  wsl-rebuild.tar.gz (a 90 MB cache), never a 1.1 GB re-import.

TEST EVERYTHING
  docs\wsl-SMOKE-TEST.md is the checklist. For anything that fails, send
  the command and its output (plus /var/log/bootlog.txt — NOT the old
  airgap-bootlog.txt name — for anything boot- or session-related).

────────────────────────────────────────────────────────────────────
YOUR NOTES, ANSWERED  (2026-09-26 evening)
────────────────────────────────────────────────────────────────────

fish startup error (00-env.fish: "Expected a string, but found a
redirection")?  A REAL bug in bootstrap, now fixed: the pod-side generator
embedded a bash heredoc inside the FISH drop-in, so fish refused the whole
file (no PATH, no env) and podman's storage.conf was never written. It bit
your host because that generator had been run against the real home during a
rehearsal (the scratch files are in /tmp/opencode: gen.sh, heredoc-test.fish).
The polluted file has been removed, bootstrap writes storage.conf from bash
now, and the container test asserts `fish -n` on the generated drop-in.

Windows configs, version controlled?  Now yes:
  nix/packages/windows/zed-client-settings.json and .../wezterm.lua are
  repo files, copied into windows-kit on every build. Themes too (pinned
  by hash to immutable commits): Tokyo Night, Catppuccin, Kanagawa,
  Rose Pine, Nord, Dracula, Eldritch. Gruvbox ships inside Zed itself.
  Your live copies on this laptop are also already updated (Zed settings:
  auto_update off, telemetry off, extensions declared; WezTerm: kitty
  keyboard on).

sha sidecars: gone. Nothing writes or checks them any more.

Zed still downloaded stuff / auto-updated itself?  Both explained from
your own logs:
  - 19:41 the client auto-updated to 1.21.0 and fetched that version's
    server. auto_update is now OFF in your settings; if it ever applies a
    pending update, reinstall the kit installer (it is pinned to 1.17.2,
    the version whose remote server this closure ships).
  - Node.js + basedpyright + ruff downloads at 16:51 came from the
    packaged ~/.config/zed/settings.json being SHADOWED by a real
    settings.json in your home. A fresh import starts without that file,
    so the pins apply. On the current distro: check
    `ls -l ~/.config/zed/settings.json` — symlink = ours (good), real
    file = yours (merge the lsp/languages blocks from the packaged
    default).
  - json-language-server npm ENOTFOUND: Zed's built-in JSON support
    npm-installs vscode-langservers-extracted. That package is in the
    closure now and pinned in the settings, alongside yaml/taplo/bash.
  - Prettier was being installed on format for JSON/JS/HTML/Markdown;
    `"prettier": {"allowed": false}` in the packaged settings — nothing
    here uses it.

/var/log/airgap-bootlog.txt missing: the file is /var/log/bootlog.txt
(and C:\twentyx\bootlog.txt). The old name in this file was stale; fixed.

opencode slow to open: it ran on the old distro before this round's fixes
(no PATH wrap, no pinned LSPs). Re-test after the fresh start; if it still
stalls, send ~/.local/share/opencode/log/*.log — that names the step.

Zed agent: the packaged default has opencode over ACP, and Terminal
Threads (agent panel -> New Thread -> Terminal) start opencode immediately
via agent.terminal_init_command -- the plain TUI, same binary.

Python 3.12 only: deliberate (one interpreter; uv builds pinned 3.11
venvs by itself). Adding 3.11 is a closure change and a new transfer.

────────────────────────────────────────────────────────────────────
HISTORY (why things look the way they do)
────────────────────────────────────────────────────────────────────

BUILD #3 — first boot fixed: the imported distro's "/" was mode 0700
(mktemp root + tar ./ entry + WSL import). Every non-root process got
EACCES traversing absolute paths; root bypassed it via DAC_OVERRIDE,
which is why every dbus fix looked right but wasn't. The builder now
enforces "every directory a+rx" for the whole tree and FAILS the build on
violation. dbus implementation reverted to the NixOS default; the
journal-chmod unit removed.

POLISH ROUND — nvim LSP argv fixed (ruff server, taplo lsp stdio,
yaml-language-server --stdio, basedpyright-langserver --stdio,
bash-language-server start), completion per attached client ("invalid
client ID" gone), nixd settings object; btop tokyo-night; Zed pins;
WezTerm kitty keyboard protocol (shift+enter).

DEEP DIVE — the Zed remote-server lookup is EXACT-MATCH on the client's
full version string (build metadata included); the shim is generated from
nix/zed-client-version.nix (the kit installer's build). The ".gz" in
client logs is a PID-suffixed temp upload, not the name.

THIS ROUND — LSPs declared once (nix/modules/lsp.nix) and routed to
everything, opencode wrapped with them on PATH, JSON LSP added; VS Code
removed (kit + image); Windows templates + themes in the kit; repo now
ships as a git bundle.
────────────────────────────────────────────────────────────────────
EOF

# ── 5. the one-shot setup scripts ─────────────────────────────────────────
# Both are idempotent and non-destructive: UNPACK.ps1 runs on Windows (extract
# the kit, install themes/templates), setup-wsl.sh runs inside the distro as
# root (clone the bundle, import the cache, rebuild). See MANUAL.md.
say "carrying the setup scripts"
cp scripts/windows/UNPACK.ps1 scripts/setup-wsl.sh "$OUT/"

# ── 6. the repo itself, as a git bundle ───────────────────────────────────
# The WSL side clones this (`git clone /mnt/c/twentyx/twentyx-airgap.bundle`)
# and has the real history -- commits, diffs, bisect -- not a tar of the
# working tree. Committed state only, text only, a few hundred KB.
say "bundling the repo"
git bundle create "$OUT/twentyx-airgap.bundle" --all >/dev/null

# ── 7. the bundle at a glance ─────────────────────────────────────────────
cd "$OUT"
say "bundle contents:"
du -h nix-layer.tar.gz nix-layer-nvim.tar.gz repo-layer.tar nixos-wsl.tar.gz twentyx-airgap.bundle windows-kit 2>/dev/null | sort -k2
