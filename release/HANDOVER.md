# Handover: @RELEASE@

KIND=delta on BASE_RELEASE=@BASE_RELEASE@. For the inner agent.

**The inner repo is the source of truth.** This was cut outside, without sight
of inner. Every path and script name below describes the outside repo; where
inner differs, keep inner and adapt the change. Never copy `inside-seed.tar`
over the inner repo.

## Read this first: what this release assumes

Outside cannot build inner's system. It only has `nixos-system-airgap-wsl`, and
inner runs its own `nixos-system-twentyx-wsl`, from a repo outside never sees.

- WSL: `wsl-delta.nar.tar.gz` is not a system and assumes nothing about the store.
  It is closed under references, so it imports anywhere, and it holds what
  inner's rebuild cannot make offline: the new packages, and the tools the rebuild
  uses. `apply.sh` imports it and stops. Inner's own rebuild does the switch.
- Pods: `pod-delta.tar.gz` assumes nothing either. Despite the name it holds its
  whole closure, 692 store paths, plus a complete `/opt/twentyx`, so it works on
  whatever base it lands on. That is why it is larger than a delta.

## What is in this folder

| File | Use |
|---|---|
| `MANIFEST.txt` | RELEASE, KIND, BASE_RELEASE, source rev |
| `pod-delta.tar.gz` | nvim layer: its full closure, plus a complete `/opt/twentyx` |
| `wsl-delta.nar.tar.gz` | `nix-store --export` stream of `wsl-delta.nar`, gzipped in a tar: new packages and build tools, with their closures. Not unpacked beforehand: `apply.sh` streams it |
| `apply.sh` | WSL updater: imports and adds GC roots. Does not switch |
| `inside-seed.tar` | Outside repo at this release, under `inside-seed/`. **Not** a snapshot of inner, which is not visible from here. Reference to port from and diff against |
| `crane-layer.tar` | crane and its closure, glibc included, at `nix/store/...`. Binary: `@CRANE@/bin/crane`. Nothing at `/bin/crane`: CI synthesizes that as before |

## Apply

1. **WSL store:** `sudo ./apply.sh`. Safe on any store, and to rerun. Roots go in
   `/nix/var/nix/gcroots/twentyx-release`, so a GC before the rebuild cannot undo
   it. The next release replaces them.
2. **Repo:** make the edits below, before rebuilding anything. The delta's configs
   expect them.
3. **WSL system:** port the Nix changes from `inside-seed/nix/` (below), then
   `nixos-rebuild dry-build` from the inner flake. Only config glue should be
   listed: `home-manager-path`, `man-cache`, `etc`, the system itself. Then
   `nixos-rebuild switch`.
   If it lists a tarball or a compiler, stop: that package's hash differs from
   this release, and it cannot build here. See "Nix changes".
4. **Pod image:** put `pod-delta.tar.gz` above the base nix layer, where the delta
   always goes, and feed it to `scripts/build-binary-layer.sh`. The outside repo
   has no such script, so check how it takes its inputs. `session-env` must be
   read from this layer, the topmost nix layer: it holds new variables (below),
   and they only reach image ENV through that read.
5. **crane:** use `crane-layer.tar` in CI in place of the previous one.

## Inner repo edits

All new or changed files are in `inside-seed.tar`, under `inside-seed/`.

**Nix changes, for the WSL rebuild.** Take these as they are. A store path is a
hash of its expression, so the imported packages only match a rebuild if the
expressions match, on the same nixpkgs pin (`c043004`).

- New: `nix/pkgs/pbs-python.nix`, `nix/pkgs/harlequin.nix`,
  `nix/pkgs/open-code-review.nix`.
- Changed: `nix/modules/tools.nix`, `nix/modules/nvim.nix`, `nix/modules/home.nix`,
  `nix/modules/shell.nix`.

Keep inner's own changes around them: hostname, users and the package list can
differ, and dropping a package is fine. Changing how a package is built, or its
overrides, means it no longer matches, and the rebuild will try to fetch or
compile it. `nixos-rebuild dry-build` names the derivation; compare it with the
same package in `/nix/var/nix/gcroots/twentyx-release`.

**Required, the delta depends on these exact paths.** The first two are compiled
into the delta's configs. Both fail quietly if absent, so a miss shows up as a
missing feature and not an error. If inner renamed `libexec/airgap-*` or the
`airgap` prefix, tell outside: these strings need a rebuilt delta, or keep a
symlink at the old name.

| Path in the image | Source | Used by |
|---|---|---|
| `/opt/twentyx/libexec/airgap-limits.sh` | `libexec/airgap-limits.sh` | `.bashrc`, thread caps and the PID warning |
| `/opt/twentyx/libexec/airgap-tmux-status` | `libexec/airgap-tmux-status`, executable | tmux status line |

**Pods stop dying with "os error 11".** Three leaks fill `pids.max`.

- `libexec/airgap-entrypoint`: re-exec under tini as PID 1, guarded by
  `AIRGAP_UNDER_INIT`, and source `airgap-limits.sh` before bootstrap. Port both
  blocks. tini is in the delta at `/opt/twentyx/profile/bin/tini`.
- `libexec/airgap-pids`: new, executable. Must keep working with no PIDs left:
  bash builtins only, no `$(...)`.
- `libexec/airgap-doctor`: add the limits section and the ffmpeg, ffprobe and
  runai checks.
- If the workload has no CPU limit, `cpu.max` is `max` and the caps do nothing.
  Set `AIRGAP_THREADS` in the workload env.

**opencode starts without waiting on the network.**

- `libexec/airgap-bootstrap`: the block that symlinks `$CACHE/opencode` to
  `$DHOME/.local/share/opencode-cache`. The `OPENCODE_DISABLE_*` variables are
  already in the delta's `session-env`.

**Optional.**

- runai CLI in images: `RUNAI_CLI_URL` in `.gitlab-ci.yml` and the `RUNAI_CLI`
  block in `docker/assemble.sh`. Without it, install by hand into
  `~/.local/bin`, which is now on PATH.
- open-code-review needs tool calling on vLLM: `--enable-auto-tool-choice` plus
  a Qwen tool-call parser. See `NOTES.md`, section 8.

**No edits needed**, these are entirely in the deltas: gnumake, wheelhouse,
python3.10 and 3.11, uv, harlequin, ffmpeg, debugpy and nvim DAP.

## Environment names

The root moved to `/opt/twentyx`, but the variables keep their names:
`AIRGAP_ROOT`, `AIRGAP_THREADS`, `AIRGAP_CPUS`, `AIRGAP_UNDER_INIT`. The outside
scripts default `AIRGAP_ROOT` to `/opt/twentyx`. If inner renamed them, adapt the
ported scripts, not the delta. The delta sets none of them.

## dotfiles: wiring is NOT trivial

`inside-seed/dotfiles/` holds every config changed since `921bfd6`, which covers
0.2.0 and everything after it, as plain files. Outside they are generated, by
`scripts/export-dotfiles.sh`. The inner `dotfiles/` layout is unknown here, so
map them onto it. Paths are relative to `$HOME`, except `session-env`.

| File | Change since base |
|---|---|
| `.config/nvim/init.lua` | Changed: new extras |
| `.config/nvim/lua/config/{options,autocmds}.lua` | New: yank-only clipboard, basedpyright |
| `.config/nvim/lua/plugins/{completion,lsp,lualine,markdown,nix-pins}.lua` | New |
| `.config/nvim/lua/plugins/_lazyvim_nix_default.lua` | Removed: delete it if inner has it |
| `.config/tmux/tmux.conf` | Changed: status line |
| `.config/fish/config.fish`, `.bashrc` | Changed: thread caps, PID warning |
| `session-env` | Changed: seven variables, below |

`session-env` is image ENV, one `KEY=VALUE` per line, and normally comes from the
delta. New since base: the five `OPENCODE_DISABLE_*`, `PIP_FIND_LINKS` and
`UV_FIND_LINKS`. Also new, and not in that file because it needs a shell:
`~/.local/bin` on PATH.

Not new, so not here: git, starship, atuin, tealdeer, `lg.fish`, `.profile`,
`.bash_profile`. Their content is unchanged; only store hashes moved.

1. **The same files are already in the delta**, at
   `/opt/twentyx/home-defaults`. If inner's bootstrap still links from there,
   the configs arrive with no dotfiles work at all. Decide this first.
2. **Six files name `/nix/store` paths:** `.bashrc`, `config.fish`, `init.lua`,
   `plugins/markdown.lua`, `plugins/nix-pins.lua`, `session-env`. They resolve only against this
   release's pod-delta, and every later release changes them. Do not hand-edit
   the hashes; re-export.
3. **nvim is more than these files.** It also needs these links, which are in
   `home-defaults` and not in `dotfiles/`:
   `.local/share/nvim/lazy/lazy.nvim` and
   `.local/share/nvim/site/{pack/hm,parser,queries}`. Without `lazy.nvim`,
   `init.lua` runs `git clone`, which fails in the gap, and nvim exits at start.
4. **A real file in `$HOME` beats a default.** On a PVC with older copies, the
   new config stays hidden until `airgap refresh`, or until they are removed.
5. **`.bashrc`:** outside, bootstrap parks this as `~/.bashrc.hm` and writes its
   own stub that sources it. A plain copy to `~/.bashrc` loses bootstrap's env.
6. **Pods only.** WSL gets its config from the rebuild in step 3.

If porting nvim by hand and not by file, also carry the extras in `init.lua`:
`dap.core`, `lang.python`, `lang.toml`, `lang.yaml`.

## Check after applying

In a new pod:

    airgap doctor                     # store-paths intact, limits sane
    cat /proc/1/comm                  # tini
    airgap pids --summary             # thread cap matches the CPU limit
    ffprobe -version; python3.10 -V; uv --version; harlequin --version
    nvim --headless "+checkhealth dap" +qa

Then open tmux and look for `cpu x/y  mem x/yG  pids x/y` on the right, and time
`opencode` across a pod restart.

On WSL: `nvim`, `ffprobe -version`, `python3.10 -V`.
