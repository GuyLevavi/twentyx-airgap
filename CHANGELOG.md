# Changelog

Newest first, from 0.2.0 on. Base of all of it: outside rev `921bfd6`.

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
