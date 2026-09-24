# Manual

The short path from connected machine to working pod. For the *why* behind
every step — what a closure is, why there is no `FROM` in the image build —
see [`ARCHITECTURE.md`](ARCHITECTURE.md); details live in
[`README.md`](README.md) and [`NOTES.md`](NOTES.md). This file is the sequence.

## 0. One-time, on the connected machine

```bash
nix flake check                      # evaluates both targets
nix develop                          # shellcheck, nixfmt, crane, skopeo, jq
```

If `nix build` fails with "store path ... does not exist", the local store lost
files or DB rows — see NOTES.md §9 for the diagnosis classes and the repair
(recipe: copy files from a chroot store, then one `nix copy` as root), or
build into a throwaway store: `nix build --store /tmp/airgap-test-store .#runai-layer`.

Declare what only you know — nothing here is a closure value any more:

- Identity in a pod comes from the workspace-name convention
  (`<username>-<whatever>-<n>-<n>` → first part = your PVC directory). No
  email is baked in: this toolchain is distributed to a team, and a baked
  identity would file everyone's state into one person's directory. If your
  username contains a dash, set `SESSION_USER=<you>` in the workspace env
  (RunAI pod template) — that is the override chain's first rule.
- Git identity is per-user and cheaply editable on purpose: one
  `git config --global user.email` on the durable home, a real file, done
  forever. Nothing in the image owns it.

What you fill in **at the airgap side instead** (no transfer involved):

- `.gitlab-ci.yml` cluster facts (`BASE_REGISTRY`, `BASE_TAG`,
  `LAYER_BASE_URL`, lint-image digest) — git text, edited on the work WSL PC
  and pushed to the internal GitLab before the first CI run.
- `nix/packages/runai-cli.nix` — fill version/hash/URL on the work PC (the
  binary's URL is only reachable there), then rebuild offline. Day-one
  fallback: put the binary in `~/.local/bin` by hand and pin it later.

Also build the Windows-side kit while connected — it is what makes the
Windows half of the gap turnkey:

```bash
nix build .#windows-kit       # one tar.gz: Zed (release-matched), VS Code, WSL2 MSI
```

## 1. The WSL machine (NixOS inside the gap)

The laptop runs **NixOS inside WSL2**: a complete Linux system (your shell,
your Nix store, your configs) booted in a lightweight VM that Windows manages.
Files are shared both ways (`/mnt/c` from Linux, `\\wsl$\twentyx` from
Windows). It is a real NixOS machine — rebuilds, systemd, everything.

**One-time build on the connected machine (Linux):** — per team member, since
each imports their own tarball. Set the WSL username first (a per-machine,
gitignored one-liner, not a closure value):

```bash
echo <your-name> > wsl-username                 # only if you are not the default
nix build .#wsl-tarball                         # ~1.4 GB, one file
./result/bin/nixos-wsl-tarball-builder dist/nixos-wsl.tar.gz   # no sudo
```

**One-time setup on Windows — from absolute zero, no WSL installed.**
PowerShell, **run as Administrator**. DISM is the Windows component store;
each line flips on an optional feature WSL depends on: the Linux-subsystem
API, and the virtual-machine platform that WSL2 actually runs on:

```powershell
dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart
dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart
```

**Reboot now** — neither feature is active until you do. (Windows 11 shortcut:
`wsl --install --no-distribution` does the same two things and reboots for
you, *without* installing Ubuntu — we bring our own distro.)

After the reboot, still Administrator PowerShell:

```powershell
wsl --set-default-version 2      # WSL2 (real kernel), not the legacy WSL1
# WSL2 itself: on an internet-less Windows, install the MSI from the kit
# (windows-kit result). On a connected one, `wsl --update` does the same.
msiexec /i wsl.2.9.12.0.x64.msi
wsl --import twentyx D:\wsl\nixos C:\path\to\nixos-wsl.tar.gz --version 2
wsl -d twentyx                   # you are now inside the NixOS machine
```

Put `D:\wsl\nixos` on a drive with tens of GB free — the VM disk lives there
and grows. `wsl --import` registers the tarball as a distro named `twentyx`;
the name is what every `wsl -d` command refers to. WSL details that matter
(vscode-server pre-seeding, auto-update pins, first-boot gotchas): see
[`wsl/README.md`](wsl/README.md).

**Every later change** — build the closure on the connected machine, transfer,
import, rebuild:

```bash
# connected machine:
./scripts/nix-export.sh              # sharded, content-addressed, .sha256 sidecars
# transfer the chunks (any order — reassembly is by hash)
# WSL:
sudo ./scripts/nix-import.sh         # into /var/cache/nix-transfer, then:
sudo nixos-rebuild switch --flake /etc/nixos#... # or wherever the flake lives
```

A config *edit* (not a new package) rebuilds offline in seconds — `writeText`
and friends need no network. Adding a package is what needs a transfer.

Daily drivers on WSL: `zed` (GUI), VS Code desktop over Remote-SSH (the host
has `nix-ld`), `opencode`, `runai` CLI once pinned — see
`nix/packages/runai-cli.nix` for the recipe; the binary the RunAI UI offers is
the right one (it matches the cluster's server version).

## 2. Build the pod layers (connected machine)

```bash
./scripts/build-layers.sh            # dist/nix-layer.tar.gz[.nvim] + repo-layer.tar
./scripts/build-layers.sh plain      # first transfer: deliberately small (~847 MB)
```

Verify each artifact's `.sha256` sidecar — from any directory:

```bash
sha256sum -c dist/*.sha256
```

## 3. Cross the gap

Carry, in one go:

| Artifact | Size | Lands in |
|---|---|---|
| `dist/nix-layer.tar.gz` (+`-nvim` optional) | ~847 / ~880 MB | Artifactory → CI `crane append` |
| `dist/repo-layer.tar` | ~80 KB | CI re-tars it per commit anyway |
| `nix-export.sh` chunks | ~1 GB | WSL binary cache |
| `nixos-wsl.tar.gz` (first time only) | ~4.3 GB | `wsl --import` |
| `.#windows-kit` result | ~660 MB | Windows machines: one tar.gz — Zed installer (release-matched with the closure), VS Code installer, WSL2 MSI. Ships as a single archive so no bare `.exe`/`.msi` crosses the gap; Windows extracts it with its built-in `tar.exe` |

The WSL bootstrap is one ~4.3 GB file; the binary-cache exporter shards by
default if the cache chunks ever exceed a per-file cap.

## 4. Registry side (inside the gap)

```bash
./scripts/push-artifactory.sh        # layers → generic-local/airgap/<ver>/
```

Fill in `.gitlab-ci.yml`: `BASE_REGISTRY` (internal path), `BASE_TAG`
(pin per transfer — digest, not `latest`). CI then assembles the image
registry-side with `crane append` — no `FROM`, no Docker build, the bases are
never pulled or unpacked.

## 5. Pod template (RunAI UI)

- **Env**: `LLM_BASE_URL` (internal vLLM endpoint), `LLM_API_KEY`.
- **Mount**: a ConfigMap/Secret at `/opt/airgap-env` containing
  `ca-bundle.crt` and `pip.conf` (known names are wired to
  `SSL_CERT_FILE`, `PIP_CONFIG_FILE`, … automatically; a PVC dir at
  `/data/.airgap-env` works as fallback).
- **PVC**: `/data` writable by the runtime user.
- **Base**: any internal flavor; `vscode-*` bases hand their ENTRYPOINT back
  automatically.

## 6. First session in a pod

```bash
runai exec -it -- /opt/airgap/libexec/airgap-doctor   # paste this if anything is off
runai exec -it -- /opt/airgap/libexec/airgap-opencode # the agent; preload handled
sudo <cmd>                                            # passwordless (gid 0)
sudo podman images                                    # rootful podman, vfs prewritten
```

Editors: `code-server` is in the closure and wins over the base's copy;
a `vscode-*` workspace starts it via the base ENTRYPOINT. Zed remote connects
through `scripts/ssh-bridge.sh` (WSL side) — see README "Zed remote, declared".
The `-nvim` flavor adds pure nvim + treesitter (~880 MB layer — LazyVim is gone; its LSPs moved to the shared Nix-declared set that Zed also reads); plain ships `nano` as `EDITOR`.

## 7. Updating later

| Change | Where | Cost |
|---|---|---|
| libexec/agent text, home-defaults override | git commit | none — CI re-tars `repo-layer.tar` |
| anything in the closure | rebuild → export → transfer → push | a physical transfer |

## 8. When something is wrong

`airgap-doctor` first; it prints closure integrity, terminal env, sudo,
podman, injected env and the model endpoint, and never changes anything.
Then: NOTES.md §8 for what is and is not simulated locally, and the
`tests/test-container.sh` suite (16 checks) which reproduces the pod shape
without a cluster.
