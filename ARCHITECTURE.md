# Architecture — what is going on here, and in what order to read it

For someone landing in this repo cold: what the technology is, how the pieces
work, and the order to read them so each file makes sense when you open it.
[`README.md`](README.md) is the overview, [`MANUAL.md`](MANUAL.md) the
do-this, [`NOTES.md`](NOTES.md) open items and the why; this file is the map
between them.

## The situation

Two environments must work with **zero network access**:

1. **A RunAI/OpenShift cluster** — GPU pods on an airgapped network. You get
   a pod with a random UID, a shared PVC, a Python base image you don't own,
   and a GPU-fractioning middleware that injects libraries through
   `LD_PRELOAD`.
2. **The Windows laptop** — which runs the same toolchain as a full NixOS
   system inside WSL2, because the machine itself is outside the gap.

Everything the pod will ever need (compilers, editors, the agent binary, man
pages) must cross the gap as **planned artifacts**, never fetched at runtime.
The repo is one machine that produces those artifacts.

## The one idea: Nix computes the closure on the connected machine

Nix builds software into **store paths** — content-addressed, immutable
directories like `/nix/store/x2qk5vrr…-nixd-2.9.2/bin/nixd`. A **closure**
is a store path plus every store path it references, recursively: if a
program is in the closure, nothing it needs can be missing, and the hash in
the path name proves the bytes. A **flake** (`flake.nix`) pins its inputs by
hash (`flake.lock`).

This repo's rule is the consequence: **nothing evaluates Nix inside the
gap.** The connected machine evaluates and builds everything; what crosses
is plain files.

Two evaluations, one source of truth:

| flake output | shape | arrives as |
|---|---|---|
| `nixosConfigurations.wsl` | a complete NixOS system | `nixos-wsl.tar.gz` (first) / `wsl-update.nar` (updates) |
| `packages.runai-layer{,-nvim}` | a read-only tree of store paths | `nix-layer.tar.gz` appended to a base by CI |

`nix/packages.nix` is the package list, `nix/profile.nix` builds the profile
+ session environment + packaged defaults, and `dotfiles/` is plain text. A
package change moves the closure (physical transfer); a text change is one
commit.

## What crosses the gap

| Artifact | Made by | Lands in |
|---|---|---|
| `wsl-update.nar` | `transfer-bundle.sh` (delta against `.gcroots/wsl-system`) | `nix-store --import` on the distro |
| `nix-layer*.tar.gz` | `scripts/build-layers.sh` → `push-gitlab-packages.sh` (Artifactory fallback) | GitLab generic packages, appended onto base images by CI |
| `nixos-wsl.tar.gz` | the upstream NixOS-WSL builder under sudo | `wsl --import` on Windows |
| `windows-kit-*.tar.gz` | `nix build .#windows-kit` | `UNPACK.ps1` on Windows |
| `repo-layer.tar` | `docker/mklayer.sh` (also per-commit in CI) | appended after the closure layer |
| `twentyx-airgap.bundle` | `git bundle` | `git clone` for history |

`scripts/transfer-bundle.sh` assembles the flat `dist/`: every big artifact
inside a `.7z` container (the pipeline drops big gzip), the small text files
plain, plus `MANIFEST.txt` and `SHA256SUMS`. Windows unpacks with 7-Zip,
then `SETUP.ps1` imports the rootfs, unpacks the kit, and runs
`setup-wsl.sh` inside the distro.

There is deliberately no signing: Nix verifies per store path, which is
stronger than a tarball signature. `SHA256SUMS` is a post-copy convenience
for the carry medium, not the trust anchor.

## How the pod image is assembled (and why not Dockerfile)

The pytorch bases are 15–30 GB. A `FROM base-pytorch` build unpacks the whole
thing into the build pod's ephemeral disk — it dies. But everything we add is
just files, and an OCI image is a stack of tar-layer diffs. So:

```
base manifest (never pulled, never unpacked)
   + nix-layer.tar.gz      the closure, landed at literal /nix/store
   + repo-layer.tar        this repo's text (libexec/, agent/, dotfiles/, defaults)
   = assembled image, done registry-side by CI with `crane append`
```

Three hard constraints that are silent failures if ignored
(`docker/assemble.sh`):

- the closure must be at `/nix/store` — ELF interpreters are absolute paths;
- the base's `PATH` must be **prepended** to, not replaced (torch needs its
  conda paths first);
- `ENTRYPOINT` must never be replaced — the base's is recorded in
  `BASE_ENTRYPOINT` and handed back by our entrypoint, or a `vscode-*`
  workspace boots with no IDE.

## How a pod boots, and what each script does

The runtime user is arbitrary (uid 10001, gid 0, no passwd entry), `$HOME` is
a wiped tmpfs, and RunAI preloads GPU-fractioning `.so` files that crash the
agent binary. The boot chain:

1. `libexec/entrypoint` — runs first; calls bootstrap, re-resolves `$HOME`
   onto the PVC (the runtime sets `HOME=/` when there is no passwd entry),
   then execs the base's stashed ENTRYPOINT.
2. `libexec/bootstrap` — relocates `$HOME` to `/data/<user>` (durable),
   generates the runtime env into `/opt/twentyx/etc/`, prewrites podman's
   `storage.conf` (vfs — no mounts needed), and execs `seed-home`.
3. `libexec/seed-home` — the only writer into `$HOME`: refreshes the
   packaged-default store symlinks and copies each dotfile in once. A real
   file is the user's and is never touched.
4. `libexec/run-opencode` — the agent launcher: replaces the hostile
   `LD_PRELOAD` with the libc *matching opencode's own glibc* (via `ldd`),
   stashes the original in `PRELOAD_ORIGINAL`, and points `BASH_ENV` at a
   restore script so every command the agent runs gets CUDA back.
5. `libexec/doctor` — read-only diagnosis of all of the above.
6. `libexec/sshd-inetd` — an sshd driven over `runai exec` stdio, so
   Zed/SSH can reach a pod with no exposed port (`scripts/ssh-bridge.sh` on
   the WSL side).

The `$HOME` rule to remember: **a symlink into `/nix/store` is ours, a real
file is the user's.** Packaged defaults are refreshed symlinks; dotfiles are
copied once. `/opt/twentyx/profile/bin/<tool>` is the stable path editor
settings point at, so they survive closure updates.

Cluster-specific files (internal CA, pip.conf) are never baked in: they
arrive at `/opt/airgap-env` (ConfigMap mount) or `/data/.airgap-env` (PVC),
and `injection_exports()` in `libexec/common.sh` wires known file names to
the standard env vars.

## The WSL side

Same profile, evaluated as a real NixOS system: systemd, sshd, podman,
nix-ld, and a Python stack (the pod deliberately does *not* carry Python —
the base image owns torch). But it is a **frozen appliance**:

- the image ships the closure; `setup-wsl.sh` overlays the text layer and
  imports a store delta, then switches the system profile;
- config lives in `dotfiles/`, seeded once into `$HOME` — edits are local
  files, and the gap never gives them back;
- the internal CA is built at runtime by the `airgap-ca` oneshot from the
  system bundle + `/var/lib/airgap-env/ca-bundle.crt`;
- a user-visible smoke checklist is MANUAL.md §5.

The Windows side is one script (`SETUP.ps1`): rootfs import, the kit (Zed
and Microsoft VS Code — both pinned; the VS Code server and the Zed remote
server ship in the closure), then the Linux half. Updaters stay off on both
editors: the pre-seeded artifacts match the kit's exact versions, and a
rebuilt one is a transfer.

## Reading order

| # | File | What you will learn |
|---|---|---|
| 1 | `flake.nix` | the two targets, pinned inputs, what each flake output is |
| 2 | `nix/packages.nix` + `nix/profile.nix` | the package list, session env, packaged defaults |
| 3 | `nix/hosts/wsl.nix` | the WSL system: `/opt` symlinks, seed-home, CA, VS Code, podman |
| 4 | `nix/runai/layer.nix` | closure → OCI layer tarball, session-env via image ENV |
| 5 | `nix/packages/nvim-plugins.nix` + `nix/scripts/nvim-offline-check.lua` | the LazyVim tree and its sandbox check |
| 6 | `docker/assemble.sh` + `mklayer.sh` | the append-not-FROM build, PATH/ENTRYPOINT rules, setuid sudo |
| 7 | `libexec/common.sh` | identity chain, HOME resolution, env-injection contract |
| 8 | `libexec/entrypoint` → `bootstrap` → `seed-home` → `run-opencode` → `doctor` | the pod boot chain, in that order |
| 9 | `agent/plugins/preload.ts` + `agent/restore-preload.sh` | the child-restore half of the preload split |
| 10 | `scripts/` (transfer-bundle, build-layers, setup-wsl, push-gitlab-packages, ssh-bridge) | the transfer flows |
| 11 | `dotfiles/` | the seeded shell/editor configs |
| 12 | `tests/test-container.sh` | the problematic pod, reproduced locally |
| 13 | `NOTES.md` | why things are the way they are — the failures behind the comments |

## Glossary

Terms defined in the tour above are not repeated here.

- **drv (derivation)** — Nix's build plan for one store path; its file lives
  in the store too, which is why losing `.drv` files breaks builds even when
  the built software is still there.
- **OCI layer** — a tar diff in an image; overlayfs merges the stack.
- **crane** — a registry client that can append layers to a manifest without
  ever pulling the base image's data.
- **`LD_PRELOAD`** — libraries injected into every new process; RunAI uses it
  for GPU fractioning, and it is hostile to non-baseline binaries.
- **chroot store** — a secondary Nix store rooted elsewhere (we use
  `/tmp/airgap-test-store` for building without touching the system store).
- **nix-ld** — the NixOS shim that runs foreign dynamically-linked binaries
  (the runai CLI, uv-managed interpreters, the stock VS Code server).
- **GC root** — a symlink Nix will not collect; `.gcroots/wsl-system` keeps
  the last shipped system alive as the delta base.
