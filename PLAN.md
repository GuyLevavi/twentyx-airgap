# Plan: cumulative store deltas, links-only $HOME, two repos

**Status: executed** (Stages 1–3 on branch `split`, 2026-10-13). Kept as the decision record
(D1–D18) and the verified facts; the step lists below are historical, and where they differ the
code, `HANDOVER.md` (the Stage 4 procedure, as shipped) and the docs win. Originally a draft
from the 2026-10-12 design review, verified against the code and a scratch
store on 2026-10-13 (see "Verified facts"). It supersedes the 2026-10-05 plan, whose phases
are done. Execute in stages, one green commit or more per stage. The WSL distro must keep
working after every stage. Do **not** commit, push or rebase without asking the owner.

## Why

Small changes (one new binary, one config tweak) still cost large transfers, and the
scripts keep growing modes: checkout vs carried, fetched vs carried, fresh import vs delta, full vs
delta. Each mode exists because a boundary was never decided. This plan decides the boundaries.
Most of the simplification then comes from deleting code.

## Locked decisions (owner answered, 2026-10-12, amended 2026-10-13)

| # | Decision |
|---|---|
| D1 | **Nix's job:** compile closures outside. Inside, Nix is at most a quiet package database on WSL and absent in pods. |
| D2 | **WSL keeps NixOS and the `nix` binary, but quiet.** Updates are `nix-store --import` + `nix-env --set` + `switch-to-configuration`. No substituters (`mkForce [ ]`), no flakes, no `nix-command`. Rollback and GC stay. *(Amended: NAR import stays — it is atomic, verifies hashes, refuses missing references and works through the read-only store; the tar + `--load-db` route needed ~25 lines of hand-written guards for the same.)* |
| D3 | **Per-target artifact, one pinned base.** Pods get a tar (OCI layer), WSL gets a NAR. Both are computed against the same `base.rev`. Each transfer is two big files at most, each under the 3072 MB/file cap. *(Amended: the union tar saved only the shared paths' bytes, not files.)* |
| D4 | **Deltas are cumulative against one pinned base.** Nothing comes back out to say what the far side has. Any delta applies to anything that has the base. Skipping or reordering deltas is harmless, because store paths only add. |
| D5 | **Rebase** (ship full closures and move the base pin) on a nixpkgs bump, or when the deltas pass ~300 MB. The transfer script warns; the owner decides. |
| D6 | **Two repos, split by who can change what.** *Outside* (connected, only the owner): flake, `nix/`, build and transfer scripts, WSL installer. *Inside* (internal GitLab): dotfiles and all Linux-side app config, pod boot scripts, CI, publishing, docs, cluster knowledge. Artifacts cross; git history does not. Information flows out only by hand. |
| D7 | **The inner repo owns all Linux-side config** (opencode.jsonc, fish, zed, tmux, git, VS Code machine settings, …). The outside ships binaries plus *binary-coupled defaults* (opencode plugins from upstream, skills, Zed remote server, vsix, package-lock) and the Windows kit with its client configs. |
| D8 | **The pod boot chain lives inside** and shrinks to `entrypoint`, `run-opencode` (+ preload restore), `sshd-inetd`, and a short `doctor`. WSL needs none of it. |
| D9 | **Pod config is baked by inner CI** into the thin repo layer, appended onto a per-release store image. No big image rebuild, and the base is never pulled. A config commit means a new ~400 KB layer. |
| D10 | **nvim is folded** into the one closure. No twin layer, no `-nvim` tags. Pods lose `nano` (`EDITOR=nvim`). |
| D11 | **System-level WSL tweaks** (units, sysctl, /etc) are carried out by hand and rebuilt outside, shaped to keep the delta small (leaf changes, no overrides of shared deps). User-level services go in dotfiles as `~/.config/systemd/user/*`. |
| D12 | **Staged migration.** The split comes last and is handed inside with explicit merge instructions for the inside agents. |
| D13 | **Fetch code follows the pin.** Every package lives in the internal GitLab registry, as today, under `twentyx-store/<RELEASE>/`. `apply.sh` reads local files only; the inner repo's `wsl/update.sh` downloads the pinned `STORE_RELEASE` and calls it. `SETUP.ps1` keeps its install-time fetch (outside repo, new package path). `push-gitlab-packages.sh` moves inside. |
| D15 | **One shipment.** Stages 1–3 are local commits; the gap receives one transfer: a rebase (`pod-full` + `wsl-full` + the install set; the first `base.rev` must carry the new build attrs), `inside-seed.tar`, `HANDOVER.md`. |
| D16 | **Handover as required edits.** Outside changes to inside-owned files (dotfiles, `.gitlab-ci.yml`) are numbered edits — intent, exact snippet, how to verify — applied on top of the inside version, which wins everywhere else. `HANDOVER.md` (procedure + change log) is appended with every stage commit and ships with every transfer, so nothing is reconstructed at the end. |
| D17 | **Windows client configs live inside** (`windows/`: `wezterm.lua`, `zed-client-settings.json`, `vscode-settings.json`). `UNPACK.ps1` takes them from the clone (`\\wsl.localhost\<distro>\home\<user>\twentyx\windows`) when it exists; the kit takes `inside-seed/windows/` as first-install defaults (D18), refreshed from inside by hand. `UNPACK.ps1 -ConfigOnly` re-applies them after a `git pull`. |
| D14 | **$HOME linking: one linker, `pod/link-home` (stow + ~20 lines), on both targets.** The pod entrypoint runs it; on WSL `wsl/link.sh` does. Packaged defaults are not linked file by file: `opencode.jsonc` names the skills and plugin by their `/opt/twentyx/home-defaults` paths, and only `~/.zed_server` (+ the pod's code-server extension) is linked, once. *(Amended 2026-10-13: stow refuses absolute links into the store, which ruled out stowing the defaults.)* |
| D18 | **`inside-seed/` stays in the outside repo** as the one outside copy of the inner repo: the handover payload (`inside-seed.tar`, every transfer), the fixture `tests/test-container.sh` runs against, and the spec two outside builds read (the LazyVim sandbox check, the Windows kit's client configs). It replaces `tests/fixtures/pod/` and `nix/packages/windows/`. Never live config: the inner repo wins, and the outside edits it only to mirror a required edit. *(2026-10-13, Stage 3.)* |

## Verified facts (2026-10-13)

Found while checking this plan; each one shapes a step below.

- **Pods ship without three store paths their image ENV names.** `layer.nix` roots the closure at
  `{profile, homeDefaults, nvimPlugins}`, and `profile.nix` returns a stub empty `nvimPlugins`.
  `TWENTYX_NVIM_PLUGINS` (the real LazyVim tree), `LOCALE_ARCHIVE` (glibc-locales) and the
  wezterm terminfo in `TERMINFO_DIRS` are all absent from `store-paths` today. Fix: root the
  closure at the session-env file too, so whatever it references ships (Stage 1.1).
- **NixOS-WSL remounts `/nix/store` read-only** (`utils/src/shim.rs`). A plain `tar -x -C /` there
  fails; `nix-store --import` works because the daemon remounts in its own namespace.
- **`nix-store --load-db` registers paths whose files do not exist**, and `--check-validity` then
  reports them valid (reproduced in a scratch store with `hello`'s closure). Not used any more.
- **`nix.settings.substituters = [ ]` still yields `cache.nixos.org`** (the NixOS default merges
  in); it needs `lib.mkForce [ ]`. Today the WSL config has the default substituter.
- **Closure sizes (NAR, uncompressed):** pod 3.75 GB, WSL 4.3 GB, shared 3.0 GB; pod-only 0.7 GB
  (code-server 536 MB), WSL-only 1.26 GB (k9s, kubectl, helm, python, uv, vscode-server). The pod
  layer is ~1.08 GB gzipped; the WSL full NAR is expected ~1.3 GB after 7z (measure at the first
  rebase).
- **The git-email identity fallback cannot fire:** `git config --global` reads `$HOME`, which is
  what is being resolved.
- **`runai exec` (CRI exec) never passes through the entrypoint** and does not inherit its
  environment: it gets image ENV + pod-spec env, and `HOME=/` for the arbitrary UID. code-server
  works today because the base entrypoint is exec'd *by* ours and inherits its exports.

## Target architecture

```
OUTSIDE repo (connected)                       INSIDE repo (internal GitLab)
  flake.nix, flake.lock, nix/                    dotfiles/            all Linux-side app config
  base.rev            <- the pinned base         pod/entrypoint, run-opencode, sshd-inetd, doctor
  scripts/transfer.sh                            pod/mklayer.sh, assemble.sh, .gitlab-ci.yml
  install/ (SETUP.ps1, UNPACK.ps1, apply.sh)     wsl/link.sh, wsl/update.sh, wsl/ssh-bridge.sh
  tests/ (+ frozen pod fixtures)                 scripts/push-gitlab-packages.sh
  CONTRACT.md                                    env/                 CA, pip.conf
                                                 STORE_RELEASE        pinned artifact release
                                                 REQUESTS.md          the outbound channel
                                                 CONTRACT.md (copy)
            |                                              ^
            |  artifacts only (7z-wrapped)                 |  owner carries a line by hand
            v                                              |  ("add hyperfine", "sysctl x")
   pod-delta.tar.gz  wsl-delta.nar  MANIFEST.txt  apply.sh
   (rebase: pod-full.tar.gz + wsl-full.nar instead, + nixos-wsl.tar.gz, windows-kit, SETUP/UNPACK.ps1)
```

### The contract (CONTRACT.md, identical in both repos)

The only interface between the repos. Changing it is the only change that needs both sides.

- **Paths:** `/opt/twentyx/profile/bin/<tool>` (stable tool path), `/opt/twentyx/home-defaults/…`
  (binary-coupled defaults), `/opt/twentyx/session-env` (KEY=VALUE for image ENV),
  `/opt/twentyx/store-paths`, `/opt/twentyx/bin/sudo` (setuid, made outside).
- **Artifacts:** names and meanings as in the table below.
- **MANIFEST.txt keys:** `RELEASE`, `BASE_RELEASE`, `BASE_WSL_SYSTEM`, `WSL_SYSTEM`,
  `NIXPKGS_REV`, `KIND=delta|full`, `WINDOWS_KIT`.
- **Publishing:** GitLab generic package `twentyx-store/<RELEASE>/<file>`. The inside pins the
  release it uses in `STORE_RELEASE`; CI finds the full layer under `BASE_RELEASE`.
- **RELEASE id:** `<yyyymmdd>-<outside short rev>`.

### Artifacts

| File | Contents | Consumer |
|---|---|---|
| `pod-delta.tar.gz` | the `/opt/twentyx` tree, then pod closure − pod base closure | pod: appended after the full layer; its `opt/` wins |
| `pod-full.tar.gz` | the `/opt/twentyx` tree, then the whole pod closure (rebase only) | pod: the base layer |
| `wsl-delta.nar` | `nix-store --export` of WSL closure − WSL base closure | WSL: `nix-store --import` |
| `wsl-full.nar` | the whole WSL closure (rebase only) | WSL: `nix-store --import` |
| `MANIFEST.txt` | contract keys | both |
| `apply.sh` | WSL update: import, root the base, set profile, switch | WSL |
| `nixos-wsl.tar.gz` | the rootfs of the new base, so every machine has the base | Windows, rebase only |
| `windows-kit-*.tar.gz` | WSL MSI, Zed, VS Code, **WezTerm (nightly)** installers + client configs | Windows, rebase only |

The `opt/` tree carries the setuid `sudo`: a mode bit inside a tar header is data, so the Nix
derivation that writes the tar sets `4555` on that member (Nix only forbids setuid *files* in
outputs). `mklayer.sh`'s `extract_sudo` goes away.

### Handover log (`HANDOVER.md`, outside, every stage commit)

Each entry: what changed and why; the inside files it touches; for inside-owned files a numbered
**required edit** (intent, exact snippet, verify step); and **likely inside overlaps**: inside work
this supersedes (e.g. a workaround for missing locale/terminfo/nvim store paths in pods is obsolete
once the closure roots include session-env). Stage 3 renders it into `HANDOVER.md`.

### Pod image (inner CI, never pulls the base)

```
workspace-store:<RELEASE>-<variant>-<base digest>   built once per release (or base change)
  = base manifest + pod-full(BASE_RELEASE) + pod-delta(RELEASE), session-env -> image ENV
workspace:<commit>-<variant>                          every commit
  = workspace-store + repo-layer (~400 KB), entrypoint + labels
```

The store job runs only when its tag is missing (`crane manifest` fails), so a config commit
downloads nothing big and uploads one tiny blob.

### WSL

- First install: `nixos-wsl.tar.gz` (built from `base.rev`), then `apply.sh` with the current delta.
- Update: `apply.sh` from the transfer folder, or `wsl/update.sh` (inside) which fetches the
  pinned release first.
- Config: the inner repo cloned at `~/twentyx`; `wsl/link.sh` stows `dotfiles/` into `$HOME`.
  A `git pull` is the deploy. Re-run `link.sh` only when files are added or removed.

### $HOME rule (both targets)

`$HOME` holds **links** into two stable roots that update themselves:

- config → the inner repo's `dotfiles/` (WSL: the clone; pod: `/opt/twentyx/dotfiles` baked by CI);
- binary-coupled defaults → `/opt/twentyx/home-defaults/…`, **not resolved** to `/nix/store`, so a
  closure update moves them without touching `$HOME`.

A real file in `$HOME` is a local override and is never touched. Machine-specific settings use
each tool's include (fish `conf.d/local.fish`, git `~/.gitconfig`, tmux `source-file -q`).
On WSL, stow refuses the whole run when a real file sits where a link should go; `link.sh`
prints stow's conflict list, and the owner resolves it (never `--adopt`: it moves the user's
file into the repo).

---

## Stage 1: cumulative per-target deltas against base.rev (outside)

**Status: done** on branch `split` (2026-10-13). The as-built record is `HANDOVER.md`. `--install` was folded into
`--rebase`, and the transfer script is `scripts/transfer.sh`.

1. **Fold nvim, fix the closure roots.** One profile (`nvim = true`); drop `runai-layer-nvim`,
   the twin delta, `-nvim` flavors in `assemble.sh` and the CI loop, and the stub `nvimPlugins`
   in `profile.nix`. Root `closureInfo` at the session-env file as well, so every path
   `session-env` names is in `store-paths`. Add a test: every `/nix/store/…` in `session-env` is
   in `store-paths`.
2. **`base.rev`**: a committed file holding the outside git rev of the base. The script builds the
   base closures from it (`nix build "git+file:.?rev=$(cat base.rev)#…" -o build/base-*`; the
   result links are a cache, normally a hit, and losing the build machine loses nothing). Nix
   cannot take another rev's outputs as a pure input, so the diff lives in the script, not a
   derivation. Delete `.gcroots/`, `.updatestamp`, `.layerdrv`, `.layerdelta`, `.wlldrv`.
3. **`nix/runai/layer.nix`** keeps one job: the `opt` tree (profile, home-defaults, session-env,
   store-paths, sudo). The script tars `opt` (sudo member `4555`) then the path list:
   `tar --owner=0 --group=0 --sort=name --mtime=@1 -T paths`, paths fed with `-T`, never argv.
   Keep `build-layers.sh`'s coverage check (every new-closure path is in base or delta).
4. **WSL quiet Nix** (`nix/hosts/wsl.nix`): `nix.settings.substituters = lib.mkForce [ ]`,
   `experimental-features` without `nix-command`/`flakes`, keep `nix.channel.enable = false` and
   the empty registry. Delete the `seed-home` service and the embedded `gitconfig` and VS Code
   machine settings (they move to dotfiles in Stage 2). Fix the "none is configured" comment.
5. **`install/apply.sh`** (replaces `scripts/setup-wsl.sh`, ~25 lines): as root,
   `nix-store --import < wsl-*.nar` (skipped when `WSL_SYSTEM` is already valid);
   `ln -sfn` the base (`BASE_WSL_SYSTEM`, or `WSL_SYSTEM` when `KIND=full`) into
   `/nix/var/nix/gcroots/twentyx-base`, because the monthly `--delete-older-than 90d` would
   otherwise collect the base generation and every later delta would be refused;
   `nix-env -p …/system --set`; switch (exit 4 = warn). A failed import names the missing base
   path: carry the full NAR. No registry fetching, no checkout mode, no CA staging.
6. **`scripts/transfer.sh`** (replaces `transfer-bundle.sh` + `build-layers.sh`):
   - default: `pod-delta`, `wsl-delta`, MANIFEST and `apply.sh`, each big file in 7z;
   - `--rebase`: `pod-full` + `wsl-full` instead, plus the install set (rootfs of the new base,
     Windows kit, SETUP/UNPACK); then write `base.rev = HEAD`. No `--install`: the rootfs must
     be the base's, so it is built exactly when the base moves; a kit change warns for a rebase;
   - prints the delta sizes, warns past 300 MB, when `NIXPKGS_REV` differs from the base's, or
     when the Windows kit changed;
   - refuses any file at or over 3072 MB;
   - no git bundle, no docs copy, no `repo-layer.tar`, no `UPDATE=`/`SQUASH=`.
7. **Windows kit:** add the WezTerm Windows build (pinned `fetchurl`, same re-pin note as Zed);
   `wezterm.lua` is already in the kit.
8. **`docker/assemble.sh`**: append `pod-full(BASE_RELEASE)`, `pod-delta`, `repo-layer`;
   session-env is read from the delta's `opt/` (the full's when there is no delta).

**Done when:** adding a package not yet in the closure (e.g. `hyperfine`) yields a pod delta of a
few MB plus the rebuilt profile/opt trees (record the number in NOTES.md); `apply.sh` imports
the WSL delta on the distro with networking off; and CI assembles a pod image from full + delta
whose `store-paths` are all present (`doctor`).

## Stage 2: links-only $HOME, small pod boot (paths that will move inside)

**Status: done** on branch `split` (2026-10-13). D14 supersedes steps 1 and 2: one `pod/link-home` and no
tmpfiles rules or link lists. The pod scripts live in `pod/` (`/opt/twentyx/libexec` in the image),
and `wsl/` holds `link.sh` and `ssh-bridge.sh`. The as-built record is `HANDOVER.md`.

1. **dotfiles on WSL:** add `stow` to the closure (perl is already there). `wsl/link.sh` runs
   `stow -d ~/twentyx -t ~ --no-folding dotfiles` and stows `/opt/twentyx/home-defaults` the same
   way (verify stow accepts the symlinked package dir; fall back to the pod loop if not), creates an
   empty real `~/.gitconfig` when absent, then copies `env/ca-bundle.crt` and `env/pip.conf` to
   `/var/lib/airgap-env` and restarts `airgap-ca`.
2. **home-defaults:** links to `/opt/twentyx/home-defaults/<rel>` (unresolved). The Zed server
   entry has a version in its name; stale entries are pruned: dangling links that point into
   `/opt/twentyx/home-defaults`, searched only under the directories home-defaults ships (never a
   whole-`$HOME` walk on the PVC). Check whether `stow -R` already does this on WSL.
3. **git and VS Code config move to dotfiles:** `~/.config/git/config` (today's `/etc/gitconfig`
   text, deleted from `wsl.nix` and `mklayer.sh`), and
   `~/.vscode-server/data/Machine/settings.json`. Identity goes to `~/.gitconfig`, a real file:
   git writes `--global` there when it exists, so `git config --global user.email` never writes
   through a link into the repo.
4. **Pod `entrypoint`** (merges `entrypoint` + `bootstrap` + `common.sh` + `seed-home`):
   - passwd/group entry for the arbitrary UID;
   - identity: `$SESSION_USER`, else the hostname rule (`<user>-<…>-<n>-<n>`), else `$USERNAME`;
     the git-email rule is dropped;
   - `HOME=/data/<user>` (or `/code/<user>`), with the ephemeral warning when neither is writable;
   - CA/pip vars from `/opt/airgap-env`, else `/data/.airgap-env`;
   - writes everything resolved to **`/opt/twentyx/etc/session.env`** as `export K="v"` lines
     (valid in bash and fish). `.bashrc`, `config.fish`, `run-opencode`, `sshd-inetd` and `doctor`
     source it, so `runai exec` processes get what the entrypoint resolved. One resolver; no
     "keep in sync";
   - the link loop over `/opt/twentyx/dotfiles` and `home-defaults`, then `exec $BASE_ENTRYPOINT`
     (code-server inherits the exports, as today).
   - `XDG_CACHE_HOME=/tmp/twentyx-cache` and `CONTAINERS_STORAGE_CONF` become image ENV; podman
     `storage.conf` becomes a static file in the repo layer (vfs, under `/tmp`). The generated
     `env.fish`/`env.bash` go.
5. **opencode preload**: `preload.ts` and `restore-preload.sh` move next to `run-opencode` (pod,
   inside). Drop `preload.ts` from `homeDefaults`; link it from the repo layer.
6. **`doctor`**: cut to the checks that found real failures (sudo, preload, HOME durability,
   session.env present, store-paths complete), ~60 lines.
7. **Delete** the home-manager migration code (`hm_era_link`), copy-once logic, "newer default
   available" reporting, and the `/opt` → `~/twentyx` exec redirect in `seed-home`.
8. **Check write-through:** open and save settings in Zed and VS Code; quit btop after changing a
   setting (it may rewrite its config through the link — on WSL into the clone, in a pod into the
   group-writable image copy). For each tool that replaces the link or writes into it, use its
   include/override mechanism for that file instead.

**Done when:** on WSL, editing `~/twentyx/dotfiles/.config/opencode/opencode.jsonc` and running
`git pull` takes effect with no service restart; `runai exec -- bash -lc 'echo $HOME'` in a test pod
prints the PVC home; a pod from a new repo layer picks up a config change on the next start; and
`test-container.sh` passes.

## Stage 3: split (outside)

**Status: done** on branch `split` (2026-10-13). Amended by D18: `inside-seed/` stays (no `tests/fixtures/pod/`, no second copy of the Windows configs), and steps 4–5 became "point the tests and the two seed-reading builds at it". `HANDOVER.md` is the renamed `handover/CHANGES.md` with the Stage 4 procedure on top. `transfer.sh` ships it and `inside-seed.tar` every time, and builds the rootfs first so the sudo prompt comes before the long part. Docs: `ARCHITECTURE.md` folded into `README.md`; each repo has README, AGENTS, MANUAL, NOTES.

1. Create the outside repo layout (above) in this repo: move `install/`, keep `nix/`, `scripts/`,
   `tests/`, and add `CONTRACT.md` and `base.rev`.
2. Produce `inside-seed/`, the tree the inner repo should end up with: `dotfiles/`, `pod/`, `wsl/`
   (`link.sh`, `update.sh`, `ssh-bridge.sh`), `windows/` (the Windows client configs, D17),
   `scripts/push-gitlab-packages.sh`, `env/` (empty
   placeholders, never real certs), `.gitlab-ci.yml`, `CONTRACT.md`, `STORE_RELEASE`, `REQUESTS.md`
   (empty template), `AGENTS.md` (inside rules) and `MANUAL.md` (inside operations).
3. **Inner `.gitlab-ci.yml`:**
   - `store` job: when `workspace-store:<RELEASE>-<variant>-<base digest>` is missing, fetch
     `pod-full(BASE_RELEASE)` + `pod-delta(RELEASE)`, append, set session-env as image ENV;
   - `assemble` job: append the repo layer onto that store image, set entrypoint and labels;
   - `smoke` job: its image *is* the freshly assembled tag; runs `doctor` and
     `shellcheck -S warning` over the pod/wsl scripts (add `shellcheck` to the closure). This
     replaces the Docker Hub lint image, which the gap cannot pull. Optional: add `crane` to the
     closure so the store image can serve as CI's job image instead of a hand-built one.
4. `tests/fixtures/pod/` gets a frozen copy of the pod scripts so `test-container.sh` still runs
   outside. It is a fixture, not a source of truth; the inner `smoke` job tests the real ones.
5. Remove `inside-seed` paths from the outside repo. The outside `AGENTS.md` says: never edit
   Linux-side config here; config lives inside.
6. Ship `inside-seed.tar` plus `HANDOVER.md` (Stage 4 text) with the next transfer.

## Stage 4: handover inside (instructions for the inside agents)

Write to `HANDOVER.md`, ship it with the transfer, and follow it inside. Written for a careful but
less capable agent: mechanical steps, no judgement calls without a rule.

1. **Branch.** In the internal repo: `git switch -c adopt-split`. Never work on `main`.
2. **Inventory inside work first.** For each path below, list the inside commits since the last
   imported bundle (`git log --oneline <last-bundle-commit>..main -- <path>`) and save the output to
   `adopt-split-inventory.md`. Every listed commit must be accounted for by the end.
3. **Apply by category. The rule is fixed per category:**
   - `flake.nix`, `flake.lock`, `nix/`, `scripts/build-*`, `scripts/transfer*`, `scripts/setup-wsl.sh`:
     **delete**. They are dead inside. If an inside commit changed one, write what it wanted as a
     line in `REQUESTS.md` (e.g. "need `hyperfine` in the closure"). Do not try to keep the change.
   - `dotfiles/`, `env/`, `.gitlab-ci.yml`: **the inside version wins.** Move files to the new
     layout if their path changed; never take content from `inside-seed` over inside content.
     Exception: `.gitlab-ci.yml` takes the new job structure from `inside-seed`, then re-applies
     inside-only variables and runner settings.
   - Pod scripts (`libexec/*` → `pod/`) and `scripts/ssh-bridge.sh` → `wsl/`: **take the new
     structure from `inside-seed`, then re-apply each inside fix** from the inventory by hand, one
     commit per fix, naming the original commit.
   - Docs: take `inside-seed` `AGENTS.md`/`MANUAL.md`, then append any inside-only knowledge from
     the old docs under a "Site notes" heading.
4. **Pin the store release.** Set `STORE_RELEASE` to the `RELEASE` in the shipped `MANIFEST.txt`;
   publish the artifacts to `twentyx-store/<RELEASE>/` with `scripts/push-gitlab-packages.sh`.
5. **Verify** in this order and stop at the first failure: CI `store`, `assemble` and `smoke` pass;
   a pod from the new image boots and `doctor` is green; on WSL, `wsl/update.sh` (or
   `install/apply.sh` from a transfer folder) then `wsl/link.sh` run clean, and opencode starts.
6. **Close the inventory:** every commit in `adopt-split-inventory.md` is marked *re-applied*,
   *moved to REQUESTS.md*, or *obsolete because …*. Then merge to `main`.
7. **From now on:** inside never edits Nix; anything needing a binary or system change goes in
   `REQUESTS.md`, and the owner carries it out by hand.

## What gets deleted (expected)

`runai-layer-nvim`, `.gcroots/` and four stamp files, `UPDATE=`/`SQUASH=` modes, the git bundle,
`repo-layer.tar` on WSL, the `seed-home` service and script, `bootstrap`, `common.sh`, generated
env files, the duplicated `gitconfig`, home-manager migration code, registry fetching in the WSL
setup, `mklayer.sh`'s sudo extraction, the Docker Hub lint job, and `build-layers.sh`. Rough
target: the transfer path drops from ~600 lines of shell to ~150, and the pod boot chain from
~900 to ~250.

## Open risks to verify early

- WSL full NAR size after 7z at the first rebase (expected ~1.3 GB; the cap is 3072 MB/file).
- **`nixos-wsl.tar.gz` is 2954 MB today, 4% under the cap**, and 7z cannot shrink a gzip. The
  closure trims from this plan (no channel, no graphics) help; if it crosses, the transfer refuses
  and the fix is trimming the WSL closure, not splitting the file.
- `crane append` of a delta whose `opt/` overrides the full layer's: identical-path overlay, no
  whiteouts. Works today; confirm once with `dive` after the nvim fold.
- stow with a symlinked package dir (`/opt/twentyx/home-defaults`) and whether `-R` prunes
  entries removed from the package (Stage 2, steps 1–2).
- Tools that replace or write through links (Stage 2, step 8).
- Delta size depends on where a change sits in the graph. Leaf packages are cheap; overriding a
  shared dependency rebuilds its dependents. Keep fixes at the leaves (like the opencode phdr fix).
