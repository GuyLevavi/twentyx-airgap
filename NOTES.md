# Notes: open items and the why

`README.md`, `ARCHITECTURE.md` and `MANUAL.md` are canonical for how the
system works. This file is the other half: what is still open, and the
reasoning behind the pieces that are load-bearing and must not be
"simplified".

## Open items

- **nginx site config.** nginx is in the pod closure so port exposure does
  not depend on the base; the exact site config RunAI expects (or whether it
  wants one) is unpinned. When known it belongs in the env-injection mount,
  not the closure.
- **sshd bridge.** `libexec/sshd-inetd` + `scripts/ssh-bridge.sh` are
  implemented but only exercised against a real `runai exec`.
- **opencode slowness on WSL [open].** Reported slow in the distro; the log
  directory has not been read (the VHDX cannot be inspected from Linux). Ask
  for a dump from inside:
  `wsl -d twentyx -- bash -lc 'cd ~; { ls -la .local/share/opencode/log/; tail -150 "$(ls -t .local/share/opencode/log/*.log | head -1)"; } > /mnt/c/twentyx/diag.txt 2>&1'`
- **`no-new-privileges`.** Whether RunAI sets it (which would block the
  setuid sudo) is unverifiable locally; `doctor`'s sudo line answers it on a
  real pod.
- **CUDA under the real fractioning preloaders.** The preload split is fully
  covered by tests, but the proprietary RunAI libraries only exist in a
  fractioned pod.
- **First transfer against the real bases** (PATH prepending on a pytorch
  base, ENTRYPOINT hand-over on a `vscode-*` one) and the laptop no-WWW
  rehearsal are the two end-to-end checks still pending.
- **Zed `cloud.zed.dev` preflight.** On first connect the client may check
  its account/extension service; with the vendored extensions and the
  release-matched server it should not need it, but only the gap proves it.

## Frozen appliance: why home-manager was dropped

The old WSL side rebuilt config inside the gap, and that never actually
worked: the shipped system's runtime closure was missing the build-time
inputs every home-manager rebuild needs — `lndir` (every `symlinkJoin`),
`babelfish` (fish session vars; its source is on GitHub, which is the
"rebuild looks for github" report), `json2x` (every TOML/YAML `formats.*`
file), `jq.dev` (every `formats.json`), and buildEnv's `builder.pl`. The only
rebuild that succeeded was a no-op at the same commit.

So the model changed: **nothing evaluates Nix inside the gap.**

- `nix/profile.nix` builds the package profile, the session environment and
  a tree of packaged defaults; `nix/packages.nix` is the package list with
  plain `wsl`/`nvim` booleans.
- `dotfiles/` is plain text in the repo. `libexec/seed-home` symlinks each
  file from `$HOME` into the toolchain tree, so a text-layer update renews it
  with no reseed. On WSL `seed-home` prefers a checkout at `~/twentyx` over
  `/opt` (script-level, so the text layer alone enables it), so that tree is
  the clone itself: edit
  `~/.config/<file>`, commit, push, done. A real file at the same path is the
  user's and is never clobbered, and a default that moved on reports
  `newer default available: diff <shipped> <yours>`. An identical real copy
  is adopted as a link, so pre-symlink homes migrate on the next start. A
  stale home-manager-era link (dangling, or into `*-home-manager-files`) is
  treated as ours and replaced.
- Local overrides: delete the link and write a real file; it is yours from
  then on, and a repo update will never touch it.

**Stable paths.** Everything points at `/opt/twentyx/profile/bin/<tool>`:
on WSL a tmpfiles rule links `/opt/twentyx/profile` to the system path, in a
pod the layer links it to the buildEnv. A store path baked into an editor
setting goes stale on the next closure update; this is the fix.

## WSL updates: the delta and the builder

- The update artifact is a store delta (`wsl-update.nar`) exported against
  the last shipped system, kept as an indirect GC root
  (`.gcroots/wsl-system`) so a collection cannot delete the base. With no
  base (first transfer, or a far side older than the last shipment) the whole
  closure is exported.
- `setup-wsl.sh` overlays the text layer (from a checkout there is nothing to
  overlay: `seed-home` prefers the clone instead), stages
  CA/pip.conf, imports the delta, `nix-env --set`s the system profile, runs
  `switch-to-configuration switch`, and restarts `seed-home`. Rollback is
  `nix-env --rollback` + switch.
- The tarball is built by the **upstream** NixOS-WSL builder under `sudo`.
  The previous custom rootless builder existed only to work around
  user-namespace EINVALs; with real root those workarounds
  (`createHome = false`, tmpfiles home rules, activation chowns) are gone.
  No `--chown home/jensen`: upstream applies chowns before `nixos-install`
  (it is for `--extra-files`), and the activation script already creates the
  home as 1000:100. The tarball is the only artifact that needs sudo.

## The pod layer delta (why cumulative, not chained)

The WSL side always had a closure delta because `nix-store --export` supports
one; the OCI side did not, so any package addition re-gzipped and re-carried
the whole ~1 GB layer per flavor. The fix uses the property the layers already
rely on: Nix store paths are immutable and image layers are additive. A delta
is therefore just the new store paths plus the regenerated `opt/` tree, and
`crane append` overlays it in order.

It is **cumulative against the base layer** (everything since the last full
build), not chained delta-on-delta. Chained would need the registry and CI to
track and append an ordered list of layers; cumulative needs no state — CI
always appends base + one delta. The cost is that the delta grows until a
squash, which is accepted: `SQUASH=1` rebuilds the base, and
`transfer-bundle.sh` squashes automatically when the delta passes half the
base, which is exactly what a nixpkgs bump produces. Removed packages linger
as orphan store paths until then (disk only, no whiteouts needed).

`build/.layerdrv` stamps the base; `build/.layerdelta` stamps what the delta
was built from. The delta is valid only for the base tarball beside it, so
`transfer-bundle.sh` rebuilds the base when the tarball is missing and
`build-layers.sh --delta` refuses to run without it. On WSL the same change
also produces the usual `wsl-update.nar`, so both targets move with one
small carry; `UPDATE=1` skips the unchanged big artifacts entirely.

## WSL switches exit 4 (WSL >= 2.9.8)

`switch-to-configuration` returns 4 when units fail although the switch
happened. Two known WSL-side sources, both fixed at the config:

- WSL's init generates `wsl-mnt-guard.service` (`ExecStart=/bin/true`);
  NixOS-WSL's minimal `/bin` lacked `true`, so it died 203/EXEC whenever
  `sysinit-reactivation.target` restarted it. `wsl.extraBin` now appends
  coreutils `true` (NixOS-WSL#1100).
- `wsl.interop.register = true` asked systemd-binfmt to bind `WSLInterop`
  again; WSL's init already bound it and the kernel refuses a duplicate name
  with `-EEXIST`. Left at the upstream default (false).

`setup-wsl.sh` still tolerates exit 4 (warns + `systemctl --failed`, then
continues to re-seed `$HOME`); anything else is fatal. The switch has
already happened by then, so aborting would skip step 4 over a degraded
unit.

## No signing, by decision

Integrity is the content-addressed store hash: a damaged path fails on the
path it damaged, not on "the transfer". `SHA256SUMS` in `dist/` is a
post-copy convenience for the carry medium, not the trust anchor. There is no
`require-sigs`/substituter configuration on WSL at all any more — nothing
fetches.

## Identity on the shared PVC

Every runtime user is uid 10001/gid 0 and the hostname is
`<workspace-name>-<n>-<n>`; the OS knows nothing about who you are.
`session_user()` resolves, first hit wins: `$SESSION_USER` → workspace-name
leading component → local part of `git config user.email` → `$USERNAME`/
`$USER`. A baked email deliberately does not exist: the closure is
distributed to a team, and a baked identity would file everyone's state into
one person's PVC directory. For the same reason there is no packaged
`~/.config/git/config` (a store symlink would make `git config --global`
unwritable on the PVC); neutral git settings ship as `/etc/gitconfig`.
`doctor` prints which rule fired.

## The `$HOME` rule

A symlink into `/nix/store` or the toolchain tree is ours; a real file is the
user's. `seed-home` enforces it: defaults and dotfiles are refreshed links, a
real file is never clobbered. `XDG_CACHE_HOME`
is deliberately ephemeral (the PVC is network-backed; nvim/LSP/pip on it are
painfully slow).

## LD_PRELOAD / CUDA split

RunAI injects GPU-fractioning `.so`s through `LD_PRELOAD`; they crash
opencode, but CUDA needs them back in everything the agent runs. The antidote
does **not** unset `LD_PRELOAD` — it replaces it with the libc matching the
target binary's own glibc (a system libc preloaded into a Nix binary is a
`GLIBC_PRIVATE` symbol-lookup error) and stashes the original in
`PRELOAD_ORIGINAL` for children (`agent/plugins/preload.ts` via opencode's
`shell.env`, `agent/restore-preload.sh` via `BASH_ENV`).

**SIGPIPE trap:** `ldd`/`ldconfig -p | awk '…exit'` returns 141 under
`set -o pipefail`, silently killing the launcher. Every such probe carries
`|| true`.

## opencode on old kernels

nixpkgs must patchelf bun (its `PT_INTERP` points into the store), and
patchelf's header sort moves `PT_GNU_STACK` to the front; `bun build
--compile` recycles that slot so the highest-vaddr `PT_LOAD` lands first.
Linux <= 6.6 (WSL2, RHEL 8/9) never maps the BSS and SIGSEGVs in ld.so before
`main`. `opencodeFixed` runs `nix/scripts/fix-phdr-order.py` in `postFixup`
and fails the build if the layout is still unsafe; `tests/test-container.sh`
asserts the shipped binary's LOADs ascend. References:
nixpkgs #520383 / #523047, opencode #26846.

Separately, the binary is AVX2-only (bun compile without `--baseline`): on a
pre-Haswell cluster node it SIGILLs. The fix is a local overlay, not a
downgrade.

**npm stall:** opencode's loader runs an npm install of `@opencode-ai/plugin`
in every config dir at startup; with no registry the TUI stalls ~1.5 min.
Seeding `node_modules/.keep` + a `package-lock.json` declaring the dependency
skips it. Re-check that pair when opencode bumps.

## Zed, offline

The remote server ships in the closure under the client's **exact full
version string** (build metadata included) — `nix/zed-client-version.nix`,
re-pinned in lockstep with the kit installer. The client treats the file as
present iff `<file> version` exits 0, so no download happens. LSPs are pinned
to `/opt/twentyx/profile/bin` in the seeded
`dotfiles/.config/zed/settings.json`; prettier is off. The kit vendors the
nix/toml/tombi/dockerfile/env extensions (nixd and tombi have no built-in
adapter in the server); `UNPACK.ps1` extracts them client-side and removes
`extensions\index.json`, which Zed rebuilds from `installed/` at startup.

## VS Code, offline

The Windows client is Microsoft VS Code, and Remote-WSL demands a server for
the client's exact commit. `nix/vscode-version.nix` pins the release +
commit; `nix/vscode-extensions.nix` pins each `.vsix` with an explicit
fetchurl (no nixpkgs coupling). A oneshot runs as `jensen`, extracts the
server when absent, writes the remote machine settings with `/opt` pins when
absent, and installs the extensions with the server's own CLI.

**Fallback if Remote-WSL fails to start on the real machine:** the stock
server's bundled node runs through `programs.nix-ld`; if the vsce-sign
libssl check defeats that, re-add the `nixos-vscode-server` flake input and
its module (it RPATH-patches the bundled node), and drop the oneshot's
extraction step. Do not keep both.

## LazyVim, offline

`nix/packages/nvim-plugins.nix` builds one linkFarm: every plugin under the
name lazy.nvim derives from its URL, plus `parser/` and `queries/` from the
selected treesitter grammars. `lua/config/airgap.lua` points lazy's `dev` at
it (`patterns = { "" }`, `fallback = false`), disables installs/checker/
change detection, and sets nvim-treesitter's `install_dir` there. Mason is
disabled, so the language servers come from PATH (the profile). The same
derivation runs a headless nvim check **in the Nix sandbox** (no network):
every enabled spec must resolve inside the tree, every wanted parser must be
installed, every LSP binary must be on PATH, and `:messages` must be clean —
a missing piece fails the build, not the airgap session.

## code-server and the arbitrary UID

code-server is in the pod closure (built from source against a baseline
Node), ahead of the base's copy; the `sst-dev.opencode` extension is seeded.
`assemble.sh` records the base's ENTRYPOINT in `BASE_ENTRYPOINT` and the
entrypoint hands over to it, and the session variables are image ENV so
code-server's task runner still gets `TERMINFO_DIRS`/`LOCALE_ARCHIVE`.

OpenShift's arbitrary UID has no passwd entry and a nameless supplementary
gid. Our append-only layers cannot chmod `/etc/passwd`; the documented fix is
a thin derived base:

```dockerfile
FROM <vendor-base>
RUN chgrp 0 /etc/passwd /etc/group && chmod g+w /etc/passwd /etc/group
```

Meanwhile `entrypoint` self-registers the UID/group when `/etc` is writable,
and `doctor` reports whether that worked. Until the derived base exists the
warning is noise, not breakage.

## How this is tested without the gap

`tests/test-container.sh` assembles the image against a mock base
(ubuntu:24.04 in a local registry) and runs it under the problematic pod
shape (`--user 10001:0`, tmpfs PVC, a hostile preloader, an env-injection
mount). It asserts: HOME relocation, closure integrity after `crane append`,
the preload split (bare opencode dies, the launcher survives, children get
the preload back), address-ascending `PT_LOAD`s, defaults as store symlinks
vs dotfiles as real files, Zed pins at `/opt`, the env-injection contract,
sudoers + setuid sudo, nginx, and repo-layer determinism.

Two harness artifacts, not image bugs: the sudo PAM error under rootless
podman (setuid-root maps to the host user, which cannot read `/etc/shadow`),
and a signal-death exit code of 139 or 134 depending on opencode's own
handlers.

`tests/test-gpu-cuda.sh` is opt-in for GPU hosts (nvidia CDI setup in its
header) — in practice gpubox only.

## The local store repair (2026-09)

The default store had never held the layer's build-plan closure (6,034
paths: `.drv` files, patches, source trees); the layer builds lived in the
chroot store `/tmp/airgap-test-store`, which built the same eval fine. Three
damage classes, each with a different remedy:

1. *file + row missing* (545 `.drv` files): `nix copy` skips these (its
   skip-on-row logic) — needs a file copy **and** row registration;
2. *row present, file lost*: `nix copy` silently skips them ("copying 0
   paths"), and `nix build` believes the path is realized until build-env
   setup trips over the missing file — only a file copy fixes these;
3. *rows for paths in no store anymore*: harmless unless a current eval
   references them; `sudo nix-store --verify --check-contents --repair`
   substitutes or unregisters the rest.

The repair that worked (chroot store as donor):

    nix path-info --store /tmp/airgap-test-store -r <top-drv...>
    sudo xargs -a missing.txt -I{} cp -a "/tmp/airgap-test-store{}" /nix/store/
    sudo nix copy --from /tmp/airgap-test-store --to daemon <top-drv...>
    sudo nix-store --verify --check-contents --repair

Two facts worth remembering: **`/nix/store` was never read-only** (the
"remount first" advice was wrong — remount-rw on an already-rw mount fails
`EBUSY`), and running `nix copy` as root **from** a chroot store leaves
root-owned lock files in the donor, so the next build there dies with
`opening lock file ... Permission denied`; `sudo chown -R <you>
/tmp/airgap-test-store` fixes it. Both layer flavors build on the default
store (verified 2026-09); the chroot remains the throwaway fallback.

## Shell gotchas worth keeping

- **One heredoc per language.** A bash heredoc nested inside a generated
  fish file made fish refuse the whole file ("Expected a string, but found a
  redirection"), so no PATH or env reached any interactive pod shell and
  podman's `storage.conf` was never written. The test suite now feeds the
  generated fish to `fish -n` and asserts `storage.conf` exists.
- **tmux panes opened as bash** because the tmux server inherited
  `BASH_EXECS_FISH`; the config sets `default-shell` to the profile fish
  directly.
- **`find` does not descend into a symlinked starting point** — `seed-home`
  resolves `home-defaults` with `readlink -f` first, or every default would
  link to a garbage path and the install loop would silently no-op.
