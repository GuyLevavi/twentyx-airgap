# twentyx-airgap

The airgapped toolchain for the TwentyX lab: one build on a connected machine
feeds two targets — a NixOS-WSL distro on a Windows laptop and a
RunAI/OpenShift workspace image. Nothing is fetched at runtime; everything
arrives through the internal GitLab.

## New here?

**Windows / WSL** — see [`MANUAL.md`](MANUAL.md) §1. From the repo (or its
GitLab archive zip), in an elevated PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\windows\SETUP.ps1 `
  -GitlabUrl https://gitlab.internal -GitlabProject <group/project>
```

`SETUP.ps1` fetches the rootfs — and the Windows kit, when missing — from
this project's package registry, imports it, then clones this repo into the
distro and runs it there — `~/twentyx` is the live tree, so config edits
stick and are yours to push. `-SkipUnpack` installs the distro only. If
Windows does not trust the internal CA yet, the repo's `env\ca-bundle.crt`
(or a copy next to the script) pins the fetches. `doctor` checks the result.

**Pod** — use the workspace image the `assemble` job built into this project's
registry. The toolchain lives at `/opt/twentyx`; `doctor` reports anything
missing.

## Config lives here

On WSL the clone at `~/twentyx` is the live tree: `dotfiles/` are
symlinked into `$HOME` (setup points that up), pods get the same tree in
their image. The loop is: edit `~/.config/<file>` — the symlink writes into
the clone — then `git commit` and `git push`; everyone else gets it with
`git pull`. To keep a private override, delete the link and write a real
file — it is yours from then on.

## Read next

- [`MANUAL.md`](MANUAL.md) — build → carry → install → update → rollback.
- [`ARCHITECTURE.md`](ARCHITECTURE.md) — how it works, and the reading order.
- [`NOTES.md`](NOTES.md) — open items and the why behind load-bearing pieces.
