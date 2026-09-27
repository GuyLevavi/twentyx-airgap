# TODO — from the 2026-09 opencode refactor to the first real transfer

Everything below is ordered. Steps marked **[root]** need sudo on this
machine; steps marked **[gap]** can only happen inside the airgapped
environment. Nothing here is optional hand-waving — each item is the exact
command or decision.

## State (2026-09-27, after `791a598` — the debloat merge)

- The debloat branch is merged (rebased, fast-forward): closures trimmed
  (nvim ruby/python/wayland off, fish python off, idle tools out), fixes in
  (injection-export dedup, the transfer-bundle SIGPIPE probe, CI `mkdir`),
  docs lean. Layers re-measured: plain ~840 MiB, `-nvim` ~857 MiB.
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

## 1. Fill in the cluster facts only you know (NOTES.md §4)

- [ ] `.gitlab-ci.yml`: replace `BASE_REGISTRY = "quay.internal/ai"`
      with the real base registry/repo path, and set the base tag convention.
      Pin `BASE_TAG` to something immutable per transfer (digest or
      date-stamped tag) — `latest` can silently drift between transfers.
- [ ] Decide the Artifactory version path: `LAYER_BASE_URL` pins
      `.../airgap/0.1.0` while `push-artifactory.sh` derives the path from
      `VERSION` — bumping `VERSION` without updating CI fetches stale layers.
      Keep them mirrored or drop the version prefix.
- [ ] Pin the CI lint image (`koalaman/shellcheck-alpine:stable` → digest)
      when it goes through the internal mirror.

## 2. First transfer (NOTES.md §5 — deliberately small)

- [ ] **Outside**, assemble everything in one shot (both tracks — layers, WSL
      tarball, git bundle, kit, docs, scripts):

      ```bash
      ./scripts/transfer-bundle.sh       # -> dist/, then carry dist/ to C:\twentyx
      ```

      Layers only — the script always builds both flavors; for the first
      transfer carry only the plain one — `assemble.sh` copes without
      `nix-layer-nvim.tar.gz`:

      ```bash
      ./scripts/build-layers.sh          # -> dist/nix-layer.tar.gz + -nvim + repo-layer.tar
      ```

      No signing key, by decision (2026-09): integrity is the content-addressed
      store hash; `nix/hosts/wsl.nix` already degrades to `require-sigs = false`
      when `cache-pubkey` is absent.

- [ ] Carry `dist/nix-layer.tar.gz` across physically.
- [ ] **[gap]** Push to Artifactory:

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
- [ ] Fresh import on a new machine (skip if keeping the current distro):

      ```powershell
      powershell -ExecutionPolicy Bypass -File C:\twentyx\UNPACK.ps1   # Windows: kit, themes, templates
      wsl --import twentyx C:\WSL\nixos C:\twentyx\nixos-wsl.tar.gz --version 2
      ```

      then inside, as root:

      ```bash
      wsl -d twentyx -u root -- bash /mnt/c/twentyx/setup-wsl.sh
      ```

- [ ] Prove the offline loop (now scripted; `setup-wsl.sh` runs steps 2–3):

      ```bash
      ./scripts/export-rebuild-cache.sh    # outside -> dist/wsl-rebuild.tar.gz
      # carry it to C:\twentyx, then inside the distro (as root):
      #   tar -xzf /mnt/c/twentyx/wsl-rebuild.tar.gz -C /var/cache/nix-transfer --strip-components=1
      #   nix copy --from file:///var/cache/nix-transfer --all
      #   nixos-rebuild switch --flake /home/jensen/twentyx-airgap#wsl   # network down
      ```

- [ ] Copy the kit's themes into `%APPDATA%\Zed\themes\` and
      zed-client-settings.json into `%APPDATA%\Zed\settings.json` (UNPACK.ps1
      does both; a real settings file wins and gets a `.example` beside it),
      keeping Zed auto-update off (the closure's server moves only when the
      kit installer + nix/zed-client-version.nix move together).
- [ ] Install the runai CLI for the bridge client side. Preferred: the exact
      Linux executable the RunAI UI offers (it matches your cluster's server
      version). Make it a pinned, declared derivation instead of a stray
      binary in `~/.local/bin`:

      ```bash
      nix store prefetch-file --json <url-or-file>          # capture sha256
      ```

      then fill `nix/packages/runai-cli.nix` (version + hash) and add
      `runai-cli` to `environment.systemPackages` in `nix/hosts/wsl.nix`.
      Fallback if the UI offers nothing: `uv tool install runai` (resolves
      internal Artifactory).

## 6. After the first transfer

- [ ] Move to `-nvim` flavor and all four base variants if needed.
- [ ] `/tmp/airgap-test-store` served as the donor and fallback during the
      store repair (NOTES.md §9). Keep it as the throwaway build store —
      do not retire it while it is the only place that can rebuild if the
      main store ever loses paths again.
