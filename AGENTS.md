# AGENTS.md (outside repo)

The connected half of an **airgapped** toolchain: Nix builds the closures for
a NixOS-WSL laptop and RunAI/OpenShift pods, and `scripts/transfer.sh` turns
them into files that cross the gap. `README.md` is the map, `MANUAL.md` the
operations, `NOTES.md` the why; read them before a non-trivial change.
`inside-seed/CONTRACT.md` is the interface with the inner repo.

## Never edit Linux-side config here

Dotfiles, pod scripts, CI, Windows client configs and publishing belong to
the **inner repo**. `inside-seed/` is only the outside's reference copy of
it: the handover payload, the test fixture, and the spec the LazyVim check
and the Windows kit read. Change it only to mirror a change the inside must
make, and record that change as a numbered required edit in `HANDOVER.md`
(intent, exact snippet, verify step). The contract is
`inside-seed/CONTRACT.md` alone: the inner repo's file, one copy.

## Verification

```bash
nix flake check                      # both targets + the LazyVim sandbox check
nix build .#pod-opt                  # the pod closure
./tests/test-container.sh            # podman; TEST_KEEP=1 keeps the registry
nix shell nixpkgs#shellcheck -c shellcheck -S warning scripts/*.sh install/apply.sh tests/*.sh \
    inside-seed/pod/* inside-seed/wsl/*.sh inside-seed/docker/*.sh inside-seed/scripts/*.sh
```

Run the container test after touching `nix/profile.nix`, `nix/runai/`,
`scripts/pod-tar.sh` or anything in `inside-seed/`. Shell style:
`set -euo pipefail`, `say()` for status, a header comment with a usage line.

## Rules

- **Nothing evaluates Nix inside the gap.** WSL updates are a NAR import
  (`install/apply.sh`); pods never run Nix. No implicit runtime fetch: a
  failed fetch in the gap is a hang. Every runtime auto-update stays off.
- **Git is text only.** No vendored blobs; binaries are fetched by hash in
  Nix. `nix flake update` runs only here.
- **The flake attribute names `pod-opt`, `wsl-system`, `wsl-tarball`,
  `windows-kit` are a contract with every past `base.rev`** (the transfer
  builds the base from its own rev). Renaming one needs a rebase.
- **Keep closure changes at the leaves.** Overriding a shared dependency
  rebuilds its dependents and bloats every delta (the opencode phdr fix is
  the pattern: a `postFixup` on the leaf).
- **Stable paths:** anything a config points at lives under
  `/opt/twentyx/profile/bin` or `/opt/twentyx/home-defaults`; never hand a
  `/nix/store` path to the inside.
- **Session env** belongs in `nix/profile.nix` (`sessionEnv`): image ENV in a
  pod, `environment.sessionVariables` on WSL.
- **Pins that move together:** Zed installer ↔ `nix/zed-client-version.nix`;
  `nix/vscode-version.nix` ↔ `nix/vscode-extensions.nix`.
- **The pod closure roots** include the session-env file, so whatever image
  ENV names ships. Keep it that way.
- `ldd ... | awk '... exit'` under `pipefail` returns 141: add `|| true`.
- Do not commit, push or rebase without asking the owner.
