# AGENTS.md (inner repo)

Config for an **airgapped** RunAI/OpenShift environment and a NixOS-WSL
laptop. The binaries come from the outside repo as a pinned store release
(`STORE_RELEASE`); this repo is text only. `README.md` is the map,
`MANUAL.md` the operations, `NOTES.md` the why; read them before a
non-trivial change. `CONTRACT.md` is the interface with the outside and
changes only together with it.

## Rules

- **Never edit Nix here, and never vendor binaries.** A new tool, a package
  bump, a WSL service/sysctl/`/etc` change: one line in `REQUESTS.md`.
- **Config lives here, nowhere else.** Linux-side config goes in `dotfiles/`
  at its `$HOME`-relative path; Windows client config in `windows/`.
  Machine-local overrides use each tool's include (fish `conf.d/local.fish`,
  `~/.gitconfig`, tmux `source-file -q`), never an edit to a shared file.
- **Point at stable paths:** `/opt/twentyx/profile/bin/<tool>` and
  `/opt/twentyx/home-defaults/...`. Never a `/nix/store` path in a config:
  it goes stale with the next release.
- **No runtime fetch.** A failed fetch in the gap is a hang, not an error.
  Auto-update, extension auto-install, model fetches and npm installs stay
  off. The only fetches are the token-gated package-registry pulls
  (`docker/assemble.sh`, `wsl/update.sh`, `SETUP.ps1`).
- **Required edits from `HANDOVER.md`** are applied on top of the inside
  version; everywhere else the inside version wins. `inside-seed.tar` in a
  transfer is the outside's reference copy of this repo, never a source to
  copy over inside content.

## The pod

- `pod/` becomes `/opt/twentyx/libexec/` (`docker/mklayer.sh`): the
  ENTRYPOINT, PATH and sudo targets name that path.
- `pod/entrypoint` is the only resolver of identity, `HOME` and injected
  assets; everything else sources `/opt/twentyx/etc/session.env`. Keep that
  file `export K="v"` lines only (bash and fish both parse it).
- `docker/assemble.sh` must prepend to the base's `PATH`, never replace the
  base's ENTRYPOINT without recording it in `BASE_ENTRYPOINT`, and keep the
  session variables as image ENV (`runai exec` sources no rc file).
- The LD_PRELOAD split (`run-opencode` + `preload.ts` + `restore-preload.sh`)
  is load-bearing (NOTES.md).
- `ldd`/`... | awk '... exit'` under `pipefail` returns 141: add `|| true`.
- `sshd-inetd` rides `runai exec` stdio: no pty anywhere on that path.

## Verification

```bash
shellcheck -S warning pod/* wsl/*.sh docker/*.sh scripts/*.sh
```

CI's `smoke` job runs the freshly built image's `doctor` and that
shellcheck; a red `smoke` blocks nothing automatically, so read it. On WSL,
`wsl/link.sh` must run clean and `systemctl --failed` be empty. Shell style:
`set -euo pipefail`, `say()` for status, a header comment with a usage line.
