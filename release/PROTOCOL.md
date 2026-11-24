# Transfer protocol: @RELEASE@

This is the protocol for the inner agent and for whoever carries the release. Follow the steps in
order. Do not skip or reorder them, and do not "improve" a step. If a step fails, stop: send its
exact output outside and change nothing else.

## 0. Terms

| Word | Means |
|---|---|
| outside | the connected machine and the `twentyx-airgap` repo it builds from |
| inner | the airgapped side: the GitLab project `324cv/twentyx`, its CI, the WSL boxes and the pods |
| release | one folder `twentyx-store/<RELEASE>/`, cut by `scripts/make-release.sh` |
| delta | `KIND=delta`: only what the boxes do not already hold. Its id is `<yyyymmdd>-<rev>` |
| full | `KIND=full`: everything, for a reset. Its id ends in `-full` |
| box | one WSL machine (yours or a friend's) |

## 1. Receive (inner)

1. The release arrives as `<RELEASE>-b64/`, base64 parts plus `reassemble.sh`.
2. In that folder, run `sh reassemble.sh ./release`.
3. It must end with `RESULT: ok -> ./release`. If it names a missing or damaged part, ask outside
   for that part by name and stop here.
4. Read `./release/MANIFEST.txt`. `KIND` and `RELEASE` decide everything below.

## 2. Publish (inner)

5. Upload every file of `./release/` to the GitLab generic registry as package `twentyx-store`,
   version `<RELEASE>`, keeping the file names exactly. Boxes fetch from there.
6. Check that `MANIFEST.txt`, `apply.sh`, `wsl-needs.txt` and `wsl-<KIND>.nar.tar.gz` all
   download. A 404 on any of them breaks every box.

## 3. Repo (inner, once per release)

7. Copy `./release/update.sh` over the inner repo's `wsl/update.sh`, unchanged. It supersedes
   MR !14: close that MR, or merge it and then overwrite the file.
8. Set the repo's `STORE_RELEASE` file to `<RELEASE>`.
9. Make the edits `HANDOVER.md` lists under "Inner repo edits", then commit and push.

## 4. Update each WSL box

10. On the box: `git pull` in the inner repo, then run `~/twentyx/wsl/update.sh` as the user, not
    root. It runs `sudo` itself.
11. update.sh finds out how far behind the box is and applies the missing releases in order. It
    prints `plan: <release> <release> ...` before it changes anything.
12. It must end with `done: <RELEASE>`. Then open a new shell.
13. Check: `cat /var/lib/twentyx/release` prints `<RELEASE>`, and
    `readlink -f /run/current-system` equals `WSL_SYSTEM` in `MANIFEST.txt`.

**If update.sh stops with "no release between this box and ... can be applied":** nothing was
changed. Do one of these two things:

- Run `~/twentyx/wsl/update.sh <id>-full` with a full release that is already published. That is
  the reset path.
- Carry the `~/twentyx-baseline-<date>.store-paths` file it wrote outside. The next delta is then
  cut against it.

**Never** run `nixos-rebuild`, build from `inside-seed/`, or hand-edit store paths. Inside, the box
is only switched by `apply.sh`.

Without the registry, from a transfer folder: run
`TWENTYX_STORE_URL=file:///mnt/c/twentyx-store ~/twentyx/wsl/update.sh <RELEASE>`. Each release
must sit in its own `<RELEASE>/` subfolder there. Or, for a single release on a box known to be
one step behind: `sudo ./apply.sh` in the release folder.

## 5. Pods (inner CI)

14. Delta: `pod-delta.tar.gz` goes **directly above** the 20261013 nix layer, as before.
15. Full: `pod-full.tar.gz` goes directly on the base image, with **no** older nix layer under it.
    That is the reset.
16. Read image ENV from `opt/twentyx/session-env` of the **topmost** nix layer.
17. Check in a new vscode-pytorch pod: `command -v code-server` prints a path under
    `/opt/twentyx/profile/bin`, `airgap doctor` is clean, and `echo $TWENTYX_NVIM_PLUGINS` is not
    empty.

## 6. Report back (inner to outside)

Send one message per release with:

- `RELEASE`, and which steps passed
- for each box: `cat /var/lib/twentyx/release`
- any step's failing output, verbatim
- any `twentyx-baseline-*.store-paths` that update.sh wrote

## 7. Undo

- One WSL step:
  `sudo nix-env -p /nix/var/nix/profiles/system --rollback && sudo /nix/var/nix/profiles/system/bin/switch-to-configuration switch`
- Pods: rebuild the image without the new layer, or deploy the previous image tag.
