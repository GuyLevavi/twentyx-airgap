# AGENTS.md

A toolchain for an **airgapped** RunAI/OpenShift environment and a NixOS-WSL laptop, from one source of truth. `README.md` is the authoritative overview; `ARCHITECTURE.md` is the how-it-works tour with a reading order for new readers; `MANUAL.md` is the step-by-step; `NOTES.md` lists open items and in-cluster facts (some registry names there are still placeholders). Read them before making non-trivial changes.

## Verification (there is no test suite — but there are tests)

```bash
./tests/test-container.sh    # full image integration, needs podman (mock base + local registry)
nix shell nixpkgs#shellcheck -c shellcheck -S warning libexec/airgap-* agent/*.sh tests/*.sh scripts/*.sh docker/*.sh   # CI lint gate
nix flake check                            # evaluates both targets
nix build .#runai-layer                    # real check that the closure builds (needs a Nix host)
nix develop                                # devshell: shellcheck, shfmt, nixfmt, statix, deadnix, crane, skopeo, jq
```

`tests/test-container.sh` simulates the problematic pod (uid 10001, hostile preloader, env-injection mount) — run it after touching anything in `libexec/`, `agent/`, `docker/`, or the layer. Match the existing shell style: `set -euo pipefail`, `say()` for status output, `--help`-less comment headers with a usage line. There is no `bin/` dispatcher — libexec scripts are the entry points (`airgap-doctor`, `airgap-opencode`, `airgap-bootstrap`, `airgap-entrypoint`, `airgap-sshd-inetd`).

## The one distinction that drives everything

| Change type | Where | Deploy cost |
|---|---|---|
| `libexec/`, `agent/` | git text | CI re-tars `repo-layer.tar` per commit (no transfer) |
| anything in `flake.nix` / `nix/` | closure | rebuild → **physical transfer** |

Adding a package to `nix/modules/tools.nix` changes both targets at once. Shell/prompt/tmux/nvim/git configs are Nix-*generated* — editing them is a closure change, even though they look like config. Config *edits* (writeText/buildEnv/symlinkJoin) still rebuild offline in seconds; adding a *package* is what forces a transfer.

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

RunAI injects GPU-fractioning libs via `LD_PRELOAD` (they crash opencode), but CUDA needs them back in every command the agent runs. `libexec/airgap-opencode` replaces the preload with the libc **matching the target binary's own glibc** (via `ldd` — a *system* libc preloaded into a Nix binary is a `GLIBC_PRIVATE` error) and stashes the original in `PRELOAD_ORIGINAL`; `agent/plugins/airgap-preload.ts` (`shell.env` hook) and `agent/restore-preload.sh` (`BASH_ENV`) restore it for children. Gotcha: `ldd/ldconfig -p | awk '…exit'` returns 141 (SIGPIPE) under `pipefail` — always add `|| true`.

## `$HOME` layering rule

`$HOME` is relocated to the PVC. A **symlink into `/nix/store` is packaged**; a **real file is the user's** and must never be clobbered. `XDG_CACHE_HOME` is deliberately ephemeral (local disk), so nothing durable may live there. For an arbitrary UID with no passwd entry the runtime itself sets `HOME=/` — `airgap-entrypoint` and `airgap-opencode` re-resolve it via `airgap_home()`; keep those in sync when touching identity resolution.

Packaged defaults are a real directory of per-file symlinks (not one symlink), so overlayfs merges them across layers: **the repo layer can override individual defaults per commit** — no closure rebuild, no transfer. Precedence: user's real file > repo-layer default > Nix default.

## Environment-provided assets

Cluster-specific files (internal CA bundle, pip.conf, nginx site config) are never baked in. Contract: `/opt/airgap-env` (ConfigMap mount) wins over `/data/.airgap-env` (shared PVC). Known files are wired to env vars by `airgap_injection_exports()` in `airgap-common.sh`, consumed by bootstrap (drop-ins), the entrypoint (exec'd payloads) and the launcher (agent tree) — keep all three in sync. CRI exec (`runai exec -- cmd`) sees none of these; scripts reached that way must self-resolve.

## opencode & root in the pod

- opencode + herdr + zed-editor are in the closure (nixpkgs builds opencode from source: models catalog baked in, autoupdate off, `OPENCODE_DISABLE_MODELS_FETCH=true`). **The opencode binary is AVX2-only** (bun compile without `--baseline`) — SIGILL on pre-Haswell cluster nodes; fix is a local overlay, not a downgrade.
- The user's `opencode.json` is NOT shipped — the working config lives on the PVC (durable `$HOME`). The preload plugin and the Zed `agent_servers` default ship as packaged defaults via `home.file`.
- Root: the repo layer ships `/etc/sudoers{,.d/airgap}` granting `%#0` (gid 0) passwordless sudo; the setuid binary comes from the closure. `airgap-doctor` checks it. Podman's `storage.conf` (vfs) is written by bootstrap into the ephemeral cache.
- Zed/SSH into a pod rides `sshd -i` inside `runai exec` stdio (`libexec/airgap-sshd-inetd` + `scripts/ssh-bridge.sh`); no pty anywhere on that path — a pty corrupts the SSH protocol.

## Gotchas

- `scripts/nix-export.sh` / `nix-import.sh` (WSL binary cache) and `push-artifactory.sh` (image layers to Artifactory) are **different flows** — don't confuse them.
- Chunked transfers are order-independent and re-importable (content-addressed cache); verify with the `.sha256` sidecars, which must verify from any directory.
- `mklayer.sh` builds `repo-layer.tar` as plain tar (text, no container); CI rebuilds it per commit — it's the one-commit deploy path.
- Identity in a pod comes from `airgap_user()` in `libexec/airgap-common.sh` (env → workspace name → git email → `$USER`); the workspace rule is the intended one and there is deliberately no baked git email (team distribution), and no packaged `~/.config/git/config` (it would block `git config --global` on the PVC) — neutral git settings ship as `/etc/gitconfig` instead.
- First WSL artifact: `nix build .#wsl-tarball && sudo ./result/bin/nixos-wsl-tarball-builder` — see `wsl/README.md` (VS Code server must be pre-seeded; auto-update pinned off on Windows).
- Local connected machine: the store was repaired 2026-09 (both layer flavors build on the default store); if a "store path ... does not exist" ever reappears, the damage classes, the `nix copy` skip-on-row gotcha and the remedies are in NOTES.md §9 — the chroot store (`nix build --store /tmp/airgap-test-store .#runai-layer`) is the donor and fallback.
