# AGENTS.md

A toolchain for an **airgapped** RunAI/OpenShift environment and a NixOS-WSL laptop, from one source of truth. `README.md` is the authoritative overview; `ARCHITECTURE.md` is the how-it-works tour with a reading order for new readers; `MANUAL.md` is the step-by-step; `NOTES.md` holds open items, in-cluster facts and war stories (registry names there are still placeholders); `TODO.md` is the ordered next-step checklist. For changes touching WSL boot, read `wsl/FIRST-BOOT.md` and `wsl/SMOKE-TEST.md` first. Read them before making non-trivial changes.

## Verification (there is no test suite — but there are tests)

```bash
./tests/test-container.sh    # full image integration, needs podman (mock base + local registry)
nix shell nixpkgs#shellcheck -c shellcheck -S warning libexec/* agent/*.sh tests/*.sh scripts/*.sh docker/*.sh   # CI lint gate
nix flake check                            # evaluates both targets
nix build .#runai-layer                    # real check that the closure builds (needs a Nix host)
nix develop                                # devshell: shellcheck, shfmt, nixfmt, statix, deadnix, crane, skopeo, dive, jq
```

`tests/test-container.sh` simulates the problematic pod (uid 10001, hostile preloader, env-injection mount) — run it after touching anything in `libexec/`, `agent/`, `docker/`, or the layer. First run builds a throwaway store (~10 min), reruns are fast; `TEST_KEEP=1` leaves the local registry up for debugging, `TEST_NIX_LAYER=...` reuses a prebuilt layer. Match the existing shell style: `set -euo pipefail`, `say()` for status output, `--help`-less comment headers with a usage line. There is no `bin/` dispatcher — libexec scripts are the entry points (`doctor`, `run-opencode`, `bootstrap`, `entrypoint`, `sshd-inetd`).

## The one distinction that drives everything

| Change type | Where | Deploy cost |
|---|---|---|
| `libexec/`, `agent/` | git text | CI re-tars `repo-layer.tar` per commit (no transfer) |
| anything in `flake.nix` / `nix/` | closure | rebuild → **physical transfer** |

Adding a package to `nix/modules/tools.nix` changes both targets at once. Shell/prompt/tmux/nvim/git configs are Nix-*generated* — editing them is a closure change, even though they look like config. Config *edits* (writeText/buildEnv/symlinkJoin) still rebuild offline in seconds; adding a *package* is what forces a transfer.

## Transfers

`./scripts/transfer-bundle.sh` assembles the whole `dist/` in one shot: both nix layers, `repo-layer.tar`, `nixos-wsl.tar.gz`, the windows kit, docs and `START-HERE.txt`. It content-probes an existing WSL tarball (`./bin/init` present) and rebuilds it when stale — existence alone is not enough. Layers only: `./scripts/build-layers.sh [outdir]`, which builds in the chroot store `/tmp/airgap-test-store` when that exists (a new closure's drvs are not in the default store — NOTES §9).

`wsl-username` is per-machine and gitignored: a plain-directory flake copy uses it, a git checkout excludes it and ships the default (`jensen` in `flake.nix`).

## Nix rules

- **Git is text-only, enforced by design.** No vendored blobs, no binaries, no lockfile-generated artifacts. The closure replaces any manifest/CHECKSUMS scheme.
- **Never run Nix inside a pod.** `nix/runai/layer.nix` extracts the built closure as an OCI layer tarball; the lock is law in the airgap (`nix flake update` only on a connected machine).
- Pin inputs deliberately; most follow `nixpkgs`. The `vscode-server` input must *not* (overriding a nonexistent input warns on every eval). Marketplace extensions and tarball fetches pin exact hashes — re-pin only when upstream mutates the asset.
- Auto-updates are disabled everywhere: a runtime fetch in the gap is a hang, not an error (tldr/tealdeer was removed entirely for this reason — a 2 MB nicety that mutated upstream three times is not worth a fetch class that bites).

## Image assembly (`docker/`)

Bases are 15–30 GB; two layers are appended registry-side with `crane append`, never `FROM base-pytorch`. Constraints that are silent failures, not build errors:

- The closure must land at literal `/nix/store` — ELF interpreters are absolute store paths.
- `crane mutate` must **prepend** to the base's `PATH` (torch breaks without conda paths) and never replace `ENTRYPOINT` — the base's is stashed in `BASE_ENTRYPOINT` and handed over.
- Session env (`TERMINFO_DIRS`, `LOCALE_ARCHIVE`, …) must be image ENV via `layer.nix`'s `session-env`, not shell rc — `runai exec` and code-server never source rc files. Image ENV does no expansion; shell-expression values are filtered out in `assemble.sh`.
- Nix **strips setuid bits** from build outputs. The setuid `sudo` copy is made in `mklayer.sh` (extracted from the nix layer, `chmod 4555` — not 4755, the tar's `g=u` would make it group-writable).

## LD_PRELOAD / opencode split

RunAI injects GPU-fractioning libs via `LD_PRELOAD` (they crash opencode), but CUDA needs them back in every command the agent runs. `libexec/run-opencode` replaces the preload with the libc **matching the target binary's own glibc** (via `ldd` — a *system* libc preloaded into a Nix binary is a `GLIBC_PRIVATE` error) and stashes the original in `PRELOAD_ORIGINAL`; `agent/plugins/preload.ts` (`shell.env` hook) and `agent/restore-preload.sh` (`BASH_ENV`) restore it for children. Gotcha: `ldd/ldconfig -p | awk '…exit'` returns 141 (SIGPIPE) under `pipefail` — always add `|| true`.

## `$HOME` layering rule

`$HOME` is relocated to the PVC. A **symlink into `/nix/store` is packaged**; a **real file is the user's** and must never be clobbered. `XDG_CACHE_HOME` is deliberately ephemeral (local disk), so nothing durable may live there. For an arbitrary UID with no passwd entry the runtime itself sets `HOME=/` — `entrypoint` and `run-opencode` re-resolve it via `session_home()`; keep those in sync when touching identity resolution.

Packaged defaults (`layer.nix`) are a real directory of per-file symlinks (not one symlink), so overlayfs merges them across layers and a repo-layer file at the same path would override a single default per commit. Wiring caveat: `docker/mklayer.sh` stages only `libexec/`, `agent/`, `VERSION` and generated `etc/` files — there is no repo-level `home-defaults/` directory, so use that override mechanism only after adding it to `mklayer.sh`. Precedence: user's real file > repo-layer override > Nix default.

## Environment-provided assets

Cluster-specific files (internal CA bundle, pip.conf, nginx site config) are never baked in. Contract: `/opt/airgap-env` (ConfigMap mount) wins over `/data/.airgap-env` (shared PVC). Known files are wired to env vars by `injection_exports()` in `common.sh`, consumed by bootstrap (drop-ins), the entrypoint (exec'd payloads) and the launcher (agent tree) — keep all three in sync. CRI exec (`runai exec -- cmd`) sees none of these; scripts reached that way must self-resolve.

## opencode, editors & root in the pod

- opencode + herdr + zed-editor (with its remote server) + code-server are in the closure (nixpkgs builds opencode from source: models catalog baked in, autoupdate off, `OPENCODE_DISABLE_MODELS_FETCH=true`). **The opencode binary is AVX2-only** (bun compile without `--baseline`) — SIGILL on pre-Haswell cluster nodes; fix is a local overlay, not a downgrade.
- Editor pins move in lockstep: `.#windows-kit`'s Zed installer is pinned to `pkgs.zed-editor.version` (re-pin via `nix store prefetch-file` when nixpkgs bumps zed), and its VS Code installer/server commit must stay in sync with `vscodeCommit` in `nix/hosts/wsl.nix`. Zed's remote-server lookup is exact-match on the client's FULL version string (build metadata included), so the shim name comes from `nix/zed-client-version.nix` — pinned to the kit installer's build and re-pinned in the same commit — never from `pkgs.zed-editor.version` alone.
- The user's `opencode.json` is NOT shipped — the working config lives on the PVC (durable `$HOME`). The preload plugin and the Zed `agent_servers` default ship as packaged defaults via `home.file`.
- Root: the repo layer ships `/etc/sudoers{,.d/twentyx}` granting `%#0` (gid 0) passwordless sudo; the setuid binary comes from the closure. `doctor` checks it. Podman's `storage.conf` (vfs) is written by bootstrap into the ephemeral cache.
- Zed/SSH into a pod rides `sshd -i` inside `runai exec` stdio (`libexec/sshd-inetd` + `scripts/ssh-bridge.sh`); no pty anywhere on that path — a pty corrupts the SSH protocol.

## Gotchas

- `scripts/nix-export.sh` / `nix-import.sh` (WSL binary cache) and `push-artifactory.sh` (image layers to Artifactory) are **different flows** — don't confuse them.
- Chunked transfers are order-independent and re-importable; integrity is the content-addressed store hash, not a tarball checksum.
- `mklayer.sh` builds `repo-layer.tar` as plain tar (text, no container); CI rebuilds it per commit — it's the one-commit deploy path.
- Identity in a pod comes from `session_user()` in `libexec/common.sh` (env → workspace name → git email → `$USER`); the workspace rule is the intended one and there is deliberately no baked git email (team distribution), and no packaged `~/.config/git/config` (it would block `git config --global` on the PVC) — neutral git settings ship as `/etc/gitconfig` instead.
- First WSL artifact: `./scripts/transfer-bundle.sh`, or `nix build .#wsl-tarball` + `./result/bin/nixos-wsl-tarball-builder dist/nixos-wsl.tar.gz` — **no sudo**, the builder self-elevates in a user namespace (`NO_UNSHARE=1` opts out). See `wsl/README.md`; VS Code server must be pre-seeded and auto-update pinned off on Windows.
- Local connected machine: the store was repaired 2026-09 (both layer flavors build on the default store); if "store path ... does not exist" reappears, NOTES.md §9 has the three damage classes, the `nix copy` skip-on-row trap and the remedies (`/nix/store` was never read-only — no remount needed); the chroot store (`nix build --store /tmp/airgap-test-store .#runai-layer`) is the donor and fallback.
