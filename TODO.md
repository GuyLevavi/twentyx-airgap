# TODO — from the 2026-09 opencode refactor to the first real transfer

Everything below is ordered. Steps marked **[root]** need sudo on this
machine; steps marked **[gap]** can only happen inside the airgapped
environment. Nothing here is optional hand-waving — each item is the exact
command or decision.

## State (2026-09-28 — round in the working tree, after `0125acf`)

- Round 2026-09-28 (uncommitted working tree): the first-remote-test fixes.
  opencode gets the kernel<=6.6 program-header repair (`opencodeFixed`), the
  Zed settings are composed so the LSP pins cannot be shadowed by the tracked
  personal file, tmux spawns fish directly, and VS Code returns to the WSL
  side pinned end to end (client installer ↔ server commit ↔ extension
  engines ↔ a code-server lockstep `throw`). The transfer is re-shaped: flat
  `dist/`, transport twins for the big artifacts (.zst; 7z for the WSL
  image -- the filter drops big gzip and rejected its zstd twin),
  `MANIFEST.txt` + `SHA256SUMS`, drvPath
  staleness stamps, always-regenerated delta, `SETUP.ps1`. Container test:
  21 checks (2 new — PT_LOAD order, the Zed pins). Mechanisms: NOTES.md §12;
  user-facing index: `wsl/dist-readme.md` -> `dist/README.md`.

### Previous state (2026-09-27, after `791a598` — the debloat merge)

- The debloat branch is merged (rebased, fast-forward): closures trimmed
  (nvim ruby/python/wayland off, fish python off, idle tools out), fixes in
  (injection-export dedup, the transfer-bundle SIGPIPE probe, CI `mkdir`),
  docs lean. Layers re-measured: plain ~840 MiB, `-nvim` ~857 MiB.
- Sync round (2026-09-27): the WSL side and the pod now mirror the connected
  machine — workmux (pinned flake input) with its tmux integration and
  opencode status plugin on BOTH targets (herdr removed), the full tmux config
  on a static Tokyo Night theme (extended-keys included, so Ctrl-hjkl survives
  the kit's WezTerm), vendored opencode skills (matt-skills, same pinned
  revision as /etc/nixos), yazi/lazydocker/podman-compose/gcc/nodejs/bubblewrap
  in both closures, and `rb` for the WSL one-command offline rebuild (wheel
  sudo now needs no password — the account's password is locked anyway).
  Windows kit ships `zed-client-settings.personal-example.json` next to the
  neutral file. Re-measured: WSL tarball ~1.3 GB, cache ~107 MB, kit ~433 MiB;
  layers grew to ~1070/~1087 MiB — parity moved gcc (370 MB unpacked),
  nodejs (254), yazi (523) and podman-compose (211) into the pod closure.
- WSL first boot is proven on the real machine; the distro lives at
  `C:\WSL\nixos\ext4.vhdx`. `C:\twentyx` was re-seeded from `dist/` and holds
  every artifact plus the two one-shot scripts (`UNPACK.ps1` on Windows,
  `setup-wsl.sh` as root inside the distro). `docs/` ships user-facing files
  only — NOTES.md/TODO.md no longer cross the gap.
- Container test: 19/19, including the two new bootstrap assertions (the fish
  drop-in parses; podman `storage.conf` exists) — see NOTES.md §11.
- Open: the opencode slowness diagnosis (NOTES.md §11) — the WSL VHDX cannot
  be read from Linux, so it waits on a diag dump from inside the distro.
- Zed client: installed (kit 1.17.2), auto-update off, live settings merged
  (all LSPs pinned, prettier off, Terminal Threads → opencode). The remaining
  Zed item is a real-pod connect (below).

## 0. This machine, before anything builds again

- [x] **[root] Repair the local Nix store** — done 2026-09, both layer flavors
      build on the default store. The damage was three classes (missing
      files+rows, stale rows, dead relics) and `/nix/store` was never
      read-only — the diagnosis, remedies and the `nix copy` skip-on-row
      gotcha are recorded in NOTES.md §9.

- [ ] **[gpubox, OPTIONAL] GPU test rig** — not a gate for the first
      transfer: the in-pod `doctor` two-sided torch check answers
      CUDA where it matters (see the transfer checklist). Build this local
      rig only if a pod ever misbehaves and a local repro is wanted
      (tests/test-gpu-cuda.sh header has the exact setup; gpubox is the
      only machine it applies to — the work WSL PC is CPU-only, and on
      RunAI the cluster itself injects the GPUs):

      ```bash
      TEST_TORCH_IMAGE=pytorch/pytorch:latest ./tests/test-gpu-cuda.sh
      ```

## 1. Cluster facts — set in the airgap, not here

By decision (2026-09-27): every cluster fact is a CI variable set on the
airgap's GitLab (project/group variables beat `.gitlab-ci.yml`). The file
only carries readable defaults, and the versioned paths derive from `VERSION`
— they can no longer skew from the publisher. Since 2026-09-28 the primary
in-gap layer transport is GitLab generic packages
(`push-gitlab-packages.sh`); Artifactory stays as the fallback.

- [ ] **[gap]** Set the real values in the airgap GitLab: `BASE_REGISTRY`,
      `BASE_TAG` (pin per transfer — digest or date-stamped tag; `latest`
      can silently drift), `ARTIFACTORY_URL`, `ARTIFACTORY_GENERIC_REPO`,
      `ARTIFACTORY_TOKEN`.
- [ ] **[gap]** Pin the CI lint image (`koalaman/shellcheck-alpine:stable`
      → digest) when it goes through the internal mirror.
- [ ] **[gap]** Before the first generic-package push, check the GitLab
      instance's max package size (Admin > Settings > Preferences,
      `max_package_size`) — it may cap below the multi-GB layer size. The
      header of `scripts/push-gitlab-packages.sh` has the details; if a layer
      does not fit, keep `push-artifactory.sh` as the publisher (the CI
      fallback path is already wired).

## 2. First transfer (NOTES.md §5 — deliberately small)

- [ ] **Outside**, assemble everything in one shot (both tracks — layers, WSL
      tarball, git bundle, kit, docs, scripts), then carry the dist files:

      ```bash
      ./scripts/transfer-bundle.sh       # -> dist/ (flat; big artifacts get .zst twins)
      ```

      Layers only — the script always builds both flavors; for the first
      transfer publish only the plain one — `assemble.sh` copes without
      `nix-layer-nvim.tar.gz`:

      ```bash
      ./scripts/build-layers.sh          # -> dist/nix-layer.tar.gz + -nvim + repo-layer.tar
      ```

      No signing key, by decision (2026-09): integrity is the content-addressed
      store hash, and `nix/hosts/wsl.nix` sets `require-sigs = false` to match.

- [ ] Carry the dist files as-is: `*.tar.gz.zst` (layers, kit) and
      `nixos-wsl.tar.gz.7z` stand in for their plain `.tar.gz` twins (the
      filter drops big gzip).
- [ ] **[gap]** Publish the transfer artifacts — GitLab generic packages is
      the primary path now, Artifactory the fallback. Run it after this
      round is reviewed/committed, so the published layers match the repo:

      ```bash
      export GITLAB_TOKEN=... GITLAB_PROJECT=<id|group/project>   # or the CI env
      ./scripts/push-gitlab-packages.sh dist
      ```

      then delete stale `twentyx-airgap` package versions in GitLab — the
      registry accumulates, and CI fetches exactly `<VERSION>`. Artifactory
      stays available:

      ```bash
      export ARTIFACTORY_URL=https://artifactory.internal/artifactory   # real URL
      ./scripts/push-artifactory.sh dist/nix-layer.tar.gz
      ```

- [ ] **[gap]** Run CI (GitLab, branch `main`): lint → assemble. The assemble
      stage fetches the nix layer, builds `repo-layer.tar` with
      `docker/mklayer.sh` (libexec/, agent/, VERSION — not the whole
      checkout), and crane-appends onto every configured base variant.

## 3. First pod — the questions only a real pod answers

Start a workspace, then:

- [ ] `doctor` — paste the full output somewhere. Specifically:
  - [ ] **sudo line**: `ok "sudo: passwordless for gid 0"` ⇒ RunAI does NOT
        set `no-new-privileges`; `bad` ⇒ setuid sudo is dead and podman needs
        a rethink (privileged pod or a rootless plan) — NOTES.md §8.
  - [ ] env injection shows the ConfigMap (mount `/opt/airgap-env` with
        `pip.conf` + `ca-bundle.crt` via pod-template customization first).
- [ ] `run-opencode --version` runs, and an agent bash command sees
      `torch.cuda.is_available() == True` while the pod is GPU-fractioned.
- [ ] **nginx**: find out what RunAI's port-exposure expects from the
      workspace (a running nginx? a specific site config?). Config belongs in
      the env-injection mount, not the closure — NOTES.md §11.
- [ ] **sshd -i bridge** (NOTES.md §11): put your pubkey in the pod's
      `$HOME/.ssh/authorized_keys`, then on WSL:

      ```bash
      ./scripts/ssh-bridge.sh <runai-workload>          # default port 2222
      ssh -p 2222 jensen@127.0.0.1                      # from Windows: localhost
      ```

      Verify the privsep-user / passwd self-registration held. Then point
      Zed at `ssh://<that host>` if you want Zed-remote.

## 4. Zed remote — matched by construction, verify once

The remote server ships in the closure (`zed-editor.remote_server`); the
lookup is exact-match on the client's full version string (build metadata
included), so `nix/zed-client-version.nix` records the kit installer's exact
client version and the shim is generated from it — install the shipped
installer and the match is by construction.

State 2026-09-27: the Windows client is installed (kit 1.17.2), auto-update
is off, and the live settings carry the merged kit template (LSPs pinned,
prettier off, Terminal Threads → opencode). The remaining verification is the
first connect to a real pod.

- [ ] On Windows, install the kit's `Zed-x86_64-*-setup.exe` and turn
      auto-update OFF in Zed settings.
- [ ] On first connect, if the client still uploads its own server, the log
      line `uploading remote server to WSL "..."` names the exact string to
      re-pin in `nix/zed-client-version.nix`; the shim then matches.
- [ ] When nixpkgs bumps zed-editor: re-pin the installer
      (`nix/packages/windows-kit.nix` — URL + `nix store prefetch-file`
      hash) AND `nix/zed-client-version.nix` in the same commit; rebuild.

## 5. WSL (independent track, wsl/README.md)

- [x] First artifact built and imported on the real machine (2026-09-26):
      `C:\WSL\nixos\ext4.vhdx`, first boot fixed (NOTES.md §11). Everything
      needed for a fresh machine ships in `C:\twentyx`.
- [ ] Fresh import on a new machine (skip if keeping the current distro).
      Extract the outer tar on Windows, then from an elevated PowerShell:

      ```powershell
      powershell -ExecutionPolicy Bypass -File .\SETUP.ps1
      ```

      SETUP.ps1 is the whole chain now: `wsl --import` (skipped when the
      distro exists), UNPACK.ps1 (kit: Zed + VS Code + themes + templates),
      then `setup-wsl.sh` as root inside the distro (clone the bundle, import
      the delta, rebuild as the user via sudo). It takes `-Base <dir>`, so it
      no longer assumes `C:\twentyx`. Put `ca-bundle.crt` and `wsl-username`
      in the transfer first — both are gitignored; `setup-wsl.sh` copies and
      `git add -f`s them so the flake source tree sees them.

- [ ] Rolling update on the existing distro (the cheap path, never tested
      end to end yet): carry `twentyx-airgap.bundle` + the ALWAYS-regenerated
      `wsl-rebuild.tar.gz`, re-run `setup-wsl.sh`, and rebuild with the
      network down. The manual equivalent, if you want to see each step:

      ```bash
      ./scripts/export-rebuild-cache.sh    # outside -> dist/wsl-rebuild.tar.gz
      # carry it to C:\twentyx, then inside the distro (as root):
      #   tar -xzf /mnt/c/twentyx/wsl-rebuild.tar.gz -C /var/cache/nix-transfer --strip-components=1
      #   nix copy --from file:///var/cache/nix-transfer --all
      #   nixos-rebuild switch --flake /home/jensen/twentyx-airgap#wsl   # network down
      ```

      A missing store path names the next delta root — add it to
      `wslDeltaRoots` in `flake.nix` (or the list in
      `scripts/export-rebuild-cache.sh`) and re-export.

- [ ] First boot after the import: confirm `nixos-vscode-server`'s node patch
      actually ran before the first Remote-WSL connect (`linger = true` +
      service ordering). If the client uploads its own server or node cannot
      exec, the user service's journal names the step; the auto-fix is what
      keeps the pre-seeded server usable on NixOS.

- [ ] Copy the kit's Zed themes/settings **and** the VS Code installer +
      settings into place (SETUP.ps1 / UNPACK.ps1 do all of it; a real
      settings file wins and gets a `.example` beside it). Keep Zed and VS
      Code auto-update off: the closure's Zed server and the pre-seeded VS
      Code server move only when the kit + pins move together.
- [ ] Install the runai CLI for the bridge client side: `uv tool install
      runai` (resolves internal Artifactory), or drop the Linux executable
      the RunAI UI offers into `~/.local/bin`.

## 6. After the first transfer

- [ ] Move to `-nvim` flavor and all four base variants if needed.
- [ ] On the next nixpkgs bump: the lockstep `throw` in
      `nix/vscode-version.nix` forces the VS Code re-pin (version + commit +
      both hashes). While re-pinning, re-check every `engines.vscode` range
      and the extension list in `nix/vscode-extensions.nix` against the new
      release — the file records the ranges verified 2026-09.
- [ ] `/tmp/airgap-test-store` served as the donor and fallback during the
      store repair (NOTES.md §9). Keep it as the throwaway build store —
      do not retire it while it is the only place that can rebuild if the
      main store ever loses paths again.
