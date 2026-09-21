# TODO — from the 2026-09 opencode refactor to the first real transfer

Everything below is ordered. Steps marked **[root]** need sudo on this
machine; steps marked **[gap]** can only happen inside the airgapped
environment. Nothing here is optional hand-waving — each item is the exact
command or decision.

## 0. This machine, before anything builds again

- [x] **[root] Repair the local Nix store** — done 2026-09, both layer flavors
      build on the default store. The damage was three classes (missing
      files+rows, stale rows, dead relics) and `/nix/store` was never
      read-only — the diagnosis, remedies and the `nix copy` skip-on-row
      gotcha are recorded in NOTES.md §9.

- [ ] **[root, gpubox only] One-time CDI setup for GPU tests** (tests/test-gpu-cuda.sh header):

      ```bash
      # NixOS: add  hardware.nvidia-container-toolkit.enable = true;  and rebuild, then
      sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
      ```

- [ ] **[gpubox] Run the GPU test** (closes the only CUDA claim the suite
      cannot make locally). gpubox is the only machine this applies to: the
      work WSL PC is CPU-only (run `test-container.sh` there, nothing GPU
      related), and on RunAI the cluster itself injects the GPUs — the
      in-pod `airgap-doctor` two-sided torch check is what answers CUDA
      there (see the transfer checklist):

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

- [ ] **Outside**, build the layers (plain flavor only is fine for the first
      run; skip `-nvim` if transfer size matters — `assemble.sh` copes):

      ```bash
      ./scripts/build-layers.sh          # -> dist/nix-layer.tar.gz (+ .sha256)
      ```

      No signing key, by decision (2026-09): integrity is the content-addressed
      store hash for the cache and the `.sha256` sidecars for the layer
      tarballs; `nix/hosts/wsl.nix` already degrades to `require-sigs = false`
      when `cache-pubkey` is absent.

- [ ] Carry `dist/nix-layer.tar.gz` (+ `.sha256`) across physically.
- [ ] **[gap]** Push to Artifactory:

      ```bash
      export ARTIFACTORY_URL=https://artifactory.internal/artifactory   # real URL
      ./scripts/push-artifactory.sh dist/nix-layer.tar.gz
      ```

- [ ] **[gap]** Run CI (GitLab, branch `main`): lint → assemble. The assemble
      stage fetches the nix layer, tars this checkout as `repo-layer.tar`,
      and crane-appends onto every configured base variant.

## 3. First pod — the questions only a real pod answers

Start a workspace, then:

- [ ] `airgap-doctor` — paste the full output somewhere. Specifically:
  - [ ] **sudo line**: `ok "sudo: passwordless for gid 0"` ⇒ RunAI does NOT
        set `no-new-privileges`; `bad` ⇒ setuid sudo is dead and podman needs
        a rethink (privileged pod or a rootless plan) — NOTES.md §8.
  - [ ] env injection shows the ConfigMap (mount `/opt/airgap-env` with
        `pip.conf` + `ca-bundle.crt` via pod-template customization first).
- [ ] `airgap-opencode --version` runs, and an agent bash command sees
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

## 4. Zed remote — set the client version, that is all

The remote server ships in the closure (`zed-editor.remote_server`), placed in
`~/.zed_server/` as a packaged default. Zed's client looks for a file named
after its OWN version string, so:

- [ ] On Windows, get the client's exact version string: `zed --version`.
- [ ] Set `airgap.zed.remoteClientVersion` in `nix/modules/home.nix` to that
      string (build metadata included) and rebuild — offline, seconds.
- [ ] Rebuild the layer only when the closure changed (`nix build
      .#runai-layer`); the WSL side just needs `nixos-rebuild switch`.
- [ ] Update the option whenever the Windows Zed is updated (auto-update is
      pinned off anyway, same as vscode-server).

## 5. WSL (independent track, wsl/README.md)

- [ ] **Outside**, build the first artifact:

      ```bash
      nix build .#wsl-tarball
      sudo ./result/bin/nixos-wsl-tarball-builder     # -> nixos.wsl
      ```

- [ ] On Windows: `wsl --import airgap C:\WSL\airgap nixos.wsl --version 2`
- [ ] Inside, prove the offline loop:

      ```bash
      ./scripts/nix-export.sh              # outside
      sudo ./scripts/nix-import.sh /path/to/nix-transfer   # inside
      sudo nixos-rebuild switch --flake /etc/nixos#wsl     # network down
      ```

- [ ] Pre-seed the VS Code server for the exact Windows VS Code commit and
      pin VS Code auto-update off on Windows (wsl/README.md).
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
- [ ] `code --install-extension` the shipped vsix on Windows:
      `~/.local/share/vsix/sst-dev.opencode-0.0.13.vsix` (copied over).

## 6. After the first transfer

- [ ] Move to `-nvim` flavor and all four base variants if needed.
- [ ] `/tmp/airgap-test-store` served as the donor and fallback during the
      store repair (NOTES.md §9). Keep it as the throwaway build store —
      do not retire it while it is the only place that can rebuild if the
      main store ever loses paths again.
