# Contract between the outside and the inside repo

The only interface between the two repos. It lives in the inner repo; the
outside reads the same file as `inside-seed/CONTRACT.md`. Changing anything
below is the only kind of change that needs both sides; everything else is
one repo's business.

- **Outside** (connected; the owner only): `flake.nix`, `nix/`, the transfer,
  the WSL installer. Produces the artifacts below.
- **Inside** (internal GitLab): dotfiles and every Linux-side config, the pod
  boot scripts, the Windows client configs, CI, publishing. Consumes them.

Artifacts cross the gap; git history does not. Requests go out by hand
(`REQUESTS.md` inside); changes to inside files come in as numbered required
edits (`HANDOVER.md`).

## Releases

- **RELEASE id:** `<yyyymmdd>-<outside short rev>` (commit date, 10 hex digits).
- **Kinds:** `full` (a rebase: whole closures + install set) or `delta`
  (what the release adds to its base). A delta applies to anything that has
  its base, in any order; store paths only add.
- **Publishing:** GitLab generic package `twentyx-store/<RELEASE>/<file>`,
  every file of a transfer under the release that made it. A delta's full
  layer, rootfs and kit therefore live under its `BASE_RELEASE`.
- **Pin:** the inside's `STORE_RELEASE` file (one line, the RELEASE id).

## Files of a release

| File | Contents | Consumer |
|---|---|---|
| `MANIFEST.txt` | the keys below | everyone |
| `pod-full.tar.gz` | `opt/twentyx/` tree, then the whole pod closure at `nix/store/` (full only) | inner CI: the store layer |
| `pod-delta.tar.gz` | `opt/twentyx/` tree, then the closure minus the base's (delta only) | inner CI: appended after the full layer; its `opt/` wins |
| `wsl-full.nar` / `wsl-delta.nar` | `nix-store --export` of the WSL closure / of what it adds | `apply.sh` |
| `apply.sh` | the WSL updater: import, root the base, set the profile, switch | WSL, as root |
| `nixos-wsl.tar.gz` | rootfs of the base system (full only) | `wsl --import` |
| `windows-kit-<zed version>.tar.gz` | Windows installers, Zed themes/extensions, first-install client configs (full only) | `UNPACK.ps1` |
| `SETUP.ps1`, `UNPACK.ps1` | the Windows installer (full only) | Windows |
| `HANDOVER.md` | required edits to the inner repo, with the adoption procedure | the inside agents |
| `inside-seed.tar` | the inner repo as the outside knows it (`inside-seed/` prefix); a reference, never extracted over inside content | the inside agents |

`MANIFEST.txt` keys, `KEY=value` one per line, `#` comments:
`RELEASE`, `BASE_RELEASE`, `KIND` (`full`|`delta`), `WSL_SYSTEM`,
`BASE_WSL_SYSTEM`, `NIXPKGS_REV`, `WINDOWS_KIT` (the kit's file name).

## Paths inside a pod image (from the store layer)

| Path | What |
|---|---|
| `/opt/twentyx/profile/bin/<tool>` | every tool, at a path that survives closure updates; configs point here, never at `/nix/store` |
| `/opt/twentyx/home-defaults/` | binary-coupled defaults, see below |
| `/opt/twentyx/session-env` | `KEY=VALUE` lines, made image ENV by inner CI |
| `/opt/twentyx/store-paths` | the closure, one path per line (doctor checks it) |
| `/opt/twentyx/bin/sudo` | setuid (4555) sudo; inner CI ships the sudoers |

`/opt/twentyx/home-defaults/` holds:
`.zed_server/zed-remote-server-stable-<zed version>`,
`.config/opencode/plugins/workmux-status.ts`,
`.config/opencode/skills/<name>/`, and in pods only
`.local/share/code-server/extensions/sst-dev.opencode/`.

The inside owns everything else under `/opt/twentyx` (`libexec/`,
`dotfiles/`, `etc/`, `VERSION`) through its repo layer.

## Paths on WSL

The same `/opt/twentyx/profile` and `/opt/twentyx/home-defaults` (tmpfiles
links into the current system), and the session variables as
`environment.sessionVariables`. The inner repo is cloned at `~/twentyx`;
`/var/lib/airgap-env/{ca-bundle.crt,pip.conf}` is where `wsl/link.sh` stages
the internal CA and pip config (the `airgap-ca` unit reads it).
