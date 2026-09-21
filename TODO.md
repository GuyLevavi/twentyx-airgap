# TODO — from the 2026-09 opencode refactor to the first real transfer

Everything below is ordered. Steps marked **[root]** need sudo on this
machine; steps marked **[gap]** can only happen inside the airgapped
environment. Nothing here is optional hand-waving — each item is the exact
command or decision.

## 0. This machine, before anything builds again

- [ ] **[root] Repair the local Nix store** (NOTES.md §9). Until this lands,
      `nix build .#runai-layer` and `nix flake check` fail on this host (the
      chroot store under `/tmp/airgap-test-store` works — it is disposable):

      ```bash
      sudo cp /tmp/airgap-test-store/nix/store/sbl1wlvqkr05i4jysvygdpsq7rshznwd-source.drv /nix/store/
      nix build .#runai-layer --no-link   # must now succeed
      ```

      If `/tmp/airgap-test-store` was wiped, rebuild it first:
      `nix build --store /tmp/airgap-test-store .#runai-layer --no-link`
      and copy the drv from there.

- [ ] **[root] One-time CDI setup for GPU tests** (tests/test-gpu-cuda.sh header):

      ```bash
      # NixOS: add  hardware.nvidia-container-toolkit.enable = true;  and rebuild, then
      sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
      ```

- [ ] **Run the GPU test** (closes the only CUDA claim the suite cannot make):

      ```bash
      AIRGAP_TEST_TORCH_IMAGE=pytorch/pytorch:latest ./tests/test-gpu-cuda.sh
      ```

## 1. Fill in the cluster facts only you know (NOTES.md §4)

- [ ] `.gitlab-ci.yml`: replace `AIRGAP_BASE_REGISTRY = "quay.internal/ai"`
      with the real base registry/repo path, and set the base tag convention.
- [ ] Decide the Artifactory version path: `LAYER_BASE_URL` pins
      `.../airgap/0.1.0` — keep `VERSION` at 0.1.0 or move both together.

## 2. First transfer (NOTES.md §5 — deliberately small)

- [ ] **Outside**, build the layers (plain flavor only is fine for the first
      run; skip `-nvim` if transfer size matters — `assemble.sh` copes):

      ```bash
      ./scripts/build-layers.sh          # -> dist/nix-layer.tar.gz (+ .sha256)
      ```

- [ ] **Outside**, optionally generate the signing key once (NOTES.md, README
      "Before the first transfer"):

      ```bash
      nix key generate-secret --key-name airgap-transfer > ~/.config/airgap/cache-priv.key
      ```

      (This keys `nix/hosts/wsl.nix` off `cache-pubkey` for the WSL flow; the
      image layers always verify via `.sha256` sidecars.)

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

## 4. Zed decision

- [ ] `opencode acp` integration needs nothing extra — it is the packaged
      default and runs locally. Only if you want **Zed remote development**
      into the pod: pre-seed the client-version-matched `zed-remote-server`
      into `~/.local/share/zed/remote_server/` on the pod side (nixpkgs does
      not package it; same dance as vscode-server). Otherwise declare it
      deliberately not-supported and delete this line.

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
- [ ] Install the runai CLI for the bridge client side:
      `uv tool install runai` (resolves internal Artifactory).
- [ ] `code --install-extension` the shipped vsix on Windows:
      `~/.local/share/vsix/sst-dev.opencode-0.0.13.vsix` (copied over).

## 6. After the first transfer

- [ ] Move to `-nvim` flavor and all four base variants if needed.
- [ ] Retire `/tmp/airgap-test-store` if the store repair landed; re-run
      `./tests/test-container.sh` for a fast green baseline before any
      further repo-layer change.
