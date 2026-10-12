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
sudo ./result/bin/nixos-wsl-tarball-builder nixos-wsl.tar.gz
```

The upstream builder needs real root (it chroots and bind-mounts), hence
`sudo`. Do not pass `--chown`: it runs before the install (it exists for
`--extra-files`) and would fail on the not-yet-created home; the activation
script creates `/home/jensen` as 1000:100 anyway. `transfer-bundle.sh` runs
exactly this.

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
WezTerm, VS Code), and — with `-GitlabUrl`/`-GitlabProject` — clones/pulls
`~/twentyx` inside the distro and runs that checkout's `setup-wsl.sh`
(otherwise the carried `setup-wsl.sh` runs against the transfer folder).
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
| `repo-layer.tar` | plain file | overlaid by `setup-wsl.sh` when run from a transfer folder; a checkout needs nothing |
| `ca-bundle.crt` | plain file (when `env/` has it) | staged into the distro; pins `SETUP.ps1`'s registry fetches (`curl.exe --cacert`) |
| `nixos-wsl.tar.gz` (inside `.7z`) | unpack with 7-Zip | consumed by `wsl --import` |
| `windows-kit-*.tar.gz` (inside `.7z`) | unpack with 7-Zip | extracted by `UNPACK.ps1`; fetched from GitLab packages when missing |
| `wsl-update.nar` (inside `.7z`) | unpack with 7-Zip | imported by `setup-wsl.sh` on an existing distro |
| `twentyx-airgap.bundle` | stays as-is | a git bundle: `git clone` it for history |
| `nix-layer*.tar.gz` (inside `.7z`) | unpack with 7-Zip | consumed by `crane append` / CI |
| `SETUP.ps1`, `UNPACK.ps1`, `setup-wsl.sh` | plain scripts | run directly |

**A new machine** (or another user) whose WSL can reach the internal GitLab
needs only the repo — clone it or take GitLab's archive zip — and runs:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\windows\SETUP.ps1 `
  -GitlabUrl https://gitlab.internal -GitlabProject <group/project>
```

`SETUP.ps1` fetches what is missing from the project's package registry:
`nixos-wsl.tar.gz` (rootfs), `windows-kit-*.tar.gz` (the Windows half,
~600 MB, named by `MANIFEST.txt`'s `WINDOWS_KIT=` line), and `MANIFEST.txt`
itself. Versions come from the repo's `VERSION` unless `-Version` is given.
`-SkipUnpack` installs the distro only. Fetches pin the internal CA with a
carried (or committed) `env/ca-bundle.crt`; without one, Windows must
already trust it.

## 2. Cross the gap

```bash
./scripts/transfer-bundle.sh
```

Builds `build/` (plain, gitignored, stamp-guarded) and assembles `dist/`:
the `.7z` containers plus the small files. The script refuses a dirty
worktree (`ALLOW_DIRTY=1` overrides); `build/` and `.gcroots/` are local
state.

A closure change ships as a small **cumulative delta layer** against the last
full layer; the base is rebuilt only on a full run, with `SQUASH=1`, or when
the delta passes half the base. `UPDATE=1 ./scripts/transfer-bundle.sh`
assembles an update-only bundle: deltas, `wsl-update.nar` and the text,
without the unchanged base layers, root tarball or Windows kit. It needs a
prior full transfer (a brand-new machine still needs those).

| dist file | Size | Lands in |
|---|---|---|
| `nix-layer.tar.gz.7z` (+`-nvim`) | ~1.1 GB each | GitLab packages → CI `crane append` (full transfers and `SQUASH=1`) |
| `nix-layer-delta.tar.gz.7z` (+`-nvim`) | usually <100 MB | appended right after its base layer; cumulative since that base |
| `repo-layer.tar` | ~400 KB | `setup-wsl.sh` overlays `/opt/twentyx` (CI builds its own for pods) |
| `nixos-wsl.tar.gz.7z` | ~1.5 GB | `wsl --import`, or GitLab packages → `SETUP.ps1` fetch |
| `wsl-update.nar.7z` | closure delta | `setup-wsl.sh` on an existing distro (registry fetch available) |
| `windows-kit-*.tar.gz.7z` | ~600 MB | Windows: `UNPACK.ps1`, or GitLab packages → `SETUP.ps1` fetch |
| `twentyx-airgap.bundle` | ~300 KB | git history inside the distro |
| docs + scripts + `MANIFEST.txt` + `SHA256SUMS` | KB | read directly |

## 3. Updating the WSL appliance

A text-only change (`libexec/`, `agent/`, `dotfiles/`) needs the new
`repo-layer.tar` only. A closure change needs `wsl-update.nar` too, built by
`transfer-bundle.sh` from the last shipped system (`.gcroots/wsl-system`).
Neither big file has to be carried when the internal GitLab is reachable:
from a transfer folder `setup-wsl.sh` reads the local `MANIFEST.txt`; from a
checkout it fetches `MANIFEST.txt` first (the version comes from the repo's
`VERSION`), then `wsl-update.nar` — with `GITLAB_URL`/`GITLAB_PROJECT` set;
the project is public, no token (`GITLAB_TOKEN` is for a private mirror). A
404 or an unreachable registry just falls back to the text layer.

```bash
# Windows, elevated, from the extracted transfer folder
wsl -d twentyx -u root -- bash /mnt/c/twentyx/setup-wsl.sh

# or, from inside the distro, pulling the delta instead of carrying it:
sudo env GITLAB_URL=https://gitlab.internal GITLAB_PROJECT=<group/project> \
    bash /mnt/c/twentyx/setup-wsl.sh
```

A distro with the repo checked out carries nothing at all: the clone is the
live text tree. `seed-home` prefers the clone over `/opt`, so `$HOME`
dotfile links target `~/twentyx/dotfiles` — a config edit or `git pull` is
live at once. On an existing distro, `SETUP.ps1 -GitlabUrl/-GitlabProject`
also passes those coordinates to `setup-wsl.sh`, so the same run picks up a
closure delta when the registry has one.

```bash
git -C ~/twentyx pull
sudo systemctl restart seed-home        # after files are added or renamed
sudo ~/twentyx/scripts/setup-wsl.sh     # after env/; add GITLAB_URL/GITLAB_PROJECT
                                        # (as above) for a closure change
```

Sharing: edit `~/.config/<file>` — the symlink writes into the clone — then
`git -C ~/twentyx commit -am '<what changed>' && git push`; teammates
pick it up with `git pull`.

Run from a transfer folder, `setup-wsl.sh` overlays `/opt/twentyx`; run from
a checkout it installs the clone's seed-home as the `/opt` entry point and
skips the rest. Either way it stages `ca-bundle.crt`/
`pip.conf` into `/var/lib/airgap-env` and restarts `airgap-ca`, then (when a
delta is carried) `nix-store --import`s it, sets the system profile, runs
`switch-to-configuration switch`, and re-seeds `$HOME`. A switch that
reports failed units has still switched: the script prints them and
continues (exit 4); any other failure aborts.

**Rollback:**

```bash
wsl -d twentyx -u root -- bash -c \
  'nix-env -p /nix/var/nix/profiles/system --rollback &&
   /nix/var/nix/profiles/system/bin/switch-to-configuration switch'
```

A config fix is an edit to `dotfiles/` in the repo, not to `$HOME`: the file
there is a symlink into the toolchain tree — the clone itself when
`setup-wsl.sh` ran from a checkout, otherwise `/opt/twentyx/dotfiles`. To keep
a private override instead, delete the link and write a real file — it is
yours from then on. An edited real file reports when the shipped default has
moved on: `newer default available: diff <shipped> <yours>`.

### Internal CA and pip.conf (WSL only)

The repo carries them as `env/ca-bundle.crt` and `env/pip.conf`; the text
layer puts them at `/opt/twentyx/env/`, and `setup-wsl.sh` stages them into
`/var/lib/airgap-env` (a file next to `setup-wsl.sh` in the transfer folder
still wins). Rotate by editing `env/` and re-running the text update.

```bash
wsl -d twentyx -u root -- systemctl restart airgap-ca   # re-run without an update
```

`airgap-ca` concatenates the system bundle with `ca-bundle.crt`;
`/etc/ssl/certs/*` and `NODE_EXTRA_CA_CERTS` point at the result.

Pods do not use `env/`: their base image already handles CA and pip.

## 4. Pods

The push scripts are in the repo, not in `dist/` — the repo travels as
`twentyx-airgap.bundle`. In the gap, in the transfer folder: unpack the
layer containers, clone the bundle, publish. One-time: a GitLab token with
`api` scope and the project; check the instance's `max_package_size` before
the first multi-GB push (Admin > Settings > Preferences) — if a layer does
not fit, use Artifactory instead.

```bash
7z x nix-layer.tar.gz.7z && 7z x nix-layer-nvim.tar.gz.7z   # plain names; never publish the .7z
7z x nix-layer-delta.tar.gz.7z && 7z x nix-layer-delta-nvim.tar.gz.7z
git clone twentyx-airgap.bundle twentyx
export GITLAB_TOKEN=<token> GITLAB_PROJECT=<group/project|id>
export GITLAB_URL=https://gitlab.internal          # default: gitlab.com
# An update shipment carries and pushes only the deltas (plus MANIFEST.txt).
# Push the base layers too only on a full transfer or after SQUASH=1 bumped
# them, at the same VERSION as the delta they pair with.
./twentyx/scripts/push-gitlab-packages.sh \
    nix-layer-delta.tar.gz nix-layer-delta-nvim.tar.gz
./twentyx/scripts/push-gitlab-packages.sh nix-layer.tar.gz nix-layer-nvim.tar.gz  # full/squash only
# the WSL artifacts too, so SETUP.ps1 / setup-wsl.sh can fetch them (never the .7z):
7z x nixos-wsl.tar.gz.7z && 7z x wsl-update.nar.7z && 7z x windows-kit-*.tar.gz.7z
./twentyx/scripts/push-gitlab-packages.sh \
    nixos-wsl.tar.gz wsl-update.nar windows-kit-*.tar.gz MANIFEST.txt
# fallback (pods only; the WSL fetch paths read GitLab packages):
./twentyx/scripts/push-artifactory.sh nix-layer.tar.gz nix-layer-nvim.tar.gz
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
