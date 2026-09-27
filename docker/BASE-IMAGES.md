# Base images: what to rely on, what to derive

The pod image is assembled by `docker/assemble.sh`: two layers are appended
onto an existing base **registry-side** with `crane` (see `docker/README.md`).
This page is about the base itself — the 15–30 GB vendor image underneath.

## The situation

- The internal vendor bases (`base-slim`, `base-pytorch`, `vscode-slim`,
  `vscode-pytorch`) are **already in the airgap registry**. They do not cross
  the gap; `crane append` cross-mounts their blobs.
- The vendor base carries the GPU stack: CUDA userland, conda, torch, and the
  site-packages layout the cluster's jobs expect. Its CUDA version is matched
  to the cluster's driver by whoever maintains it.
- We build images **on top of** the vendor base ourselves (that predates this
  project). That is the escape hatch for anything the layers cannot do.

## What size costs, now that layers exist

| Operation | Cost of a 30 GB base |
|---|---|
| Build (assemble.sh) | **none** — `crane` fetches manifest + config only, never unpacks layers |
| Push (assemble.sh) | none — unchanged base blobs are cross-mounted, not re-pushed |
| Pod start (node pull) | the base is normally already cached on the node; only our ~850 MB layer is new |
| Cold node pull | the full image — the one place base size still shows |

So "the base is huge" is **not** a reason to rebuild it: the build-pod
storage problem that motivated this pipeline is solved by cross-mounting.
Size only matters for the first pull onto a node that has never seen the
image, and for that the vendor base's caching is usually enough.

## Three options

### 1. Vendor base as-is (default)

Use `base-slim` / `base-pytorch` directly as `BASE_TAG`. Everything this
repo adds is appended as layers. This is the tested path
(`tests/test-container.sh` simulates it).

### 2. Thin derived base (the one to use when you need a fix)

A 5-line Dockerfile `FROM` the vendor base that changes only what layers
cannot express:

- registry / CA / pip / npm defaults for Artifactory (baked as *defaults* —
  the env-injection contract at `/opt/airgap-env` overrides them per cluster,
  so a rebuilt base never strands old pods);
- the arbitrary-UID fix: an `/etc/passwd` (or nss-wrapper) line for uid
  10001 / gid 0, which removes the `groups: cannot find name` noise and lets
  tools that read passwd work (NOTES §6);
- nothing else.

Push it to the internal registry under your own tag and point the assemble
invocation at it (`BASE_REGISTRY` / `BASE_TAG`, or the CI variables). That is
the workflow that has been in use — keep it that small.

**What does NOT belong in a derived base**, even though it works: the
toolchain and CLI binaries (they are one line in `nix/modules/tools.nix` and
ship in the layer — a base copy splits the source of truth and is invisible to
`doctor`), dotfiles (packaged defaults on the PVC), the runtime user and sudo
(the repo layer), editors (the closure). An imperative "install a bunch of
CLI tools into the base" habit is how the base drifts from the closure; if a
tool is missing, add it to the closure and transfer — it is the cheaper path
now.

### 3. Custom minimal base (not recommended)

A slim base plus pinned CUDA runtime and torch wheels. It can save 10–20 GB,
but you then own:

- CUDA-userland ↔ cluster-driver compatibility, forever;
- torch/numpy wheel pinning and rebuilds when the cluster moves;
- the security-patch cadence the vendor base already has;
- one more artifact that must reach the airgap registry.

Only worth it if cold-pull size is a measured problem, or if the org mandates
a base other than the vendor's. The vendor base being already in the registry
removes the usual reason (transfer size).

## If you still run the old derived Dockerfile

The historical `Dockerfile.airgap` (generic Fedora/UBI/Ubuntu + user + stow +
packages) is **obsolete for this toolchain**: it duplicated what the layers,
the repo layer and the PVC packaged defaults now own, and it was built from
public bases rather than the vendor base. Keep a derived base only in the
shape of option 2 above; anything else is drift.

## First-transfer checklist (with the base)

1. `./scripts/build-layers.sh` — plain flavor only is fine (`NOTES.md` §5).
2. `scripts/push-artifactory.sh` — layers to Artifactory.
3. Inside: `docker/assemble.sh <tag-prefix>` against **base-slim** first.
4. Then against **base-pytorch** — the two things that can only fail against
   the real base are `PATH` prepending (torch breaks without conda paths) and
   `ENTRYPOINT` hand-over on a `vscode-*` base; `assemble.sh` handles both,
   but this is where you see it.
5. Run `doctor` in the pod; it checks closure integrity against exactly the
   store paths the layer promised.
