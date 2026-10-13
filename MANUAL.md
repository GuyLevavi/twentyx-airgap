# Manual (outside)

From a change here to a machine in the gap. The why is in
[`NOTES.md`](NOTES.md); the inside operations (publishing, CI, pods, WSL
config) are the inner repo's `MANUAL.md`.

## 0. Checks

```bash
nix develop                          # shellcheck, nixfmt, crane, jq, 7z, ...
nix flake check                      # both targets + the LazyVim sandbox check
nix build .#pod-opt                  # the pod closure
./tests/test-container.sh            # the pod, reproduced (podman); against inside-seed/
shellcheck -S warning scripts/*.sh install/apply.sh tests/*.sh \
    inside-seed/pod/* inside-seed/wsl/*.sh inside-seed/docker/*.sh inside-seed/scripts/*.sh
```

If `nix build` says "store path ... does not exist", the local store lost
files or DB rows: NOTES.md "The local store repair".

## 1. Transfer

Commit first (a dirty tree is refused; `ALLOW_DIRTY=1` makes a `-dirty`
release for testing only).

```bash
nix develop -c ./scripts/transfer.sh             # a delta against base.rev
nix develop -c ./scripts/transfer.sh --rebase    # full closures + install set
git add base.rev && git commit -m "base: <RELEASE>"   # after a --rebase
```

`dist/` gets, every time: `pod-<kind>.tar.gz.7z`, `wsl-<kind>.nar.7z`,
`MANIFEST.txt`, `apply.sh`, `HANDOVER.md`, `inside-seed.tar`. A rebase adds
`nixos-wsl.tar.gz.7z` (built from the new base, under `sudo`; the password
prompt comes first), `windows-kit-*.tar.gz.7z`, `SETUP.ps1`, `UNPACK.ps1`.
Every file must stay under the 3072 MB transfer cap; the script refuses
otherwise.

**When to rebase:** the first transfer; a nixpkgs bump; deltas past ~300 MB;
a Windows kit change (Zed, VS Code, WezTerm, WSL MSI). The script warns for
each. Machines that missed a rebase need its `wsl-full.nar` (from the
package registry) before a later delta imports.

**Handover:** before transferring, add an entry to `HANDOVER.md` for every
change the inside must act on (required edits to inside files, with intent,
snippet and verify step), and mirror inside-file changes in `inside-seed/`.

## 2. Install and update in the gap

One procedure, kept in the inner repo's manual: `inside-seed/MANUAL.md` §4
(Windows install with `SETUP.ps1`, from a transfer folder or the package
registry; WSL updates with `apply.sh` or `wsl/update.sh`; rollback). What
the outside guarantees for it: `SETUP.ps1`/`UNPACK.ps1` and the rootfs ship
with every rebase, `apply.sh` and `MANIFEST.txt` with every release, and a
delta imports on any machine that has its base.

## 3. Answering requests

A carried-out `REQUESTS.md` line becomes a change here: a package in
`nix/packages.nix`, a system setting in `nix/hosts/wsl.nix` (keep it at the
leaves: overriding a shared dependency rebuilds its dependents and bloats the
delta), a LazyVim plugin in `nix/packages/nvim-plugins.nix` plus the spec in
`inside-seed/dotfiles/.config/nvim/`. Then transfer, with a `HANDOVER.md`
entry if inside files must change.

## 4. Re-pinning

Pins that move together, in one commit:

- the Zed installer in `nix/packages/windows-kit.nix` ↔
  `nix/zed-client-version.nix` (the client's exact `zed --version` string);
- `nix/vscode-version.nix` ↔ `nix/vscode-extensions.nix`;
- the WezTerm nightly: name date + hash in `windows-kit.nix` (header there).

All three change the kit, so they ship with a rebase. `nix flake update`
runs only here.
