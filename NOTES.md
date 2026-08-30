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

## 2. Identity on the shared /code PVC  [awaiting probe output]

All runtime users are `jensen`; each works in a subdirectory of `/code`. Workspace name is not
stable. Run this in a pod and paste back `/tmp/airgap-probe.txt`:

```bash
{ env|grep -iE 'runai|workload|job|project|user|owner|namespace|pod|team'|sort; echo "--hostname"; hostname; id; echo "--ns"; cat /var/run/secrets/kubernetes.io/serviceaccount/namespace 2>/dev/null; echo "--podinfo"; cat /etc/podinfo/* 2>/dev/null; echo "--preload"; echo "[$LD_PRELOAD]"; ls -l /runai/shared/*/*.so 2>/dev/null; echo "--code"; ls -ld /code/*/ 2>/dev/null|head; } 2>&1 | tee /tmp/airgap-probe.txt
```

Resolution chain (first hit wins), pending that output:

1. `$AIRGAP_USER` (explicit override)
2. a stable RunAI env var, if one exists
3. local part of `git config user.email`
4. `$USERNAME`
5. first path component under `/code` owned by the caller

Used only to pick `/code/<user>/.airgap` for persistent state. A wrong guess is cosmetic, not
destructive.

## 3. Artifactory + transfer flow  [SETTLED]

Fully airgapped. Build-time network reaches **internal Artifactory only**; pip resolves there,
vsix come from files or the internal shop.

    outside -> fetch-vendor.sh -> vendor tarball -> physical transfer
            -> push-artifactory.sh (jf rt upload) -> generic-local/airgap/<ver>/
            -> CI fetches from Artifactory (never from git)

- Git repo holds **text only**: dispatcher, configs, pi package, manifests, CI. `vendor/` is
  gitignored.
- `scripts/push-artifactory.sh` uses the `jf` CLI, with a `curl` fallback for when `jf` is not
  yet on the box (chicken-and-egg on first transfer).
- npm-local: pi + our pi package, so `pi install npm:@corp/airgap-pi` works in-cluster.
- generic-local: static binaries, node tarball, nvim pack, crane.

## 4. Base images  [editor resolved; names for you to fill in]

Internal flavors: `base-slim`, `base-pytorch`, `vscode-slim`, `vscode-pytorch`. Preconfigured
with registries and CA certs, so Stage 1 builds on an internal slim base, not a public image.

Editor is **code-server** (Coder). Consequences, already implemented:

- vsix are installed with `code-server --install-extension --extensions-dir`, not unzipped by
  hand, so the layout and metadata are what code-server expects.
- Stage 1 should therefore build on **`vscode-slim`** (it has the code-server binary) rather than
  `base-slim`. Set `BASE_IMAGE` accordingly in `.gitlab-ci.yml`.
- `airgap-bootstrap` seeds the baked extensions to `$AIRGAP_STATE/share/code-server/extensions`
  once, then leaves them alone -- code-server needs that dir writable, and this way extensions
  you install by hand survive restarts.

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

- `config/bashrc.d/10-path.sh` sets `USER`, `LOGNAME`, `HOME`, which most tools consult before
  attempting a passwd lookup.
- `airgap-entrypoint` registers the UID and names the groups **if** `/etc/passwd` and
  `/etc/group` happen to be writable, and stays quiet if not.
- `airgap doctor` reports whether self-registration is possible and which groups are unnamed.

The real fix is one line in the base image, worth requesting from its owners:

```dockerfile
RUN chgrp 0 /etc/passwd /etc/group && chmod g+w /etc/passwd /etc/group
```

This is the documented OpenShift pattern for images that must run as an arbitrary UID. Until
then the warning is noise, not breakage.

## 7. code-server  [implemented]

The base image's code-server is slightly old, so a newer one is vendored to
`/opt/airgap/code-server` and put ahead of `/usr/bin` on `PATH`. The base image is never
modified; reverting is removing a `PATH` entry.

vsix are installed with the **new** binary at build time, so extensions resolve against the
version that will actually run them.

One risk, checked at build time and by `airgap doctor`: the standalone tarball bundles its own
Node at `lib/node`, which may target a newer x86-64 microarchitecture than some cluster CPUs --
exactly what segfaulted OpenCode. If it will not run, the build swaps in our vendored
baseline-safe Node automatically.

Bump the version in `vendor/manifest.toml` to update; it is a tier-3 blob, so it needs a
transfer, not just an `airgap update`.

## 5. First transfer should be deliberately small

Dispatcher + configs + pi + `crane` + ~6 static binaries. No nvim pack, no vsix. A few hundred
MB, proving manifest/verify/entrypoint/append end-to-end. Find checksum and wrapper bugs on a
cheap round-trip, not a 2GB one.
