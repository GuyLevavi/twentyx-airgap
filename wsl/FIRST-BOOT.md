# WSL first boot: forensics, gotchas, and is this the right shape?

This is the honest write-up of why the imported distro booted to a root shell
but never a user session, what actually caused it, what the fix is, and what
the failure taught us about the builder. Read this before touching
`nix/hosts/wsl.nix` or the tarball builder.

Status: root cause found and proven; fix built and verified in the archive
(`./` entry is `drwxr-xr-x`, no untraversable directory in the tree, the
builder now asserts it). Booted on Windows: pending the next re-import.

## 1. The symptom

`wsl --import` succeeds; `wsl -d <distro>` prints

```
wsl: Failed to start the systemd user session for 'jensen'.
<3>WSL (497 - Relay) ERROR: CreateProcessCommon:810: chdir(/mnt/c/...) failed 13
<3>WSL (497 - Relay) ERROR: CreateProcessCommon:818: execvpe(/nix/store/...wrapped-bash/wrapper) failed: Permission denied
```

and `wsl -d <distro> -u root` gives a working root shell. Every user-level
path fails with `EACCES` in some form; root is always fine.

## 2. Root cause: the imported `/` was mode 0700

The builder assembles the image in `root=$(mktemp -d)`. **`mktemp -d` creates
mode 0700.** `tar -C "$root" ... .` records the `./` entry with the directory's
mode, and extractors apply directory modes from the archive — measured:

```
$ mktemp -d -p /tmp x.XXXX     -> 700
$ tar -tvzf img './'           -> drwx------ ./        (old builds)
$ tar -xzf img -C existing/    -> existing/ becomes 700
```

So WSL's import produced a distro whose **`/` is `0700 root:root`**. Every
non-root process then gets `EACCES` traversing *any* absolute path, because
`/` is the first component of every path. `CAP_DAC_OVERRIDE` lets root ignore
it — which is exactly why the symptom looked like "root works, everything
user-level is mysteriously denied".

Every observed failure maps to this one cause:

| symptom | what was actually denied |
|---|---|
| `execvpe(...wrapped-bash/wrapper) EACCES` | jensen traversing `/` to the store |
| `chdir(/mnt/c/...) failed 13` | the WSL relay as jensen traversing `/` |
| dbus-broker `launcher_open_journal: Permission denied` | `messagebus` traversing `/` to `/run/systemd/journal/socket` |
| classic dbus `Failed to connect stdout to the journal socket` + `status=200/CHDIR` | same, as `messagebus` |
| `login[504]: unable to cd to '/home/jensen'` | jensen (post-PAM) traversing `/home` |
| logind `user@.service: Transport endpoint is not connected` | dbus was already dead (cascade) |
| WSL "Failed to start the systemd user session" / 10 s init timeout | the session stack above (cascade) |
| `NSS returned no entry for 'systemd-oom'` | **separate, real** (missing passwd entries; fixed by declaring the users) |

The dbus-broker vs dbus-daemon difference, the journal socket mode, and the
`/home` ownership were all red herrings *for this failure*: the classic daemon
failed identically (it connects stdio to the same journal socket after dropping
to `messagebus`), which is what finally exposed the real invariant.

Why local checks missed it:

- the chroot smoke test ran **as root** (namespace root), and root bypasses
  the 0700 `/`;
- extracting the tar as `gl` into a `gl`-owned directory and reading it back
  as `gl` also works — the directory is 0700 but *owned by gl*, so traversal
  is allowed;
- the mode lives in the `./` entry, which nobody looks at until it bites.

## 3. The separate, real ownership class

The builder runs the NixOS activation inside `unshare -rm` where **only uid 0
is mapped**; every `chown()` to a real user or group returns `EINVAL`. Tar
then stamps `--owner=0 --group=0`, so anything needing non-root ownership is
root-owned in the archive. This is unavoidable without real root at build
time, and is handled where root *is* real: systemd-tmpfiles at boot.

| thing | at build | at boot |
|---|---|---|
| user home `/home/<user>` | chown EINVAL, ships root | tmpfiles `d`/`z` create/re-own it |
| `/var/lib/dbus`, `/var/empty`, journal dirs | tmpfiles chowns fail | systemd-tmpfiles as real root |
| `.vscode-server` pre-seed | `chown -R` EINVAL, aborted the activation | guard `|| true`; tmpfiles `z` re-owns |

The seed's unguarded `chown -R` under `set -e` used to abort the activation
snippet; that is why it is now `|| true` (ownership is fixed at boot anyway).

## 4. The boot logger

Every boot appends identity, `/` mode, home permissions, a real `su -l` exec
test, failed units, dbus status, journal socket modes, mounts, and the journal
head to `/var/log/bootlog.txt`, and copies it to `C:\twentyx`. Notes:

- `/var/log` does not exist in the image; the script creates it.
- `/mnt/c` can mount later than the service; the copy retries for ~30 s.
- The service must set an explicit `path` (`coreutils`, `util-linux`,
  `shadow`, `systemd`) — the default unit environment has none of them.
- In the last failing boot the service ran (30 s of retries) but could not
  see `/mnt/c`; the local copy is the source of truth:
  `wsl -d <distro> -u root -- cat /var/log/bootlog.txt`.

## 5. What the shipped build contains

| change | where | why | proof |
|---|---|---|---|
| dir traversal invariant + fatal assertion | builder, `nix/hosts/wsl.nix` (search "Normalizing directory permissions") | fixes the 0700 `/` and **any** restrictive directory, for the whole tree, not one path | tar `./` entry is `drwxr-xr-x`; no `find -type d ! -perm -o+x` hit; extraction into a dir leaves it 0755 |
| bind-mount prune in that pass | same | the rbind'd `/dev /sys /proc` survive the builder's best-effort umount; walking them chmods host state and fails | first attempt aborted with 6365 EPERM; pruned version completes |
| `findutils`/`gnugrep` in `runtimeInputs` | builder | the pass and the assertion run in the unit's PATH | build completes |
| tmpfiles `d`/`z /home/<user>` + `createHome = false` | `users.users`, `systemd.tmpfiles.rules` | §3 ownership class | rules in the built `etc/tmpfiles.d/00-nixos.conf` |
| seed chown made non-fatal | activation snippet | stops a doomed build-time chown from aborting the activation | build no longer aborts |
| boot logger incl. `/` mode check | `bootlog` | telemetry for an unreachable machine | unit + script verified in the built system |
| declared internal users, static `mutableUsers`, `jensen` default | users block, flake default | missing passwd entries caused the (separate) NSS errors; one user per Windows user | passwd contains all six |

Deliberately **not** in the build anymore:

- no `services.dbus.implementation = "dbus"` — the classic-daemon switch was
  a misdiagnosis; the broker is NixOS's default and works once `/` is
  traversable;
- no `airgap-fix-journal` chmod unit — the journal socket mode was never the
  problem; traversal was.

## 6. Was the approach healthy? (no)

The first several iterations patched *symptoms*: switched D-Bus
implementations, added a unit to re-chmod a socket, guarded a chown — each
justified by the last EACCES seen. That is exactly the kind of iteration that
keeps failing at runtime, and it did: every "fix" moved the error somewhere
new instead of removing the cause.

The healthy version, and the principle this file now records:

1. **Find the invariant, not the symptom.** "Root works, nothing user-level
   does" is a traversal-class statement, not a dbus statement.
2. **Enforce it for the whole tree, at one place.** The fix is one `find`
   pass over the image: every directory is traversable. Not a `chmod` on one
   path.
3. **Assert it at build time.** The builder now fails if any directory in the
   image is not traversable. That is the difference between "fixed" and "will
   bite us again": the invariant can no longer silently rot.
4. **Do not widen files.** The store's exec bits are already correct, and
   widening files would break sshd (it refuses to start unless host keys are
   exactly 0600). Directory traversal is the actual requirement.

The remaining scoped patches (tmpfiles for the home directory, the boot
logger) survive the same test: each addresses a class root cause with a
general mechanism (tmpfiles is NixOS's own declarative ownership engine), not
a one-off observation.

The deeper structural note stands: the builder's user-namespace design is the
source of both the ownership class (§3) and the mode trap (§2). Real root at
build time (one `sudo`, or `systemd-nspawn`/a VM) would remove both. If that
becomes acceptable, take it and delete the scaffolding.

## 7. Gotchas checklist

### Build / transfer workflow

- **`result/` staleness.** After any eval-affecting edit, `nix build
  .#wsl-tarball` before running `./result/bin/nixos-wsl-tarball-builder`. The
  inner script embeds `config.system.build.toplevel` at *its* evaluation;
  running a stale `result` shipped the previous default user twice.
- **Gitignored files are invisible to a git flake.** `wsl-username` only
  works in a plain-directory copy; in a dirty git tree Nix excludes ignored
  files and the `else` branch in `flake.nix` ships.
- **`nix flake check` evaluates, it does not build.** The gate is: build →
  extract → inspect `etc/passwd`, unit wants-dirs, the `etc` derivation →
  smoke-test `/bin/sh`.
- **Never test permissions as root.** A root smoke test in the build
  namespace bypasses DAC, and an extract owned by you is traversable despite
  being 0700. Test as a *different, unprivileged* uid or assert modes from
  the tar listing.
- **`--owner=0 --group=0` erases ownership** (intentional, reproducible);
  ordering by directory modes is the part that must be asserted.
- **The bind-mounted `/dev /sys /proc` persist** past the builder's
  best-effort `umount`; any tree-wide operation must prune them.
- **Read-only store modes.** Remove an extract with
  `unshare -rm bash -c 'chmod -R u+w <dir>; rm -rf <dir>'`.
- **No unclosed backgrounded `rm -rf`** — one raced an extraction and voided
  a whole forensics round.

### Host-side forensics

- **Absolute symlinks in an extract resolve against the host.** `etc/static`,
  `etc/systemd/system` and friends point at `/nix/store/...`; `ls`/`cat`
  through them reads *this machine*, not the image. This once made a `jensen`
  image appear to ship `home-manager-gl.service` (it was the host's units).
  Read the `etc` derivation directly, or `tar -xOf` individual files.
- The store is content-addressed, so the image's files also exist on the
  build host — usually easier than extracting 4.6 GB.
- To inventory cheaply: `tar -tvzf` the listing and check the first entry is
  `drwxr-xr-x ./`.

### WSL runtime

- Every tarball change requires `wsl --unregister` + `wsl --import`.
- `/mnt/c` mounts late; do not assume it in first-boot code.
- Launching from a Windows directory makes WSL `chdir` there; under the
  `metadata` automount that can fail `EACCES` — `--cd /` sidesteps it.
- WSL waits ~10 s for the systemd user session; slow boots can time out even
  when healthy (NixOS-WSL #888) — `wsl --shutdown` then relaunch.
- A working root shell says nothing about systemd (see §1).
- NixOS-WSL wraps every user shell: passwd points at a per-user
  `wrapped-bash/wrapper` (a copy of `nativeUtils`' `shell-wrapper` next to a
  `shell` symlink, `modules/systemd/native/wrap-shell.nix`). Root's login
  path uses the original `shell-wrapper`, so the two are not comparable.
- `/etc/machine-id` and `/var/log` are boot-created; their absence in the
  image is normal.

## 8. Is Nix the right tool?

**For the constraint, yes; for this implementation, the builder is the weak
link.**

What Nix buys, and what nothing else does as cleanly:

- One pinned source of truth for both sides of the gap (same flake for the
  RunAI pod layer and the WSL laptop), so pod/laptop drift is designed out.
- The closure *is* the manifest: content-addressed, per-path signatures,
  offline rebuilds for config edits, and no runtime fetch classes.

What it costs, learned the hard way here:

- The WSL rootfs is bespoke tooling. Upstream NixOS-WSL builds its tarball
  with real root; this repo reimplemented activation in a user namespace to
  avoid sudo, and both major bug classes came from that choice.
- Debugging crosses four layers (flake eval → chroot activation → tar
  extraction → WSL first boot) and the last one is a machine we do not have.

Alternatives, and their cost:

| option | first boot | airgap story | pod parity |
|---|---|---|---|
| plain Debian/Ubuntu WSL + offline debs | trivial | second toolchain to pin and carry | none |
| Docker/Dev Container on Windows | easy | registry export, another runtime | can reuse the pod image, no RunAI scheduling |
| upstream NixOS-WSL tarball + `nixos-rebuild` | easy | still needs a prebuilt closure moved in | needs a root/VM builder for this flake |
| **current: custom tarball, no sudo** | fixable, now asserted | excellent | excellent |
| custom tarball built as root once | easy | excellent | excellent |

Verdict: the Nix bet is right because the hard constraint is one source of
truth across the airgap and the RunAI side is not negotiable. The wrong tool
is the no-root user-namespace builder, not Nix.

## 9. Open items

- **Pending**: boot the fixed image on Windows and confirm the session; the
  boot log now records the `/` mode so the invariant is visible from inside.
- If a future change makes the builder's assertion fire, do not lower the
  assertion — fix the mode at the source.
- Reconsider a root/`systemd-nspawn` build to delete §2/§3 scaffolding
  entirely (see §6 and §8).
- `wsl/README.md` links here for the builder's design notes; keep the two in
  sync if the builder changes.
