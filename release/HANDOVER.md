# Handover: @RELEASE@

KIND=delta on BASE_RELEASE=@BASE_RELEASE@. For the inner agent.

**The inner repo is the source of truth.** This was cut outside, without sight
of inner. Every path and script name below describes the outside repo; where
inner differs, keep inner and adapt the change. Never copy `inside-seed.tar`
over the inner repo.

## Read this first: the baseline is an assumption

`d13208ce9f` does not exist outside. Both deltas were computed against the last
build known to have crossed the gap, outside rev `921bfd6` (September, before
0.2). If the inner store has anything else, the deltas omit paths it lacks.

- WSL: `apply.sh` checks first and stops before importing, naming what is missing.
- Pods: nothing checks at append time. After the first image, run
  `airgap doctor`: it compares `/opt/twentyx/store-paths` with the disk.

If either fails, ask for a release against the real baseline. Bring out the base
layer's `opt/twentyx/store-paths` and the WSL closure list
(`nix-store -qR /run/current-system`).

## What is in this folder

| File | Use |
|---|---|
| `MANIFEST.txt` | RELEASE, KIND, BASE_RELEASE, source rev |
| `pod-delta.tar.gz` | nvim layer delta. Store paths the base lacks, plus a complete `/opt/twentyx` |
| `wsl-delta.nar.tar.gz` | `nix-store --export` stream of `wsl-delta.nar`, gzipped in a tar. Not unpacked beforehand: `apply.sh` streams it |
| `apply.sh` | WSL updater |
| `inside-seed.tar` | Outside repo at this release, under `inside-seed/`. **Not** a snapshot of inner, which is not visible from here. Reference to port from and diff against |
| `crane-layer.tar` | crane and its closure, glibc included, at `nix/store/...`. Binary: `@CRANE@/bin/crane`. Nothing at `/bin/crane`: CI synthesizes that as before |

## Apply

1. **WSL:** `sudo ./apply.sh`. This switches to the system built outside. If the
   inner flake has WSL changes of its own, that would drop them, so use
   `./apply.sh --import-only` and then rebuild from the inner flake.
2. **Repo:** make the edits below, before rebuilding images. The delta's configs
   expect them.
3. **Pod image:** put `pod-delta.tar.gz` directly above the base nix layer, which
   must stay in place, and feed it to `scripts/build-binary-layer.sh`. The
   outside repo has no such script, so check how it takes its inputs.
   `session-env` must be read from the delta, the topmost nix layer: it holds new
   variables (below), and they only reach image ENV through that read.
4. **crane:** use `crane-layer.tar` in CI in place of the previous one.

## Inner repo edits

All new or changed files are in `inside-seed.tar`, under `inside-seed/`.

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

`inside-seed/dotfiles/` holds the new configs as plain files, laid out as they
sit under `$HOME`: nvim, tmux, fish, `.bashrc`. Outside they are generated, by
`scripts/export-dotfiles.sh`. The inner `dotfiles/` layout is unknown here, so
map them onto it.

1. **The same files are already in the delta**, at
   `/opt/twentyx/home-defaults`. If inner's bootstrap still links from there,
   the configs arrive with no dotfiles work at all. Decide this first.
2. **Five files name `/nix/store` paths:** `.bashrc`, `config.fish`, `init.lua`,
   `plugins/markdown.lua`, `plugins/nix-pins.lua`. They resolve only against this
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
6. **Pods only.** WSL gets its config from `apply.sh`.

The user-facing nvim changes, if porting by hand and not by file:
`lua/plugins/{completion,lsp,lualine,markdown}.lua`,
`lua/config/{options,autocmds}.lua`, the extras in `init.lua` (`dap.core`,
`lang.python`, `lang.toml`, `lang.yaml`), and the OSC 52 block at its top.

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
