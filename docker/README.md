# Build strategy: append layers, don't rebuild an image

## The problem

The internal `*-pytorch` bases are 15–30GB. An OpenShift BuildConfig that does
`FROM base-pytorch` must pull the base, unpack every layer into the build pod's ephemeral
filesystem, add layers, and push the result. Peak disk is roughly 2–3× the image size, which is
why the pytorch variants die on ephemeral storage while the slim ones succeed.

Raising the storage quota treats the symptom. The real issue is that we unpack 30GB in order to
add 400MB.

## The insight

Everything we add on top of the base is **just files** — and since the move to Nix, most of them
are files somebody else already built:

| Layer | Contents | Built by | Changes |
|---|---|---|---|
| `nix-layer.tar.gz` | the whole toolchain closure, at `/nix/store` | `nix build` **outside** the gap | monthly |
| `node-layer.tar` | pi and its `node_modules` | `Containerfile.node`, in CI | monthly |
| `repo-layer.tar` | dispatcher, libexec, pi package | `mklayer.sh`, plain `tar` | every commit |

Only the middle one needs a container at all, and only because pi ships as an npm package and npm
needs a registry. The other two are `tar`.

## The design

    OUTSIDE   scripts/build-layers.sh   ->  nix-layer.tar.gz  (414MB)
                                            nix-layer-nvim.tar.gz  (634MB)
    TRANSFER  physical, then scripts/push-artifactory.sh
    INSIDE    .gitlab-ci.yml  ->  node-layer.tar, repo-layer.tar
              docker/assemble.sh  ->  crane append + crane mutate

`crane append` fetches only the base's **manifest and config**, never its layers. It uploads the
new layer blobs and cross-mounts everything else. The fat base is never pulled, never unpacked,
never re-pushed.

Cost per variant: one manifest GET, one config GET, three blob PUTs (deduplicated after the first
variant), one manifest PUT. Seconds, and a few hundred MB of disk.

## Why the store must land at `/nix`

Every Nix-built binary names its ELF interpreter by **absolute store path**. Unpacking the closure
anywhere but literal `/nix/store` produces several hundred megabytes of binaries that cannot
`exec` — and the failure is `No such file or directory` on a file that plainly exists, which is a
genuinely confusing hour. Appending as an image layer puts it at `/` for free.

## What `crane mutate` must NOT do

Two settings look like they can be overwritten and cannot:

- **`PATH`.** The pytorch bases put conda and site-packages directories on it, and torch does not
  import without them. There is no shell at image-config level to expand `$PATH`, so `assemble.sh`
  reads the base's own value with `crane config` and *prepends* to it.
- **`ENTRYPOINT`.** On the `vscode-*` bases it launches code-server. Replacing it is how
  `airgap-entrypoint` gets to run at all, so the original is recorded in `AIRGAP_BASE_ENTRYPOINT`
  and handed over to when the container is started with no arguments.

Both were being clobbered before; both are silent failures rather than build errors.

## Session variables are image ENV, not shell config

`layer.nix` writes `/opt/airgap/session-env` and `assemble.sh` turns each line into `--env`.
A shell rc only reaches processes that source it, which excludes exactly the ones that break most
confusingly: `runai exec -- cmd`, code-server's task runner, anything the agent spawns. Those need
`TERMINFO_DIRS` and `LOCALE_ARCHIVE` as much as an interactive shell does.

Values that mention the eval-time home, or that are shell *expressions* rather than literals
(`TMUX_TMPDIR` is `${XDG_RUNTIME_DIR:-...}`), are filtered out — image ENV does no expansion, and
tmux handed that literal string would create a directory named `$(id`.

## Constraint

Stage 2 cannot run commands — it only adds files and edits image config (`ENV`, `ENTRYPOINT`,
`LABEL`) via `crane mutate`. Anything requiring execution must happen in `Containerfile.node` or at
container startup in `airgap-entrypoint`.

This is a feature: it forces the toolchain to be relocatable and inspectable, which is exactly what
lets the WSL target share the same Nix expressions.

## Two flavors

`nvim` roughly adds 220MB, and not every workspace wants an editor in it. Every variant is built
twice, `-nvim` suffixed, from the same node and repo blobs. If `nix-layer-nvim.tar.gz` is absent,
`assemble.sh` builds the plain flavor only and says so.

## Fallback if crane is unavailable

In rough order of preference: `regctl image mod`, `oras`, or a buildah build with its storage dir
on a mounted PVC instead of ephemeral disk. All are strictly worse. `crane` now comes from nixpkgs
(`nix shell .#`), so it rides in on the same transfer as everything else.
