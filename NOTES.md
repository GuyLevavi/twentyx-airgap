# Notes: open items and the why (outside)

What is still open, and the reasoning behind the pieces that are
load-bearing and must not be "simplified". The pod-side why (session.env,
preload split, identity, `$HOME` rule) is in `inside-seed/NOTES.md`.

## Open items

- **`nixos-wsl.tar.gz` is ~2954 MB, 4% under the 3072 MB/file cap**, and 7z
  cannot shrink a gzip. If it crosses, the transfer refuses; the fix is
  trimming the WSL closure, not splitting the file.
- **WSL full NAR size** after 7z (expected ~1.3 GB) and unpacked (several GB)
  against the inside GitLab's `max_package_size`: measure at the first rebase.
- **opencode is AVX2-only** (bun compile without `--baseline`): it SIGILLs on
  a pre-Haswell node. The fix would be a local overlay, not a downgrade.
- **First release on the real bases and runners** (inside NOTES.md lists the
  pod-side checks).

## Nothing evaluates Nix inside the gap

The old WSL side rebuilt config inside, and it never worked: the shipped
closure lacked the build-time inputs every home-manager rebuild needs
(`lndir`, `babelfish`, `json2x`, `jq.dev`, buildEnv's `builder.pl`), and the
only rebuild that succeeded was a no-op. So the model is: this machine builds
everything, files cross, the far side only imports.

- WSL keeps the `nix-store`/`nix-env` binaries for import, profile switching,
  rollback and GC. `nix.settings.substituters = lib.mkForce [ ]` (a plain
  `[ ]` still merges in `cache.nixos.org`); no flakes, no `nix-command`.
- Config is the inner repo's text, linked into `$HOME`; the closure only
  provides binaries and binary-coupled defaults under stable paths
  (`/opt/twentyx/profile`, `/opt/twentyx/home-defaults`). A store path baked
  into a config goes stale on the next update; a stable path does not.

## Deltas: cumulative against one pinned base

Nothing comes back out of the gap to say what a machine has, so every delta
is computed against `base.rev`, which every machine is known to have (it
installed from that base's rootfs, or imported its full NAR). Store paths
are immutable, so a delta is just the paths HEAD adds; skipping or
reordering deltas is harmless. Removed packages linger until a rebase (disk
only). The transfer builds the base's closures from `git+file:.?rev=<base>`,
so the flake attribute names are a contract with every past base: renaming
one needs a rebase.

- **Pods:** a tar layer. `pod-tar.sh` writes the `/opt/twentyx` tree first
  (so `assemble.sh` finds `session-env` with `--occurrence=1`), then the store
  paths, deterministically (`--sort=name --mtime=@1 --owner=0`, `gzip -n`).
  The delta's `opt/` overlays the full layer's: identical paths, no
  whiteouts.
- **The setuid sudo** is a tar member with mode 4555: a mode bit in a tar
  header is data, while Nix forbids setuid *files* in outputs.
- **WSL:** a NAR, because NixOS-WSL remounts `/nix/store` read-only (a plain
  `tar -x` fails) and `nix-store --import` is atomic, verifies hashes and
  refuses a delta whose references are missing. `nix-store --load-db` was
  rejected: it registers paths whose files do not exist as valid. An empty
  export (8 bytes) imports as a no-op, so a release always has the same
  files. The NAR is one `nix-store --export` with the paths as argv:
  concatenated exports import only up to the first end marker.
- `apply.sh` roots the base (`/nix/var/nix/gcroots/twentyx-base`), so the
  monthly GC cannot collect what later deltas assume.

## The rootfs builder needs real root

The upstream NixOS-WSL builder chroots and bind-mounts, hence `sudo`. A
previous rootless builder existed only to dodge user-namespace EINVALs; with
real root those workarounds are gone. No `--chown home/jensen`: it runs
before `nixos-install` (it is for `--extra-files`), and activation creates
the home as 1000:100 anyway. The rootfs is built from `base.rev`, so a fresh
install already has the base.

## WSL switches exit 4 (WSL >= 2.9.8)

`switch-to-configuration` returns 4 when units fail although the switch
happened. Two WSL-side sources, both fixed in `wsl.nix`:

- WSL's init generates `wsl-mnt-guard.service` (`ExecStart=/bin/true`);
  NixOS-WSL's minimal `/bin` lacked `true`. `wsl.extraBin` adds it
  (NixOS-WSL#1100).
- `wsl.interop.register = true` re-bound `WSLInterop`, which WSL's init
  already binds (`-EEXIST`). Left at the upstream default (false).

`apply.sh` still treats exit 4 as a warning and prints `systemctl --failed`.

## No signing, by decision

Integrity is the store hash: a damaged path fails on that path, and
`nix-store --import` checks every NAR hash. There is no `require-sigs` and no
substituter on WSL at all, because nothing fetches.

## opencode on old kernels

nixpkgs patchelfs bun, and patchelf's header sort moves `PT_GNU_STACK` first;
`bun build --compile` recycles that slot so the highest-vaddr `PT_LOAD` comes
first. Linux <= 6.6 (WSL2, RHEL 8/9) then never maps the BSS and SIGSEGVs in
ld.so. `opencodeFixed` runs `nix/scripts/fix-phdr-order.py` in `postFixup`
and fails the build if the layout is still unsafe; `tests/test-container.sh`
asserts the shipped LOADs ascend. nixpkgs #520383 / #523047, opencode #26846.

## Zed, offline

The remote server ships in the closure under the client's **exact full
version string** (`nix/zed-client-version.nix`), re-pinned with the kit's
installer: the client treats the file as present iff `<file> version` exits
0, so nothing downloads. It sits in `home-defaults/.zed_server/`, and the
inside links `~/.zed_server` to that directory once. The kit vendors the
nix/toml/tombi/dockerfile/env extensions (nixd and tombi have no built-in
adapter); `UNPACK.ps1` extracts them and drops `extensions\index.json`, which
Zed rebuilds at startup.

## VS Code, offline

Remote-WSL demands a server for the client's exact commit.
`nix/vscode-version.nix` pins release + commit; `nix/vscode-extensions.nix`
pins each `.vsix` by explicit fetchurl. A oneshot in `wsl.nix` extracts the
server when absent and installs the extensions with the server's own CLI;
the LSP pins are an inside dotfile
(`.vscode-server/data/Machine/settings.json`).

**Fallback if Remote-WSL fails on the real machine:** the stock server's node
runs through `programs.nix-ld`; if the vsce-sign libssl check defeats that,
re-add the `nixos-vscode-server` flake input and module (it RPATH-patches the
bundled node) and drop the oneshot's extraction. Never both.

## LazyVim, offline

`nix/packages/nvim-plugins.nix` builds one linkFarm: every plugin under the
name lazy.nvim derives from its URL, plus treesitter `parser/` and
`queries/`. The inner repo's nvim config points lazy's `dev` at it
(`TWENTYX_NVIM_PLUGINS`, `fallback = false`), with installs, checker and
Mason off. Its `.check` (a flake check, so every transfer runs it) runs a
headless nvim **in the Nix sandbox** against
`inside-seed/dotfiles/.config/nvim`, kept out of the tree so the closure
never depends on inside text: every spec must resolve, every parser
exist, every LSP be on PATH, `:messages` be clean. A plugin the inside wants
is therefore a request: add it to `pluginAttrs` and to the seed's spec
together.

## Pod closure roots

The pod closure is rooted at the profile, `home-defaults` **and the
session-env file**. Before that, three store paths named by image ENV
(`TWENTYX_NVIM_PLUGINS`, `LOCALE_ARCHIVE`, the wezterm terminfo in
`TERMINFO_DIRS`) were missing from every pod image.

## How this is tested without the gap

`tests/test-container.sh` packs a release with `pod-tar.sh`, assembles the
image with `inside-seed/docker/` against a mock base (ubuntu:24.04 in a local
registry), and runs it as the problematic pod: `--user 10001:0`, tmpfs PVC, a
hostile preloader, an env-injection mount, plus a `podman exec` session like
`runai exec`. It checks HOME relocation, closure integrity, the preload split,
ascending `PT_LOAD`s, dotfile links and real-file precedence, git identity,
Zed/code-server links, session.env in bash and fish, sudoers + setuid sudo,
and layer determinism. Harness artifacts, not bugs: the sudo PAM error under
rootless podman, and exit 139 vs 134 for a signal death.

`tests/test-gpu-cuda.sh` is opt-in for a GPU host (CDI setup in its header).

## The local store repair (2026-09)

The default store had never held the layer's build-plan closure (6,034
paths: `.drv` files, patches, sources); builds had lived in the chroot store
`/tmp/airgap-test-store`. Three damage classes:

1. *file + row missing* (545 `.drv`s): `nix copy` skips these; needs a file
   copy **and** row registration;
2. *row present, file lost*: `nix copy` silently skips them, and `nix build`
   trips later; only a file copy fixes them;
3. *rows for paths in no store*: harmless unless referenced;
   `sudo nix-store --verify --check-contents --repair` cleans up.

The repair that worked:

    nix path-info --store /tmp/airgap-test-store -r <top-drv...>
    sudo xargs -a missing.txt -I{} cp -a "/tmp/airgap-test-store{}" /nix/store/
    sudo nix copy --from /tmp/airgap-test-store --to daemon <top-drv...>
    sudo nix-store --verify --check-contents --repair

`/nix/store` on this machine was never read-only (remount-rw fails `EBUSY`),
and `nix copy` as root from a chroot store leaves root-owned locks there:
`sudo chown -R <you> /tmp/airgap-test-store`.
