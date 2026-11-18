# Changelog

Newest first, from 0.2.0 on. Base of all of it: outside rev `921bfd6`.

## Unreleased

- **Release crosses as base64 parts:** big files arrive as `<file>.partN` in
  `<RELEASE>-b64/`, with `part0` also as `part00`. Run `sh reassemble.sh
  ./release` there first; it checks every part and file by sha256. See
  "Reassemble first" in the handover.
- **harlequin theme:** a Nix-owned `~/.config/harlequin/config.toml` sets
  `tokyo-night`, the nearest match for nvim's tokyonight. harlequin removes
  Textual's ANSI themes, so it cannot use the terminal's own palette. Try
  another theme for one session with `harlequin -t <name>`.
- **harlequin wrapper:** unsets `PYTHONPATH`/`PYTHONHOME`. The wrapper put both
  ahead of its own packages, so a base image that exports either would have
  replaced pyarrow/duckdb and crashed harlequin on import. Tested offline:
  postgres needs no `psql`/`pg_dump` (psycopg loads libpq by store path), sqlite
  needs no `sqlite3` CLI, and `ssh` is needed only for `--ssh-host`.
- **PID logger:** `airgap pids --watch` writes one line every 5 minutes to
  `~/.local/state/twentyx/pids.log` (on the PVC). The line covers PID use, refused
  forks, memory, OOM kills, zombies, exec sessions and the top thread owners. When
  forks start failing, or use reaches 75%, it also writes a full `airgap pids`
  report to `pids-full.log`. A new pod keeps the previous pod's logs as `*.1`.
  The entrypoint starts it, and interactive shells start it as a fallback.
  Set `AIRGAP_PIDS_WATCH=0` to turn it off.
- **CPU pinning:** pins the pod to as many CPUs as its quota allows.
  Bun, JavaScriptCore, Node, Rust and Go size their thread pools from the CPUs
  they can see, which is the whole node. The 0.2.1 caps only covered OpenMP,
  MKL, BLAS, Rayon and Go, so opencode and the JS language servers were left
  sized to the host. `AIRGAP_PIN=0` in the workload env turns it off. It applies to the entrypoint
  and to every `runai exec` shell, and ships `taskset` alone.
- **Clipboard in pods:** nvim uses OSC 52 wherever there is no X11/Wayland
  (WSL unchanged), instead of only when a k8s env var made it through the exec.
  `"+p` returns the last yank rather than reading `"`.
- **tmux** forwards OSC 52 to the terminal even when the outer `TERM`'s
  terminfo has no `Ms`.
- **Pod prompt badge.** A `runai exec` shell now starts its prompt with a yellow
  `⎈ <hostname>` badge, so it no longer looks like a local pane. It also still
  shows over SSH. Only `.config/starship.toml` changes (`nix/modules/shell.nix`).
- **nushell:** `nu`, typed from fish, is a secondary shell (never a login shell)
  with the starship, zoxide, atuin and direnv integrations. Its prompt shows a
  green `nu` marker; fish and bash prompts are unchanged. nvim gets LazyVim's
  `lang.nushell` extra, the `nu` parser and `nu --lsp`.

### nvim: "tree-sitter CLI missing", and `:TSUpdate` errors

- **Cause:** nvim-treesitter only counts parsers under
  `~/.local/share/nvim/site/parser`, a `home-defaults` link that `dotfiles/`
  does not carry. Without it, LazyVim tries to compile every parser, which
  offline fails as a missing tree-sitter CLI.
- **Fix:** new `lua/plugins/treesitter.lua` sets `install_dir` to the parsers'
  store path, so the config finds them with no `$HOME` link.
- **Undo inside:** the `~/.local/bin/tree-sitter` symlink, and any local
  `:TSUpdate` patch. The CLI only lets LazyVim try a download that fails offline.
- `check-nvim-offline.sh` now runs without the `.local` links and fails on any
  missing parser.

## Release after 20261102-717fbad554

`20261102-717fbad554` could not be applied. Its WSL delta was cut for outside's
system and refused to import on inner's. Use this one instead.

- `wsl-delta.nar.tar.gz` no longer depends on any base: it is closed under
  references, and imports into any store.
- It leaves out outside's system and profiles, which inner cannot use, and adds
  the build tools a rebuild of inner's own needs.
- `apply.sh` imports and adds GC roots. It no longer switches, and the pre-check
  and `--import-only` are gone. `nixos-rebuild` from the inner flake does the switch.
- `pod-delta.tar.gz` now holds its whole closure, so it fits any base. It goes in the
  same place, and CI does not change.

## Release format (20261102)

- **Root moved to `/opt/twentyx`.** Variable names such as `AIRGAP_ROOT` are unchanged.
- **Transfers are now `twentyx-store/<RELEASE>/`,** cut by `scripts/make-release.sh`,
  which replaces `make-transfer.sh`.
- **WSL payload is a `nix-store --export` stream,** applied by `apply.sh`, which
  checks the delta's references before importing.
- **`crane-layer.tar`:** crane and its closure at `nix/store/...`.
- **`dotfiles/`:** the pod's generated configs as plain files, from
  `scripts/export-dotfiles.sh`.
- **tmux status** no longer prints an error if `airgap-tmux-status` is missing.

## 0.2.1

### Pods that stop forking ("os error 11")

- **tini as PID 1:** the entrypoint re-execs under it, so orphans are reaped.
- **Thread pools sized to the CPU quota:** OMP, MKL, OpenBLAS, NumExpr, Rayon and
  GOMAXPROCS, filled only when unset. `AIRGAP_THREADS` overrides all of them.
- **`airgap pids`:** shows what is using the PID budget, and `--kill <sid>` ends a
  session. Runs on bash builtins, so it works with no PIDs left.
- **Warnings:** interactive shells warn at 75% PID use, and `airgap doctor` has a
  limits section that fails at the same point.
- **tmux status line:** the pod's real `cpu  mem  pids` budget, yellow at 75% and
  red at 90%. btop reads `/proc`, which describes the node.

### Tools

- **ffmpeg and ffprobe** (`ffmpeg-headless`), both targets.
- **runai CLI:** `~/.local/bin` is on PATH for a hand install, or CI bakes it in
  with `RUNAI_CLI_URL`. It must match the cluster, so it is never transferred.

### opencode

- **Faster start in the gap:** autoupdate, default plugins, models.dev fetch, LSP
  download and share are off (`OPENCODE_DISABLE_*`).
- **Cache survives restarts:** `~/.cache/opencode` lives on the PVC in a pod.

### Transfers

- **Signing removed** across the repo. Nix still checks each path's hash.
- **`nix-export.sh --cache`:** keeps compressed output between runs.

## 0.2.0

### Python

- **python3.10 and 3.11** from python-build-standalone, under versioned names
  only, so the base image keeps `python3`. On WSL 3.11 stays the nixpkgs build.
- **uv in pods.** `uv venv -p 3.10` finds the interpreters on PATH.
- **gnumake**, plus a setuptools and wheel wheelhouse (`PIP_FIND_LINKS`,
  `UV_FIND_LINKS`), so sdists build with the pod's gcc.

### nvim

- **Python debugging:** nvim-dap with debugpy.
- **Imported from the desktop config:** render-markdown, manual blink completion
  (lsp, path, snippets; menu on `<C-Space>`), yank-only clipboard, basedpyright,
  inlay hints off, lualine progress, location and encoding, `lang.yaml`, `lang.toml`.
- **markdown-oxide replaces marksman,** which drops .NET from the closure.
- **Offline start fixed:** 0.1 cloned lazy.nvim and several plugins at startup, so
  it hung in the gap. `scripts/check-nvim-offline.sh` now guards this.

### Tools

- **harlequin:** SQL TUI for postgres and sqlite (plus duckdb). No Redis, Kafka
  or Mongo.
- **open-code-review (experimental):** `ocr review`, wired to the in-house vLLM.
  Needs tool calling on the server.

### Transfers and images

- **Deltas:** ships only what the far side lacks.
- **One RunAI flavor, nvim.** The editor-less layer is gone. Tags keep `-nvim`.
- **tldr pages** come from the tag archive, because upstream re-uploaded the
  release asset under the same tag.
