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
nix build .#windows-kit       # one tar.gz: Zed (release-matched), VS Code, themes, templates, WSL2 MSI
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
nix build .#wsl-tarball                         # builds the tarball builder
./result/bin/nixos-wsl-tarball-builder dist/nixos-wsl.tar.gz   # no sudo; ~1.1 GB
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

After the reboot, still Administrator PowerShell, from the **extracted
transfer folder** (the carry tar `twentyx-airgap-<VERSION>.tar.gz` is flat
inside — see §3):

```powershell
wsl --set-default-version 2      # WSL2 (real kernel), not the legacy WSL1
# No WSL at all? The kit carries WSL2 itself: extract the kit tar and install
# its MSI (on a connected Windows, `wsl --update` does the same).
tar -xf .\windows-kit-<ver>.tar.gz
msiexec /i .\windows-kit\wsl.2.9.12.0.x64.msi
```

Then one command does the whole chain:

```powershell
powershell -ExecutionPolicy Bypass -File .\SETUP.ps1
```

`SETUP.ps1` imports `nixos-wsl.tar.gz` as the `twentyx` distro (skipped when
it is already registered), runs `UNPACK.ps1` (kit, Zed themes/settings,
WezTerm, VS Code) and then `setup-wsl.sh` as root inside the distro (clone
the repo bundle, import the offline rebuild cache); the final
`nixos-rebuild` runs as the user via sudo, never as root. Every knob is a
parameter:

```powershell
.\SETUP.ps1 -Distro twentyx -InstallDir C:\wsl\nixos -User jensen -Base <extracted folder>
```

Put `C:\wsl\nixos` (`-InstallDir`) on a drive with tens of GB free — the VM
disk lives there and grows. The distro name is what every `wsl -d` command
refers to.

**Manual equivalent** (the fallback) — `wsl --import` + the two scripts:

```powershell
wsl --import twentyx C:\wsl\nixos .\nixos-wsl.tar.gz --version 2
powershell -ExecutionPolicy Bypass -File .\UNPACK.ps1
wsl -d twentyx -u root -- bash /mnt/c/<extracted folder>/setup-wsl.sh jensen
```

`UNPACK.ps1` extracts the kit and installs the themes/templates (never
overwriting a personal file); `setup-wsl.sh` clones the repo bundle, imports
the offline rebuild cache and runs the first `nixos-rebuild` as the user via
sudo. Both are idempotent.

Sudo asks for a password once? It is locked by design; the imported image
carries passwordless sudo for wheel, so the rebuild never needs one. If you
see a prompt you are on an older image — log in as the user and run the
rebuild from your own shell once:
`sudo nixos-rebuild switch --flake ~/twentyx-airgap#wsl`.

WSL details that matter (first-boot gotchas, the no-WWW rehearsal): see
[`wsl/README.md`](wsl/README.md).

### Packed vs extracted (the one table)

| Artifact | Travels as | Becomes |
|---|---|---|
| `README.md`, `MANIFEST.txt`, `SHA256SUMS` | plain files | read directly (the page replaced `START-HERE.txt`; checksums via `sha256sum -c`) |
| `nixos-wsl.tar.gz` | stays packed | consumed by `wsl --import` — never extracted by hand |
| `windows-kit-*.tar.gz` | stays packed | extracted by `UNPACK.ps1`; Zed/VS Code, themes/templates installed |
| `wsl-rebuild.tar.gz` | packed until inside | extracted to `/var/cache/nix-transfer` by `setup-wsl.sh` |
| `twentyx-airgap.bundle` | stays packed | `git clone`d — a bundle is a git remote, not an archive |
| `nix-layer*.tar.gz`, `repo-layer.tar` | stay packed | consumed by `crane append` / CI — never opened by hand |
| `SETUP.ps1`, `UNPACK.ps1`, `setup-wsl.sh` | plain scripts | run directly (`SETUP.ps1` chains the other two) |

**Every later change** — edit in the WSL-side repo, commit, rebuild:

```bash
# inside the distro, as the user (the repo lives on the durable home; the
# flake reads the GIT TREE, so stage new files before rebuilding)
rb                          # git add -A + sudo nixos-rebuild switch --flake <repo>#wsl
# spelled out: sudo nixos-rebuild switch --flake ~/twentyx-airgap#wsl
```

A config *edit* (not a new package) rebuilds offline in seconds — `writeText`
and friends need no network. Adding a package is what needs a transfer.

Daily drivers on WSL: Zed from Windows over its WSL remote (server ships in
the closure), VS Code Remote-WSL (kit client, pre-seeded server + extensions),
`opencode`, `runai` CLI once pinned — see `nix/packages/runai-cli.nix` for
the recipe; the binary the RunAI UI offers is the right one (it matches the
cluster's server version).

## 2. Build the pod layers (connected machine)

```bash
# The arg is an OUTPUT DIRECTORY, not a flavor: both flavors are always built.
./scripts/build-layers.sh            # dist/nix-layer.tar.gz + nix-layer-nvim.tar.gz + repo-layer.tar
./scripts/build-layers.sh /tmp/out   # same three files, elsewhere
```

## 3. Cross the gap

`./scripts/transfer-bundle.sh` assembles all of `dist/` in one shot. What it
carries, and what each thing becomes:

| Artifact | Size | Lands in |
|---|---|---|
| `dist/twentyx-airgap-<VERSION>.tar.gz` | the whole flat folder | the one file carried in; extract, then `SETUP.ps1` |
| `dist/README.md`, `dist/MANIFEST.txt`, `dist/SHA256SUMS` | KB | the Windows-side page, versions, `sha256sum -c` |
| `dist/nix-layer.tar.gz` (+`-nvim`) | ~1.12 / ~1.14 GB | Artifactory → CI `crane append` |
| `dist/repo-layer.tar` | ~380 KB | CI rebuilds it with `docker/mklayer.sh` per commit |
| `dist/nixos-wsl.tar.gz` (first time / re-import) | ~1.5 GB | `wsl --import` |
| `dist/windows-kit-*.tar.gz` | ~612 MB | Windows: Zed + VS Code + WSL2 MSI, themes, templates (`UNPACK.ps1`) |
| `dist/wsl-rebuild.tar.gz` | ~299 MB | `/var/cache/nix-transfer` (offline rebuild cache) |
| `dist/twentyx-airgap.bundle` | ~308 KB | `git clone` inside the distro (real history) |
| `dist/SETUP.ps1`, `dist/UNPACK.ps1`, `dist/setup-wsl.sh` | KB | run directly (`SETUP.ps1` chains all three) — see §1 |

The bases themselves never cross the gap (they are in the airgap registry and
`crane` cross-mounts them) — see [`docker/BASE-IMAGES.md`](docker/BASE-IMAGES.md)
for base-image choices and the first-transfer checklist.

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

### Where cluster-specific config goes

The mount above is the pod's half of the contract; the WSL side has the
parallel file story (gitignored `ca-bundle.crt` next to the flake, your own
durable `~/.config` files). The full map — every setting, its lifetime, who
consumes it, which changes need a transfer, and how to fold an inner
(`tenx`-style) repo build into this toolchain — is
[`docs/INNER-CONFIG.md`](docs/INNER-CONFIG.md).

## 6. First session in a pod

```bash
runai exec -it -- /opt/twentyx/libexec/doctor   # paste this if anything is off
runai exec -it -- /opt/twentyx/libexec/run-opencode # the agent; preload handled
sudo <cmd>                                            # passwordless (gid 0)
sudo podman images                                    # rootful podman, vfs prewritten
```

Editors: `code-server` is in the closure and wins over the base's copy;
a `vscode-*` workspace starts it via the base ENTRYPOINT. Zed remote connects
through `scripts/ssh-bridge.sh` (WSL side) — see README "Zed remote, declared".
The `-nvim` flavor adds pure nvim + treesitter (~1.14 GB layer; its LSPs come
from the shared Nix-declared set that Zed also reads); plain ships `nano` as
`EDITOR`.

## 7. Updating later

| Change | Where | Cost |
|---|---|---|
| libexec/agent text, home-defaults override | git commit | none — CI re-tars `repo-layer.tar` |
| anything in the closure | rebuild → export → transfer → push | a physical transfer |

## 8. When something is wrong

`doctor` first; it prints closure integrity, terminal env, sudo,
podman, injected env and the model endpoint, and never changes anything.
Then: NOTES.md §8 for what is and is not simulated locally, and the
`tests/test-container.sh` suite (19 checks) which reproduces the pod shape
without a cluster.
