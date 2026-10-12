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

**R2. Publish under the new path.** `inside-seed` carries `scripts/push-gitlab-packages.sh` already
switched to `twentyx-store/<RELEASE from MANIFEST.txt>`; take it as-is, then re-apply any inside
auth or proxy tweaks. Run it from the transfer folder with the unpacked files (never the `.7z`), including
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

---

## Stage 1b: Windows client configs move inside

### What and why

The Windows client configs (`wezterm.lua`, `zed-client-settings.json`, `vscode-settings.json`)
were versioned only outside and installed once, so edits made in the gap were tracked nowhere.
They now live in the inner repo's `windows/` folder, flat:

- `UNPACK.ps1` reads them from the clone (`\\wsl.localhost\<distro>\home\<user>\twentyx\windows`)
  when it exists. The kit's copies are first-install defaults only.
- `SETUP.ps1` now runs UNPACK last, after the clone, so a fresh install already takes the inner
  repo's versions.
- `UNPACK.ps1 -ConfigOnly [-Force]` re-applies them after a `git pull`. A real file is still
  left alone (a `*.example` is written beside it) unless you pass `-Force`.

### Inside files

New `windows/` folder (in `inside-seed`).

### Required edits

**R6. Adopt `windows/`.** Take `inside-seed/windows/*` as-is. If anyone in the gap has a tuned
`%USERPROFILE%\.wezterm.lua` or Zed/VS Code client settings worth sharing, merge them into these
files in their own commit, keeping the kit's OpenGL / 60 fps / Alt+Enter settings unless a
machine needs otherwise. *Verify:* on a Windows PC with the clone,
`UNPACK.ps1 -ConfigOnly` prints `configs from \\wsl.localhost\...\twentyx\windows`.

### Likely overlaps

Windows config snippets kept in the inside docs (MANUAL, wiki pages): move them into
`windows/` and replace the doc text with a pointer.

---

## Stage 2: one pod entrypoint, session.env, links-only $HOME

### What and why

- **Pod boot chain merged.** `pod/` replaces `libexec/` and `agent/` in the repo. In the image it
  is still `/opt/twentyx/libexec/`, so the ENTRYPOINT, PATH and sudo targets don't change.
  `entrypoint` absorbs `bootstrap`, `common.sh` and `seed-home`. What remains:
  `entrypoint`, `run-opencode`, `restore-preload.sh`, `sshd-inetd`, `doctor`.
- **One resolver, written down.** `runai exec` never passes through the entrypoint, and arrives
  with `HOME=/` and no CA. So the entrypoint resolves identity, the PVC `HOME` and the injected
  CA/pip once, and writes `/opt/twentyx/etc/session.env` as `export K="v"` lines (bash and fish
  both parse them). These source it: `.bashrc`, `config.fish`, `/etc/profile.d/twentyx.sh`
  (login shells), `run-opencode`, `sshd-inetd` and `doctor`. The generated `env.fish`/`env.bash`
  and the duplicated `session_home()` resolution are gone.
- **Identity rules.** `SESSION_USER`, then the hostname rule, then `USERNAME`. The git-email
  rule is dropped: it read `$HOME`, which is the thing being resolved, so it could never fire.
- **Static things are static.** `XDG_CACHE_HOME=/tmp/twentyx-cache` and
  `CONTAINERS_STORAGE_CONF=/opt/twentyx/etc/containers/storage.conf` are image ENV, set by
  `assemble.sh`. `storage.conf` (vfs) ships in the repo layer instead of being generated.
- **Config moved into dotfiles.**
  - `/etc/gitconfig` was duplicated in `wsl.nix` and `mklayer.sh`. It is now
    `dotfiles/.config/git/config`, and the link scripts create an empty real `~/.gitconfig`, so
    `git config --global` writes identity there and never through the link.
  - The VS Code remote machine settings (LSP pins) are now
    `dotfiles/.vscode-server/data/Machine/settings.json`.
  - `preload.ts` is now `dotfiles/.config/opencode/plugins/preload.ts`. It is a no-op wherever
    `PRELOAD_ORIGINAL` is unset.
- **doctor**: 272 lines down to about 90. It covers session, closure, `$HOME` links, sudo,
  preload, terminal and injection, and exits 1 when a check fails. CI's `smoke` job gates on it.
  The LLM-endpoint, network-posture and GPU probes are gone.
- **The repo layer no longer copies `env/`.** A pod takes its CA and pip config from the base
  or from the injection mounts. On WSL, `wsl/link.sh` stages `env/`.
- **`wsl/ssh-bridge.sh`** (was `scripts/ssh-bridge.sh`).
- **One linker for both targets: `pod/link-home <dotfiles-dir>`.**
  - It is stow (`--no-folding -R`, which also prunes links to removed files) plus about 20
    lines: a real file in `$HOME` is skipped and listed; old absolute or store links from
    `seed-home` are replaced; `~/.zed_server` and the pod's code-server extension are linked
    once (their names never change); and `~/.gitconfig` is created empty.
  - The pod entrypoint runs it from `/opt/twentyx/libexec`; on WSL, `wsl/link.sh` runs the
    clone's copy and stages `env/`.
- **Packaged defaults no longer live in `$HOME` file by file.** `opencode.jsonc` names the
  vendored skills (`skills.paths`) and workmux's plugin (`plugin`) at their stable
  `/opt/twentyx/home-defaults/...` paths. The npm-stall pair (`package-lock.json`,
  `node_modules/.keep`) is plain dotfiles: opencode checks the dependency name, not the
  version. A transfer updates all of it without touching `$HOME`.

### Inside files

`pod/*` (new home of `libexec/*` and `agent/restore-preload.sh`), `wsl/link.sh`,
`wsl/ssh-bridge.sh`, `docker/mklayer.sh`, `docker/assemble.sh`, `.gitlab-ci.yml`,
`dotfiles/.bashrc`, `dotfiles/.profile`, `dotfiles/.bash_profile`,
`dotfiles/.config/fish/config.fish`, `dotfiles/.config/git/config`,
`dotfiles/.vscode-server/...`, `dotfiles/.config/opencode/plugins/preload.ts`.

### Required edits

**R7. Shells source session.env.** Apply both on top of any inside rc edits:
- In `dotfiles/.bashrc`, replace the `/opt/twentyx/etc/env.bash` line with:

  ```bash
  [ -r /opt/twentyx/etc/session.env ] && . /opt/twentyx/etc/session.env
  for f in ~/.config/bashrc.d/*.sh; do [ -r "$f" ] && . "$f"; done
  unset f
  ```

- In `dotfiles/.config/fish/config.fish`, replace the `env.fish` block with:

  ```fish
  if test -f /opt/twentyx/etc/session.env
      source /opt/twentyx/etc/session.env
  end
  ```

*Verify:* in a pod, `runai exec -it <ws> -- bash -lc 'echo $HOME'` prints the PVC home.

**R8. git identity.** Add `dotfiles/.config/git/config`. If the inside edited `/etc/gitconfig`
handling in `mklayer.sh`, move those settings into this file. Each user's identity stays in
their own `~/.gitconfig`. *Verify:* `git config --global user.email x@y` writes `~/.gitconfig`
and the repo stays clean.

**R9. Pod script fixes.** For every inventory commit that touched `libexec/*` or `agent/*`,
re-apply its intent in `pod/` by hand (one commit each, naming the original). Logic that lived
in `common.sh`/`bootstrap`/`seed-home` now lives in `pod/entrypoint`.

**R10. opencode.jsonc.** Keep the inside's provider/model block, and add the two keys from
`inside-seed`:

```jsonc
"skills": { "paths": ["/opt/twentyx/home-defaults/.config/opencode/skills"] },
"plugin": ["/opt/twentyx/home-defaults/.config/opencode/plugins/workmux-status.ts"],
```

If the inside already has a `plugin` list, append to it. Also take
`dotfiles/.config/opencode/{package-lock.json,node_modules/.keep}` and the `.gitignore` line
`!dotfiles/.config/opencode/node_modules/`. *Verify:* opencode lists the vendored skills, and
starts without an npm stall.

**Also fixed in this stage** (no inside action):
- A WSL NAR is always shipped. With no new paths it is an 8-byte no-op import, so SETUP.ps1
  never asks for a file that isn't there.
- `--rebase` refuses a dirty tree.
- `assemble.sh` builds the store image under a `-partial` tag, so a half-built image is never
  reused.
- `scripts/push-artifactory.sh` and `VERSION` are deleted. If the inside still uses Artifactory,
  see R4.

**R11. Smoke runner.** `doctor` now exits 1 when a check fails, and `smoke` runs it. CI runners are
assumed to have no working sudo, so `sudo -n true` failing is only a note; the setuid bit on
`/opt/twentyx/bin/sudo` is still checked (a file-mode fact of the layer). Nothing to do unless an
inside `doctor` change turns an environmental check back into a failure.

### Likely overlaps

- Inside tweaks to the generated env files (extra exports): add them to the `session.env` block
  in `pod/entrypoint` if they depend on `HOME`; otherwise put them in the dotfiles.
- Inside fixes to `seed-home`'s link logic: obsolete. `pod/link-home` replaces it, and it migrates the old
  store links on first run.
