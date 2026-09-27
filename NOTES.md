# Notes: war stories, design decisions, open items

Blockers are marked. Everything else has a working default. README,
ARCHITECTURE and MANUAL are canonical for how the system works; the resolved
sections here are verdicts plus pointers, kept because the failures behind a
line of code are worth one paragraph each.

## 1. RunAI preload antidote  [RESOLVED -- implemented]

The working antidote does **not** unset `LD_PRELOAD`; it *replaces* it with the
libc **matching the target binary's own glibc** (a system libc preloaded into a
Nix-built binary is a `GLIBC_PRIVATE` symbol-lookup error, not a no-op), and
stashes the original in `PRELOAD_ORIGINAL` for children. Tested across the four
input cases: both RunAI `.so`s / RunAI + a legitimate `.so` / unrelated `.so`
only (untouched) / unset (no-op). The split and its rationale: README "The
LD_PRELOAD / CUDA split"; the implementation: `libexec/run-opencode`,
`agent/plugins/preload.ts` (opencode `shell.env` hook),
`agent/restore-preload.sh` (`BASH_ENV`).

**Bug found while testing:** `ldconfig -p | awk '...exit'` returns 141
(SIGPIPE) under `set -o pipefail`, silently killing the launcher. Every
`ldd`/`ldconfig | awk ...exit` probe in libexec carries `|| true` for this.
Still worth confirming in-pod that nothing beyond the TUI is affected; set
`PRELOAD_RESTORE_AGENT_BASH=0` to disable the restore half.

## 2. Identity on the shared PVC  [RESOLVED -- implemented, team-shaped]

Probe findings: every runtime user is uid 10001/gid 0 and the hostname is
`<workspace-name>-<n>-<n>` with `<username>-<whatever>` workspace names, so the
OS knows nothing about who you are. `session_user()` resolves, first hit wins:
`$SESSION_USER` -> workspace-name leading component -> local part of
`git config user.email` -> `$USERNAME`/`$USER`. A baked email deliberately does
not exist: the closure is distributed to a team, so a baked identity would file
everyone's state into one person's PVC directory. For the same reason there is
no packaged `~/.config/git/config` (a store symlink would make
`git config --global` unwritable on the PVC): neutral git settings ship as
`/etc/gitconfig`, identity is a real file on the durable home. Renaming a
workspace changes the answer — accepted, and visible because `doctor` prints
which rule fired. Details: `libexec/common.sh`, MANUAL §0.

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
                     -> CI fetches, builds repo-layer.tar, crane appends

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
which is the failure that matters.

## 4. Base images  [resolved 2026-09-27 -- see docker/BASE-IMAGES.md]

Internal flavors: `base-slim`, `base-pytorch`, `vscode-slim`, `vscode-pytorch`. Preconfigured
with registries and CA certs, so CI runs on an internal slim base, never a public image.
The vendor bases are **already present in the airgap registry**: `crane append` cross-mounts
them, so they never cross the gap and their size does not touch the build pod. Rely on them.

Editor is **code-server**, shipped in the closure (see §7) rather than borrowed from the
base, so an editor exists on every base including the slim ones.

There is no container build left in OUR pipeline -- no Stage 1, no node layer, only
`tar` + `crane`. CI's assemble stage still runs on `base-slim`.

A **derived tag** on top of the vendor base is the escape hatch for what layers cannot do
(registry/CA/pip/npm defaults as overridable defaults — the env-injection contract in
`libexec/common.sh` wins per cluster; the uid-10001 passwd line, §6). The
derived-base workflow is in use; keep it to exactly that, and let everything else come from
the layers -- the imperative "install CLI tools into the base" habit is how a base drifts
from the closure. The full decision matrix (vendor as-is / thin derived / custom minimal),
what does NOT belong in a derived base, and the first-transfer checklist live in
`docker/BASE-IMAGES.md`. The historical `Dockerfile.airgap` (generic public base + user +
stow + packages) is obsolete for this toolchain.

Cluster facts are CI variables set in the airgap's GitLab (project/group
variables beat `.gitlab-ci.yml`) -- decision 2026-09-27, so nothing is
"filled in" from the connected side. The file carries readable defaults
only, and the Artifactory path derives from `VERSION`.

## 5. First transfer should be deliberately small

Still true, and Nix makes it easy to honour: build `.#runai-layer` (the plain flavor, ~1070 MB)
and skip `-nvim` (~1087 MB). `assemble.sh` detects the missing nvim tarball and builds one
flavor.

That proves transfer -> Artifactory -> `crane append` -> pod end to end, including the two things
that can only fail against real internal bases: `PATH` prepending on a pytorch base and
ENTRYPOINT hand-over on a `vscode-*` one.

The WSL side has its own chicken-and-egg, which is `nix build .#wsl-tarball` -- see `wsl/README.md`.

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

Verdict: nixpkgs' `code-server` is in the pod closure, built from source against a
baseline Node (no bundled-runtime microarchitecture trap), on PATH ahead of the
base's copy, with the `sst-dev.opencode` extension seeded as a packaged default.
The slim bases get an editor; the `vscode-*` bases get a current one via the same
mechanism. Two things from the old deferral stay because they cost nothing and are
load-bearing: `assemble.sh` records the base's ENTRYPOINT in `BASE_ENTRYPOINT`
and `entrypoint` hands over to it, and the session variables are image ENV so
code-server's task runner still gets `TERMINFO_DIRS`/`LOCALE_ARCHIVE`. Details:
`docker/README.md`, `nix/runai/layer.nix`.

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
  setuid sudo, nginx presence, repo-layer determinism. 19 checks total.

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

Also in the closure: `workmux` (worktrees + tmux for parallel agents, both targets),
`zed-editor` (remote server), `code-server` (the pod IDE, §7), `openssh`, `nginx`, and
`sst-dev.opencode` 0.0.13 (the official extension, seeded for code-server).

## 9. The local store was missing the layer's build plan  [RESOLVED -- healed 2026-09]

Verdict: the default store had never held the layer's build-plan closure (6,034
paths: drv files, patches, source trees) -- only the WSL system; the layer builds
lived in the chroot store (`/tmp/airgap-test-store`), which built the same eval
fine, so the pinned snapshot was always healthy. Three damage classes, each with
a different remedy:

1. *file + row missing* (545 `.drv` files): invisible to `nix copy` (its
   skip-on-row logic and ordering interact badly) -- needs file copy **and**
   row registration;
2. *row present, file lost* (e.g. `jlgld...-zsh-5.9.2.tar.xz.drv`): `nix copy`
   silently skips these ("copying 0 paths" -- the daemon trusts its DB row),
   and `nix build` believes the path is realized until build-env setup trips
   over the missing file. Only a file copy fixes these;
3. *rows for paths in no store anymore* (53 relics of old WSL generations):
   harmless unless a current eval references them;
   `sudo nix-store --verify --check-contents --repair` substitutes what the
   public cache serves and unregisters the rest.

The repair that worked, in order (against the chroot store as donor):

    # 1. enumerate: closure of the top drvs vs what exists in the default store
    nix path-info --store /tmp/airgap-test-store -r <top-drv...>
    # 2. restore lost files (fixes stale rows for free)
    sudo xargs -a missing.txt -I{} cp -a "/tmp/airgap-test-store{}" /nix/store/
    # 3. register rows for the file-restored-but-unregistered paths, in order
    sudo nix copy --from /tmp/airgap-test-store --to daemon <top-drv...>
    # 4. if some lost relic of an old generation ever blocks a build:
    sudo nix-store --verify --check-contents --repair   # substitutes or unregisters

Two facts worth remembering: **`/nix/store` was never read-only** (the earlier
"remount first" advice was wrong -- `mount -o remount,rw` on an already-rw mount
fails `EBUSY`, which is how the misdiagnosis started), and running `nix copy` as
root **from** a chroot store leaves root-owned lock files in the donor, so the
next build there dies with `opening lock file ... Permission denied`; one
`sudo chown -R <you> /tmp/airgap-test-store` fixes it. Both layer flavors now
build on the default store (verified 2026-09); the chroot remains the
independent throwaway and fallback (see AGENTS.md).

## 10. The role of Nix: where configs belong  [design note, 2026-09 refactor]

Premise: configs change often and must push cheap; the toolchain closure
changes rarely and is expensive to transfer. The consequence, spelled out so
it is not relitigated:

- **Nix owns binaries and the packaged defaults, not live config.** The
  frequent config edits happen on the durable PVC (`$HOME`), where a real file
  shadows the packaged symlink. A config tweak inside the pod has never
  required a rebuild -- that is the `$HOME` layering rule.
- **The closure-vs-text split already is the config-layer split.** The repo
  layer (380 KB of git text, re-tarred by CI per commit) is the "frequent, thin
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
- **Zed remote development [RESOLVED -- in the closure]**: the remote server
  ships as a packaged default, and the client's exact-match lookup on its FULL
  version string is satisfied by a shim generated from
  `nix/zed-client-version.nix`. Re-pin the kit installer and that file in
  lockstep when nixpkgs bumps zed. The `sshd -i` bridge
  (`libexec/sshd-inetd` + `scripts/ssh-bridge.sh`) is implemented but only
  exercised against a real `runai exec`. Full story: README "Zed remote,
  declared", `nix/modules/home.nix`.
- **runai CLI on WSL**: prefer the Linux executable the RunAI UI offers (it
  matches the cluster's server version); pin it as a declared derivation --
  recipe in `nix/packages/runai-cli.nix` (fill version/hash/url, wire into
  `nix/hosts/wsl.nix`). Fallback: `uv tool install runai` (resolves internal
  Artifactory). It is a client tool, deliberately not in the pod closure.
- **shell.env hook**: verified against the shipped opencode version's
  documented behavior; upstream has a TODO about honoring `shell.env` in the
  v2 bash tool -- the `BASH_ENV` path is the belt to that suspenders.
- **bootstrap drop-ins and the nested heredoc [fixed 2026-09-27]**: the podman
  `storage.conf` writer sat *inside* the fish drop-in heredoc in
  `libexec/bootstrap`, so fish refused to parse the whole generated
  `00-env.fish` ("Expected a string, but found a redirection") -- no PATH, no
  env in every interactive pod shell -- and `storage.conf` was never written.
  It predates `ebaeef7`. Fixed by generating the fish text and the bash-side
  `storage.conf` in separate steps; `tests/test-container.sh` now asserts the
  drop-in parses (`fish -n`) and that `storage.conf` exists and says `vfs`.
  Lesson: one heredoc per language, and a generated file needs a parse check,
  not just a grep for a substring.
- **Zed LSP pins [resolved 2026-09-27]**: every server the packaged settings
  declare is pinned by store path -- `bash-language-server`,
  `yaml-language-server` (with `schemaStore.enable=false`: otherwise it
  fetches schemastore.org per YAML file), and `tombi` (the `toml` extension is
  syntax-only since 1.0.3; taplo remains nvim's). Prettier auto-install is off
  (`"prettier": {"allowed": false}`). The agent integration is Terminal
  Threads + `"agent": {"terminal_init_command": "opencode"}`, not tasks.json.
- **workmux / skills / daily drivers [added 2026-09-27, both targets]**: workmux
  (pinned flake input) ships with its tmux integration and the opencode status
  plugin from the same revision; opencode skills are vendored from the
  matt-skills input (same revision as /etc/nixos). Both targets by decision --
  the pod gets the same worktree+tmux agent workflow as WSL (herdr is gone),
  and yazi/lazydocker/podman-compose/gcc/nodejs/bubblewrap ride in both
  closures for parity.
- **opencode slowness [open]**: reported slow in the WSL distro; the log
  directory has not been read yet -- the VHDX cannot be inspected from Linux
  (`qemu-img` hangs on this image's VHDX parser; 7-Zip reads the VHDX
  container but not the ext4 inside; the `debugfs` route is untested). Waiting
  on a dump from inside the distro:
  `wsl -d twentyx -- bash -lc 'cd ~; { cat .config/opencode/opencode.json; ls -la .local/share/opencode/log/; tail -150 "$(ls -t .local/share/opencode/log/*.log | head -1)"; } > /mnt/c/twentyx/diag.txt 2>&1'`.
- **WSL first boot [RESOLVED -- root cause found 2026-09-26]**: the imported
  distro's `/` shipped mode 0700 (the build root came from `mktemp -d` and tar
  recorded that mode on the `./` entry), so every non-root process got EACCES
  traversing absolute paths while root bypassed it via DAC_OVERRIDE. The
  builder now enforces one invariant for the whole tree (every directory
  traversable) and fails the build if violated; the home-directory ownership
  class is restored by tmpfiles at boot. Full story: `wsl/FIRST-BOOT.md`.
