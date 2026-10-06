# Plan: Simplify to a Frozen Appliance, Remove Home-Manager, Make Editors Work Offline

**Status:** approved by the owner 2026-10-05. Supersedes `TODO.md` and the deleted `HANDOFF.md`. Execute top to bottom, one commit per phase (or more — keep each commit green).

**Working dir:** `/home/gl/projects/twentyx-airgap`. On the connected NixOS machine. Do **not** run `git commit`, `git push`, or `git rebase` without asking.

## What we are fixing (context)

The project builds one toolchain for two targets: a NixOS-WSL distro for the Windows laptop inside an airgapped lab, and an OCI layer appended onto RunAI/OpenShift pods. Everything crosses the gap physically as tarballs in 7z containers (dist/ has the current bundle).

Three concrete problems, verified in the store before writing this plan:

1. **Offline rebuilds don't work.** The shipped WSL system's runtime closure (`nix-store -qR` of its toplevel) is missing the build-time inputs every config rebuild actually needs: `lndir` (home-manager-files, system-units, user-units, tmpfiles.d, every symlinkJoin), `babelfish` (fish session vars — its source is on GitHub, this is the "rebuild looks for github" report), `json2x` (every TOML/YAML `formats.*` file: starship, atuin, podman confs), `jq.dev` (every `formats.json` file), and buildEnv's `builder.pl` + desktop-file-utils + texinfo. The only rebuild that succeeds today is a no-op at the same commit with the default username. The README's "rebuilds offline in seconds" claim is false.
2. **Zed LSPs fail offline** because `auto_install_extensions` fetches from zed.dev, and there are no built-in adapters for nixd or tombi in the shipped remote server (verified by `strings` on the closure binary: basedpyright, ruff, json, yaml, bash and package-version-server are built in; nixd and tombi are not).
3. **Zed has a second fetch:** `package-version-server` is in the closure but not pinned in the Zed settings, so Zed falls back to downloading it from GitHub.

## Locked decisions (owner answered)

- **WSL updates:** frozen appliance. Nix is never evaluated inside the gap. Changes outside: build on the connected machine, ship a store delta as `wsl-update.nar.7z`, apply with `nix-store --import` + `nix-env --set` + `switch-to-configuration switch`.
- **Editors:** Zed and VS Code both fully offline (extensions vendored), plus LazyVim with Nix-built plugins.
- **WSL tarball:** built with `sudo` using the upstream NixOS-WSL builder (no custom rootless builder).
- **WSL username:** fixed `jensen` for everyone. The `wsl-username` file mechanism is deleted.
- **Pod layer publisher:** unknown until first transfer, keep both GitLab packages and Artifactory, but trim auth paths.
- **Gap edits:** never come back out. Any config the owner edits lives as a real file in `$HOME`, copied in once and never overwritten.
- **home-manager:** dropped. Dotfiles become plain files in the repo. Nix only builds the package profile and the nvim plugin set.

## Architecture after the refactor

- **Connected machine builds everything.** Nothing evaluates Nix inside the gap. AGENTS.md's "never run Nix in a pod" becomes "never evaluate Nix inside the gap".
- **Two kinds of artifact:** the closure (binaries, nvim plugins, Zed server, skills; changing it costs a physical transfer) and the repo layer (`libexec/`, `agent/`, a new `dotfiles/` folder; text, cheap to carry).
- **One `$HOME` rule on both targets:** a symlink into `/nix/store` is ours and gets refreshed on every update; a real file is yours and is never touched. Bootstrap's existing semantics already encode this; seed-home generalizes it.
- **Stable tool paths:** `/opt/twentyx/profile/bin/<tool>` works on both targets (on WSL it is a symlink to the system profile). Editor settings point there, so they survive updates without going stale (this fixes the VS Code stale-store-path bug).
- **WSL is NixOS at the system level** (sshd, podman, nix-ld, systemd); at the user level it is identical to a pod.

## Verification you can run

- `./tests/test-container.sh` — full image integration against a mock OpenShift pod (uid 10001, gid 0, hostile LD_PRELOAD, env-injection mount). Needs podman on the connected machine.
- `nix shell nixpkgs#shellcheck -c shellcheck -S warning libexec/* agent/*.sh tests/*.sh scripts/*.sh docker/*.sh` — CI lint gate.
- `nix flake check` and `nix build .#runai-layer` — evaluate and build both targets.
- `nix develop` — devshell with shellcheck, shfmt, statix, deadnix, crane, skopeo, dive, jq.

## Phase 0 — small cuts (one commit)

Scope: cuts from the current-changes review that the redesign does not delete anyway.

1. `tests/test-container.sh`: delete the `run_step`/`run_step_out` spinner (~32 lines) and the default-store→chroot fallback. Run commands unmuted (plain `podman pull`, `nix build`).
2. `scripts/build-layers.sh`: delete the chroot fallback and the 2>/dev/null swallow. One `nix build --no-link --print-out-paths .#runai-layer .#runai-layer-nvim`.
3. `scripts/windows/SETUP.ps1` + `scripts/windows/UNPACK.ps1`: fold the "extract the .7z first" hint into the existing `missing <file>` error. Delete the `Assert-Unpacked` helper.
4. `opencode/tui.json`: delete. `nix/modules/home.nix` stop linking it.
5. `opencode/opencode.jsonc`: drop the entries that repeat opencode's built-in servers (`nixd`, `bash`, `yaml-ls`) and drop `package-version-server` and `markdown-oxide` from the agent's LSP set.
6. Add to the session variables (`home.nix` for now): `OPENCODE_DISABLE_LSP_DOWNLOAD`, `OPENCODE_DISABLE_DEFAULT_PLUGINS`, `OPENCODE_DISABLE_SHARE`. The 1.18.28 binary supports all three.
7. Fix the false claims: `README.md` around L165-169 ("rebuilds offline in seconds") and `wsl/README.md` around L166-171 — say instead: config edits inside the gap are real files in `$HOME`; Nix changes need a new closure transfer.

**Verify:** shellcheck + `nix flake check` + `tests/test-container.sh` pass.

## Phase 1 — drop home-manager (both targets)

Scope: replace the HM machinery with plain dotfiles + one small Nix module that builds only what Nix must build.

### What HM currently generates (snapshot source of truth)

The built tree is `/nix/store/28sn37c3m5h8a83bm9bha019qw40wj1q-home-manager-files`. Snapshot the relevant files before deleting HM:
- `.config/fish/config.fish` (the rehome block, the interactive init, the `__rehome` prompt hook, the AIRGAP-SETUP warnings)
- `.config/tmux/tmux.conf`
- `.config/starship.toml`
- `.config/atuin/config.toml`
- `.config/btop/btop.conf`
- `.config/zed/settings.json` (the airgap half — LSP pins, agent_servers, prettier off)
- `.config/opencode/opencode.jsonc`
- `.bashrc` (the exec-into-fish block)

Copy them into `dotfiles/`, then rewrite every `/nix/store/...` path to a stable `/opt/twentyx/...` path, and every `/home/jensen` bake-in to `$HOME` lookups.

### New files

- `dotfiles/` — see above. This is what crosses the gap as text in the repo layer.
- `nix/packages.nix` — the package list from `tools.nix`, using plain `wsl`/`pod` booleans. Drop: visidata, tree-sitter CLI, nix-direnv, `opencodeWithLsp`, `twentyx.python`/`twentyx.tools.*` options.
- `nix/profile.nix` — one small module producing:
  - `twentyx.profile`: a `buildEnv` of `packages.nix` (+ `sessionPath` of LSP binaries)
  - `twentyx.sessionEnv`: the env var list (TERMINFO_DIRS, COLORTERM, EDITOR/VISUAL/PAGER/LESS, `UV_PYTHON_DOWNLOADS=never`, `PIP_DEFAULT_TIMEOUT=10`, `GIT_TERMINAL_PROMPT=0`, `OPENCODE_DISABLE_*`)
  - `twentyx.homeDefaults`: a `runCommand` dir of store-symlinks we own:
    - `.zed_server/zed-remote-server-stable-${zedClientVersion}` → `pkgs.zed-editor.remote_server`'s binary (one entry, no shims, no option)
    - `.config/opencode/plugins/preload.ts` → `../../agent/plugins/preload.ts`
    - `.config/opencode/plugins/workmux-status.ts` → workmux input's file
    - `.config/opencode/skills/<name>` → matt-skills dirs (same reject list as today)
    - `.config/opencode/node_modules/.keep` + `package-lock.json`
    - `.local/share/code-server/extensions/sst-dev.opencode` → the pinned vsix dir
    - `.local/share/vsix/sst-dev.opencode-0.0.13.vsix` → the pinned vsix file
  - `twentyx.nvimPlugins`: built in P3; placeholder empty dir for now.
- `libexec/seed-home` — new script:
  1. Refresh every symlink from `$TOOLCHAIN_ROOT/home-defaults` into `$HOME` (replace if it points elsewhere; leave real files alone).
  2. Copy every file from `$TOOLCHAIN_ROOT/dotfiles` into `$HOME` only if the destination is absent.
  3. Replace stale home-manager-era store symlinks at those paths (a symlink into `/nix/store` whose target no longer exists, or that exists but is a `*-home-manager-files` path, counts as ours).
  4. For each dotfile the user owns (a real file that differs from the shipped default), print one line: `newer default available: diff <shipped> <yours>`.
- `docker/mklayer.sh` — stage `dotfiles/` into `opt/twentyx/dotfiles` alongside `libexec/`, `agent/`, `VERSION`.

### Changed files

- `flake.nix`:
  - Delete the `home-manager` input.
  - Delete `homeConfigurations` and `mkRunai`.
  - Replace them with:
    - `packages.x86_64-linux.runai-layer = pkgs.callPackage ./nix/runai/layer.nix { }`
    - `packages.x86_64-linux.runai-layer-nvim = pkgs.callPackage ./nix/runai/layer.nix { nvim = true; }`
    - `packages.x86_64-linux.wsl-tarball` (see P2)
  - Fix `username = "jensen"`. Delete the `wsl-username` plumbing, `specialArgs`, the whole let-block.
- `nix/runai/layer.nix` — stop consuming `hm`. Take `profile`, `sessionEnv`, `homeDefaults`, `nvimPlugins` directly from `nix/profile.nix`. The `session-env` file no longer needs the eval-home filter (delete it and the `eval-home` file).
- `libexec/bootstrap` — pods only:
  - Keep the `session_home()` relocation and the durable-home warnings.
  - Replace the linking loop with `exec "$TOOLCHAIN_ROOT/libexec/seed-home"`.
  - Keep the podman `storage.conf` and env drop-ins; generate them into `$TOOLCHAIN_ROOT/etc/env.fish` and `$TOOLCHAIN_ROOT/etc/env.bash` style (sourced from the seeded rc files), not the other way around.
  - Delete the `.bashrc.hm` parking and the `99-rehome.fish` removal.
- `libexec/doctor` — drop the `stragglers`/eval-home check (no longer applicable). Keep the rest; add a `seed-home` line to the summary.
- `nix/hosts/wsl.nix`:
  - Delete `home-manager.nixosModules.home-manager`, the `home-manager.users` block, `backupFileExtension`.
  - Add `/opt/twentyx/profile` symlink to the system profile (one tmpfiles or systemd-tmpfiles rule).
  - Add `environment.sessionVariables` from `twentyx.sessionEnv`.
  - Add a one-shot user service or `/etc/profile.d` hook that runs `seed-home` once per boot (or once per user login).
  - Keep podman, nix-ld, sshd, and the user/`mutableUsers = false` block.
- **Delete:** `nix/modules/home.nix`, `nix/modules/shell.nix`, `nix/modules/nvim.nix`, `nix/modules/skills.nix`, `nix/modules/lsp.nix`, `nix/modules/tools.nix`. `zed-settings.json` at repo root moves into `dotfiles/.config/zed/settings.json`.

**Verify:** `tests/test-container.sh` — assert dotfiles land as real files (not symlinks), defaults land as symlinks, `fish -n` parses the seeded config, Zed settings point at `/opt/twentyx/profile/bin/`, opencode plugin and code-server extension still link.

## Phase 2 — WSL frozen appliance

### Builder + username

- `flake.nix`: `wsl-tarball = self.nixosConfigurations.wsl.config.system.build.tarballBuilder`. Delete the unshare wrapper.
- `nix/hosts/wsl.nix`:
  - Delete the custom `system.build.tarballBuilder` override (the whole block L444-587).
  - Delete the workarounds it needed: `createHome = false`, the tmpfiles `d`/`z` home rules, the three `.vscode-server` chowns, `defaultNixosConfig`, `wslDistroConf`.
  - Let the upstream builder's `nixos-install` create `/home/jensen` (activation + `createHome` default): `sudo ./result/bin/nixos-wsl-tarball-builder nixos-wsl.tar.gz`. (uid 1000 is the first normal user on NixOS-WSL; jensen is that user. `--chown` runs before the install and is for `--extra-files` only.)
  - Cut `bootlog` to: date, `systemctl --failed --no-pager`, `journalctl -b --no-pager | tail -100`, copy to `/mnt/c/twentyx/bootlog.txt` if mounted.
- Delete `wsl/FIRST-BOOT.md`. Its builder lessons no longer apply.

### Delete the in-gap rebuild machinery

- `scripts/export-rebuild-cache.sh` — delete.
- `flake.nix` `wslDeltaRoots` — delete.
- `tools.nix`'s `rb` — delete (it is gone with tools.nix anyway; if you keep a minimal shell.nix, drop the script there).
- `nix/hosts/wsl.nix` — delete the `substituters = [ "file:///var/cache/nix-transfer" ]` block, `trusted-public-keys = []`, `require-sigs = false`, `connect-timeout`, and the comment that says they are for offline rebuilds.
- `scripts/setup-wsl.sh` — delete steps 2 (cache import) and 4 (nixos-rebuild). Step 3 (CA staging) changes per below.

### VS Code server without the patcher

- Delete the `nixos-vscode-server` flake input, `inputs.nixos-vscode-server.nixosModules.default` import, `services.vscode-server.enable = true`, and `linger = true`.
- The nix-ld block (`programs.nix-ld.enable = true` with `stdenv.cc.cc.lib zlib openssl`) is already there and is what lets the stock server run.
- Move the server extraction into the existing `vscode-extensions` oneshot (which already runs as jensen, after tmpfiles): if `$HOME/.vscode-server/bin/$COMMIT/bin/code-server` is absent, extract the tarball there. This removes the activation script and its chowns entirely.
- **Fallback:** if Remote-WSL still fails to start on the real machine, put back just the `nixos-vscode-server` module (it does RPATH patching; nix-ld may not cover the vsce-sign libssl check). Do not keep both.

### CA bundle at runtime (no rebuild to add or rotate)

- New oneshot (or a tmpfiles + generator, whatever is smallest): build `/var/lib/airgap-env/ca-certificates.crt` by concatenating the system cacert bundle with `/var/lib/airgap-env/ca-bundle.crt` if present.
- `environment.etc."ssl/certs/ca-certificates.crt".source = lib.mkForce "/var/lib/airgap-env/ca-certificates.crt"` and the same for `ssl/certs/ca-bundle.crt`.
- `environment.sessionVariables.NODE_EXTRA_CA_CERTS = "/var/lib/airgap-env/ca-certificates.crt"`.
- `setup-wsl.sh` drops the CA and pip.conf into `/var/lib/airgap-env/` and runs the oneshot.
- Delete the bootlog + fish warnings that say "drop ca-bundle.crt and run rb" — there is no rb.

### The update artifact

- `scripts/transfer-bundle.sh`:
  - Build the new toplevel: `NEW=$(nix build --no-link --print-out-paths .#nixosConfigurations.wsl.config.system.build.toplevel)`.
  - Base: `BASE=$(readlink -f /nix/var/nix/profiles/system)` of the last shipped system (kept as a GC root `.gcroots/wsl-system` in the repo). If absent or the far side has an older one, fall back to a full export (the whole closure — about 1.5 GB, same size class as the tarball, fine for a one-time or nixpkgs-bump update).
  - Export the delta: `comm -13 <(nix-store -qR "$BASE" | sort) <(nix-store -qR "$NEW" | sort) | xargs nix-store --export | gzip -n -6 > build/wsl-update.nar.gz`, then wrap in 7z like every other big artifact.
  - Record `WSL_SYSTEM=$NEW` and `WSL_BASE=$BASE` in the MANIFEST.
  - Advance the GC root only after the export succeeds.
- `scripts/setup-wsl.sh` — the new shape, about 30 lines:
  ```bash
  #!/usr/bin/env bash
  set -euo pipefail
  # run as root inside the distro: wsl -d twentyx -u root -- bash /mnt/c/twentyx/setup-wsl.sh
  . /opt/twentyx/libexec/common.sh 2>/dev/null || true  # for say/die if already installed
  T="${TRANSFER:-/mnt/c/twentyx}"
  # 1. text layer (dotfiles, libexec, agent) — overlay the opt/ subtree
  tar -xf "$T/repo-layer.tar" -C / opt
  # 2. CA bundle + pip.conf
  install -Dm644 "$T/ca-bundle.crt" /var/lib/airgap-env/ca-bundle.crt 2>/dev/null || true
  # 3. closure delta
  if [ -f "$T/wsl-update.nar" ]; then
    NEW=$(sed -n 's/^WSL_SYSTEM=//p' "$T/MANIFEST.txt")
    BASE=$(sed -n 's/^WSL_BASE=//p' "$T/MANIFEST.txt")
    if [ -n "$BASE" ] && [ ! -e "$BASE" ]; then
      die "this update is a delta against $BASE which is not in the store; carry the full wsl-update.nar instead"
    fi
    nix-store --import < "$T/wsl-update.nar"
    nix-store --check-validity "$NEW"
    nix-env -p /nix/var/nix/profiles/system --set "$NEW"
    /nix/var/nix/profiles/system/bin/switch-to-configuration switch
  fi
  ```
- Rollback: `nix-env -p /nix/var/nix/profiles/system --rollback && /nix/var/nix/profiles/system/bin/switch-to-configuration switch`.

**Verify (on the dual-boot Windows side, after carrying dist/ over):**
1. `wsl --import twentyx-test C:\wsl\nixos-test dist\nixos-wsl.tar.gz` (side-by-side, does not touch the working distro).
2. First boot: `systemctl --failed` is empty, `su - jensen` works, `bootlog.txt` is copied to Windows.
3. Network off (`wsl --shutdown`, disable the network on the Windows side or pull the cable), then apply a delta that changes one dotfile and adds one package. `nix-store --check-validity` passes and `switch-to-configuration switch` finishes.

## Phase 3 — editors fully offline

### LazyVim (user-editable, no runtime fetch)

- `nix/packages/nvim-plugins.nix` — a `linkFarm` of:
  - LazyVim core (nixpkgs 16.0.0 — verified all present in the pinned nixpkgs): `LazyVim`, `lazy-nvim`, `snacks-nvim`, `blink-cmp`, `friendly-snippets`, `bufferline-nvim`, `lualine-nvim`, `noice-nvim`, `nui-nvim`, `mini-icons`, `mini-ai`, `mini-pairs`, `which-key-nvim`, `gitsigns-nvim`, `trouble-nvim`, `todo-comments-nvim`, `flash-nvim`, `grug-far-nvim`, `persistence-nvim`, `plenary-nvim`, `conform-nvim`, `nvim-lint`, `nvim-lspconfig`, `lazydev-nvim`, `nvim-treesitter-textobjects`, `nvim-ts-autotag`, `ts-comments-nvim`, `tokyonight-nvim`, `catppuccin-nvim`.
  - Extras: `SchemaStore-nvim` (json/yaml), `venv-selector-nvim` (python), `markdown-preview-nvim` if you want preview.
  - Treesitter parsers as a `linkFarm` of each grammar derivation's `parser/` and `queries/` dirs, installed at `$out/parsers` (this is the `install_dir` LazyVim's TS module will treat as installed — verified: `install_dir` is configurable, and `get_installed()` scans that dir's `parser/` subdirectory).
- `dotfiles/.config/nvim/init.lua` — the LazyVim starter (require lazyvim), plus `lua/config/airgap.lua`:
  ```lua
  require("lazy").setup({
    spec = { { "LazyVim/LazyVim", import = "lazyvim.plugins" }, { import = "plugins" } },
    dev = { path = vim.env.TWENTYX_NVIM_PLUGINS, patterns = { "" }, fallback = false },
    install = { missing = false },
    checker = { enabled = false },
    change_detection = { enabled = false },
    rocks = { enabled = false },
    performance = { rtp = { reset = false }, reset_packpath = false },
  })
  ```
  and `lua/plugins/airgap.lua`:
  - disable `mason.nvim` and `mason-lspconfig.nvim` (LazyVim then starts servers from PATH — verified against LazyVim 16 source);
  - set `nvim-treesitter`'s `install_dir` to the Nix parser dir;
  - set blink's `fuzzy.prebuilt_binaries.download = false` (nixpkgs builds the native lib);
  - set `baleia`/`SchemaStore` to prefer local store, disable JSON/YAML schema downloads;
  - override the lang.nix extra to use `nixd` not `nil_ls` (the extra defaults to nil).
- `TWENTYX_NVIM_PLUGINS` env var points at the linkFarm path.
- **Build-time check** (a derivation, runs in the Nix sandbox = no network): run `nvim --headless '+lua ...'` against the seeded starter and assert:
  - `require("lazy").plugins()` has every spec installed;
  - `require("nvim-treesitter.config").get_installed()` covers the wanted list;
  - the LSP binaries resolve from PATH;
  - exit non-zero on any `E`rror in `:messages`.

### Zed

- `nix/packages/windows-kit.nix`:
  - Add a pinned fetchurl per extension: `https://api.zed.dev/extensions/<id>/download?version=<v>` (verified — returns the .tar.gz of `extension.toml` + `extension.wasm` + `grammars/`, 140 KB for nix 0.1.5).
  - Extensions to vendor: `nix`, `toml`, `tombi`, `dockerfile`, `env`.
- `scripts/windows/UNPACK.ps1`: extract each to `%LOCALAPPDATA%\Zed\extensions\installed\<id>\` and rebuild `%LOCALAPPDATA%\Zed\extensions\index.json` (the remote server has `remote_extensions_dir` and `remote_extensions_uploads_dir` paths — the client uploads installed extensions to the remote on connect).
- `nix/packages/windows/zed-client-settings.json`: delete `auto_install_extensions`. Merge the two templates (client + personal-example) into one.
- `dotfiles/.config/zed/settings.json`: pin all eight servers (`nixd`, `basedpyright`, `ruff`, `json-language-server`, `bash-language-server`, `yaml-language-server`, `tombi`, `package-version-server`) to `/opt/twentyx/profile/bin/...` paths. `agent_servers` stays.

### VS Code

- `nix/vscode-version.nix`: delete the `throw`. Keep version + commit.
- `nix/vscode-extensions.nix`: replace the `pkgs.vscode-extensions.*` refs with explicit `fetchurl` per extension, pinned to the versions that match the pinned VS Code (engines verified). This decouples VS Code from nixpkgs bumps.
- `dotfiles/.config/Code - OSS/User/settings.json` (or the Remote-WSL machine settings seed, whichever is the file that gets seeded once): `ruff.path` and `nix.serverPath` point at `/opt/twentyx/profile/bin/...`.

### opencode

- `dotfiles/.config/opencode/opencode.jsonc` — the seeded config. The placeholder check in the shell warning now looks at `$HOME/.config/opencode/opencode.jsonc`.
- Optional: switch the provider to `{env:LLM_BASE_URL}` + `{env:LLM_API_KEY}` substitution so pods can configure through the RunAI workspace env and `doctor`'s endpoint check becomes real.

**Verify, network off, on the laptop:**
- Zed → open `flake.nix`, `docker/assemble.sh`, `pyproject.toml`, a Python file, `docker/BASE-IMAGES.md`, a JSON, a YAML. `Zed.log` shows no download lines. Language servers start from `/opt/twentyx/profile/bin/`.
- VS Code Remote-WSL → same files. No "Install" toasts, no marketplace calls.
- `nvim .` in a shell → no install popups, `:checkhealth lazy` all green, LSPs attach.

## Phase 4 — transfer, publish, docs

- `scripts/transfer-bundle.sh`:
  - Plain artifacts land in a gitignored `build/`; `dist/` holds only the `.7z` files and small files.
  - Stamps: `.layerdrv`, `.wlldrv` now stamp `.#wsl-tarball.drvPath` (covers builder + toplevel), `.updatestamp` for the NAR.
  - Delete: `.complete` marker, the unwrap-on-rerun loop, the WSL tarball content probe, SHA256SUMS for big artifacts (7z CRC + Nix nar hashes already cover it — keep SHA256SUMS for the small files if you want, it's 3 lines).
  - Slim the MANIFEST to: VERSION, GIT_REV, WSL_SYSTEM, WSL_BASE, NIXPKGS_REV.
  - `nix shell nixpkgs#p7zip` → take p7zip from the devShell.
- `scripts/push-gitlab-packages.sh`: drop the `glab packages upload` and `glab auth status --show-token` paths; keep CI token and `GITLAB_TOKEN` only.
- `nix/packages/windows-kit.nix`: delete the README.txt heredoc, keep only the themes actually used (the owner uses Catppuccin Mocha / Latte and Tokyo Night).
- **Docs:** keep `README.md` (one page), `MANUAL.md` (build → carry → Windows setup → WSL update/rollback → pods → debugging → smoke checklist), `NOTES.md` (open items only), `AGENTS.md` (rewrite the rules: never evaluate Nix inside the gap; text = repo layer, binaries = closure; `/opt/twentyx/profile` is the stable path; dotfiles are seed-once). Delete `TODO.md`, `wsl/README.md`, `wsl/SMOKE-TEST.md`, `wsl/FIRST-BOOT.md`, `wsl/dist-readme.md`, `docs/INNER-CONFIG.md`, `docker/README.md`, `docker/BASE-IMAGES.md` — fold what's still true into MANUAL/NOTES. Cut code comments to one line each; put the "why" in NOTES.md.
- `AGENTS.md` verification block: add the headless nvim offline check.

**Verify:** `grep -rn` the docs for the deleted names (`rb`, `export-rebuild-cache`, `wsl-username`, `home-manager`, `.zst`).

## Phase 5 — inside the gap (owner actions)

1. Set the CI variables (`BASE_REGISTRY`, `BASE_TAG`, `ARTIFACTORY_URL` + `ARTIFACTORY_GENERIC_REPO` + `ARTIFACTORY_TOKEN`, and/or `GITLAB_TOKEN` + `GITLAB_PROJECT`).
2. Publish the layers (GitLab packages or Artifactory — pick after measuring the instance's `max_package_size`).
3. Run CI assemble.
4. Start a workspace, run `doctor`, paste the output.
5. Test the sshd bridge + Zed SSH remote into a pod.
6. Carry the first `wsl-update.nar` to the laptop and apply it on the existing distro (the base is whatever `readlink /run/current-system` says there — record it as `.gcroots/wsl-system` on the connected machine first, or do one full export).

## Things that are load-bearing, don't "simplify" them

- `libexec/run-opencode` + `agent/plugins/preload.ts` + `agent/restore-preload.sh` — the LD_PRELOAD split is what keeps CUDA working in agent shells while opencode itself runs clean.
- `nix/scripts/fix-phdr-order.py` — required for opencode on Linux ≤ 6.6 (WSL2 kernel and the RHEL 8/9 cluster nodes).
- The `sshd -i` bridge (`libexec/sshd-inetd` + `scripts/ssh-bridge.sh`) — how Zed reaches a pod with no exposed port.
- The `no-new-privileges` sudo question — `doctor` answers it on a real pod; keep the check.
- The bootstrap `HOME=/` re-resolution for arbitrary UIDs — OpenShift sets `HOME=/` when there is no passwd entry; entrypoint and run-opencode both re-resolve.

## Migration notes for the existing laptop

- The current distro was built with the rootless builder and `createHome = false`. Switching it to the new toplevel via `wsl-update.nar` is fine (the builder differences only affect the tarball, not the runtime system).
- Home-manager leaves its symlinks behind when the module is removed. `seed-home` handles the paths it knows about; after the first switch, run `find ~ -xtype l -lname '/nix/store/*'` and delete what's dangling.
- First update on the laptop needs the base path: `readlink /run/current-system` on the WSL side, record it as `.gcroots/wsl-system` on the connected machine before building the delta. If you skip this, the delta export falls back to a full closure (≈1.5 GB, fine once).

## Suggested skills for the next agent

- `implement` — for executing each phase.
- `diagnosing-bugs` — if the headless nvim check or the VS Code-over-nix-ld fallback surprises you.
- `ponytail` — stays on; keep the diff small.
- `writing-for-agents` — when you touch AGENTS.md.
