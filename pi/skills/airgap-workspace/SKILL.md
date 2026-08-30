---
name: airgap-workspace
description: >
  REQUIRED when working inside the airgapped RunAI workspace. Use when a command
  fails with a network error, when installing any dependency, when a config
  change does not survive a restart, when CUDA works in the shell but not under
  the agent, or when building/pushing workspace images. Triggers: airgap, RunAI,
  LD_PRELOAD, preloader, /code, /data, AIRGAP_STATE, ephemeral home, vendor
  manifest, Artifactory, crane append, vscode-server image, pip install fails,
  npm install fails, no route to host, offline.
---

# Airgapped RunAI workspace

## The three layers

`$HOME` does not survive a pod restart. Never put anything of value there.

| Layer | Path | Lifetime | Writable |
|---|---|---|---|
| Packaged defaults | `$AIRGAP_ROOT` (`/opt/airgap`) | image | build time only |
| User overrides + state | `$AIRGAP_STATE` (`/code/<user>/.airgap`) | persistent | yes |
| Running config | `$HOME` | **until pod restart** | yes, pointlessly |

`airgap bootstrap` rebuilds `$HOME` from the two durable layers on every start.
Anything in `$HOME` that is not a symlink into those layers is already lost.

To change a config permanently, write it to `$AIRGAP_STATE/config/`, not `$HOME`.
Run `airgap refresh list` to see what is overridden, `airgap refresh <name>` to
revert to the packaged default.

## There is no internet

`pip`, `npm`, and `git` reach **internal Artifactory and GitLab only**. Any
failure mentioning `registry.npmjs.org`, `pypi.org`, `github.com`, or a DNS or
connect timeout is this, not a broken package.

Do not retry, do not switch mirrors, do not suggest `--trusted-host`. Report
that the dependency is not present internally and stop. Adding one is a
deliberate act requiring a physical transfer -- see `vendor/manifest.toml` and
`scripts/push-artifactory.sh`.

`airgap doctor` verifies the endpoints and, usefully, asserts that public hosts
are unreachable.

## CUDA under the agent

RunAI injects GPU-fractioning interceptors through `LD_PRELOAD`:
`/runai/shared/pid/preloader.so` and `/runai/shared/memory/loader.so`.

The `pi` launcher replaces `LD_PRELOAD` with `libc.so.6` (a no-op preload, since
libc is already loaded) so Node does not segfault, and stashes the original in
`AIRGAP_ORIG_LD_PRELOAD`. `pi/extensions/preload.ts` restores it for every bash
call, so agent-run commands see the same environment an interactive shell does.

If `torch.cuda.is_available()` is `False` under the agent but `True` in a
terminal, that restoration is broken. Check with `airgap doctor`, which prints
both. Do not work around it by editing `LD_PRELOAD` inside the command.

## Images

Never `FROM` a `*-pytorch` base to add tooling. Those bases are 15-30GB and the
OpenShift build pod runs out of ephemeral storage unpacking them.

Everything we add is files, so build the tree once on `base-slim`
(`docker/Containerfile.toolchain`) and append it registry-side onto every
variant with `docker/assemble.sh`, which never pulls the base layers.

## Cheat sheet

```
airgap doctor          diagnose: layers, tools, preloaders, model endpoint
airgap refresh list    which configs are overridden
airgap update          pull config/script changes from GitLab (no rebuild)
airgap bootstrap       rebuild $HOME from the layers
```
