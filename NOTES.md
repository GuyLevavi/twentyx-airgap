# Open items -- fill in from work

Blockers are marked. Everything else has a working default.

## 1. RunAI preload antidote  [RESOLVED -- implemented]

The interceptors:

    /runai/shared/pid/preloader.so
    /runai/shared/memory/loader.so

The working antidote does **not** unset `LD_PRELOAD`; it *replaces* it with libc:

    LD_PRELOAD="${LIBC:-/lib/x86_64-linux-gnu/libc.so.6}"   # LIBC via ldd + awk

That is better than unsetting, and `libexec/run-opencode` now matches it exactly -- with one
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
the launcher and opencode never starts. Fixed with `|| true` -- the same pattern guards every
`ldd`/`ldconfig \| awk ...exit` probe in libexec.

Still worth confirming in-pod: nothing beyond the TUI is affected once the split is in place --
the TUI gets the matching-libc no-op preload, and every bash child gets the original back via
`agent/plugins/preload.ts` (opencode `shell.env` hook) plus `agent/restore-preload.sh`
(`BASH_ENV`). Set `PRELOAD_RESTORE_AGENT_BASH=0` to disable the restore half.

## 2. Identity on the shared PVC  [RESOLVED -- implemented, team-shaped]

Probe output confirmed: every runtime user is `jensen`, uid 10001, gid 0, and the hostname is
`<workspace-name>-<n>-<n>` where workspace names follow a `<username>-<whatever>` convention.
The OS knows nothing about who you are; the workspace name is the per-user signal the platform
gives.

Resolution chain in `session_user()`, first hit wins:

1. `$SESSION_USER` (explicit override -- the dash-in-username escape hatch)
2. hostname, stripped of the `-<n>-<n>` suffix, leading component -- **the
   intended rule**: the platform's own per-user convention, and the reason a
   baked identity is NOT part of the image
3. local part of `git config user.email` -- the USER's own, set once on the
   durable PVC (`git config --global user.email`); it can only ever fire
   when rule 2 produced nothing, so configuring git later can never
   relocate an existing directory
4. `$USERNAME` / `$USER`

This is deliberately **not** what it used to be: a baked `airgap.git.userEmail`
sat at rank 2, which was right for a single owner and wrong for a team -- the
closure is distributed, so a baked email would file every teammate's state
into the owner's PVC directory. Consequently there is also NO packaged
`~/.config/git/config`: it would be a store symlink, and `git config --global`
on the PVC could never write through it (EROFS). The neutral git settings
(defaultBranch, pager/delta) ship as `/etc/gitconfig` from the repo layer
(pod) and `environment.etc` (WSL), and each user owns their identity as a real
file on the durable home. Renaming a workspace changes rule 2's answer -- that
tradeoff is accepted and visible (doctor prints which rule fired); the
override at rank 1 exists for it.

It picks `/data/<user>` (falling back to `/code/<user>`) as the relocated `$HOME`. A wrong guess
is cosmetic, never destructive.

## 3. Artifactory + transfer flow  [SETTLED -- reshaped by Nix]

Fully airgapped. Build-time network reaches **internal Artifactory only**; pip resolves there.

Two independent flows, which used to be one:

    WSL      outside -> nix-export.sh -> binary cache, sharded
                      (unsigned by decision; optional key path kept)
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

**No signing keys, by decision (2026-09).** The two-checksum scheme is covered by Nix's
per-store-path hashing; adding an ed25519 trust chain on top was declined as ceremony.
`nix/hosts/wsl.nix` keys `require-sigs` off `cache-pubkey`'s existence,
so the unsigned path needs no edit and prints that it is unverified.

**What replaced the two-checksum scheme.** `manifest.toml` hashed upstream archives (*did I
download what upstream published?*) and `CHECKSUMS.sha256` hashed extracted files (*did the
transfer corrupt anything?*). Nix covers both, better: the flake lock pins inputs by hash, and the
binary cache is verified per **store path** rather than per tarball -- so a damaged chunk fails on
the path it damaged, not on "the transfer". The tarballs carry no checksum sidecars either: a
corrupt layer surfaces as missing store paths in the pod (`doctor` checks exactly that),
which is the failure that matters. (Signing was the old plan for tamper-evidence; declined
2026-09 -- see above.)

## 4. Base images  [resolved 2026-09-27 -- see docker/BASE-IMAGES.md]

Internal flavors: `base-slim`, `base-pytorch`, `vscode-slim`, `vscode-pytorch`. Preconfigured
with registries and CA certs, so CI runs on an internal slim base, never a public image.
The vendor bases are **already present in the airgap registry**: `crane append` cross-mounts
them, so they never cross the gap and their size does not touch the build pod. Rely on them.

Editor is **code-server**, now shipped in the closure (see §7) rather than borrowed from the
base, so an editor exists on every base including the slim ones.

There is no container build left in OUR pipeline -- no Stage 1, no node layer, only
`tar` + `crane`. CI's assemble stage still runs on `base-slim`.

A **derived tag** on top of the vendor base is the escape hatch for what layers cannot do
(registry/CA/pip/npm defaults as overridable defaults; the uid-10001 passwd line, §6). The
derived-base workflow is in use; keep it to exactly that, and let everything else come from
the layers -- the imperative "install CLI tools into the base" habit is how a base drifts
from the closure. The full decision matrix (vendor as-is / thin derived / custom minimal),
what does NOT belong in a derived base, and the first-transfer checklist live in
`docker/BASE-IMAGES.md`. The historical `Dockerfile.airgap` (generic public base + user +
stow + packages) is obsolete for this toolchain.

Fill in yourself: registry hostname, repo paths, tag convention
(`BASE_REGISTRY` / `BASE_TAG` in `.gitlab-ci.yml`).

## 6. Arbitrary UID: one line in your own derived base  [cosmetic today]

Probe findings: `uid=10001 gid=0(root) groups=0(root),1001650000`, and every shell start prints
`groups: cannot find name for group id 1001650000`.

Standard OpenShift arbitrary-UID behaviour: the pod gets a UID and a supplementary GID that
exist in no `/etc/passwd` or `/etc/group`.

**Our layers cannot fix it** -- they are appended files only (`crane append`), so a `chmod` on
`/etc` is not possible at build time, and shipping our own `/etc/passwd` would clobber whatever
the pytorch base defines. But you build images on top of the vendor base yourself, so the fix
does not need to be requested from anyone: put it in a **thin derived base** and point
`BASE_TAG` at it.

```dockerfile
FROM <vendor-base>
RUN chgrp 0 /etc/passwd /etc/group && chmod g+w /etc/passwd /etc/group
```

This is the documented OpenShift pattern for images that must run as an arbitrary UID. It is
the one thing `crane append` structurally cannot do (appended layers can only ADD files; they
cannot chmod or rewrite existing ones), which is exactly why it belongs in a derived base
rather than in our append-only flow.

Mitigated meanwhile (works today, no base change needed):

- `bootstrap` sets `USER`, `LOGNAME` and `HOME` in the generated fish and bash drop-ins,
  which most tools consult before attempting a passwd lookup.
- `entrypoint` registers the UID and names the groups **if** `/etc/passwd` and
  `/etc/group` happen to be writable, and stays quiet if not.
- `doctor` reports whether self-registration is possible and which groups are unnamed.

Until the derived base exists the warning is noise, not breakage.

## 7. code-server  [RESOLVED -- in the closure, 2026-09]

It was deferred on the grounds that the base `vscode-*` images ship code-server and shadowing
it was a tier-3 blob with a bundled-Node microarchitecture risk. Deferred is no longer the
right word: **nixpkgs' `code-server` is in the pod closure now.** It is built from source
against a baseline Node (no microarch trap, unlike the bundled-runtime failure that SIGILL'd
opencode), lands on PATH ahead of the base's copy because our PATH is prepended, and the
`sst-dev.opencode` extension is seeded as a packaged default (see home.nix). The slim bases,
which had no editor at all, get one; the vscode-* bases get a current one via the same
mechanism instead of whatever the base bundled.

What stays from the deferral, because it costs nothing:

- `assemble.sh` records the base's ENTRYPOINT in `BASE_ENTRYPOINT` and `entrypoint`
  hands over to it. Without that, replacing ENTRYPOINT to run bootstrap would give you a
  `vscode-*` workspace whose IDE never starts.
- Session variables are image ENV, so code-server's task runner -- not a login shell -- still gets
  `TERMINFO_DIRS` and `LOCALE_ARCHIVE`.

If the version ever matters more than the closure cost, the interesting part is smarter vsix
management, not the binary.

## 5. First transfer should be deliberately small

Still true, and Nix makes it easy to honour: build `.#runai-layer` (the plain flavor, ~847 MB) and
skip `-nvim` (~880 MB). `assemble.sh` detects the missing nvim tarball and builds one flavor.

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
  entrypoint and launcher re-resolve via `session_home()`.
- **The preloader crash is reproduced** with `tests/hostile-preloader.c`, a
  synthetic .so that aborts only the agent binary -- the same shape as the
  real fractioning libs (opencode dies, system binaries are fine). Asserted:
  bare opencode dies, `run-opencode` survives, children get the original
  preload back via `BASH_ENV`.
- Also asserted: closure integrity after `crane append`, defaults seeding
  (opencode plugin, Zed settings), the env-injection contract, sudoers +
  setuid sudo, nginx presence, repo-layer determinism.

Two artifacts of the harness, not the image: the sudo PAM error under rootless
podman is a userns artifact (setuid-root maps to the host user, which cannot
read /etc/shadow; in a real pod setuid-root is real root), and the repro exits
139 or 134 depending on the agent binary's own signal handlers. **Unverified
in the gap: whether RunAI sets `no-new-privileges`**, which would block the
setuid bit entirely -- `doctor`'s sudo line answers it on a real pod.

GPU: `tests/test-gpu-cuda.sh` verifies passthrough + `torch.cuda` on a host
with the nvidia CDI setup (one-time, root) -- which means gpubox only: the
work laptop's WSL PC is CPU-only (nothing to set up there), and on RunAI the
cluster injects the GPUs into pods itself. What no local test can claim:
CUDA under the REAL fractioning preloaders (they are proprietary) -- only a
fractioned pod answers that. The preload split itself is fully covered.

Rootful `sudo podman` in a pod may still lack `CAP_SYS_ADMIN` for overlay
mounts; the prewritten `storage.conf` defaults to `vfs`, which needs no
mounts. Rootless podman (no sudo) needs unprivileged userns + subuids, which
OpenShift usually denies -- hence the sudo path.

Also in the closure: `herdr` (0.8.2 in the pinned snapshot), `zed-editor` (remote server),
`code-server` (the pod IDE, §7), `openssh`, `nginx`, and
`sst-dev.opencode` 0.0.13 (the official VS Code extension, seeded for
code-server and shipped as a raw `.vsix` for the Windows side, which has no
marketplace in the gap).

## 9. The local store was missing the layer's build plan  [RESOLVED -- healed 2026-09]

`nix build .#runai-layer` on the connected NixOS machine failed with
`store path '...drv' does not exist`, and each fix revealed the next path.
The real diagnosis, after the whack-a-mole was decoded:

- **The default store never held the layer's build-plan closure** -- 6,034
  paths (drv files, patches, source trees). It had only ever held the WSL
  system; the layer builds lived in the chroot store
  (`/tmp/airgap-test-store`), which builds the same eval fine -- so the pinned
  snapshot was always healthy and this was purely local store state.
- Three damage classes, each needing a different remedy:
  1. *file + row missing* (545 `.drv` files): invisible to `nix copy`
     (source-side closure says "needed", but the destination-side skip logic
     and ordering interact badly) -- needs file copy **and** row registration;
  2. *row present, file lost* (e.g. `jlgld...-zsh-5.9.2.tar.xz.drv`, later
     `file-5.48`): **`nix copy` silently skips these** ("copying 0 paths" --
     the daemon trusts its DB row), and `nix build` believes the path is
     realized until build-env setup trips over the missing file. Only a file
     copy fixes these;
  3. *rows for paths in no store anymore* (53 relics of old WSL system
     generations, e.g. `zed-editor-wrapped-1.16.1`): harmless unless a current
     eval references them; the cure is
     `sudo nix-store --verify --check-contents --repair`, which substitutes
     what the public cache serves and unregisters the rest so nix rebuilds
     them.
- **`/nix/store` was never read-only.** The earlier "read-only mount, remount
  first" advice was wrong: `mount -o remount,rw` on an already-rw mount fails
  `EBUSY` ("mount point is busy"), which is how the misdiagnosis started. The
  mount is a rw subdirectory bind of the root partition -- plain `sudo cp`
  works.

The repair that worked, in order (against the chroot store as donor):

    # 1. enumerate: closure of the top drvs vs what exists in the default store
    nix path-info --store /tmp/airgap-test-store -r <top-drv...>
    # 2. restore lost files (fixes stale rows for free)
    sudo xargs -a missing.txt -I{} cp -a "/tmp/airgap-test-store{}" /nix/store/
    # 3. register rows for the file-restored-but-unregistered paths, in order
    sudo nix copy --from /tmp/airgap-test-store --to daemon <top-drv...>
    # 4. if some lost relic of an old generation ever blocks a build:
    sudo nix-store --verify --check-contents --repair   # substitutes or unregisters

Gotcha while using the chroot as donor: running `nix copy` as root **from** a
chroot store leaves root-owned lock files / store dir in the donor -- the next
`gl` build there dies with `opening lock file ... Permission denied`. One line
fixes it: `sudo chown -R <you> /tmp/airgap-test-store`.

Both layer flavors now build on the default store (verified 2026-09); the
chroot store remains the independent throwaway. The diagnostic classes above
are worth remembering because `nix copy`'s skip-on-row behavior makes it a
no-op precisely for damage class 2, which is the least visible one.

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
  independent and hash-verified per store path, which an OCI tarball is
  not.
- The one real tradeoff left: a NEW packaged default chosen inside the pod
  must be committed to git to reach other users of the image. That is a
  feature (defaults are reviewed), not a rebuild.

## 11. Open items from the 2026-09 refactor

- **nginx**: added to the closure so port-exposure does not depend on the
  base. The exact site config RunAI expects (and whether it wants one at all)
  is unpinned -- when known, it belongs in the env-injection mount, not in
  the closure.
- **Zed remote development [RESOLVED -- in the closure]**: `zed-editor` builds
  the remote server as a second output (`remote_server`), shipped as a
  packaged default under `~/.zed_server/`. The lookup is EXACT-MATCH on the
  client's full version string, build metadata included:
  `zed-remote-server-stable-<1.17.2+stable.349.c8e44cf...>` (zed
  `crates/remote/src/transport/wsl.rs`: `format!("zed-remote-server-{}-{}",
  dev_name, version.to_string())`), and "present" means running `<file>
  version` exits 0. The `.gz` name that shows up in client logs is a
  PID-suffixed temporary upload (`{dst}.{pid}.gz`) -- not the lookup name.
  So `.#windows-kit` pins the installer, `nix/zed-client-version.nix` carries
  that installer's exact client version string (single source for the shim),
  and `home.nix` generates the shim from it. Measured 2026-09-26: with only
  bare `<v>`/`<v>+stable` shims the client silently downloaded its own server;
  with the packaged settings default shadowed by a real `settings.json` it
  also downloaded Node.js, the basedpyright npm package and the ruff release
  tarball. Both fixed; re-pin the two files in lockstep when nixpkgs bumps
  zed. Known edge: the client
  resolves `.zed_server` relative to the SSH session's `$HOME`, which is why
  the entrypoint/sshd-inetd self-registration must point at the PVC home --
  it does. The `opencode acp` integration needs none of this: it runs
  locally. The `sshd -i` bridge (`libexec/sshd-inetd` +
  `scripts/ssh-bridge.sh`) is implemented but only exercised against a real
  `runai exec` -- the privsep-user and passwd self-registration inside the
  pod are best-effort until then.
- **runai CLI on WSL**: prefer the Linux executable the RunAI UI offers (it
  matches the cluster's server version); pin it as a declared derivation --
  recipe in `nix/packages/runai-cli.nix` (fill version/hash/url, wire into
  `nix/hosts/wsl.nix`). Fallback: `uv tool install runai` (resolves internal
  Artifactory). It is a client tool, deliberately not in the pod closure.
- **shell.env hook**: verified against the shipped opencode version's
  documented behavior; upstream has a TODO about honoring `shell.env` in the
  v2 bash tool -- the `BASH_ENV` path is the belt to that suspenders.
- **WSL first boot [root cause found 2026-09-26]**: the imported distro's `/`
  shipped mode 0700 — the build root came from `mktemp -d` and tar recorded
  that mode on the `./` entry, which extractors apply to the distro root. Every
  non-root process then got EACCES traversing absolute paths (shell exec,
  messagebus's journal connect, login's cd, the WSL relay); root bypassed it
  via DAC_OVERRIDE, which is why the first iterations chased dbus and were
  reverted. The builder now enforces one invariant for the whole tree (every
  directory traversable) and fails the build if violated. A separate class —
  ownership that cannot be set inside the build's user namespace (home dir) —
  is restored by tmpfiles at boot. Full story, gotchas, and the
  builder-is-the-weak-link assessment: `wsl/FIRST-BOOT.md`.
