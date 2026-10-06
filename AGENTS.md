# AGENTS.md

A toolchain for an **airgapped** RunAI/OpenShift environment and a NixOS-WSL
laptop, from one source of truth. `README.md` is the authoritative overview;
`ARCHITECTURE.md` is the how-it-works tour with a reading order for new
readers; `MANUAL.md` is the step-by-step; `NOTES.md` holds open items and the
why behind load-bearing pieces. Read them before making non-trivial changes.

## Verification

```bash
./tests/test-container.sh    # full image integration, needs podman (mock base + local registry)
nix shell nixpkgs#shellcheck -c shellcheck -S warning libexec/* agent/*.sh tests/*.sh scripts/*.sh docker/*.sh
nix flake check                            # evaluates both targets
nix build .#runai-layer                    # real check that the closure builds
nix build .#runai-layer-nvim               # also runs the headless nvim offline check (Nix sandbox)
nix develop                                # devshell: shellcheck, shfmt, nixfmt, statix, deadnix, crane, skopeo, dive, jq, 7z
```

`tests/test-container.sh` simulates the problematic pod (uid 10001, gid 0,
hostile LD_PRELOAD, env-injection mount) — run it after touching anything in
`libexec/`, `agent/`, `docker/`, or the layer. `TEST_KEEP=1` leaves the local
registry up for debugging; `TEST_NIX_LAYER=...` reuses a prebuilt layer.
Match the existing shell style: `set -euo pipefail`, `say()` for status
output, comment headers with a usage line. There is no `bin/` dispatcher —
libexec scripts are the entry points (`doctor`, `run-opencode`, `bootstrap`,
`seed-home`, `entrypoint`, `sshd-inetd`).

## The one distinction that drives everything

| Change type | Where | Deploy cost |
|---|---|---|
| `libexec/`, `agent/`, `dotfiles/` | git text | CI re-tars `repo-layer.tar` per commit (no transfer) |
| anything in `flake.nix` / `nix/` | closure | rebuild → **physical transfer** |

`nix/packages.nix` is the package list; adding a package changes both
targets. `nix/profile.nix` builds the profile, the session environment and
the packaged defaults. `dotfiles/` is seeded into `$HOME` **once** and then
belongs to the user — editing a seeded file in the repo changes nothing for
an existing home.

## Never evaluate Nix inside the gap

- WSL updates are a store delta (`wsl-update.nar`): `nix-store --import`,
  `nix-env --set`, `switch-to-configuration switch`. The base is the GC root
  `.gcroots/wsl-system`; `transfer-bundle.sh` advances it only after a
  successful export. Rollback is `nix-env --rollback` + switch.
- Pods never run Nix: `nix/runai/layer.nix` extracts the built closure as an
  OCI layer tarball; `docker/assemble.sh` appends it registry-side.
- No runtime fetch anywhere: opencode's model fetch/updates are off, Zed's
  auto-update and `auto_install_extensions` are off, npm is seeded around,
  and LazyVim resolves through lazy's `dev` mechanism. A runtime fetch in the
  gap is a hang, not an error.

## Transfers

`./scripts/transfer-bundle.sh` builds plain artifacts in the gitignored
`build/` and assembles `dist/` (every big artifact in a `.7z` container,
small text files plain). Stamps (`build/.layerdrv`, `.wlldrv`,
`.updatestamp`) rebuild only what a closure change requires; `repo-layer.tar`
is rebuilt every run. A dirty worktree is refused (`ALLOW_DIRTY=1`). The WSL
tarball is built by the upstream builder under `sudo`
(`--chown home/jensen 1000:100`). `dist/` is wiped and rebuilt each run.

## Nix rules

- Git is text-only, enforced by design. No vendored blobs, no binaries, no
  lockfile-generated artifacts; the closure replaces any manifest scheme.
- Pin inputs deliberately; `nix flake update` runs only on a connected
  machine. Pins that must move together: the Zed kit installer ↔
  `nix/zed-client-version.nix`, and `nix/vscode-version.nix` ↔
  `nix/vscode-extensions.nix`.
- Session env belongs in `nix/profile.nix` (`twentyx.sessionEnv`), which
  becomes image ENV in a pod and `environment.sessionVariables` on WSL.

## Image assembly (`docker/`)

Bases are 15–30 GB; two layers are appended registry-side with `crane
append`, never `FROM base-pytorch`. Constraints that are silent failures, not
build errors:

- the closure must land at literal `/nix/store` — ELF interpreters are
  absolute store paths;
- `crane mutate` must **prepend** to the base's `PATH` and never replace
  `ENTRYPOINT` — the base's is stashed in `BASE_ENTRYPOINT` and handed over;
- session env must be image ENV via `layer.nix`'s `session-env`, not shell
  rc — `runai exec` and code-server never source rc files;
- Nix strips setuid bits from build outputs; the setuid `sudo` copy is made
  in `mklayer.sh` (`chmod 4555`, not 4755).

## `$HOME` layering rule

A symlink into `/nix/store` is ours and refreshed on every start; a real file
is the user's and is never touched. `libexec/seed-home` is the only writer:
packaged defaults as store symlinks, dotfiles copied once. `XDG_CACHE_HOME`
is deliberately ephemeral (local disk). For an arbitrary UID with no passwd
entry the runtime sets `HOME=/`; `entrypoint` and `run-opencode` re-resolve
it via `session_home()` — keep those in sync when touching identity.

## Environment-provided assets

Cluster-specific files (internal CA bundle, pip.conf) are never baked in:
`/opt/airgap-env` (ConfigMap mount) wins over `/data/.airgap-env` (shared
PVC). Known files are wired to env vars by `injection_exports()` in
`common.sh`, consumed by bootstrap (drop-ins), the entrypoint (exec'd
payloads) and the launcher (agent tree) — keep all three in sync. CRI exec
(`runai exec -- cmd`) sees none of these; scripts reached that way must
self-resolve.

## Editors & agents

- opencode is `opencodeFixed` (phdr reorder, required on Linux ≤ 6.6) in the
  profile; the LD_PRELOAD split (`run-opencode` + `preload.ts` +
  `restore-preload.sh`) is load-bearing.
- Zed and VS Code settings pin `/opt/twentyx/profile/bin/...`; never bake a
  store path into a config file.
- LazyVim plugins and treesitter parsers come from
  `nix/packages/nvim-plugins.nix`; the headless check runs in the Nix
  sandbox when that derivation builds.
- Zed/SSH into a pod rides `sshd -i` inside `runai exec` stdio
  (`libexec/sshd-inetd` + `scripts/ssh-bridge.sh`); no pty anywhere on that
  path — a pty corrupts the SSH protocol.

## Gotchas

- `push-gitlab-packages.sh` / `push-artifactory.sh` (image layers) are a
  different flow from the WSL transfer (`transfer-bundle.sh` →
  `setup-wsl.sh`) — don't confuse them.
- `mklayer.sh` stages `libexec/`, `agent/`, `dotfiles/`, `VERSION` and the
  generated `etc/` files; it is the one-commit deploy path.
- `ldd`/`ldconfig -p | awk '…exit'` returns 141 (SIGPIPE) under `pipefail` —
  always add `|| true`.
- `find` does not descend into a symlinked starting point; `seed-home`
  resolves `home-defaults` first.
- The local-store repair history is in NOTES.md ("the local store repair").
