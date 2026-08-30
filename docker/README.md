# Build strategy: append a layer, don't rebuild an image

## The problem

The internal `*-pytorch` bases are 15-30GB. An OpenShift BuildConfig that does
`FROM base-pytorch` must pull the base, unpack every layer into the build pod's ephemeral
filesystem, add layers, and push the result. Peak disk is roughly 2-3x the image size, which is
why the pytorch variants die on ephemeral storage while the slim ones succeed.

Raising the storage quota treats the symptom. The real issue is that we unpack 30GB in order to
add 300MB.

## The insight

Everything we add on top of the base is **just files**:

| Addition | Form |
|---|---|
| static binaries (rg, fd, bat, fzf, nvim, ttyd...) | files |
| npm globals (pi, LSP servers) | files |
| nvim plugin pack | files |
| airgap dispatcher + configs | files |
| vsix extensions | files (they unpack into an extensions dir) |

None of it needs to execute `RUN` *against the pytorch base*. It only needs to execute `RUN`
somewhere. So we build the tree in a slim container and attach it to the fat bases as a layer.

## The design

    STAGE 1  build the toolchain tree, once, in a SLIM image
             Containerfile.toolchain  ->  /out  ->  toolchain-<ver>.tar.gz   (~300MB)

    STAGE 2  append that ONE tarball onto each internal base, registry-side
             assemble.sh  ->  crane append + crane mutate

`crane append` fetches only the base's **manifest and config**, never its layers. It uploads the
new layer blob and cross-mounts everything else. The fat base is never pulled, never unpacked,
never re-pushed.

Cost per variant: one manifest GET, one blob PUT (deduplicated after the first variant), one
manifest PUT. Seconds, and a few hundred MB of disk.

## Consequences

- The 4-way matrix (`base-slim`, `base-pytorch`, `vscode-slim`, `vscode-pytorch`) costs the same
  as one build, because all four append the identical blob.
- The internal team owns the bases. We never rebuild them.
- A config-only change rebuilds a 300MB tarball, not a 30GB image.
- The build pod needs no special storage quota, so the pytorch variants stop failing.

## Constraint

Stage 2 cannot run commands -- it only adds files and edits image config
(`ENV`, `ENTRYPOINT`, `LABEL`) via `crane mutate`. Anything requiring execution must happen in
Stage 1 or at container startup in `airgap-entrypoint`.

This is a feature: it forces the toolchain to be relocatable and inspectable, which is exactly
what we need for the WSL target to share the same artifact.

## Tarball layout

Paths are relative to `/`, so the tarball mirrors the final filesystem:

    opt/airgap/{bin,libexec,config,pi,nvim-pack}/
    usr/local/bin/{rg,fd,bat,...}
    usr/local/lib/node_modules/...

All content is mode `g=u` and group `0`, because OpenShift assigns an arbitrary UID at runtime
and only the GID-0 bit is guaranteed.

## Fallback if crane is unavailable

In rough order of preference: `regctl image mod`, `oras`, or a buildah build with its storage
dir on a mounted PVC instead of ephemeral disk. All are strictly worse -- prefer getting the
`crane` binary through the transfer, it is a single ~40MB static Go binary with no dependencies.

## Layer ordering inside Stage 1

Still matters, but only for the 300MB build. Order by ascending frequency of change:

    apt/system -> node -> npm globals -> vsix -> nvim pack -> vendored binaries -> configs

With registry-backed cache (`--cache-to type=registry,mode=max`), a config-only edit rebuilds
just the final layer. Ephemeral CI runners have a cold local cache, so registry cache import is
mandatory, not an optimization.
