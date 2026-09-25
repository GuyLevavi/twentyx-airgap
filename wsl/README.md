# NixOS-WSL, inside the airgap

The chicken-and-egg: `scripts/nix-import.sh` needs a machine with Nix on it, and
there isn't one yet. So the very first artifact is a rootfs tarball built
outside and imported by `wsl.exe`, which needs nothing installed on Windows.

## First install

**Outside the gap:**

```bash
nix build .#wsl-tarball
./result/bin/nixos-wsl-tarball-builder          # -> nixos.wsl (no sudo; user-ns)
sha256sum nixos.wsl > nixos.wsl.sha256
```

`tarballBuilder` runs as root because it assembles a filesystem image. It does
not touch the running system.

**Carry `nixos.wsl` in. On Windows:**

```powershell
wsl --import airgap C:\WSL\airgap nixos.wsl --version 2
wsl -d airgap
```

That gives you a working NixOS with the config already applied — the flake was
evaluated when the tarball was built, so `fish`, `nvim`, the whole toolchain are
there on first boot. Nothing further is required to *use* it.

## Rehearsing "no WWW" on a connected machine

The real environment has an internal network but no internet. The distro rides
Windows' networking, so "offline" is a routing fact, not a distro property.
The toolchain needs neither: every runtime fetch class is disabled (opencode's
model fetch and updates, Zed and VS Code auto-updaters, tldr — everything
pinned before crossing the gap). Rehearse it before trusting it. Two levels:

**Level 1 — Windows-side blackout (total, stricter than reality).** Answers
"does anything on first boot need a wire?": press Win+R → `ncpa.cpl` → disable
the **WSL** adapter → `wsl -d twentyx`. First boot should complete normally:
systemd up, tools present, the vscode-server seed intact. Re-enable after.

**Level 2 — inside the distro: no route, internal-style DNS (realistic).**
The machine keeps its Windows network; the distro is told the truth: outside
is unreachable, only internal names resolve.

```bash
sudo ip route del default
sudo sh -c 'echo "nameserver 192.168.7.7" > /etc/resolv.conf'   # a dead internal-style resolver
```

With no default route nothing can leave the laptop — any hidden network
dependency fails immediately instead of hanging, exactly like in the gap.
Run `opencode`, `zed`, `code` (Remote-SSH into itself), `nix build` of a
`writeText` change — all must behave as if nothing happened.

**Restore:** `wsl --shutdown` from PowerShell (resets routes and resolv.conf
on next start), or re-add the route:

```bash
sudo ip route add default via <windows-gateway>   # the gateway `ip route` showed before deleting
```

If anything fails with the route deleted, do not "fix" it by installing or
downloading anything — a runtime fetch is exactly what this toolchain exists
to make impossible. A failure under Level 2 is a bug in the bundle; report it.

## Subsequent updates

Once the machine exists, updates are binary-cache transfers rather than rootfs
rebuilds:

```bash
# outside
./scripts/nix-export.sh                    # -> dist/nix-transfer/*.tar.gz + TRANSFER

# inside, after carrying the directory across
sudo ./scripts/nix-import.sh /path/to/nix-transfer
```

`nix-import.sh` prints the two activation commands. After the first activation,
`sudo nixos-rebuild switch --flake /etc/nixos#wsl` works offline for any change
that does not add a package — `writeText`, `buildEnv` and `symlinkJoin` need only
`stdenvNoCC` (shipped deliberately for this reason) and build from string
literals with no fetches.

Chunks may be transferred in **any order** and re-imported freely: the cache is
content-addressed, so reassembly has no ordering requirement and no partial-state
corruption mode. This was verified by extracting in reverse.

## Windows → distro over SSH (Zed and VS Code)

Both editors connect into the distro over SSH; sshd is already on
(`services.openssh`, key-only). WSL2 forwards it to Windows' localhost.

One-time key setup, in PowerShell:

```powershell
ssh-keygen -t ed25519                      # accept defaults, no passphrase or a stored one
type $env:USERPROFILE\.ssh\id_ed25519.pub | wsl -d twentyx -- sh -c 'mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 700 ~/.ssh'
```

Then connect — Zed: Remote Servers → New SSH Server → `gl@localhost`.
The matching remote server is pre-seeded in `~/.zed_server/` (release-matched
to the installer in the kit; see the `airgap.zed.remoteClientVersion` note and
the `cloud.zed.dev` preflight caveat there). VS Code: install **Remote - SSH**,
F1 → "Connect to Host" → `gl@localhost`; the server is pre-seeded for the kit's
VS Code build, so nothing downloads.

## VS Code from Windows

This is the one thing moving off Fedora **breaks**, and it fails silently: the
prebuilt vscode-server node hardcodes `/lib64/ld-linux-x86-64.so.2`, which NixOS
does not have, so the connection hangs forever on *"Setting up VS Code Server"*
rather than erroring.

Two independent fixes, both already in `nix/hosts/wsl.nix`:

- `services.vscode-server.enable` — patches the server's node on install
- `programs.nix-ld.enable` — a generic FHS interpreter for other prebuilts

There is a third requirement the config cannot satisfy for you: in the airgap the
server tarball **cannot be downloaded**. Pre-seed it at
`~/.vscode-server/bin/<commit>/` for the exact commit of your Windows VS Code
build (`code --version`, second line), and pin VS Code's auto-update off on the
Windows side — otherwise every VS Code update silently breaks the connection
again.

## What is deliberately NOT here

The Windows-side configuration (WezTerm config, VS Code settings) is not managed.
It could be — `home.activation` copying into `/mnt/c/Users/<you>/` — but copying,
never symlinking: Windows applications do not reliably follow WSL symlinks, and a
half-working config is worse than an unmanaged one.

## Agent and containers on WSL

- **opencode** and **herdr** are in the closure, same as the pod — no extra
  setup. The preload plugin is seeded as a packaged default; opencode's own
  config is yours, in `~/.config/opencode/`.
- **Zed remote** into the pod or into WSL: the remote server is in the
  closure under `~/.zed_server/`; set `airgap.zed.remoteClientVersion` to the
  Windows client's exact `zed --version` string. Watch for a client-side
  `cloud.zed.dev` preflight on first connect (see the option comment).
- The official VS Code extension (`sst-dev.opencode`) ships as a raw `.vsix` at
  `~/.local/share/vsix/` — install it on the **Windows** side via
  "Install from VSIX", since the airgap has no marketplace.
- **podman** runs at the system level (`virtualisation.podman` in
  `nix/hosts/wsl.nix`), docker-compatible. In a RunAI pod it comes from the
  closure instead, pointed at a `vfs` storage.conf by bootstrap, with root
  available via `sudo`.
- **Internal CA**: carry `ca-bundle.crt` (the same file the pod's env-injection
  mount receives) next to the flake — `nix/hosts/wsl.nix` wires it into the
  system trust store when present, which is what `push-artifactory.sh`, the
  runai CLI and `uv` need for TLS against Artifactory.
