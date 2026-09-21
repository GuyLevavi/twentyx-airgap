# Architecture — what is going on here, and in what order to read it

For someone landing in this repo cold: what the technology is, how the pieces
work, and the order to read them so each file makes sense when you open it.
[`README.md`](README.md) is the overview, [`MANUAL.md`](MANUAL.md) the do-this,
[`NOTES.md`](NOTES.md) the war stories; this file is the map between them.

## The situation

Two environments must work with **zero network access**:

1. **A RunAI/OpenShift cluster** — GPU pods on an airgapped network. You get a
   pod with a random UID, a shared PVC, a Python base image you don't own, and
   a GPU fractioning middleware that injects libraries through `LD_PRELOAD`.
2. **The Windows laptop** — which runs the same toolchain as a full NixOS
   system inside WSL2, because the machine itself is outside the gap.

Everything the pod will ever need (compilers, editors, the agent binary, man
pages, tldr pages) must cross the gap as **planned artifacts**, never fetched
at runtime. The whole repo is one machine that produces those artifacts.

## The one idea: Nix computes the closure

Nix is a package manager that builds software into **store paths** —
content-addressed, immutable directories like
`/nix/store/x2qk5vrr…-hyprland-0.1.5/bin/hyprland`. A **closure** is a store
path plus every store path it references, recursively. That is the load-bearing
property: if a program is in the closure, nothing it needs can be missing, and
the hash in the path name proves the bytes.

A **flake** (`flake.nix`) is a Nix entrypoint whose inputs are pinned by hash
(`flake.lock`). Ours is evaluated twice from the same modules
(`nix/modules/`), producing two different things:

| | evaluation into… | shape |
|---|---|---|
| `nixosConfigurations.wsl` | a complete NixOS system config | rebuilt offline by `nixos-rebuild` |
| `homeConfigurations.runai` | a read-only tree of store paths | extracted into an OCI layer tarball |

Adding a package to `nix/modules/tools.nix` changes both. That is the point:
one source of truth, and the closure *is* the manifest — there is no separate
list of blobs to keep in sync.

## What crosses the gap

Three artifact classes, three mechanisms:

| Artifact | Made by | Lands in |
|---|---|---|
| Binary-cache chunks | `scripts/nix-export.sh` (outside) → `nix-import.sh` (inside) | the WSL Nix store |
| Layer tarballs | `scripts/build-layers.sh` → `push-artifactory.sh` | registry, appended onto base images by CI |
| The WSL root tarball | `nix build .#wsl-tarball` | `wsl --import` on Windows |

Chunks are content-addressed, so they transfer in any order and reassemble by
hash; each has a `.sha256` sidecar. There is deliberately no signing: Nix
verifies per store path, which is stronger than a tarball signature anyway.

## How the pod image is assembled (and why not Dockerfile)

The pytorch bases are 15–30 GB. A `FROM base-pytorch` build unpacks the whole
thing into the build pod's ephemeral disk — it dies. But everything we add is
just files, and an OCI image is a stack of tar-layer diffs. So:

```
base manifest (never pulled, never unpacked)
   + nix-layer.tar.gz      the closure, landed at literal /nix/store
   + repo-layer.tar        ~80 KB of this repo's text (libexec/, agent/, defaults)
   = assembled image, done registry-side by CI with `crane append`
```

Three hard constraints that are silent failures if ignored
(`docker/assemble.sh`):

- the closure must be at `/nix/store` — ELF interpreters are absolute paths;
- the base's `PATH` must be **prepended** to, not replaced (torch needs its
  conda paths first);
- `ENTRYPOINT` must never be replaced — the base's is recorded in
  `BASE_ENTRYPOINT` env and handed back by our entrypoint, or a `vscode-*`
  workspace would boot with no IDE.

## How a pod boots, and what each script does

The runtime user is arbitrary (uid 10001, gid 0, no passwd entry), `$HOME` is
a wiped tmpfs, and RunAI preloads GPU-fractioning `.so` files that crash the
agent binary. The boot chain:

1. `libexec/airgap-entrypoint` — runs first; calls bootstrap, re-resolves
   `$HOME` onto the PVC (the runtime sets `HOME=/` when there is no passwd
   entry), then execs the base's stashed ENTRYPOINT.
2. `libexec/airgap-bootstrap` — relocates `$HOME` to `/data/<user>` (durable),
   links the **packaged defaults** into it, writes the shell drop-ins with the
   session env (`TERMINFO_DIRS`, `LOCALE_ARCHIVE`, …) and the injected
   variables, and prewrites podman's `storage.conf` (vfs — no mounts needed).
3. `libexec/airgap-opencode` — the agent launcher: replaces the hostile
   `LD_PRELOAD` with the libc *matching opencode's own glibc* (via `ldd`),
   stashes the original in `PRELOAD_ORIGINAL`, and points `BASH_ENV` at a
   restore script so every command the agent runs gets CUDA back.
4. `libexec/airgap-doctor` — read-only diagnosis of all of the above.
5. `libexec/airgap-sshd-inetd` — an sshd driven over `runai exec` stdio, so
   Zed/SSH can reach a pod with no exposed port (`scripts/ssh-bridge.sh` on
   the WSL side).

The `$HOME` rule to remember: **a symlink into `/nix/store` is ours, a real
file is the user's.** Packaged defaults are per-file symlinks; the user's PVC
files shadow them; and because overlayfs merges directories across layers,
the 80 KB repo layer can override individual defaults per commit — a
fleet-wide config change without a transfer.

Cluster-specific files (internal CA, pip.conf) are never baked in: they arrive
at `/opt/airgap-env` (ConfigMap mount) or `/data/.airgap-env` (PVC), and
`airgap_injection_exports()` in `libexec/airgap-common.sh` wires known file
names to the standard env vars.

## The WSL side

Same modules, evaluated as a real NixOS system: systemd, zed GUI, the full
python stack (the pod deliberately does *not* carry python — the base image
owns torch). It rebuilds **offline** from the imported binary cache. Config
changes (generated files: starship, tmux, fish, …) rebuild in seconds without
any fetch; only adding a package needs a transfer — which is the whole
economic model: cheap text pushes, rare fat transfers.

## Reading order

| # | File | What you will learn |
|---|---|---|
| 1 | `flake.nix` | the two targets, pinned inputs, what each flake output is |
| 2 | `nix/modules/home.nix` | the shared config, session env, zed-remote, EDITOR gating |
| 3 | `nix/modules/tools.nix` | the package list, why each group exists, closure-cost comments |
| 4 | `nix/modules/shell.nix` + `nvim.nix` | generated shell + editor configs |
| 5 | `nix/hosts/wsl.nix` | the WSL system: substituters, nix-ld, sshd, podman, CA |
| 6 | `nix/runai/layer.nix` | closure → OCI layer tarball, session-env via image ENV |
| 7 | `docker/assemble.sh` + `mklayer.sh` | the append-not-FROM build, PATH/ENTRYPOINT rules, setuid sudo |
| 8 | `libexec/airgap-common.sh` | identity chain, HOME resolution, env-injection contract |
| 9 | `libexec/airgap-entrypoint` → `bootstrap` → `opencode` → `doctor` | the pod boot chain, in that order |
| 10 | `agent/plugins/airgap-preload.ts` + `agent/restore-preload.sh` | the child-restore half of the preload split |
| 11 | `scripts/` (build-layers, nix-export, nix-import, push-artifactory, ssh-bridge) | the transfer flows |
| 12 | `tests/test-container.sh` | the problematic pod, reproduced locally |
| 13 | `NOTES.md` | why things are the way they are — the failures behind the comments |

## Glossary

- **closure** — a store path plus everything it references, recursively.
- **store path** — `/nix/store/<hash>-<name>`, immutable, content-addressed.
- **drv (derivation)** — Nix's build plan for one store path; its file lives in
  the store too, which is why losing `.drv` files breaks builds even when the
  built software is still there.
- **flake** — a Nix entrypoint with hash-pinned inputs; the lockfile is law.
- **OCI layer** — a tar diff in an image; overlayfs merges the stack.
- **overlayfs merge** — directories with the same name across layers are
  merged file-by-file, which is how the repo layer overrides defaults.
- **crane** — a registry client that can append layers to a manifest without
  ever pulling the base image's data.
- **`LD_PRELOAD`** — libraries injected into every new process; RunAI uses it
  for GPU fractioning, and it is hostile to non-baseline binaries.
- **chroot store** — a secondary Nix store rooted elsewhere (we use
  `/tmp/airgap-test-store` for building without touching the system store).
- **nix-ld** — the NixOS shim that runs foreign dynamically-linked binaries
  (VS Code's server, on WSL).
