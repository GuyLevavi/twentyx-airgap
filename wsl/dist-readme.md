README — the airgap toolchain
=============================

What you got: a Linux workstation (NixOS inside WSL2) and the image layers
for the RunAI GPU cluster, built to work with the network unplugged.
Nothing here downloads anything at runtime — everything needed was pinned
and verified before crossing the gap.

This folder is FLAT by design and it is EXACTLY the send set: send it as-is.
The four big artifacts are already in their transport form:

    THE FOUR BIG ARTIFACTS (a zstd container around the plain .tar.gz):
      nix-layer.tar.gz.zst            the pod toolchain layer (plain flavor)
      nix-layer-nvim.tar.gz.zst       the pod toolchain layer (nvim flavor)
      nixos-wsl.tar.gz.zst            the NixOS-WSL image for `wsl --import`
      windows-kit-<ver>.tar.gz.zst    Zed + VS Code + WSL2 MSI, themes, templates

    EVERYTHING ELSE (direct):
      README.md  MANIFEST.txt  SHA256SUMS  repo-layer.tar  wsl-rebuild.tar.gz
      twentyx-airgap.bundle  SETUP.ps1  UNPACK.ps1  setup-wsl.sh  docs/

Each `.zst` file holds the exact `.tar.gz` inside a zstd container. The
transfer pipeline drops the big gzip files, but it does not look inside
zstd. Unpack each `.zst` on Windows first (7-Zip: right-click -> Extract);
you get the plain `.tar.gz` back, byte-identical, so `sha256sum -c
SHA256SUMS` passes once all four are unpacked. Then run one command from
this folder, as below. `.zst` is transport only: every tool here expects
the `.tar.gz`, so do not skip the unpack step.

────────────────────────────────────────────────────────────────────
FIRST TIME  (one PowerShell command)
────────────────────────────────────────────────────────────────────

PowerShell (Administrator), from the extracted folder:

    powershell -ExecutionPolicy Bypass -File .\SETUP.ps1

SETUP.ps1 is idempotent and does the whole chain:
  1. installs the Windows kit: Zed and VS Code from the pinned installers,
     themes, and the client settings templates (a personal file is never
     overwritten — you get a .example beside it instead)
  2. imports the NixOS-WSL image (`wsl --import`, skipped when the distro
     already exists)
  3. runs the Linux half (setup-wsl.sh) as root: clones the repo bundle into
     the user's home, imports the offline rebuild cache, and switches the
     system — no network anywhere

A fresh import WIPES the distro's home. That is the point: the packaged
defaults (Zed/VS Code settings, LSP pins, tmux/btop themes) get applied
cleanly instead of being shadowed by half-configured leftovers.

Non-default layout? Every knob is a parameter:

    .\SETUP.ps1 -Distro twentyx -InstallDir C:\wsl\nixos -User jensen

Sudo asks for a password once? It is locked by design; the imported image
carries passwordless sudo for wheel. If you see a prompt, you are on an
older image — log in as the user and run the rebuild from your own shell
once: `sudo nixos-rebuild switch --flake ~/twentyx-airgap#wsl`

────────────────────────────────────────────────────────────────────
WHAT IS IN THIS FOLDER
────────────────────────────────────────────────────────────────────

    README.md                 this page
    MANIFEST.txt              versions + build identity (shell-sourceable)
    SHA256SUMS                sha256sum -c compatible
    nix-layer.tar.gz          RunAI pod toolchain closure (crane appends it)
    nix-layer-nvim.tar.gz     same, plus nvim (~17 MB more)
    repo-layer.tar            this repo's text layer (CI rebuilds it per commit)
    nixos-wsl.tar.gz          the NixOS-WSL image for `wsl --import`
    wsl-rebuild.tar.gz        delta cache for an EXISTING distro (see UPDATES)
    windows-kit-<ver>.tar.gz  Zed + VS Code + WSL2 MSI, themes, templates
    twentyx-airgap.bundle     the repo as a git bundle (real history)
    SETUP.ps1 / UNPACK.ps1    Windows one-shot / kit-only unpacker
    setup-wsl.sh              Linux-side one-shot (SETUP.ps1 runs it for you)
    docs/                     README, ARCHITECTURE, MANUAL, smoke test,
                              INNER-CONFIG (where cluster config goes)

────────────────────────────────────────────────────────────────────
EVERYDAY LOOP  (after the one-time setup)
────────────────────────────────────────────────────────────────────

    # inside the distro, as the user:
    rb

`rb` stages everything (the flake reads the GIT TREE, so untracked files are
invisible to a build) and runs `sudo nixos-rebuild switch --flake .#wsl`.
Config edits rebuild offline in seconds. No re-import, no transfer.

────────────────────────────────────────────────────────────────────
UPDATES  (two shapes, pick deliberately)
────────────────────────────────────────────────────────────────────

ROLLING — text/config changes on an existing distro:
  carry `twentyx-airgap.bundle` (+ `wsl-rebuild.tar.gz` when the release
  notes say a rebuild will need new store paths) and re-run setup-wsl.sh:
  it fast-forwards the repo, imports the cache, rebuilds. This is the cheap
  path and the reason a script change is a one-commit deploy.

REBASE — closure changes (new packages, image-level fixes):
  carry the new `nixos-wsl.tar.gz`, `wsl --unregister` the distro, import
  the new tar, re-run SETUP.ps1. The home is wiped — that is what makes the
  new defaults apply. Big closure additions are usually cheaper this way
  than growing the delta.

The delta NEVER contains the image: `nixos-wsl.tar.gz` is the image, ~1.5 GB;
`wsl-rebuild.tar.gz` is an additive cache of just the store paths an offline
rebuild needs (a few hundred MB today — the pinned VS Code server and its
extensions dominate — and it shrinks to almost nothing once a rebase has
absorbed those paths). If a rebuild ever names a missing store path, that
exact path is what gets added to the next delta — send it along with the
error.

────────────────────────────────────────────────────────────────────
VS CODE
────────────────────────────────────────────────────────────────────

The kit pins VS Code to one exact release, and the distro pre-seeds the
matching remote server for that release's commit — first connect needs no
network. Do not update VS Code on Windows: a newer client demands a server
the gap cannot download. The shipped `vscode-settings.json` already pins
updates off. Extensions (ruff, basedpyright, nix-ide, YAML, themes) are
installed offline by setup-wsl.sh from the kit's .vsix files; the remote
settings point ruff and nixd at the same closure binaries Zed and nvim use.

────────────────────────────────────────────────────────────────────
IF THE REBUILD FAILS
────────────────────────────────────────────────────────────────────

It names a missing store path. Send that exact path — it gets added to
wsl-rebuild.tar.gz, never a full re-import. Boot and session problems are
written to (both are readable from Windows):

    /var/log/bootlog.txt        and        <transfer>\bootlog.txt

TEST EVERYTHING
    docs/wsl-SMOKE-TEST.md is the checklist. For anything that fails, send
    the command and its output.

────────────────────────────────────────────────────────────────────
PUBLISHING THE ARTIFACTS (for the maintainer)
────────────────────────────────────────────────────────────────────

Inside the gap, the layer tarballs go up with:

    ./scripts/push-gitlab-packages.sh dist
    ./scripts/push-artifactory.sh dist/nix-layer.tar.gz

The GitLab flow is primary (generic package registry, fetchable by CI with
a job token); Artifactory remains the fallback. CI's .gitlab-ci.yml tries
them in that order.

────────────────────────────────────────────────────────────────────
HISTORY (why things look the way they do)
────────────────────────────────────────────────────────────────────

THIS ROUND — the first-remote-test fixes:
  - opencode SIGSEGV on WSL2/RHEL8/9 kernels (<= 6.6): nixpkgs' patchelf'd
    bun template made `bun build --compile` list its highest-address segment
    first, so the BSS was never mapped and ld.so died before main. The
    closure now reorders the program headers at build time and fails the
    build if the result is unsafe. (Also fixes any pod on an old-kernel
    node.)
  - Zed LSPs stopped npm-downloading: the shipped settings are now composed
    (personal look + dynamic /nix/store pins), so the pins can never be
    shadowed by the personal zed-settings.json again.
  - tmux now spawns fish directly (`default-shell`) instead of inheriting
    bash and skipping the exec-into-fish marker.
  - VS Code returns, pinned end to end (installer ↔ server commit ↔
    extension engines), replacing nothing: Zed remote stays the default.
  - The transfer folder is FLAT; the four big artifacts cross as `.zst`
    twins (the pipeline drops big gzip and does not inspect zstd) and are
    unpacked with 7-Zip before use; a MANIFEST + SHA256SUMS, and the
    Windows side is one script (SETUP.ps1) that no longer assumes C:\twentyx.

EARLIER — fresh-start round: repo ships as a git bundle (real history), Zed
themes/client templates become version-controlled kit artifacts, the
transfer-bundle builds the offline cache in the same run.

BUILD #3 — first boot fixed: the imported distro's "/" was mode 0700
(mktemp root + tar ./ entry + WSL import); every non-root process got EACCES
on absolute paths while root bypassed it via DAC_OVERRIDE. The builder now
enforces "every directory a+rx" for the whole tree and FAILS on violation.

SYNC ROUND — workmux (worktrees + tmux for parallel agents) with its
opencode status plugin, the full tmux config, opencode skills vendored from
a pinned input, and `rb` for the one-command offline rebuild.
