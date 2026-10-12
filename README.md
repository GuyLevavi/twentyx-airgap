# twentyx-airgap (outside repo)

The connected half of the TwentyX airgap toolchain. One Nix build here feeds
two targets inside the gap: a NixOS-WSL distro on Windows laptops and
RunAI/OpenShift workspace images. Nothing is fetched inside; everything
crosses as planned artifacts.

There are two repos, split by who can change what ([`inside-seed/CONTRACT.md`](inside-seed/CONTRACT.md)):

- **This repo (outside, the owner only):** the flake and `nix/` (the
  closures), the transfer, the WSL installer.
- **The inner repo (internal GitLab):** dotfiles and every Linux-side config,
  the pod boot scripts, the Windows client configs, CI, publishing.
  `inside-seed/` here is the outside's reference copy of it: the handover
  payload, the fixture `tests/test-container.sh` runs against, and the spec
  the LazyVim check and the Windows kit read. It is not live config; the
  inner repo wins.

Artifacts cross the gap; git history does not. Requests come out by hand
(the inner `REQUESTS.md`); changes to inside files go in as numbered required
edits ([`HANDOVER.md`](HANDOVER.md)).

## Layout

| Path | What |
|---|---|
| `flake.nix`, `flake.lock` | inputs; outputs `pod-opt`, `wsl-system`, `wsl-tarball`, `windows-kit` (the names are the contract with `base.rev`) |
| `nix/packages.nix` | the package list, both targets |
| `nix/profile.nix` | the profile, session variables, binary-coupled `home-defaults` |
| `nix/hosts/wsl.nix` | the WSL system |
| `nix/runai/layer.nix` | the pod's `/opt/twentyx` tree and closure list |
| `nix/packages/` | nvim plugin tree (+ its sandbox check), the Windows kit |
| `scripts/transfer.sh`, `scripts/pod-tar.sh` | build a transfer into `dist/` |
| `install/` | `SETUP.ps1`, `UNPACK.ps1` (Windows), `apply.sh` (WSL updater) |
| `base.rev` | the outside rev whose closures every machine already has |
| `tests/` | the pod reproduced locally; the GPU test |
| `inside-seed/` | the inner repo as the outside knows it |

## How it works

Nix builds **store paths**: immutable, content-addressed, each naming its
dependencies by hash. A **closure** is a path plus everything it references,
so if a program is in it, nothing it needs is missing. Nothing evaluates Nix
inside the gap: this machine builds both closures and ships them as files.

- **Pods:** the closure lands at literal `/nix/store` as an OCI layer tar
  (`pod-*.tar.gz`) that inner CI appends onto the internal bases with
  `crane append`; the 15–30 GB bases are never pulled. The `/opt/twentyx`
  tree on top gives stable paths (`profile/bin/<tool>`, `home-defaults/`).
- **WSL:** a full NixOS system, imported once from a rootfs and updated with
  `nix-store --import` of a NAR, `nix-env --set`, switch. Nix is a quiet
  package database there: no substituters, no flakes, no rebuilds.
- **Deltas** are cumulative against `base.rev`: each transfer ships what HEAD
  adds to the base. Store paths only add, so any delta applies to any machine
  that has the base, in any order. A **rebase** ships full closures plus the
  install set and moves `base.rev`.

## Read next

- [`MANUAL.md`](MANUAL.md): build, transfer, install, update, rollback.
- [`NOTES.md`](NOTES.md): why the load-bearing pieces are the way they are.
- [`AGENTS.md`](AGENTS.md): rules for changing this repo.
- Reading order for the code: `flake.nix` → `nix/packages.nix` +
  `nix/profile.nix` → `nix/hosts/wsl.nix` → `nix/runai/layer.nix` →
  `scripts/transfer.sh` + `pod-tar.sh` → `install/` → `tests/test-container.sh`.
