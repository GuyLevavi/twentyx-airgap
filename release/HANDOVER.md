# Handover: @RELEASE@

KIND=delta on BASE_RELEASE=@BASE_RELEASE@. For the inner agent.

**The inner repo is the source of truth.** This was cut outside, without sight
of inner. Every path and script name below describes the outside repo; where
inner differs, keep inner and adapt the change. Never copy `inside-seed.tar`
over the inner repo.

## Replies to your last report

Read this before anything else. `PROTOCOL.md` is the step-by-step version.

**1. code-server missing in vscode-pytorch pods.** Your symptom is right and the
cause was ours, but your suggested fix would not have worked.

- The 20261013 pod-full layer set `/opt/twentyx/profile` to
  `/nix/store/<h>-twentyx-profile`, which held code-server.
- From 20261102 on, outside built the pod layer from a different package set,
  the home-manager one (`home-manager-path`), which never had code-server.
- The delta's `/opt/twentyx/{profile,home-defaults,session-env}` sits above
  pod-full's and hides it. Pod-full's store paths were still in the image; nothing
  pointed at them.
- `environment.systemPackages` is the WSL system, so adding code-server there
  changes no pod.
- `STORE_RELEASE=20261103` only steers `wsl/update.sh`, and 20261103's pod layer
  had the same gap. Do not pin it.

**Fixed in this release:** the pod layer carries everything pod-full had, with
the newer tools winning any clash: its packages, its `home-defaults`
(`.zed_server`, the code-server opencode extension, opencode skills, the
workmux plugin) and its session variables (`TWENTYX_NVIM_PLUGINS`). The one
exception is Nix gcc, so `make` uses the base image's `cc`. A release gate now
refuses any pod layer that lacks a command pod-full had.

**Until this release is in:** add `$(ls -d /nix/store/*-twentyx-profile)/bin`
to the image PATH right after `/opt/twentyx/profile/bin`. Set link-home's
`DEFAULTS` to the `*-twentyx-home-defaults` path, and keep
`TWENTYX_NVIM_PLUGINS` from the 20261013 `session-env`. Remove all three once this
release's pod layer is in.

What 20261122 hid in pods, all back now:

- code-server, opencode, ssh/sshd/scp
- podman, podman-compose, lazydocker, nginx
- oc, mc, yazi, stow, bwrap, workmux, openssl, patch, infocmp/tput
- the LSPs on PATH: basedpyright, ruff, nixd, nixfmt, bash/yaml/html/css/json
  servers, taplo, tombi, package-version-server
- `.zed_server` and the code-server extension
- `TWENTYX_NVIM_PLUGINS`

`/opt/twentyx/bin/sudo` was never affected.

**2. "usage: sudo apply.sh" after update.sh downloaded.** Our mistake. The
20261122 `apply.sh` refused any argument, while `wsl/update.sh` calls it as
`apply.sh "$DIR"`. It also did not download `wsl-needs.txt`, which that apply.sh
required. `apply.sh` takes `[dir]` again, and `wsl-needs.txt` is optional for it.

**3. MR !14 (fetch `wsl-<KIND>.nar.tar.gz`).** Its diagnosis is correct. It is
superseded by this release's `update.sh`, which does that, fetches
`wsl-needs.txt` too, and chains through missed releases. Copy it over
`wsl/update.sh` (PROTOCOL.md step 7).

**4. A box two releases behind broke on update.** update.sh now walks
`BASE_RELEASE` back to the newest release the box can take, then applies forward,
one `apply.sh` per release, printing the plan first. Deltas are also cut against
every base still in the field, so one step usually suffices. When nothing fits,
it changes nothing and writes `~/twentyx-baseline-<date>.store-paths` for
outside. Tested outside against a mocked registry: one, two and three behind, up
to date, multi-base, full reset, no fit, unknown release.

**5. Full releases.** A `-full` release sits beside the delta, for a reset. It
holds the whole WSL system (`wsl-full.nar.tar.gz`, empty `wsl-needs.txt`) and
the whole pod layer (`pod-full.tar.gz`, placed directly on the base with no
older nix layer). `update.sh <id>-full` resets any box, and later deltas build
on it.

**6. yazi previews.** `chafa` (images in any terminal, as text art when there is
no graphics protocol) and `pdftoppm` (PDFs) ship on WSL and in pods. Video uses
the `ffmpeg` already shipped. No imagemagick. You can now restore yazi's preview
section in inner's dotfiles; yazi's defaults work. Inside tmux, inline images
need `set -g allow-passthrough on`.

## Read this first: what this release assumes

- WSL: outside builds the box's system, `nixos-system-twentyx-wsl`, and ships it.
  `wsl-<KIND>.nar.tar.gz` holds that system minus what the boxes already have
  (nothing, for a full release). `update.sh` picks the releases a box needs, and
  `apply.sh` imports each and switches. Nothing is rebuilt inside, and there is no
  flake inside to rebuild from.
- Pods: `pod-<KIND>.tar.gz` holds its whole closure plus a complete
  `/opt/twentyx`, which now includes everything the 20261013 pod-full had.

## Reassemble first

The release crosses as `@RELEASE@-b64/`. Every file over 1 MiB comes as
base64 parts, `<file>.part0`, `.part1`, ..., and `part0` comes twice, also as
`<file>.part00`. In that folder:

```
sh reassemble.sh ./release
```

It checks every part's sha256 against `PARTS.sha256`, takes `part00` when
`part0` is missing or damaged, decodes each file and checks it against
`PARTS.txt`. The small files are checked against `PLAIN.sha256`. It ends with
`RESULT: ok -> <dir>`, or names each missing or damaged part to ask outside for.
Everything below happens in `./release`.

## What is in this folder

| File | Use |
|---|---|
| `MANIFEST.txt` | RELEASE, KIND, BASE_RELEASE, source rev, `WSL_SYSTEM` (the toplevel `apply.sh` switches to) |
| `pod-<KIND>.tar.gz` | nvim layer: its full closure, plus a complete `/opt/twentyx` |
| `wsl-<KIND>.nar.tar.gz` | `nix-store --export` stream of `wsl-delta.nar`, gzipped in a tar: the WSL system's closure minus what the box holds. Not unpacked beforehand: `apply.sh` streams it |
| `wsl-needs.txt` | Paths the stream refers to but leaves out. `apply.sh` checks the box has them before it changes anything |
| `apply.sh` | Applies one release: checks, imports, switches, records `/var/lib/twentyx/release` |
| `update.sh` | Inner's new `wsl/update.sh`: applies every release a box is missing, in order |
| `PROTOCOL.md` | The transfer protocol, step by step. Follow it |
| `WSL.md` | The WSL update on one page: steps, checks, undo |
| `inside-seed.tar` | Outside repo at this release, under `inside-seed/`. **Not** a snapshot of inner, which is not visible from here. Reference to port from and diff against |
| `crane-layer.tar` | crane and its closure, glibc included, at `nix/store/...`. Binary: `@CRANE@/bin/crane`. Nothing at `/bin/crane`: CI synthesizes that as before |

## Apply

1. **WSL:** publish, then `~/twentyx/wsl/update.sh` on each box (PROTOCOL.md
   section 4). New tools are on PATH in a new shell. Safe to rerun. It stops before changing anything if the box lacks a
   path the release assumes; send outside the list it prints. To undo:
   `sudo nix-env -p /nix/var/nix/profiles/system --rollback && sudo /nix/var/nix/profiles/system/bin/switch-to-configuration switch`.
2. **Repo:** make the edits below. The pod layer's configs expect them.
3. **WSL dotfiles:** the box's `$HOME` config still comes from inner's
   `dotfiles/` via `wsl/link.sh`; the release only changes packages and the
   system.
4. **Pod image:** put `pod-delta.tar.gz` above the base nix layer, where the delta
   always goes (a `pod-full.tar.gz` goes directly on the base instead), and feed it to `scripts/build-binary-layer.sh`. The outside repo
   has no such script, so check how it takes its inputs. `session-env` must be
   read from this layer, the topmost nix layer: it holds new variables (below),
   and they only reach image ENV through that read.
5. **crane:** use `crane-layer.tar` in CI in place of the previous one.

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

`inside-seed/dotfiles/` holds every config changed since `921bfd6`, which covers
0.2.0 and everything after it, as plain files. Outside they are generated, by
`scripts/export-dotfiles.sh`. The inner `dotfiles/` layout is unknown here, so
map them onto it. Paths are relative to `$HOME`, except `session-env`.

| File | Change since base |
|---|---|
| `.config/nvim/init.lua` | Changed: new extras (`lang.nushell` among them), OSC 52 clipboard without a display |
| `.config/nvim/lua/config/{options,autocmds}.lua` | New: yank-only clipboard, basedpyright |
| `.config/nvim/lua/plugins/{completion,lsp,lualine,markdown,nix-pins}.lua` | New |
| `.config/nvim/lua/plugins/_lazyvim_nix_default.lua` | Removed: delete it if inner has it |
| `.config/nvim/lua/plugins/treesitter.lua` | New: parsers from the store, see below |
| `.config/tmux/tmux.conf` | Changed: status line, `terminal-features *:clipboard` |
| `.config/fish/config.fish`, `.bashrc` | Changed: thread caps, PID warning |
| `.config/starship.toml` | Changed: pod badge. Not exported to `dotfiles/`; it is in `home-defaults` (below). If inner keeps its own copy, set its `[hostname]` table to `ssh_only = false`, `detect_env_vars = ["KUBERNETES_SERVICE_HOST", "SSH_CONNECTION"]`, `format = "[ ⎈ $hostname ](bold fg:black bg:yellow) "` |
| `.config/nushell/` | New: `nu` config with starship/zoxide/atuin/direnv. Not exported to `dotfiles/`; it is in `home-defaults` |
| `session-env` | Changed: seven variables, below |

`session-env` is image ENV, one `KEY=VALUE` per line, and normally comes from the
delta. New since base: the five `OPENCODE_DISABLE_*`, `PIP_FIND_LINKS` and
`UV_FIND_LINKS`. Also new, and not in that file because it needs a shell:
`~/.local/bin` on PATH.

Not new, so not here: git, atuin, tealdeer, `lg.fish`, `.profile`,
`.bash_profile`. Their content is unchanged; only store hashes moved.

1. **The same files are already in the delta**, at
   `/opt/twentyx/home-defaults`. If inner's bootstrap still links from there,
   the configs arrive with no dotfiles work at all. Decide this first.
2. **Seven files name `/nix/store` paths:** `.bashrc`, `config.fish`, `init.lua`,
   `plugins/markdown.lua`, `plugins/nix-pins.lua`, `plugins/treesitter.lua`, `session-env`. They resolve only against this
   release's pod-delta, and every later release changes them. Do not hand-edit
   the hashes; re-export.
3. **nvim is more than these files.** It also needs these links, which are in
   `home-defaults` and not in `dotfiles/`:
   `.local/share/nvim/lazy/lazy.nvim` and
   `.local/share/nvim/site/pack/hm`. Without `lazy.nvim`, `init.lua` runs
   `git clone`, which fails in the gap, and nvim exits at start. `site/parser`
   and `site/queries` are no longer needed: `plugins/treesitter.lua` points at
   the store.
4. **A real file in `$HOME` beats a default.** On a PVC with older copies, the
   new config stays hidden until `airgap refresh`, or until they are removed.
5. **`.bashrc`:** outside, bootstrap parks this as `~/.bashrc.hm` and writes its
   own stub that sources it. A plain copy to `~/.bashrc` loses bootstrap's env.
6. **Pods only.** WSL keeps linking its config from inner's `dotfiles/`.
7. **Undo the tree-sitter workaround:** remove `~/.local/bin/tree-sitter` and
   any local `:TSUpdate` patch once `plugins/treesitter.lua` is in. Parsers are
   fixed by the release; `:TSUpdate` and `:TSInstall` cannot work offline.

If porting nvim by hand and not by file, also carry the extras in `init.lua`:
`dap.core`, `lang.python`, `lang.toml`, `lang.yaml`, `lang.nushell`.

## Check after applying

In a new pod:

    airgap doctor                     # store-paths intact, limits sane
    cat /proc/1/comm                  # tini
    airgap pids --summary             # thread cap matches the CPU limit
    ffprobe -version; python3.10 -V; uv --version; harlequin --version
    nvim --headless "+checkhealth dap" +qa
    nvim --headless "+lua io.write(#require('nvim-treesitter').get_installed('parsers'))" +qa   # 26

    nu -c 'version | get version'       # nushell, a secondary shell
    taskset -cp 1                     # pinned to as many CPUs as the quota (AIRGAP_PIN=0 turns it off)
    tail -1 ~/.local/state/twentyx/pids.log   # a line every 5 min from airgap pids --watch

In nvim, yank a line and paste it on the Windows side: OSC 52 carries it.

Then open tmux and look for `cpu x/y  mem x/yG  pids x/y` on the right, and time
`opencode` across a pod restart.

From WSL, `runai exec` into the pod: the prompt starts with a yellow
`⎈ <hostname>` badge. If not, `airgap refresh starship` drops an older
`~/.config/starship.toml` on the PVC that hides the new one.

On WSL: `nvim`, `ffprobe -version`, `python3.10 -V`.
