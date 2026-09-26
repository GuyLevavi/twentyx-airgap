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
| Cluster tools | kubectl, k9s, stern, helm, crane, podman | podman + sudo (root via gid 0) |
| Agent | opencode + herdr | opencode (via `run-opencode`) + herdr |
| Editor | zed (Windows client + remote server), nvim | code-server (closure) + zed remote server |

Adding a package to `nix/modules/tools.nix` changes both at once, and the closure
tells you what that costs before you carry it anywhere.

## Sizes, measured

| | |
|---|---|
| WSL bootstrap, one file | **~1.1 GB** (gzip; dropped ~500 MB with the VS Code server pre-seed, 2026-09-26) |
| `nix-layer.tar.gz` | ~850 MB (code-server + zed remote server + podman/sudo/nginx/openssh) |
| `nix-layer-nvim.tar.gz` | ~880 MB |
| `repo-layer.tar` | ~380 KB |
| `windows-kit-*.tar.gz` | ~435 MB (Zed installer + WSL2 MSI + themes + client templates) |

The WSL bootstrap is a single ~1.1 GB gzip'd tarball (`.wsl` is just the
extension — `wsl --import` takes the same bytes under any name). The
binary-cache exporter shards by default; reassembly is order-independent
because the cache is content-addressed. If the size ever hurts, the single
biggest lever is clangd (~2 GB of the WSL closure) — removable as an offline
config edit on the WSL machine itself, no transfer needed.

## The two layers at runtime

`$HOME` in a pod is wiped on every restart, so it is **relocated wholesale** onto
the PVC. Selective symlinking only ever rescues the state you remembered to
enumerate, and there is always another tool writing a dotfile nobody listed.

| Layer | Path | Rule |
|---|---|---|
| Packaged defaults | `$TOOLCHAIN_ROOT/home-defaults` → `/nix/store` | immutable |
| Yours | `$HOME` on `/data/<user>` | durable, never clobbered |

Inside `$HOME` the distinction is visible in the filesystem: **a symlink into the
store is ours, a real file is yours.** Bootstrap never touches a real file, so
overriding a packaged default is just: edit it. Back up the real file and the
next start re-links the default.

`XDG_CACHE_HOME` is deliberately *not* durable — the PVC is network-backed, and
nvim, the LSPs and pip on a network filesystem are painfully slow. A cache is
reconstructible by definition.

```
doctor               layers, closure, terminal, sudo, podman, env, endpoint
run-opencode         launch opencode with the RunAI preload handled
code-server          the pod IDE — in the closure, ahead of the base's copy
sudo <cmd>           the runtime user (gid 0) has passwordless root
podman ...           rootful via sudo; storage.conf prewritten (vfs)
```

## Environment-provided assets

Some things must not be baked into the image because they differ per cluster
and rotate: the internal CA bundle, pip.conf, RunAI's nginx site config. The
contract, in preference order:

1. **`/opt/airgap-env`** — a ConfigMap/Secret volume, mounted via RunAI
   pod-template customization. Platform-idiomatic: updates without an image
   rebuild or a PVC write.
2. **`/data/.airgap-env`** — a directory on the shared PVC, for when mounting
   is not available. One copy per cluster.

Known file names are wired into the environment wherever it can be reached
(shell drop-ins, the pod entrypoint, the opencode launcher — everything except
CRI exec, which only sees image ENV): `pip.conf` → `PIP_CONFIG_FILE`,
`ca-bundle.crt` → `SSL_CERT_FILE`, `REQUESTS_CA_BUNDLE`, `CURL_CA_BUNDLE`,
`GIT_SSL_CAINFO`, `NIX_SSL_CERT_FILE`, `NODE_EXTRA_CA_CERTS`. Unknown file
names are simply present at their path — that is the extension point for the
next "thing that needs to be there". `doctor` reports what was found.
The system trust store is also updated best-effort via sudo (Debian bases).

Two related, operator-supplied values are plain env, not files:
`LLM_BASE_URL` + `LLM_API_KEY` point the agent at the internal
vLLM endpoint (doctor probes `$BASE/models`). On WSL, the same cluster CA is
wired declaratively instead — carry `ca-bundle.crt` next to the flake
(`security.pki.certificateFiles` picks it up if present).

Override variables — no `AIRGAP_` prefix; nothing else in these images uses
generic names, so the name is the documentation (all optional, all documented
at their use site; see [`MANUAL.md`](MANUAL.md) for the walkthrough):

`SESSION_USER`, `SESSION_HOME` (identity / relocated home),
`EPHEMERAL_CACHE` (bootstrap scratch dir),
`PRELOAD_STRIP`, `PRELOAD_PATTERN`, `PRELOAD_RESTORE_AGENT_BASH`,
`PRELOAD_LIBC` (opencode launcher; the stash it hands to children is
`PRELOAD_ORIGINAL`),
`AGENT_SHELL` (which shell opencode spawns for tools),
`SSH_BRIDGE_USER`, `SSH_BRIDGE_KEYDIR` (sshd bridge),
`LAYER_VERSION`, `REUSE_CACHE`, `CACHE_SIGN_KEY`, `NIX_TRANSFER_CACHE`,
`LAYER_NIX`, `LAYER_NIX_NVIM`, `LAYER_REPO`, `IMAGE_REGISTRY`,
`BASE_REGISTRY`, `BASE_TAG`, `IMAGE_VARIANTS` (scripts + CI),
`TEST_*` (test harness).

## Default overrides without a transfer

Packaged defaults live in `$TOOLCHAIN_ROOT/home-defaults` as a directory of
per-file symlinks into the store — and overlayfs **merges directories across
layers**. So the repo layer, which CI re-tars per commit, can override any
individual packaged default by shipping a real file at the same path
(`opt/twentyx/home-defaults/.config/starship.toml`, say): seconds, no closure
rebuild, no physical transfer. A user's real file in `$HOME` still wins over
both — that precedence is enforced by bootstrap, not by the filesystem.

## Two update paths

| Change | Path | Cost |
|---|---|---|
| anything in the closure | rebuild → transfer → CI | a physical transfer |
| libexec / agent text | push → CI re-tars `repo-layer.tar` per commit | one commit, no transfer |

Note what moved: the shell, prompt, tmux and nvim configs are Nix-generated now,
so editing *them* is a closure change. On the WSL side that is still cheap —
`writeText`/`buildEnv`/`symlinkJoin` need only `stdenvNoCC` (78 MB, shipped
deliberately) and build from string literals with no fetches, so a config edit
rebuilds **offline, in seconds**. Adding a *package* is what needs a transfer.
The closure enforces the rule that discipline used to.

## Images: append, don't rebuild

The internal `*-pytorch` bases are 15–30GB, and `FROM base-pytorch` exhausts the
build pod's ephemeral storage unpacking them. Everything we add is files, so
two tarballs are appended registry-side with `crane append`, which fetches only
each base's manifest and config. See [`docker/README.md`](docker/README.md).

## The LD_PRELOAD / CUDA split

RunAI injects GPU-fractioning `.so` files via `LD_PRELOAD`. They crash opencode,
but stripping them everywhere breaks CUDA in everything the agent runs. Both are
true at once, so treat the process and its children separately:

- `libexec/run-opencode` replaces `LD_PRELOAD` with the libc **matching the
  binary's own glibc** (resolved with `ldd` — a system libc preloaded into a
  Nix-built binary is a `GLIBC_PRIVATE` error, not a no-op), stashing the
  original in `PRELOAD_ORIGINAL`
- `agent/plugins/preload.ts` restores the stash via opencode's
  `shell.env` hook; `agent/restore-preload.sh` does the same via `BASH_ENV` for
  any non-interactive bash the hook does not cover

`doctor` prints `torch.cuda.is_available()` under both.

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

## Layout

```
flake.nix                     both targets, pinned inputs
nix/modules/                  the shared config: home, shell, tools, nvim
nix/hosts/wsl.nix             NixOS-WSL: offline substituters, nix-ld, sshd, podman
nix/runai/layer.nix           the closure -> an OCI layer tarball
libexec/*                     bootstrap, doctor, entrypoint, run-opencode, sshd-inetd
agent/                        opencode preload plugin + BASH_ENV restore helper
scripts/build-layers.sh       run OUTSIDE -> dist/*.tar.gz
scripts/nix-export.sh         run OUTSIDE -> a sharded binary cache (signing declined, 2026-09)
scripts/nix-import.sh         run INSIDE  -> imports it into the local store
scripts/push-artifactory.sh   run INSIDE  -> layers to Artifactory, for CI
scripts/ssh-bridge.sh         run on WSL  -> socat bridge: Zed/SSH into a pod
tests/                        container integration tests (podman, no cluster)
docker/                       registry-side assemble (no npm, no node layer)
NOTES.md                      open items + design notes
ARCHITECTURE.md               the tech tour: how it works, in what order to read this
MANUAL.md                     the step-by-step: build, transfer, connect, daily use
```

## Testing without the gap

`tests/test-container.sh` assembles the image against a mock base in a local
registry and runs it under the problematic pod shape — arbitrary UID 10001
with no passwd entry, tmpfs PVC, a hostile preloader on `LD_PRELOAD`, an
env-injection mount — asserting HOME relocation, closure integrity, the
preload split, defaults seeding, sudoers and layer determinism. First run
builds a throwaway Nix store (~10 min); reruns are fast. `nix develop` has
everything, or the script pulls what it needs:

```bash
nix develop -c ./tests/test-container.sh
```

`tests/test-gpu-cuda.sh` is opt-in for GPU hosts (needs the nvidia CDI setup
described in its header) — in practice that is gpubox only: the work WSL PC
is CPU-only, and on RunAI the cluster injects GPUs into pods itself. What it
cannot verify locally — CUDA under the real fractioning preloaders — only a
fractioned pod can (see NOTES.md).

## Before the first transfer

Nothing personal is declared in the closure. Identity in a pod comes from the
platform: the workspace name (`<username>-<whatever>-<n>-<n>` → first part =
your PVC directory; `SESSION_USER` env overrides for usernames with a dash).
Git identity is a real file on the durable home — one
`git config --global user.email` per person, editable forever, owned by the
user rather than by Nix (this toolchain is distributed to a team, and a baked
email would file everyone's state into the owner's directory).

No signing key, by decision: integrity is the content-addressed store hash for
the binary cache (a damaged chunk fails on the path it damaged). `nix/hosts/wsl.nix`
keys `require-sigs` off `cache-pubkey`'s existence, so the unsigned path needs
no edit and says so when it runs.

## Zed remote, declared

The remote-development server is built by the same `zed-editor` derivation and
ships in the closure as packaged defaults under `~/.zed_server/`. Zed's client
looks for a file named after its **own full version string** — build metadata
included (`1.17.2+stable.349.c8e44cf…`) — and only checks that it runs, so the
name must match the artifact, not a guess: `.#windows-kit` ships a **Windows
Zed installer**, `nix/zed-client-version.nix` records that installer's exact
client version string, and the shim is generated from it. Use the shipped
installer and the match is by construction. Keep Zed's auto-update OFF on
Windows (the closure's server moves only when the pins in
`nix/packages/windows-kit.nix` + `nix/zed-client-version.nix` move together).
The client reaches the host over plain SSH on WSL, or over
`scripts/ssh-bridge.sh` (`sshd -i` inside `runai exec`) into a pod.

## Status

The Nix side is built and tested; the layers below were produced and unpacked,
`bootstrap`/`doctor` were run against the real tree, and the
chunked transfer was verified by reassembling in reverse order and diffing.
The opencode/LD_PRELOAD split and the sudoers+setuid root path were exercised
end-to-end against a mock base in a local registry (see NOTES.md §8).

Not yet exercised **in the gap**: `assemble.sh` against real internal bases, and
the `wsl --import` of `nix build .#wsl-tarball`. See [`NOTES.md`](NOTES.md) — the
internal registry names are still placeholders.
