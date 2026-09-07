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
| Python | Nix (3.11 + 3.12, `uv`, `ruff`) | the base image's — it owns torch and CUDA |
| Cluster tools | kubectl, k9s, stern, helm, crane | none — a pod cannot reach the API server |

Adding a package to `nix/modules/tools.nix` changes both at once, and the closure
tells you what that costs before you carry it anywhere.

## Sizes, measured

| | |
|---|---|
| WSL bootstrap, one file | **948 MB** (4.3 GiB system + flake inputs, xz) |
| `nix-layer.tar.gz` | 414 MB |
| `nix-layer-nvim.tar.gz` | 634 MB |
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
| anything in the closure | rebuild → transfer → CI | a physical transfer |

Note what moved: the shell, prompt, tmux and nvim configs are Nix-generated now,
so editing *them* is a closure change. On the WSL side that is still cheap —
`writeText`/`buildEnv`/`symlinkJoin` need only `stdenvNoCC` (78 MB, shipped
deliberately) and build from string literals with no fetches, so a config edit
rebuilds **offline, in seconds**. Adding a *package* is what needs a transfer.
The closure enforces the rule that discipline used to.

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

The `-nvim` flavor is usable from a Windows terminal emulator through
`runai exec`. Six things have to be right, and all six are wired:

1. `runai exec -it` — `runai attach` gives you PID 1's stdio, which is not a TTY
2. tmux, always — an exec session dies on any network blip
3. `TERMINFO_DIRS` — the slim bases have neither `tmux-256color` nor `wezterm`
4. `LOCALE_ARCHIVE` — otherwise fish warns on every start and mangles glyphs
5. `TERM`/`COLORTERM` — kubectl forwards `TERM` but never `COLORTERM`
6. OSC 52 — the only route from a yank in the pod to the Windows clipboard

Use **WezTerm** (Ghostty has no Windows build). It announces `TERM=wezterm`,
whose terminfo ships in the closure for exactly this reason.

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
nix/runai/layer.nix           the closure -> an OCI layer tarball
bin/airgap                    dispatcher
libexec/airgap-*              bootstrap, doctor, refresh, update, pi, entrypoint
config/pi/, pi/               pi settings, preload extension, agents, prompts
scripts/build-layers.sh       run OUTSIDE -> dist/*.tar.gz
scripts/nix-export.sh         run OUTSIDE -> a sharded, signed binary cache
scripts/nix-import.sh         run INSIDE  -> imports it into the local store
scripts/push-artifactory.sh   run INSIDE  -> layers to Artifactory, for CI
docker/                       node layer + registry-side assemble
NOTES.md                      open items to fill in from work
```

## Before the first transfer

Two values only you can supply:

1. **`airgap.git.userEmail`** in `nix/modules/home.nix`. It is load-bearing
   beyond git: its local part names your directory on the shared PVC, and it
   sits above the hostname rule precisely because it is stable across sessions.
2. **A signing key**, optional but nearly free:
   ```
   nix key generate-secret --key-name airgap-transfer > ~/.config/airgap/cache-priv.key
   ```
   `nix-export.sh` then writes `cache-pubkey`, and `nix/hosts/wsl.nix` keys both
   `trusted-public-keys` and `require-sigs` off that file's existence — so
   neither path needs an edit. Without it, the import runs unverified and says so.

## Status

The Nix side is built and tested; the layers below were produced and unpacked,
`airgap bootstrap`/`doctor`/`refresh` were run against the real tree, and the
chunked transfer was verified by reassembling in reverse order and diffing.

Not yet exercised **in the gap**: `assemble.sh` against real internal bases, and
the `wsl --import` of `nix build .#wsl-tarball`. See [`NOTES.md`](NOTES.md) — the
internal registry names are still placeholders.
