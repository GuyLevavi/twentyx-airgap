# twentyx-airgap

A frozen appliance for an airgapped RunAI/OpenShift lab: one toolchain, built
on a connected machine, carried across physically, and never fetched at
runtime — in a pod or in the Windows laptop's NixOS-WSL distro.

Nix computes the closure on the connected machine. Nothing evaluates Nix
inside the gap: a WSL update is a store delta imported and switched, a pod
image is a layer appended registry-side.

## Two targets, one source of truth

| | WSL (frozen appliance) | RunAI pod (OCI layer) |
|---|---|---|
| What it is | a real NixOS system inside the gap | a read-only tree appended to an internal base |
| Nix at runtime | `nix-store`/`nix-env`: import a delta, switch | never |
| How it arrives | `nixos-wsl.tar.gz` (first) / `wsl-update.nar` (updates) | `crane append`, `docker/assemble.sh` |
| Package set | `nix/packages.nix`, one profile for both targets | same |
| Config | `dotfiles/` seeded once into `$HOME` | same, via the repo layer |
| Editors | Zed + VS Code Remote-WSL + LazyVim | code-server + Zed remote server |
| Python | Nix (3.12, uv, ruff) | the base's — it owns torch and CUDA |

`nix/profile.nix` builds the one package profile, session environment and
tree of packaged defaults both targets consume. Adding a package changes both.

## Stable tool paths

`/opt/twentyx/profile/bin/<tool>` works on both targets (on WSL it is a
symlink to the system profile). Editor settings point there, so they survive
updates; a store path baked into a config file would go stale on the next
transfer.

## The one `$HOME` rule

A symlink into `/nix/store` is ours and refreshed on every start (packaged
defaults). A real file is yours and is never touched (dotfiles are copied in
once, then they are yours). Config edits inside the gap are local and
durable; changing the closure is what needs a transfer.

## Editors, fully offline

- **Zed** — the remote server ships in the closure under the client's exact
  full version string; language servers are pinned to
  `/opt/twentyx/profile/bin`; the Windows kit vendors the nix/toml/tombi/
  dockerfile/env extensions and `UNPACK.ps1` installs them client-side (the
  client uploads them to the remote on connect). Auto-update and
  `auto_install_extensions` are off.
- **VS Code** — the server tarball is pinned and seeded by a oneshot; the
  pinned `.vsix` set installs with the server's own CLI. Updates off on both
  sides.
- **LazyVim** — plugins and treesitter parsers are a Nix-built tree that
  lazy.nvim resolves through its `dev` mechanism; mason is disabled and the
  servers come from the profile. A headless nvim check runs in the Nix
  sandbox, so a missing plugin or parser fails the build.
- **opencode** — the models catalog is baked in, autoupdate is off, and the
  plugin/skills/node_modules seeds short-circuit the startup npm install.

## The transfer

`./scripts/transfer-bundle.sh` builds plain artifacts in the gitignored
`build/` and assembles `dist/`: every big artifact inside a `.7z` container
(the pipeline drops big gzip), plus the small text files — docs, setup
scripts, the repo bundle, `MANIFEST.txt`, `SHA256SUMS`. On Windows,
`SETUP.ps1` imports the image, runs `UNPACK.ps1`, and runs `setup-wsl.sh`
inside the distro.

## The LD_PRELOAD / CUDA split

RunAI injects GPU-fractioning libraries via `LD_PRELOAD`; they crash
opencode, but CUDA needs them back in every command the agent runs.
`libexec/run-opencode` replaces the preload with the libc matching the
binary's own glibc and stashes the original; `agent/plugins/preload.ts` and
`agent/restore-preload.sh` restore it for children.

## Read next

- [`MANUAL.md`](MANUAL.md) — build → carry → Windows setup → WSL
  update/rollback → pods → debugging.
- [`ARCHITECTURE.md`](ARCHITECTURE.md) — the tour, with a reading order.
- [`NOTES.md`](NOTES.md) — open items and the why behind the load-bearing
  pieces.
- [`AGENTS.md`](AGENTS.md) — the rules for changing this repo.
