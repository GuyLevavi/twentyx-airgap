# Open items -- fill in from work

Blockers are marked. Everything else has a working default.

## 1. RunAI preload antidote  [RESOLVED -- implemented]

The interceptors:

    /runai/shared/pid/preloader.so
    /runai/shared/memory/loader.so

The working antidote does **not** unset `LD_PRELOAD`; it *replaces* it with libc:

    LD_PRELOAD="${LIBC:-/lib/x86_64-linux-gnu/libc.so.6}"   # LIBC via ldd + awk

That is better than unsetting, and `libexec/airgap-opencode` now matches it exactly -- with one
refinement the pi-era version got wrong: **the libc must come from the same glibc as the binary
being preloaded**. opencode is Nix-built (glibc 2.4x); preloading the base image's *system* libc
into it is a `GLIBC_PRIVATE` symbol-lookup error, not a no-op. The launcher resolves the libc with
`ldd $(command -v opencode)`, which is correct for both Nix-built and system-built targets.

Implemented and tested across four cases:

| `LD_PRELOAD` in | result |
|---|---|
| both RunAI `.so`s | replaced with libc |
| RunAI + a legitimate `.so` | replaced with libc (original stashed, restored for children) |
| unrelated `.so` only | **untouched** |
| unset | no-op |

**Bug found while testing:** `ldconfig -p \| awk '...exit'` returns 141 (SIGPIPE) under
`set -o pipefail`, because awk's early `exit` closes the pipe. With `set -e` that silently kills
the launcher and pi never starts. Fixed with `|| true`. **Check the original antidote script for
the same latent bug** -- it only shows up when the shell has `pipefail` set.

Still worth confirming in-pod: nothing beyond the TUI is affected once the split is in place --
the TUI gets the matching-libc no-op preload, and every bash child gets the original back via
`agent/plugins/airgap-preload.ts` (opencode `shell.env` hook) plus `agent/restore-preload.sh`
(`BASH_ENV`). Set `AIRGAP_PRELOAD_RESTORE=0` to disable the restore half.

## 2. Identity on the shared PVC  [RESOLVED -- implemented]

Probe output confirmed: every runtime user is `jensen`, uid 10001, gid 0, and the hostname is
`<workspace-name>-<n>-<n>` where workspace names follow a `<username>-<whatever>` convention.
The OS knows nothing about who you are; the hostname is the only platform-provided signal, and it
is not stable across sessions.

Resolution chain in `airgap_user()`, first hit wins:

1. `$AIRGAP_USER` (explicit override)
2. local part of `git config user.email` -- set declaratively via `airgap.git.userEmail`
3. hostname, stripped of the `-<n>-<n>` suffix, leading component
4. `$USERNAME` / `$USER`

Rule 3 is **wrong for any username containing a dash**. That is exactly why it sits below the git
identity rather than above it, and why `airgap doctor` prints which rule fired -- a surprising
answer should be visible, not silently misfile a session's history in a new directory.

It picks `/data/<user>` (falling back to `/code/<user>`) as the relocated `$HOME`. A wrong guess
is cosmetic, never destructive.

## 3. Artifactory + transfer flow  [SETTLED -- reshaped by Nix]

Fully airgapped. Build-time network reaches **internal Artifactory only**; pip resolves there.

Two independent flows, which used to be one:

    WSL      outside -> nix-export.sh -> signed binary cache, sharded
                     -> physical transfer
                     -> nix-import.sh -> /var/cache/nix-transfer -> nixos-rebuild

    IMAGES   outside -> build-layers.sh -> nix-layer{,-nvim}.tar.gz
                     -> physical transfer
                     -> push-artifactory.sh -> generic-local/airgap/<ver>/
                     -> CI fetches, tars repo-layer, crane appends

- Git holds **text only** -- now literally true. There is no `vendor/` and no blob list: the
  closure is computed, so the only binary artifacts are Nix build outputs.
- generic-local: the layer tarballs. There is no node layer and no npm anywhere in the pipeline:
  opencode is built from source by nixpkgs and rides in the closure.

**What replaced the two-checksum scheme.** `manifest.toml` hashed upstream archives (*did I
download what upstream published?*) and `CHECKSUMS.sha256` hashed extracted files (*did the
transfer corrupt anything?*). Nix covers both, better: the flake lock pins inputs by hash, and the
binary cache is verified per **store path** rather than per tarball -- so a damaged chunk fails on
the path it damaged, not on "the transfer". Signing (item: `cache-pubkey`) makes it tamper-evident
as well as corruption-evident. The layer tarballs keep a plain `.sha256` sidecar, because CI
fetches them over HTTP and has no Nix to ask.

## 4. Base images  [editor resolved; names for you to fill in]

Internal flavors: `base-slim`, `base-pytorch`, `vscode-slim`, `vscode-pytorch`. Preconfigured
with registries and CA certs, so Stage 1 builds on an internal slim base, not a public image.

Editor is **code-server** (Coder). Consequences, already implemented:

The old Stage 1 / node-layer build pod is gone entirely -- there is no container
build left, only `tar` + `crane`. CI's assemble stage still runs on `base-slim`.

Fill in yourself: registry hostname, repo paths, tag convention
(`AIRGAP_BASE_REGISTRY` / `AIRGAP_BASE_TAG` in `.gitlab-ci.yml`).

## 6. Arbitrary UID: ask the base-image owners for one line  [cosmetic today]

Probe findings: `uid=10001 gid=0(root) groups=0(root),1001650000`, and every shell start prints
`groups: cannot find name for group id 1001650000`.

Standard OpenShift arbitrary-UID behaviour: the pod gets a UID and a supplementary GID that
exist in no `/etc/passwd` or `/etc/group`.

**We cannot fix this from our layer.** Stage 1 exports only `/out`, so a `chmod` on `/etc` is
discarded, and shipping our own `/etc/passwd` would clobber whatever the pytorch base defines.

Mitigated instead:

- `airgap-bootstrap` sets `USER`, `LOGNAME` and `HOME` in the generated fish and bash drop-ins,
  which most tools consult before attempting a passwd lookup.
- `airgap-entrypoint` registers the UID and names the groups **if** `/etc/passwd` and
  `/etc/group` happen to be writable, and stays quiet if not.
- `airgap doctor` reports whether self-registration is possible and which groups are unnamed.

The real fix is one line in the base image, worth requesting from its owners:

```dockerfile
RUN chgrp 0 /etc/passwd /etc/group && chmod g+w /etc/passwd /etc/group
```

This is the documented OpenShift pattern for images that must run as an arbitrary UID. Until
then the warning is noise, not breakage.

## 7. code-server  [DEFERRED -- base image's is good enough for now]

The base `vscode-*` images ship code-server, and shadowing it was dropped: it was a tier-3 blob,
a bundled-Node microarchitecture risk, and a vsix install step, all to fix a version skew nobody
has hit yet.

What was kept from that work, because it costs nothing:

- `assemble.sh` records the base's ENTRYPOINT in `AIRGAP_BASE_ENTRYPOINT` and `airgap-entrypoint`
  hands over to it. Without that, replacing ENTRYPOINT to run bootstrap would give you a
  `vscode-*` workspace whose IDE never starts.
- Session variables are image ENV, so code-server's task runner -- not a login shell -- still gets
  `TERMINFO_DIRS` and `LOCALE_ARCHIVE`.

If it comes back, the interesting part is smarter vsix management, not the binary. The bundled
Node check is worth keeping in whatever does: it is the same failure that segfaulted OpenCode.

## 5. First transfer should be deliberately small

Still true, and Nix makes it easy to honour: build `.#runai-layer` (the plain flavor, 414 MB) and
skip `-nvim` (634 MB). `assemble.sh` detects the missing nvim tarball and builds one flavor.

That proves transfer -> Artifactory -> `crane append` -> pod end to end, including the two things
that can only fail against real internal bases: `PATH` prepending on a pytorch base and
ENTRYPOINT hand-over on a `vscode-*` one.

The WSL side has its own chicken-and-egg, which is `nix build .#wsl-tarball` -- see `wsl/README.md`.

## 8. How this is tested without the gap  [test suite: tests/]

The whole image path is exercised by `tests/test-container.sh` -- assemble
against a mock base (ubuntu:24.04 in a local registry), then run the image
under the problematic pod shape and assert the behaviors that each broke once:

- **The pod UID is emulated for real**: `podman run --user 10001:0` -- an
  arbitrary UID with no passwd entry, gid 0. This is what caught the runtime
  setting `HOME=/` (no passwd entry -> the runtime guesses), which is why the
  entrypoint and launcher re-resolve via `airgap_home()`.
- **The preloader crash is reproduced** with `tests/hostile-preloader.c`, a
  synthetic .so that aborts only the agent binary -- the same shape as the
  real fractioning libs (opencode dies, system binaries are fine). Asserted:
  bare opencode dies, `airgap-opencode` survives, children get the original
  preload back via `BASH_ENV`.
- Also asserted: closure integrity after `crane append`, defaults seeding
  (opencode plugin, Zed settings), the env-injection contract, sudoers +
  setuid sudo, nginx presence, repo-layer determinism.

Two artifacts of the harness, not the image: the sudo PAM error under rootless
podman is a userns artifact (setuid-root maps to the host user, which cannot
read /etc/shadow; in a real pod setuid-root is real root), and the repro exits
139 or 134 depending on the agent binary's own signal handlers. **Unverified
in the gap: whether RunAI sets `no-new-privileges`**, which would block the
setuid bit entirely -- `airgap-doctor`'s sudo line answers it on a real pod.

GPU: `tests/test-gpu-cuda.sh` verifies passthrough + `torch.cuda` on a host
with the nvidia CDI setup (one-time, root). What no local test can claim:
CUDA under the REAL fractioning preloaders (they are proprietary) -- only a
fractioned pod answers that. The preload split itself is fully covered.

Rootful `sudo podman` in a pod may still lack `CAP_SYS_ADMIN` for overlay
mounts; the prewritten `storage.conf` defaults to `vfs`, which needs no
mounts. Rootless podman (no sudo) needs unprivileged userns + subuids, which
OpenShift usually denies -- hence the sudo path.

Also in the closure: `herdr` 0.9.0, `zed-editor`, `openssh`, `nginx`, and
`sst-dev.opencode` 0.0.13 (the official VS Code extension, seeded for
code-server and shipped as a raw `.vsix` for the Windows side, which has no
marketplace in the gap).

## 9. Local store repair on the connected machine  [one-time, needs sudo]

`nix build .#runai-layer` on the connected NixOS machine fails with
`store path '/nix/store/sbl1wlvqkr05i4jysvygdpsq7rshznwd-source.drv' does not
exist` (input of `yodl-4.05.00.drv`, via zsh <- direnv). The DB row exists but
the file was lost. A throwaway chroot store builds the same eval fine, so the
pinned snapshot is healthy -- this is purely local damage. Fix:

    sudo cp /tmp/store/nix/store/sbl1wlvqkr05i4jysvygdpsq7rshznwd-source.drv /nix/store/

(exact bytes re-materialized during the verification run; any chroot-store copy
of the same drv works), or `sudo nix-store --verify --check-contents --repair`
for the blunt instrument.

## 10. The role of Nix: where configs belong  [design note, 2026-09 refactor]

Premise: configs change often and must push cheap; the toolchain closure
changes rarely and is expensive to transfer. The consequence, spelled out so
it is not relitigated:

- **Nix owns binaries and the packaged defaults, not live config.** The
  frequent config edits happen on the durable PVC (`$HOME`), where a real file
  shadows the packaged symlink. A config tweak inside the pod has never
  required a rebuild -- that is the `$HOME` layering rule.
- **The closure-vs-text split already is the config-layer split.** The repo
  layer (80KB of git text, re-tarred by CI per commit) is the "frequent, thin
  layer"; the Nix layer is the rare, fat one. `crane append` + overlayfs
  semantics do the rest. There is nothing to diff: the layer a change belongs
  to is visible from the directory it touched.
- **Fleet-wide default changes no longer need a transfer either.** As of the
  2026-09 refactor, `home-defaults` is a real directory of per-file symlinks,
  and overlayfs merges directories across layers -- so the repo layer can
  override individual defaults per commit. This is the "Nix owns a preset
  which gets overlaid" shape, with the overlay being ordinary git text.
- Where the "regctl / nix2container / skopeo mirror" framing misses the mark:
  we never need to DELETE base files (no whiteouts needed, `crane append`
  suffices); we do not build images with Nix (append-only against unpulled
  bases is the whole point); and the closure does not transfer as an OCI
  bundle at all -- the nix binary cache is content-addressed, order-
  independent and signature-verified per store path, which an OCI tarball is
  not.
- The one real tradeoff left: a NEW packaged default chosen inside the pod
  must be committed to git to reach other users of the image. That is a
  feature (defaults are reviewed), not a rebuild.

## 11. Open items from the 2026-09 refactor

- **nginx**: added to the closure so port-exposure does not depend on the
  base. The exact site config RunAI expects (and whether it wants one at all)
  is unpinned -- when known, it belongs in the env-injection mount, not in
  the closure.
- **Zed remote development**: the client downloads a version-matched
  `zed-remote-server` into `~/.local/share/zed/remote_server/` on first
  connect -- an airgap hang. nixpkgs' `zed-editor` does not package the
  remote-server binary separately, so pre-seeding means copying the matching
  client version's binary there (same shape as the vscode-server dance). The
  `opencode acp` integration needs none of this: it runs locally. The
  `sshd -i` bridge (`libexec/airgap-sshd-inetd` + `scripts/ssh-bridge.sh`)
  is implemented but only exercised against a real `runai exec` -- the
  privsep-user and passwd self-registration inside the pod are best-effort
  until then.
- **runai CLI on WSL**: the bridge needs it (`uv tool install runai` inside
  the gap); it is not in the closure because it is a client, not a pod tool.
- **shell.env hook**: verified against the shipped opencode version's
  documented behavior; upstream has a TODO about honoring `shell.env` in the
  v2 bash tool -- the `BASH_ENV` path is the belt to that suspenders.
