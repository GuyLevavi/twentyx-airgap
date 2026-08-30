# work-airgap-utils

A self-contained, transferable, headless workspace toolchain for a fully
airgapped RunAI/OpenShift environment — and the same tree in WSL locally.

Inspired by [Omarchy](https://omarchy.org/): a dispatcher CLI over small
scripts, immutable packaged defaults, user overrides layered on top, and
`refresh` to fall back to a known-good state.

## The three layers

`$HOME` does not survive a pod restart, so nothing durable lives there.

| Layer | Path | Lifetime |
|---|---|---|
| Packaged defaults | `$AIRGAP_ROOT` = `/opt/airgap` | baked into the image |
| Overrides + state | `$AIRGAP_STATE` = `/code/<user>/.airgap` | PVC, persistent |
| Running config | `$HOME` | **until pod restart** |

`airgap bootstrap` rebuilds `$HOME` from the two durable layers at every start.
Overrides win over defaults; `airgap refresh <name>` backs up an override and
reverts to the default.

```
airgap doctor          layers, tools, preloaders, model endpoint
airgap refresh list    what is overridden
airgap update          pull config changes from GitLab (no image rebuild)
airgap pi              launch pi with LD_PRELOAD handled
```

## Two update paths

| Change | Path | Cost |
|---|---|---|
| configs, scripts, pi package (text) | `airgap update` → `git pull` | seconds, no rebuild |
| binaries, node, nvim pack, vsix | fetch → transfer → Artifactory → CI | a physical transfer |

Roughly 90% of iteration is text, so 90% never touches Docker. Git stays
text-only; `vendor/` is gitignored and blobs live in Artifactory.

## Images: append, don't rebuild

The internal `*-pytorch` bases are 15–30GB, and an OpenShift BuildConfig that
does `FROM base-pytorch` exhausts its ephemeral storage unpacking them.

Everything we add is *files*, so:

1. `docker/Containerfile.toolchain` builds the tree once on `base-slim` → ~300MB tarball
2. `docker/assemble.sh` appends that tarball onto all four variants with
   `crane append`, which fetches only each base's manifest and config

The fat base is never pulled, unpacked, or re-pushed. See [`docker/README.md`](docker/README.md).

## The LD_PRELOAD / CUDA split

RunAI injects GPU-fractioning `.so` files via `LD_PRELOAD`. Clearing them fixes
the agent but breaks CUDA in everything the agent runs. Both are true at once,
so treat the process and its children separately:

- `libexec/airgap-pi` strips `LD_PRELOAD`, stashing it in `AIRGAP_ORIG_LD_PRELOAD`
- `pi/extensions/preload.ts` restores it via `spawnHook` for every bash call

Node runs clean; children run exactly as an interactive shell does. If pi turns
out to tolerate the preloaders, the stash is empty and the hook is a no-op — no
fork, no removal. `airgap doctor` prints `torch.cuda.is_available()` under both.

## Token budget

The in-house Qwen3 FP8 has a ~70k hard limit and degrades past ~50k. pi's
defaults assume 200k, so they are retuned in `config/pi/settings.json`
(compaction fires at ~48.5k, not ~184k).

The real savings are structural, not numeric:

| Mechanism | Effect |
|---|---|
| `scout` subagent | reads/greps in a **child** context, returns ~500 tokens |
| `/plan` → `plan.md` → `/execute` | planning context never enters the build session |
| per-agent `tools:` whitelist | strips unused tool schemas from the child |

## Layout

```
bin/airgap                    dispatcher
libexec/airgap-*              subcommands (bootstrap, doctor, refresh, update, pi)
config/                       packaged defaults (bash, starship, tmux, nvim, pi)
pi/                           pi package: preload extension, agents, prompts, skill
vendor/manifest.toml          the closure: every blob, with upstream hashes
scripts/fetch-vendor.sh       run OUTSIDE  -> dist/airgap-vendor-<v>.tar.gz
scripts/push-artifactory.sh   run INSIDE   -> Artifactory generic-local
docker/                       toolchain build + registry-side assemble
NOTES.md                      open items to fill in from work
```

## Two checksums, two jobs

- `vendor/manifest.toml` `sha256` — upstream **archive** hash, checked outside:
  *did I download what upstream published?*
- `vendor/CHECKSUMS.sha256` — **extracted file** hashes, checked at build time
  inside: *did the physical transfer corrupt anything?*

The second cannot be derived from the first: by build time the archives are gone.

## Status

Scaffold, tested locally. See [`NOTES.md`](NOTES.md) — the RunAI preloader paths
and the internal registry names are still placeholders.

**Do the first transfer small**: dispatcher, configs, pi, `crane`, and ~6 static
binaries (`--tier 1`). A few hundred MB proves manifest → transfer → verify →
append end-to-end. Find checksum and wrapper bugs on a cheap round-trip.
