# NixOS-WSL, inside the airgap

The chicken-and-egg: a rebuild inside the distro needs the repo (it arrives as
the shipped `twentyx-airgap.bundle`) and a populated Nix store — and there is
no machine with Nix on it yet. So the very first artifact is a rootfs tarball
built outside and imported by `wsl.exe`, which needs nothing installed on
Windows.

## First install

**Outside the gap:**

```bash
nix build .#wsl-tarball
./result/bin/nixos-wsl-tarball-builder          # -> nixos.wsl (no sudo; user-ns)
```

`nixos.wsl` is assembled in-process inside a user namespace (`unshare -rm`, no
sudo, nothing touched outside the build directory). That choice has its own
failure modes — everything that needs real ownership at build time cannot get
it — and the WSL first-boot forensics, gotchas and the honest assessment of
this design live in `wsl/FIRST-BOOT.md`. Read that before editing
`nix/hosts/wsl.nix` or the tarball builder. `wsl/SMOKE-TEST.md` is the
verify-everything checklist (what to run after any import or rebuild).

**Carry the folder in. On Windows** (PowerShell, **Administrator**), from the
extracted transfer folder:

```powershell
powershell -ExecutionPolicy Bypass -File .\SETUP.ps1
```

One idempotent command, the whole chain: imports `nixos-wsl.tar.gz` as the
`twentyx` distro (skipped when it is already registered), runs `UNPACK.ps1`
(kit, Zed themes/settings, WezTerm, VS Code), then runs `setup-wsl.sh` as root
inside the distro (clone the repo bundle, import the offline rebuild cache);
the final `nixos-rebuild` runs as the user via sudo, never as root. Every
knob is a parameter:

```powershell
.\SETUP.ps1 -Distro twentyx -InstallDir C:\wsl\nixos -User jensen -Base <extracted folder>
```

**Manual equivalent** (the fallback), also from the extracted folder:

```powershell
wsl --import twentyx C:\wsl\nixos .\nixos-wsl.tar.gz --version 2
powershell -ExecutionPolicy Bypass -File .\UNPACK.ps1
wsl -d twentyx -u root -- bash /mnt/c/<extracted folder>/setup-wsl.sh jensen
```

That gives you a working NixOS with the config already applied — the flake was
evaluated when the tarball was built, so `fish`, `nvim`, the whole toolchain are
there on first boot. Nothing further is required to *use* it.

Sudo asks for a password once? It is locked by design; the imported image
carries passwordless sudo for wheel, so the rebuild never needs one. If you see
a prompt you are on an older image — log in as the user and run the rebuild
from your own shell once:
`sudo nixos-rebuild switch --flake ~/twentyx-airgap#wsl`.

The transfer folder is flat by design (no nested `windows-kit/` or
`wsl-rebuild/`), and the big artifacts get a transport twin: `.tar.gz.zst`
for the layers and kit, `.tar.gz.7z` for the WSL image (the pipeline drops
big gzip and rejected its zstd twin; 7-Zip unpacks any of them back to the
exact `.tar.gz`). At a glance:

| Artifact | What it becomes |
|---|---|
| `*.tar.gz.zst` / `nixos-wsl.tar.gz.7z` twins | the transfer shape; unpack with 7-Zip to the plain `.tar.gz` before use |
| `README.md`, `MANIFEST.txt`, `SHA256SUMS` | the Windows-side page (it replaced `START-HERE.txt`), versions, `sha256sum -c` |
| `nixos-wsl.tar.gz` | the image: consumed by `wsl --import` |
| `wsl-rebuild.tar.gz` | additive cache delta for an existing distro |
| `windows-kit-<ver>.tar.gz` | `UNPACK.ps1`: Zed + VS Code + WSL2 MSI, themes, client templates |
| `twentyx-airgap.bundle` | the repo, `git clone`d inside the distro (real history) |
| `nix-layer*.tar.gz`, `repo-layer.tar` | the pod image pipeline — crane/CI consume them |
| `SETUP.ps1`, `UNPACK.ps1`, `setup-wsl.sh` | the one-shot chain and its halves |
| `docs/` | README, ARCHITECTURE, MANUAL, smoke test, INNER-CONFIG |

## Rehearsing "no WWW" on a connected machine

The real environment has an internal network but no internet. The distro rides
Windows' networking, so "offline" is a routing fact, not a distro property.
The toolchain needs neither: every runtime fetch class is disabled (opencode's
model fetch and updates, the Zed auto-updater, everything pinned before
crossing the gap). Rehearse it before trusting it. Two levels:

**Level 1 — Windows-side blackout (total, stricter than reality).** Answers
"does anything on first boot need a wire?": press Win+R → `ncpa.cpl` → disable
the **WSL** adapter → `wsl -d twentyx`. First boot should complete normally:
systemd up, tools present. Re-enable after.

**Level 2 — inside the distro: no route, internal-style DNS (realistic).**
The machine keeps its Windows network; the distro is told the truth: outside
is unreachable, only internal names resolve.

```bash
sudo ip route del default
sudo sh -c 'echo "nameserver 192.168.7.7" > /etc/resolv.conf'   # a dead internal-style resolver
```

With no default route nothing can leave the laptop — any hidden network
dependency fails immediately instead of hanging, exactly like in the gap.
Run `opencode`, `zed` (remote into itself), a VS Code Remote-WSL window,
`nix build` of a `writeText` change — all must behave as if nothing happened.

**Restore:** `wsl --shutdown` from PowerShell (resets routes and resolv.conf
on next start), or re-add the route:

```bash
sudo ip route add default via <windows-gateway>   # the gateway `ip route` showed before deleting
```

If anything fails with the route deleted, do not "fix" it by installing or
downloading anything — a runtime fetch is exactly what this toolchain exists
to make impossible. A failure under Level 2 is a bug in the bundle; report it.

## Updates: rolling, delta, rebase

Once the machine exists, most updates are cache transfers, not rootfs
rebuilds. Three shapes, pick deliberately:

| Shape | Carry | What happens |
|---|---|---|
| rolling — text/config | `twentyx-airgap.bundle` (+ `wsl-rebuild.tar.gz` when the release notes say a rebuild needs new paths) | re-run `setup-wsl.sh`: fast-forward the repo, import the delta, rebuild. No re-import. |
| delta — a rebuild names a missing store path | the next `wsl-rebuild.tar.gz` | that exact path is added to the delta and imported; then the rolling path |
| rebase — closure changes | the new `nixos-wsl.tar.gz` | `wsl --unregister`, fresh import, `SETUP.ps1`. The home is wiped — which is what makes the new defaults apply. Usually cheaper than growing the delta. |

The delta never contains the image: `nixos-wsl.tar.gz` is the image (~1.5
GB); `wsl-rebuild.tar.gz` is an additive cache of just the store paths an
offline rebuild needs (a few hundred MB today; it shrinks as a rebase
absorbs paths). A missing store path named by a rebuild is exactly what gets
added to the next delta.

The everyday path is `scripts/setup-wsl.sh` (clone/ff the bundle, import
`wsl-rebuild.tar.gz`, rebuild as the user via sudo); its steps spelled out:

```bash
# outside (connected machine)
./scripts/export-rebuild-cache.sh          # -> dist/wsl-rebuild.tar.gz

# inside, after carrying it across (as root)
tar -xzf <transfer>/wsl-rebuild.tar.gz -C /var/cache/nix-transfer --strip-components=1
nix copy --from file:///var/cache/nix-transfer --all

# then the switch, as the user (passwordless sudo from the imported image)
sudo nixos-rebuild switch --flake ~/twentyx-airgap#wsl
```

Sudo asks for a password once? It is locked by design; the imported image
carries passwordless sudo for wheel. If you see a prompt, you are on an older
image — log in as the user and run the rebuild from your own shell once.

After the first activation, `rb` (or the spelled-out `nixos-rebuild switch`)
works offline for any change that does not add a package — `writeText`,
`buildEnv` and `symlinkJoin` need only `stdenvNoCC` (shipped deliberately for
this reason) and build from string literals with no fetches. (`/etc/nixos`
holds only the just-in-case `configuration.nix`; the repo arrives as the
shipped `twentyx-airgap.bundle`.)

The rebuild delta is a content-addressed binary cache, so re-importing it is
a no-op rather than a conflict.

## Windows → distro over SSH

Zed connects into the distro over SSH; sshd is already on
(`services.openssh`, key-only). WSL2 forwards it to Windows' localhost.
(Zed's WSL integration needs no SSH setup at all — this section is the
fallback path and the pod-side story.)

One-time key setup, in PowerShell:

```powershell
ssh-keygen -t ed25519                      # accept defaults, no passphrase or a stored one
type $env:USERPROFILE\.ssh\id_ed25519.pub | wsl -d twentyx -- sh -c 'mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 700 ~/.ssh'
```

Then connect — Zed: Remote Servers → New SSH Server → `<you>@localhost`.
The matching remote server is pre-seeded in `~/.zed_server/` (release-matched
to the installer in the kit; see the `twentyx.zed.remoteClientVersion` note and
the `cloud.zed.dev` preflight caveat there).

## VS Code (Remote-WSL)

The kit installs Microsoft VS Code pinned by `nix/vscode-version.nix`; the
`vscode-settings.json` it plants pins updates **off** — required, because a
newer client demands a remote server for its own commit, and the gap cannot
download one. The WSL closure meets that exact client halfway:

- the server for the pinned commit is pre-seeded at activation under
  `~/.vscode-server/bin/<commit>/`;
- the remote machine settings carry the LSP pins (`ruff.path`,
  `nix.serverPath`, schema downloads off) pointing at the same closure
  binaries Zed and nvim use;
- a oneshot installs the pinned extensions (ruff, basedpyright, nix-ide,
  YAML, Tokyo Night, Catppuccin) with the server's own CLI from the
  closure's `.vsix` files — no Marketplace.

`nixos-vscode-server` patches each server's bundled node on first sight (user
linger is on, so that lands before the first connect). From Windows, open the
distro folder (`\\wsl$\twentyx\home\<user>\...`) — first connect must not
download anything. The checks are in `wsl/SMOKE-TEST.md` §9.

## What is deliberately NOT here

The Windows-side configuration (WezTerm config, Zed settings) is not managed.
It could be — `home.activation` copying into `/mnt/c/Users/<you>/` — but copying,
never symlinking: Windows applications do not reliably follow WSL symlinks, and a
half-working config is worse than an unmanaged one.

## Agent and containers on WSL

- **opencode** and **workmux** are in the closure, same as the pod — no extra
  setup. The preload plugin is seeded as a packaged default; opencode's own
  config is yours, in `~/.config/opencode/`.
- **Zed remote** into the pod or into WSL: the remote server is in the
  closure under `~/.zed_server/`; set `twentyx.zed.remoteClientVersion` to the
  Windows client's exact `zed --version` string. Watch for a client-side
  `cloud.zed.dev` preflight on first connect (see the option comment).
- **podman** runs at the system level (`virtualisation.podman` in
  `nix/hosts/wsl.nix`), docker-compatible. In a RunAI pod it comes from the
  closure instead, pointed at a `vfs` storage.conf by bootstrap, with root
  available via `sudo`.
- **Internal CA**: carry `ca-bundle.crt` (the same file the pod's env-injection
  mount receives) next to the flake — `nix/hosts/wsl.nix` wires it into the
  system trust store when present, which is what `push-artifactory.sh`, the
  runai CLI and `uv` need for TLS against Artifactory.
