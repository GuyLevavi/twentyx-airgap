# Manual (inside)

Operations in the gap. The why is in [`NOTES.md`](NOTES.md); the interface
with the outside repo is [`CONTRACT.md`](CONTRACT.md).

## 1. Publish a store release (each transfer)

A transfer folder holds `MANIFEST.txt`, `apply.sh`, `HANDOVER.md`,
`inside-seed.tar`, the big files as `.7z` containers, and on a rebase also
`SETUP.ps1`/`UNPACK.ps1`. Read `HANDOVER.md` first: it lists the required
edits to this repo that come with the release.

```bash
cd <transfer folder>
for f in *.7z; do 7z x "$f"; done                    # plain names; never publish the .7z
export GITLAB_TOKEN=<token, api scope> GITLAB_PROJECT=<group/project> GITLAB_URL=https://<gitlab>
~/twentyx/scripts/push-gitlab-packages.sh $(ls | grep -v '\.7z$')
```

Everything lands in `twentyx-store/<RELEASE>/` (RELEASE from `MANIFEST.txt`).
Before the first rebase push, check the instance's generic package size limit
(Admin > Settings > Preferences, `max_package_size`): `wsl-full.nar` is
several GB unpacked.

Then pin it, apply the handover's required edits, and push:

```bash
sed -n 's/^RELEASE=//p' <transfer folder>/MANIFEST.txt > STORE_RELEASE
git commit -am "store: <RELEASE>" && git push
```

## 2. CI

`assemble` (on `main`) builds, per base variant:

- `workspace-store:<release>-<variant>-<base digest>`: the base manifest plus
  `pod-full.tar.gz` (from `BASE_RELEASE`) and `pod-delta.tar.gz`, with the
  closure's session variables as image ENV. Built only when the tag is
  missing, so the ~1 GB layers are downloaded once per release or base
  change. `FORCE_STORE=1` rebuilds it.
- `workspace:<commit>-<variant>`: that plus this repo as a ~400 KB layer
  (`docker/mklayer.sh`), with our entrypoint. Seconds.

The bases are never pulled (`crane append` works on manifests). Cluster
facts are CI variables that beat `.gitlab-ci.yml`: `IMAGE_REGISTRY`,
`BASE_REGISTRY`, `BASE_TAG`, `IMAGE_VARIANTS`.

`smoke` runs the image it just built as its job image: `doctor` (exits 1 on a
failed check; unusable sudo is only a note, CI runners have none) and
`shellcheck` over `pod/ wsl/ docker/ scripts/`.

## 3. Pods

**Workspace template (RunAI):**

- **Image:** `<registry>/workspace:<commit>-<variant>`; `vscode-*` variants
  start code-server through the base's own entrypoint, handed over by ours.
- **Env:** `LLM_BASE_URL`, `LLM_API_KEY`; `SESSION_USER=<you>` if your
  username contains a dash or the workspace is not named `<user>-...`.
- **PVC:** `/data` (or `/code`), writable; `$HOME` becomes `/data/<user>`.
- **Mount (optional):** a ConfigMap/Secret at `/opt/airgap-env` with
  `ca-bundle.crt` and/or `pip.conf` (`/data/.airgap-env` is the fallback).

**First session:**

```bash
runai exec -it <ws> -- doctor                      # paste this when anything is off
runai exec -it <ws> -- /opt/twentyx/libexec/run-opencode
sudo podman images                                 # rootful podman, vfs storage
```

Git identity is yours, once: `git config --global user.email <you>` writes
the real `~/.gitconfig` on the PVC.

Zed/SSH into a pod: `wsl/ssh-bridge.sh` on the WSL side (its header has the
ssh config), `sshd-inetd` in the pod.

## 4. WSL

**A new machine.** From `twentyx-store/<BASE_RELEASE>/` (see the pinned
release's `MANIFEST.txt`) download `SETUP.ps1` and `UNPACK.ps1` into
`C:\twentyx`, then in an elevated PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File C:\twentyx\SETUP.ps1 `
  -Release <STORE_RELEASE> -GitlabUrl https://<gitlab> -GitlabProject <group/project>
```

It fetches what it needs (manifest, rootfs, NAR, Windows kit), imports the
`twentyx` distro, applies the release, clones this repo to `~/twentyx`, runs
`wsl/link.sh`, then installs the Windows side. From a transfer folder it
runs the same without fetching. No WSL at all yet: enable the
`Microsoft-Windows-Subsystem-Linux` and `VirtualMachinePlatform` features
(`dism.exe /online /enable-feature ... /all /norestart`), reboot, then install
the MSI from the kit (`msiexec /i windows-kit\wsl.*.x64.msi`).

**Config:** `~/twentyx` is the live tree. Edit, commit, push; `git pull` to
take others' changes. Run `~/twentyx/wsl/link.sh` again after a pull that
adds or removes dotfiles, or changes `env/`. A real file blocks its link and
is listed; it is yours.

**A new store release:** `git pull`, then `~/twentyx/wsl/update.sh` (fetches
the pinned release and runs its `apply.sh` under sudo). From a transfer
folder instead: `wsl -d twentyx -u root -- bash /mnt/c/<folder>/apply.sh`.
A delta needs its base on the machine; the error names the missing path, and
the fix is the base release's `wsl-full.nar`.

**Rollback:**

```bash
sudo nix-env -p /nix/var/nix/profiles/system --rollback
sudo /nix/var/nix/profiles/system/bin/switch-to-configuration switch
```

**Internal CA:** `env/ca-bundle.crt`, staged by `wsl/link.sh` into
`/var/lib/airgap-env/`; `airgap-ca` appends it to the system bundle.

## 5. Windows client configs

`windows/` holds `wezterm.lua`, `zed-client-settings.json` and
`vscode-settings.json`. `UNPACK.ps1` installs them from the clone
(`\\wsl.localhost\twentyx\home\<user>\twentyx\windows`). After a pull that
touches them:

```powershell
powershell -ExecutionPolicy Bypass -File C:\twentyx\UNPACK.ps1 -ConfigOnly [-Force]
```

Without `-Force`, an existing file is kept and a `*.example` is written next
to it to merge from.

## 6. Offline smoke checklist

Run after a release or a new install, on WSL and in a pod.

- **nvim:** `:checkhealth lazy` green; opening `.py`/`.nix`/`.yaml`/`.toml`/
  `.sh`/`.json` attaches basedpyright+ruff / nixd / yamlls / taplo / bashls /
  jsonls from `/opt/twentyx/profile/bin`; no install prompts.
- **opencode:** `opencode --version` prints; it starts without a ~1.5 min
  stall (the npm pair in `dotfiles/.config/opencode/`); the vendored skills
  are listed.
- **Zed (Windows → WSL):** a project opens with no download lines in
  `Zed.log`; servers start from `/opt/twentyx/profile/bin/`.
- **VS Code Remote-WSL:** `~/.vscode-server/bin/` holds exactly the pinned
  commit; first connect downloads nothing.
- **tmux:** in a pane, `cat -v` then Shift+Enter shows `^[[13;2u`.
- **WSL system:** `systemctl --failed` is empty.

## 7. When something is wrong

`doctor` first (pods: on PATH; WSL: not needed, `systemctl --failed` and the
checklist above). It prints session, closure integrity, `$HOME` links, sudo,
the preload split, terminal and the injected env, and changes nothing. A
missing binary or a closure problem is a `REQUESTS.md` line with the doctor
output.
