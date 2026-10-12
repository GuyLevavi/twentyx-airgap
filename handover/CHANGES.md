# Handover log: outside changes the inside must consolidate

Appended with every outside stage commit (PLAN.md, D16). Stage 3 renders it
into `HANDOVER.md`. Each entry has:

- **What and why**: the change, and the reason it exists.
- **Inside files**: paths in the inner repo this touches.
- **Required edits** (R-numbers): edits to inside-owned files, applied *on top
  of* the inside version. Each gives the intent, the exact snippet, and how to
  verify it. Everywhere else the inside version wins.
- **Likely overlaps**: inside work this supersedes or collides with, and what
  to do with it.

---

## Stage 1: cumulative store deltas against base.rev

### What and why

- **One closure, nvim folded in.** There is no plain/nvim pair any more: one pod layer, one image
  per variant, no `-nvim` tags. `EDITOR`/`VISUAL` are `nvim` everywhere, and pods no longer
  carry `nano`.
- **Pod closure fix.** The pod closure is now rooted at the session-env file too. Before this,
  three store paths named by image ENV were missing from every pod image:
  - the LazyVim tree (`TWENTYX_NVIM_PLUGINS`)
  - glibc-locales (`LOCALE_ARCHIVE`)
  - the wezterm terminfo (`TERMINFO_DIRS`)
- **New artifacts.** The old set (`nix-layer*.tar.gz`, `nix-layer-delta*.tar.gz`,
  `wsl-update.nar`, `repo-layer.tar` in the transfer, the git bundle) is replaced by:

  | File | What it is |
  |---|---|
  | `pod-full.tar.gz` | the `/opt/twentyx` tree + the whole pod closure (rebase releases only) |
  | `pod-delta.tar.gz` | the `/opt/twentyx` tree + what the closure adds since the base |
  | `wsl-full.nar` / `wsl-delta.nar` | the same for WSL, as a NAR for `nix-store --import` |
  | `MANIFEST.txt` | `RELEASE`, `BASE_RELEASE`, `KIND=full\|delta`, `WSL_SYSTEM`, `BASE_WSL_SYSTEM`, `NIXPKGS_REV`, `WINDOWS_KIT` |
  | `apply.sh` | the WSL updater (replaces `setup-wsl.sh`) |
  | rebase only | `nixos-wsl.tar.gz`, `windows-kit-*.tar.gz` (now with the WezTerm nightly installer), `SETUP.ps1`, `UNPACK.ps1` |

- **Release ids** are `<yyyymmdd>-<outside short rev>`. A delta applies to anything that has
  its base, in any order. There is no chain and no `VERSION`.
- **Package registry layout** (replaces `twentyx-airgap/<VERSION>/`). Every file of a transfer
  goes to `twentyx-store/<RELEASE>/`. A delta release's full layer therefore lives under its
  `BASE_RELEASE`.
- **The setuid sudo** now ships inside the store layer's `opt/` tree, at mode 4555.
  `mklayer.sh` no longer extracts it.
- **`docker/assemble.sh` builds two images per variant:**
  - `workspace-store:<release>-<variant>-<base digest>`: built only when missing, from the
    full layer (plus the delta, if any). The layers are fetched from the package registry
    only at that point.
  - `workspace:<commit>-<variant>`: that store image plus the repo layer. A config commit
    downloads nothing big.
- **WSL Nix is quiet.** No substituters (the old config still had `cache.nixos.org`), no
  flakes, no `nix` CLI. `nix-store`/`nix-env` remain for updates and rollback.
- **The WSL `seed-home` service is gone.** Linking `$HOME` becomes the inner repo's
  `wsl/link.sh` (Stage 2).

### Inside files

`.gitlab-ci.yml`, `docker/assemble.sh`, `docker/mklayer.sh`, `scripts/push-gitlab-packages.sh`,
a new `STORE_RELEASE` file, and the deletion of `scripts/setup-wsl.sh`,
`scripts/transfer-bundle.sh`, `scripts/build-layers.sh` and `VERSION`.

### Required edits

**R1. Pin the store release.** Create `STORE_RELEASE` at the repo root containing the
`RELEASE=` value of the shipped `MANIFEST.txt`, one line, no `RELEASE=` prefix.
*Verify:* `cat STORE_RELEASE` matches the manifest's line.

**R2. Publish under the new path.** In `scripts/push-gitlab-packages.sh`, set `PACKAGE=twentyx-store`
and take the version from the transfer's manifest:

```bash
VERSION="${PACKAGE_VERSION:-$(sed -n 's/^RELEASE=//p' MANIFEST.txt)}"
```

Run it from the transfer folder with the unpacked files (never the `.7z`), including
`MANIFEST.txt` and `apply.sh`. *Verify:* the package page lists `twentyx-store/<RELEASE>/`
with every file of the transfer.

**R3. CI structure.** `.gitlab-ci.yml` takes the new job structure: `assemble` runs
`docker/mklayer.sh` then `docker/assemble.sh "$CI_COMMIT_SHORT_SHA"`; `smoke` uses the
just-built `workspace:<sha>-base-slim` as its job image (`entrypoint: [""]`) and runs `doctor`
and `shellcheck`. Then re-apply every inside-only setting: variables, runner tags, auth steps,
proxy or CA settings, and extra rules. The removed `lint` job pulled a Docker Hub image; its
check now runs in `smoke`. *Verify:* a pipeline on `main` runs `assemble`, then `smoke`.

**R4. Fallbacks.** If the inside added an Artifactory fallback or another mirror to the layer
fetch, port it into `store_file()` in `docker/assemble.sh` (the only place store files are
fetched), keeping the `twentyx-store/<release>/<file>` naming.

**R5. tmux: Shift+Enter reaches opencode.** opencode runs inside tmux. With
`extended-keys on`, tmux forwards modified keys only to apps that request modifyOtherKeys, and
opencode requests the kitty protocol, which tmux does not speak. So Shift+Enter arrived as a
plain CR and submitted. In `dotfiles/.config/tmux/tmux.conf`, replace the `terminal-features`
RGB line and `set -g extended-keys on` with:

```tmux
set -as terminal-features ",*:RGB:extkeys"
set -g extended-keys always
set -g extended-keys-format csi-u
```

Keep any other inside tmux edits. *Verify:* in a pane, `cat -v` then Shift+Enter shows
`^[[13;2u`, and C-a, Enter and Tab behave as before. If Shift+Enter still submits under
WezTerm on Windows, add one WezTerm binding that sends `\x1b[13;2u` for Shift+Enter (the kit's
`wezterm.lua` is outside-owned; ask through `REQUESTS.md`).

The kit's `wezterm.lua` changed with it: OpenGL front end, 60 fps (was WebGpu/144),
Alt+Enter no longer toggles fullscreen, and the kitty-keyboard line is gone (tmux in between
made it a no-op). `UNPACK.ps1` installs it only where no `.wezterm.lua` exists; elsewhere it
writes `.wezterm.lua.example` to merge by hand.

### Likely overlaps

- A pod workaround for missing locale, terminfo or LazyVim paths (env overrides, dropping
  `LOCALE_ARCHIVE`, nvim tweaks) is **obsolete**: the paths now ship. Remove it, and record it in
  the inventory as *obsolete because the closure is rooted at session-env*.
- Inside edits to `nix/`, `flake.nix` or the deleted scripts: **delete**, and note each one's
  intent in `REQUESTS.md`.
- Inside edits to `docker/assemble.sh` (PATH, mutate flags, extra labels, registry auth):
  re-apply them onto the new file; the per-variant loop is in the same place.
- Old packages under `twentyx-airgap/<VERSION>/` stay where they are. Nothing reads them after R1.
