# Open items -- fill in from work

Blockers are marked. Everything else has a working default.

## 1. RunAI preload antidote  [RESOLVED -- implemented]

The interceptors:

    /runai/shared/pid/preloader.so
    /runai/shared/memory/loader.so

The working antidote does **not** unset `LD_PRELOAD`; it *replaces* it with libc:

    LD_PRELOAD="${LIBC:-/lib/x86_64-linux-gnu/libc.so.6}"   # LIBC via ldconfig + awk

That is better than unsetting, and `libexec/airgap-pi` now matches it exactly: libc is already
loaded in every process, so preloading it is a no-op, while `LD_PRELOAD` stays populated for
anything that branches on whether it is set.

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

Still worth confirming in-pod: whether pi/node is affected by the preloaders at all. If not, set
`AIRGAP_PRELOAD_STRIP=0` and nothing else changes.

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
                     -> CI fetches, builds node-layer, crane appends

- Git holds **text only** -- now literally true. There is no `vendor/` and no blob list: the
  closure is computed, so the only binary artifacts are Nix build outputs.
- `push-artifactory.sh` uses the `jf` CLI with a `curl` fallback, for the chicken-and-egg where
  `jf` itself is not yet on the box.
- npm-local: pi, so `pi install npm:@corp/airgap-pi` works in-cluster.
- generic-local: the layer tarballs.

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

With code-server deferred (item 7), the build stage no longer needs `vscode-slim` -- it only runs
`npm install`, so `base-slim` is the cheaper `BASE_IMAGE` in `.gitlab-ci.yml`.

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

That proves transfer -> Artifactory -> node layer -> `crane append` -> pod end to end, including
the two things that can only fail against real internal bases: `PATH` prepending on a pytorch base
and ENTRYPOINT hand-over on a `vscode-*` one.

The WSL side has its own chicken-and-egg, which is `nix build .#wsl-tarball` -- see `wsl/README.md`.
