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

**Carry `nixos-wsl.tar.gz` in. On Windows:**

```powershell
wsl --import twentyx C:\WSL\nixos C:\twentyx\nixos-wsl.tar.gz --version 2
wsl -d twentyx
```

Then the two one-shot scripts (see `MANUAL.md` §1): `UNPACK.ps1` on the
Windows side, `setup-wsl.sh` as root inside the distro.

That gives you a working NixOS with the config already applied — the flake was
evaluated when the tarball was built, so `fish`, `nvim`, the whole toolchain are
there on first boot. Nothing further is required to *use* it.

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
Run `opencode`, `zed` (remote into itself), `nix build` of a `writeText`
change — all must behave as if nothing happened.

**Restore:** `wsl --shutdown` from PowerShell (resets routes and resolv.conf
on next start), or re-add the route:

```bash
sudo ip route add default via <windows-gateway>   # the gateway `ip route` showed before deleting
```

If anything fails with the route deleted, do not "fix" it by installing or
downloading anything — a runtime fetch is exactly what this toolchain exists
to make impossible. A failure under Level 2 is a bug in the bundle; report it.

## Subsequent updates

Once the machine exists, updates are cache transfers rather than rootfs
rebuilds. The everyday path is `scripts/setup-wsl.sh` (clone/ff the bundle,
import `wsl-rebuild.tar.gz`, rebuild); its steps spelled out:

```bash
# outside (connected machine)
./scripts/export-rebuild-cache.sh          # -> dist/wsl-rebuild.tar.gz

# inside, after carrying it across (as root)
tar -xzf /mnt/c/twentyx/wsl-rebuild.tar.gz -C /var/cache/nix-transfer --strip-components=1
nix copy --from file:///var/cache/nix-transfer --all
```

After the first activation,
`sudo nixos-rebuild switch --flake ~/twentyx-airgap#wsl` works offline for any
change that does not add a package — `writeText`, `buildEnv` and `symlinkJoin`
need only `stdenvNoCC` (shipped deliberately for this reason) and build from
string literals with no fetches. (`/etc/nixos` holds only the just-in-case
`configuration.nix`; the repo arrives as the shipped `twentyx-airgap.bundle`.)

The generic sharded exporter (`scripts/nix-export.sh` outside,
`scripts/nix-import.sh` inside) remains for arbitrary cache moves; its chunks
may be transferred in **any order** and re-imported freely — the cache is
content-addressed, so reassembly has no ordering requirement and no
partial-state corruption mode (verified by extracting in reverse).

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

## What is deliberately NOT here

The Windows-side configuration (WezTerm config, Zed settings) is not managed.
It could be — `home.activation` copying into `/mnt/c/Users/<you>/` — but copying,
never symlinking: Windows applications do not reliably follow WSL symlinks, and a
half-working config is worse than an unmanaged one.

## Agent and containers on WSL

- **opencode** and **herdr** are in the closure, same as the pod — no extra
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
