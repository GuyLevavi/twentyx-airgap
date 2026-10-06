# Manual

The short path from connected machine to working pod. For the *why* behind
every step, see [`ARCHITECTURE.md`](ARCHITECTURE.md); open items and design
verdicts live in [`NOTES.md`](NOTES.md). This file is the sequence.

## 0. One-time, on the connected machine

```bash
nix flake check                       # evaluates both targets
nix develop                           # shellcheck, nixfmt, crane, skopeo, jq, 7z
nix build .#windows-kit               # Zed + VS Code + WSL2 MSI, themes, extensions
```

If `nix build` fails with "store path ... does not exist", the local store
lost files or DB rows — NOTES.md's "local store repair" has the diagnosis
classes and the recipe.

Cluster facts are CI variables set in the airgap's GitLab (project/group
variables beat `.gitlab-ci.yml`), so nothing is "filled in" from the
connected side: `BASE_REGISTRY`, `BASE_TAG`, `IMAGE_VARIANTS`, and either
`GITLAB_TOKEN`+`GITLAB_PROJECT` or `ARTIFACTORY_URL` +
`ARTIFACTORY_GENERIC_REPO` + `ARTIFACTORY_TOKEN`.

Declare what only you know — nothing here is a closure value:

- Identity in a pod comes from the workspace-name convention
  (`<username>-<whatever>-<n>-<n>` → first part = your PVC directory). If
  your username contains a dash, set `SESSION_USER=<you>` in the RunAI
  workspace env — that is the override chain's first rule.
- Git identity is per-user: one `git config --global user.email` on the
  durable home, a real file, done forever. Nothing in the image owns it.

## 1. The WSL machine (first install)

The laptop runs **NixOS inside WSL2**. It is a frozen appliance: its packages
and defaults arrive in the image and in the carried delta; nothing is
evaluated or fetched inside the gap.

**Build the image on the connected machine (Linux):**

```bash
nix build .#wsl-tarball
sudo ./result/bin/nixos-wsl-tarball-builder \
    --chown home/jensen 1000:100 dist/nixos-wsl.tar.gz
```

The upstream builder needs real root (it chroots and bind-mounts), hence
`sudo`; `--chown` pre-seeds `/home/jensen` for uid 1000, the first normal
user. `transfer-bundle.sh` runs exactly this.

**Windows, from absolute zero, no WSL installed.** PowerShell, **as
Administrator**:

```powershell
dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart
dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart
```

**Reboot now** — neither feature is active until you do. After the reboot,
from the **transfer folder** (unpack every `.7z` container with 7-Zip first):

```powershell
wsl --set-default-version 2      # WSL2 (real kernel), not the legacy WSL1
# No WSL at all? The kit carries WSL2 itself:
tar -xf .\windows-kit-<ver>.tar.gz
msiexec /i .\windows-kit\wsl.2.9.12.0.x64.msi
```

Then one command does the whole chain:

```powershell
powershell -ExecutionPolicy Bypass -File .\SETUP.ps1
```

`SETUP.ps1` imports `nixos-wsl.tar.gz` as the `twentyx` distro (skipped when
already registered), runs `UNPACK.ps1` (kit, Zed themes/settings/extensions,
WezTerm, VS Code), and runs `setup-wsl.sh` as root inside the distro (overlay
the text layer, stage the runtime CA, apply the closure delta when carried).
Every knob is a parameter:

```powershell
.\SETUP.ps1 -Distro twentyx -InstallDir C:\wsl\nixos -User jensen -Base <extracted folder>
```

Put `C:\wsl\nixos` on a drive with tens of GB free — the VM disk lives there
and grows.

**Manual equivalent** (the fallback):

```powershell
wsl --import twentyx C:\wsl\nixos .\nixos-wsl.tar.gz --version 2
powershell -ExecutionPolicy Bypass -File .\UNPACK.ps1
wsl -d twentyx -u root -- bash /mnt/c/<extracted folder>/setup-wsl.sh
```

Both scripts are idempotent and never overwrite a personal file. Sudo asks
for a password once? The imported image carries passwordless sudo for wheel;
if you see a prompt you are on an older image.

### Packed vs extracted (the one table)

| Artifact | Travels as | Becomes |
|---|---|---|
| `README.md`, `MANIFEST.txt`, `SHA256SUMS` | plain files | read directly (`sha256sum -c` after the unpack) |
| `nixos-wsl.tar.gz` (inside `.7z`) | unpack with 7-Zip | consumed by `wsl --import` |
| `windows-kit-*.tar.gz` (inside `.7z`) | unpack with 7-Zip | extracted by `UNPACK.ps1` |
| `wsl-update.nar` (inside `.7z`) | unpack with 7-Zip | imported by `setup-wsl.sh` on an existing distro |
| `twentyx-airgap.bundle` | stays as-is | a git bundle: `git clone` it for history |
| `nix-layer*.tar.gz`, `repo-layer.tar` (inside `.7z`) | unpack with 7-Zip | consumed by `crane append` / CI |
| `SETUP.ps1`, `UNPACK.ps1`, `setup-wsl.sh` | plain scripts | run directly |

## 2. Cross the gap

```bash
./scripts/transfer-bundle.sh
```

Builds `build/` (plain, gitignored, stamp-guarded) and assembles `dist/`:
the `.7z` containers plus the small files. The script refuses a dirty
worktree (`ALLOW_DIRTY=1` overrides); `build/` and `.gcroots/` are local
state.

| dist file | Size | Lands in |
|---|---|---|
| `nix-layer.tar.gz.7z` (+`-nvim`) | ~1.1 GB each | GitLab packages → CI `crane append` |
| `repo-layer.tar` | ~400 KB | CI rebuilds it with `docker/mklayer.sh` per commit |
| `nixos-wsl.tar.gz.7z` | ~1.5 GB | `wsl --import` |
| `wsl-update.nar.7z` | closure delta | `setup-wsl.sh` on an existing distro |
| `windows-kit-*.tar.gz.7z` | ~600 MB | Windows: `UNPACK.ps1` |
| `twentyx-airgap.bundle` | ~300 KB | git history inside the distro |
| docs + scripts + `MANIFEST.txt` + `SHA256SUMS` | KB | read directly |

## 3. Updating the WSL appliance

A text-only change (`libexec/`, `agent/`, `dotfiles/`) needs the new
`repo-layer.tar` only. A closure change needs `wsl-update.nar` too, built by
`transfer-bundle.sh` from the last shipped system (`.gcroots/wsl-system`).

```bash
# Windows, elevated, from the extracted transfer folder
wsl -d twentyx -u root -- bash /mnt/c/twentyx/setup-wsl.sh
```

`setup-wsl.sh` overlays `/opt/twentyx`, drops `ca-bundle.crt`/`pip.conf`
into `/var/lib/airgap-env` and restarts `airgap-ca`, then (when a delta is
carried) `nix-store --import`s it, sets the system profile, runs
`switch-to-configuration switch`, and re-seeds `$HOME`.

**Rollback:**

```bash
wsl -d twentyx -u root -- bash -c \
  'nix-env -p /nix/var/nix/profiles/system --rollback &&
   /nix/var/nix/profiles/system/bin/switch-to-configuration switch'
```

A config edit is not an update: edit the real file in `$HOME`, no transfer.
The seeded files report when a shipped default has moved on:
`newer default available: diff <shipped> <yours>`.

### Internal CA and pip.conf

Drop them next to `setup-wsl.sh` in the transfer folder (or into
`/var/lib/airgap-env` by hand) and restart the service:

```bash
wsl -d twentyx -u root -- systemctl restart airgap-ca
```

`airgap-ca` concatenates the system bundle with `ca-bundle.crt`;
`/etc/ssl/certs/*` and `NODE_EXTRA_CA_CERTS` point at the result. No
transfer and no rebuild to add or rotate the CA.

## 4. Pods

Publish the layers, then let CI append them:

```bash
./scripts/push-gitlab-packages.sh   # GitLab generic packages; push-artifactory.sh is the fallback
```

CI (`assemble`) fetches the layers, rebuilds `repo-layer.tar` from the
checkout, and runs `docker/assemble.sh` — `crane append` against the
internal bases, which are never pulled or unpacked. PATH is prepended and the
base's ENTRYPOINT is stashed and handed back.

**Pod template (RunAI UI):**

- **Env**: `LLM_BASE_URL`, `LLM_API_KEY`.
- **Mount**: a ConfigMap/Secret at `/opt/airgap-env` with `ca-bundle.crt`
  and `pip.conf` (known names are wired to `SSL_CERT_FILE`,
  `PIP_CONFIG_FILE`, …; a PVC dir at `/data/.airgap-env` is the fallback).
- **PVC**: `/data` writable by the runtime user.
- **Base**: any internal flavor; `vscode-*` bases hand their ENTRYPOINT back
  automatically.

**First session:**

```bash
runai exec -it -- /opt/twentyx/libexec/doctor       # paste this if anything is off
runai exec -it -- /opt/twentyx/libexec/run-opencode # the agent; preload handled
sudo <cmd>                                          # passwordless (gid 0)
sudo podman images                                  # rootful podman, vfs prewritten
```

Editors: `code-server` is in the closure; Zed remote connects through
`scripts/ssh-bridge.sh` on the WSL side (`libexec/sshd-inetd` in the pod).
The `-nvim` flavor adds LazyVim with Nix-built plugins; plain ships `nano`
as `EDITOR`.

## 5. Editors, offline (the smoke checklist)

Run everything from a `jensen` shell.

**System:** `systemctl --failed` empty; `cat /var/log/bootlog.txt` for the
automatic boot evidence.

**nvim:**

```bash
nvim --version | head -2                  # 0.12.x from the closure
:checkhealth lazy                         # all green
:lua =vim.lsp.get_clients()               # after opening a file
```

Opening `.py`/`.nix`/`.yaml`/`.toml`/`.sh`/`.json` must attach
basedpyright+ruff / nixd / yamlls / taplo / bashls / jsonls, all from
`/opt/twentyx/profile/bin`. No install popups, no downloads.

**Zed (from Windows):** connect a WSL project, open a `.nix`, a Python file,
a TOML, a YAML, a JSON, a Dockerfile. `Zed.log` must show no download lines;
servers start from `/opt/twentyx/profile/bin/`. The remote server is seeded
under `~/.zed_server/` named after the client's full version string
(`nix/zed-client-version.nix`); the kit's extensions live in
`%LOCALAPPDATA%\Zed\extensions\installed`.

**VS Code Remote-WSL:** `ls ~/.vscode-server/bin/` shows exactly the pinned
commit; `~/.vscode-server/extensions/` holds the six pinned extensions;
`~/.vscode-server/data/Machine/settings.json` pins `ruff.path` and
`nix.serverPath` to `/opt/twentyx/profile/bin`. First connect must download
nothing. If Remote-WSL fails to start on the real machine, NOTES.md's
"VS Code, offline" has the fallback.

**opencode:**

```bash
opencode --version          # must print, not die in ld.so (kernel <= 6.6 fix)
time opencode               # prompt start; a ~1.5 min stall is the npm seed missing
```

The provider/model edit is a real file: `~/.config/opencode/opencode.jsonc`,
edit in place and delete the `AIRGAP-SETUP` block.

**No-WWW rehearsal** (on the connected laptop): disable the WSL network
adapter (`ncpa.cpl`) and boot the distro; or inside the distro
`sudo ip route del default` and point `/etc/resolv.conf` at a dead
internal-style resolver. Every editor above must behave identically.

## 6. When something is wrong

`doctor` first; it prints closure integrity, defaults, terminal env, sudo,
podman, injected env and the model endpoint, and changes nothing. Then
`tests/test-container.sh` on the connected machine reproduces the problematic
pod (arbitrary UID, hostile preload, env-injection mount) without a cluster;
NOTES.md's "tested without the gap" says what it does and does not simulate.
