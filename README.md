# twentyx-airgap

A self-contained, transferable, headless workspace toolchain for a fully airgapped
RunAI/OpenShift environment — and the same toolchain in WSL, as NixOS.

Nix computes the closure. That is the whole idea: what crosses the gap is not a
hand-maintained list of blobs that drifts out of date, it is whatever the config
actually references, and nothing else.

## Two targets, one source of truth

`nix/modules/` is evaluated twice:

| | WSL | RunAI |
|---|---|---|
| What it is | a real NixOS system **inside** the gap | a read-only tree baked into an OCI layer |
| Nix at runtime | yes — rebuilds offline | **no** — never runs in a pod |
| How it arrives | binary cache, `scripts/nix-import.sh` | `crane append`, `docker/assemble.sh` |
| Python | Nix 3.11 + 3.12 (`python3` = 3.12), PBS 3.10, `uv`, `ruff` | the base image's `python3`, plus PBS 3.10 / 3.11 and `uv` under versioned names only |
| Cluster tools | kubectl, k9s, stern, helm, crane | none — a pod cannot reach the API server |

Adding a package to `nix/modules/tools.nix` changes both at once, and the closure
tells you what that costs before you carry it anywhere.

## Sizes, measured

| | |
|---|---|
| WSL bootstrap, one file | **948 MB** (4.3 GiB system + flake inputs, xz) |
| `nix-layer-nvim.tar.gz` | 634 MB (0.1 full) |
| `nix-layer-nvim-delta.tar.gz` | 266 MB (0.1 -> 0.2) |
| WSL delta, 0.1 -> 0.2 | 150 MB |
| `node-layer.tar` | ~40 MB |
| `repo-layer.tar` | 80 KB |

The whole airgapped NixOS-WSL fits in a single transfer under a 2.5GB per-file
cap. `nix-export.sh` shards anyway if it ever stops fitting; reassembly is
order-independent because the cache is content-addressed.

## The two layers at runtime

`$HOME` in a pod is wiped on every restart, so it is **relocated wholesale** onto
the PVC. Selective symlinking only ever rescues the state you remembered to
enumerate, and there is always another tool writing a dotfile nobody listed.

| Layer | Path | Rule |
|---|---|---|
| Packaged defaults | `$AIRGAP_ROOT/home-defaults` → `/nix/store` | immutable |
| Yours | `$HOME` on `/data/<user>` | durable, never clobbered |

Inside `$HOME` the distinction is visible in the filesystem: **a symlink into the
store is ours, a real file is yours.** That is what makes `airgap refresh` a
well-defined operation rather than a table someone has to maintain.

`XDG_CACHE_HOME` is deliberately *not* durable — the PVC is network-backed, and
nvim, the LSPs and pip on a network filesystem are painfully slow. A cache is
reconstructible by definition.

```
airgap doctor          layers, closure integrity, terminal, endpoint
airgap refresh list    what is overridden
airgap update          pull script changes from GitLab (no image rebuild)
airgap pi              launch pi with LD_PRELOAD handled
```

## Two update paths

| Change | Path | Cost |
|---|---|---|
| dispatcher, libexec, pi package | `airgap update` → `git pull` | seconds |
| anything in the closure | rebuild → transfer → CI | a physical transfer — a **delta** since 0.2 |

Note what moved: the shell, prompt, tmux and nvim configs are Nix-generated now,
so editing *them* is a closure change. On the WSL side that is still cheap —
`writeText`/`buildEnv`/`symlinkJoin` need only `stdenvNoCC` (78 MB, shipped
deliberately) and build from string literals with no fetches, so a config edit
rebuilds **offline, in seconds**. Adding a *package* is what needs a transfer.
The closure enforces the rule that discipline used to.

### Releases

A closure change no longer means re-shipping the closure. What crosses is the
set difference against what the far side already holds, as one folder,
`twentyx-store/<RELEASE>/`:

```
./scripts/make-release.sh --base-release <id inside> \
    --pod-base <the full layer tarball inside> \
    --wsl-base dist/baselines/wsl-<rev inside>.store-paths
```

`make-release.sh` lists what the folder holds. `release/` has the templates for
`apply.sh` and `HANDOVER.md`: write the handover for each release before cutting
it. The inner repo is the source of truth, and builds its own repo layer.

- **RunAI**: each full layer records its closure at `opt/twentyx/store-paths`,
  so the old tarball *is* the baseline. The delta layer is appended directly
  above it; the full layer has to stay in Artifactory.
- **WSL**: every export writes the closure it delivered to
  `dist/baselines/wsl-<rev>.store-paths`. Nothing comes back across the gap,
  so **keep those files** — they are the only record of what is inside.
  `apply.sh` checks a delta's references against the local store first, and
  names any that are missing instead of failing halfway.

## Images: append, don't rebuild

The internal `*-pytorch` bases are 15–30GB, and `FROM base-pytorch` exhausts the
build pod's ephemeral storage unpacking them. Everything we add is files, so
three tarballs are appended registry-side with `crane append`, which fetches only
each base's manifest and config. See [`docker/README.md`](docker/README.md).

## The LD_PRELOAD / CUDA split

RunAI injects GPU-fractioning `.so` files via `LD_PRELOAD`. Clearing them fixes
the agent but breaks CUDA in everything the agent runs. Both are true at once, so
treat the process and its children separately:

- `libexec/airgap-pi` replaces `LD_PRELOAD` with libc (a no-op preload, better
  than unsetting), stashing the original in `AIRGAP_ORIG_LD_PRELOAD`
- `pi/extensions/preload.ts` restores it via `spawnHook` for every bash call

`airgap doctor` prints `torch.cuda.is_available()` under both.

## Headless nvim over RunAI

The image (one flavor, `-nvim` tagged) is usable from a Windows terminal emulator through
`runai exec`. Six things have to be right, and all six are wired:

1. `runai exec -it` — `runai attach` gives you PID 1's stdio, which is not a TTY
2. tmux, always — an exec connection dies on any network blip, and whatever it
   started keeps running and holding PIDs (see below)
3. `TERMINFO_DIRS` — the slim bases have neither `tmux-256color` nor `wezterm`
4. `LOCALE_ARCHIVE` — otherwise fish warns on every start and mangles glyphs
5. `TERM`/`COLORTERM` — kubectl forwards `TERM` but never `COLORTERM`
6. OSC 52 — the only route from a yank in the pod to the Windows clipboard

Use **WezTerm** (Ghostty has no Windows build). It announces `TERM=wezterm`,
whose terminfo ships in the closure for exactly this reason.

## When a pod stops forking

Symptom: after hours of work or heavy compute, nothing starts, not even a
shell: `rust thread spawn failure: Resource temporarily unavailable (os error 11)`.
That is EAGAIN from fork or thread creation, and the usual cause is the pod's
**pids cgroup** (`pids.max`, often 1024–4096): threads count against it exactly
like processes do. It fills up three ways, and the image now addresses each:

| Leak | Fix |
|---|---|
| OpenMP/MKL/BLAS/torch pools sized to the **host's** cores, not the pod's quota, in every process and worker | `libexec/airgap-limits.sh` caps `OMP/MKL/OPENBLAS/NUMEXPR/RAYON_NUM_THREADS` and `GOMAXPROCS` at `ceil(cpu.max)`. The entrypoint and every bash/fish set them. Explicit exports win; `AIRGAP_THREADS=N` overrides. Also the main cause of CPU throttling. |
| PID 1 (code-server's node, a shell, `sleep`) never reaps orphans, so their zombies keep a PID until the pod dies | The entrypoint re-execs itself under **tini**. Tested: 5 orphans leave 5 zombies under `sleep` as PID 1, and 0 under tini. |
| `runai exec` sessions whose connection dropped keep running: nvim, LSPs, agents, node | **Work inside tmux** (`runai exec -it <ws> -- tmux new -A -s main`), so a reconnect reattaches instead of starting a new tree. Reclaim old trees with `airgap pids --kill <sid>`. |

`airgap pids` shows the budget, refused forks (`pids.events max=N`), CPU throttling,
memory pressure, the top thread owners and the sessions holding them. It uses
bash builtins only, so it still runs when the pod is out of PIDs, which is when
you need it:

    runai exec <ws> -- /opt/twentyx/libexec/airgap-pids              # retry until one exec gets in
    runai exec <ws> -- /opt/twentyx/libexec/airgap-pids --kill <sid>

Interactive shells warn at 75% use, and `airgap doctor` fails above it. The cap
itself is set by the cluster (CRI-O `pids_limit`, or the kubelet's
`podPidsLimit`). If `airgap pids` shows real training needing more, ask the
platform team for a higher one.

The tmux status line shows the same budget all the time: `cpu 1.4/2  mem
3.1/16G  pids 340/1024`, yellow at 75%, red at 90%. btop, top and free cannot:
they read `/proc`, which describes the node, not the pod.

## The runai CLI

It cannot be carried in. The internal control plane serves its own CLI, which
must match that cluster's version. Install it once, inside, from the UI:
Help (?) > Researcher Command Line Interface > Linux, then run the installer
and choose `~/.local/bin` as the install path. That directory is on `PATH` on
both targets, and in a pod it lives on the PVC, so it survives image updates.
On WSL, nix-ld runs the downloaded binary. `airgap doctor` reports whether it
is there.

To bake it into the pod images instead, set `RUNAI_CLI_URL` in CI to the binary
URL the installer downloads from. `assemble.sh` then adds `/usr/local/bin/runai`
as a small extra layer, refreshed on every build.

## Token budget

The in-house Qwen3 FP8 has a ~70k hard limit and degrades past ~50k. pi's
defaults assume 200k, so they are retuned in `config/pi/settings.json`
(compaction fires at ~48.5k, not ~184k). The real savings are structural:

| Mechanism | Effect |
|---|---|
| `scout` subagent | reads/greps in a **child** context, returns ~500 tokens |
| `/plan` → `plan.md` → `/execute` | planning context never enters the build session |
| per-agent `tools:` whitelist | strips unused tool schemas from the child |

## Layout

```
flake.nix                     both targets, pinned inputs
nix/modules/                  the shared config: home, shell, tools, nvim
nix/hosts/wsl.nix             NixOS-WSL: offline substituters, nix-ld, vscode-server
nix/runai/layer.nix           the closure -> an OCI layer tarball (or a delta over a previous one)
nix/pkgs/                     what nixpkgs lacks: PBS python, slim harlequin, open-code-review
bin/airgap                    dispatcher
libexec/airgap-*              bootstrap, doctor, refresh, update, pi, entrypoint
config/pi/, pi/               pi settings, preload extension, agents, prompts
scripts/make-release.sh       run OUTSIDE -> twentyx-store/<RELEASE>/: one delta release
scripts/export-dotfiles.sh    run OUTSIDE -> dotfiles/, the pod configs as plain files
release/                      templates for a release's apply.sh and HANDOVER.md
scripts/build-layers.sh       run OUTSIDE -> dist/*.tar.gz (--since: delta layers)
scripts/nix-export.sh         run OUTSIDE -> a sharded binary cache (--since-paths: delta)
scripts/check-nvim-offline.sh run OUTSIDE -> starts LazyVim with no network; run before a transfer
scripts/nix-import.sh         run INSIDE  -> imports it into the local store
scripts/push-artifactory.sh   run INSIDE  -> layers to Artifactory, for CI
docker/                       node layer + registry-side assemble
NOTES.md                      open items to fill in from work
```

## Before the first transfer

One value only you can supply:

1. **`airgap.git.userEmail`** in `nix/modules/home.nix`. It is load-bearing
   beyond git: its local part names your directory on the shared PVC, and it
   sits above the hostname rule precisely because it is stable across sessions.

## Status

The Nix side is built and tested; the layers below were produced and unpacked,
`airgap bootstrap`/`doctor`/`refresh` were run against the real tree, and the
chunked transfer was verified by reassembling in reverse order and diffing.

Not yet exercised **in the gap**: `assemble.sh` against real internal bases, and
the `wsl --import` of `nix build .#wsl-tarball`. See [`NOTES.md`](NOTES.md) — the
internal registry names are still placeholders.
