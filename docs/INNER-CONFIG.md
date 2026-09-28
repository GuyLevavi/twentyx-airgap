# Inner configuration: what goes where, and merging an inner repo

This is the operator's map for "where does cluster-specific configuration
live?" on both targets — and the checklist for folding an inner
(`tenx`-style) repo, with its Dockerfile `RUN` lines, CA install, pip.conf and
image builds, into this toolchain. Nothing cluster-specific is baked into the
images: the layers carry the closure and the repo text, and everything that
differs per cluster, per machine or per user is injected, declared in Nix, or
written on the durable home. Cross-references: `README.md`
("Environment-provided assets"), `MANUAL.md` §5, `ARCHITECTURE.md`.

## 1. Two injection sources, one precedence rule

The contract is implemented once, in `injection_exports()` in
`libexec/common.sh:68-101`:

| Source | What it is | When to use |
|---|---|---|
| `/opt/airgap-env` | ConfigMap/Secret volume, mounted via RunAI pod-template customization | platform-idiomatic: updates without an image rebuild or PVC write; **wins when both exist** |
| `/data/.airgap-env` | a directory on the shared PVC | fallback when mounting is not available; one copy per cluster |

Precedence is **per directory, not per file**. `injection_exports()` walks the
two paths in that order and returns at the first one that *exists*
(`libexec/common.sh:84-101`): if `/opt/airgap-env` exists, `/data/.airgap-env`
is never consulted — even for a known file the mount does not contain. Remove
the mount to fall back, do not half-populate it.

Known file names are wired to env vars; anything else in either directory is
simply reachable at its path, which is the extension point for the next thing
nobody enumerated (RunAI's nginx site config is the standing example,
`nix/modules/tools.nix:187-192`):

| Known file | Exported as |
|---|---|
| `pip.conf` | `PIP_CONFIG_FILE` |
| `ca-bundle.crt` | `SSL_CERT_FILE`, `REQUESTS_CA_BUNDLE`, `CURL_CA_BUNDLE`, `GIT_SSL_CAINFO`, `NIX_SSL_CERT_FILE`, `NODE_EXTRA_CA_CERTS` |
| *(pseudo-entry)* | `ENV_INJECTION_DIR` — the directory that won; `doctor` prints it as `source` |

The CA list is one file with many readers: "python ssl, requests, curl, git,
the Nix binaries themselves, node" (`libexec/common.sh:90-97`).

### Who consumes it

- **`bootstrap`** appends the pairs to the generated
  `~/.config/fish/conf.d/00-env.fish` and `~/.bashrc` (both rewritten on every
  pod start), and best-effort installs the CA into the base's system trust
  store (`/usr/local/share/ca-certificates/airgap-env.crt` +
  `update-ca-certificates`, Debian-style) — `libexec/bootstrap:166-189`.
- **`entrypoint`** calls `apply_injection_exports` before exec'ing what it was
  given, so `code-server`, the base entrypoint and everything they spawn
  inherit the set; none of those source a shell rc
  (`libexec/entrypoint:29-33`).
- **`run-opencode`** (the launcher) calls `apply_injection_exports` before
  `exec opencode`, so the agent's whole process tree trusts what an
  interactive shell trusts (`libexec/run-opencode:39-42`).
- **`doctor`** reports it read-only: the winning source, every mapping, and a
  readability check on the CA (`libexec/doctor:218-238`).

**CRI exec does not see these variables.** `runai exec -- cmd` gets image ENV
only, and the injected set is resolved at runtime, never baked into the image
(`libexec/entrypoint:29-33`, `docker/README.md`). A script reached that way
must self-resolve: source `libexec/common.sh` and call `session_home()` for
the durable home and `apply_injection_exports` for the CA/pip set. The repo's
own scripts on that path already do (`doctor`, `run-opencode`, `sshd-inetd`,
`bootstrap`) — "the two must agree by construction" is repeated at each site.

Not files, but related: `LLM_BASE_URL` + `LLM_API_KEY` are plain env from the
RunAI workspace template (`MANUAL.md` §5); `doctor` probes
`$LLM_BASE_URL/models` and reports whether `LLM_API_KEY` is set
(`libexec/doctor:265-279`). The other runtime overrides (`SESSION_USER`,
`SESSION_HOME`, `PRELOAD_*`, `AGENT_SHELL`, …) are plain env too — the list is
in README "Override variables", each documented at its use site.

## 2. Where each setting lives

| Setting | Where it belongs | Lifetime | Who consumes it |
|---|---|---|---|
| Internal CA bundle | **WSL:** gitignored `ca-bundle.crt` next to the flake; `security.pki.certificateFiles` picks it up when present (`nix/hosts/wsl.nix:27-33,138-140`). **Pod:** `/opt/airgap-env/ca-bundle.crt`, else `/data/.airgap-env/ca-bundle.crt` | WSL: per machine, re-carry on rotation, applies on the next rebuild. Pod: per cluster, read at pod start | WSL: the system trust store — `git`, `curl`, `uv`, the runai CLI against Artifactory (`wsl/README.md:145-148`). Pod: the six env vars above, plus the base's openssl after bootstrap's best-effort `update-ca-certificates` |
| `pip.conf` | **Pod:** `/opt/airgap-env/pip.conf`, else `/data/.airgap-env/pip.conf` (injection sets `PIP_CONFIG_FILE`). **WSL:** nothing wires it; a personal `~/.config/pip/pip.conf` real file is read by pip as usual | Pod: per cluster, mount/PVC. WSL: per user | pip in the base image's Python (pod); pip/uv on WSL |
| Extra environment (`LLM_BASE_URL`, `LLM_API_KEY`; identity via `SESSION_USER`) | RunAI workspace env (pod template); on WSL your shell/opencode config — the flake sets none of these | Per workspace / per user | `doctor` endpoint probe and the agent; `SESSION_USER` is the first rule of `session_user()` (`libexec/common.sh:32-37`), and `doctor` warns when identity falls through (`libexec/doctor:33-39`) |
| Git identity (`user.name`/`user.email`) | A real file written by `git config --global` → `~/.config/git/config` on the durable home. Neutral settings ship as `/etc/gitconfig` from the repo layer (`docker/mklayer.sh:50-76`) and via `environment.etc."gitconfig"` on WSL (`nix/hosts/wsl.nix:234-259`). **No email is baked in**: the toolchain is distributed to a team, so a baked identity would file every teammate's state into one person's directory (`nix/modules/home.nix:202-212`) | Durable per user | git; and the last-resort rule of `session_user()` (fires only when the workspace name gave nothing, `libexec/common.sh:54-62`) |
| opencode config | `~/.config/opencode/opencode.json` — a real file on the durable home, deliberately NOT shipped (`nix/modules/home.nix:226-232`). Ours, packaged and kept fresh: the preload plugin `~/.config/opencode/plugins/preload.ts`, the workmux status plugin, and the vendored skills — store symlinks under the `$HOME` rule | Config: durable per user. Packaged plugin/skills: next image | opencode (TUI and ACP-from-Zed); the plugin is the child half of the LD_PRELOAD split (`agent/plugins/preload.ts`) |
| Zed settings | **Linux side (pod and WSL):** packaged default `~/.config/zed/settings.json`, composed at eval from the tracked `zed-settings.json` (personal look) plus the dynamic LSP/agent pins (`nix/modules/home.nix:235-342`). In a pod, a real file at that path is the user's and wins — merge the `lsp`/`languages` blocks by hand or the pins do not apply. On WSL, home-manager owns the path: a conflicting real file is backed up to `*.hm-bak` on the next switch (`flake.nix:106`), so shared changes belong in the tracked file. **Windows client:** `%APPDATA%\Zed\settings.json`, installed by `UNPACK.ps1` from the kit template; a real file already there is never overwritten (`scripts/windows/UNPACK.ps1:47-58`) | Default: repo edit → next transfer (pod) / offline rebuild (WSL). User file: durable (pod) | Zed client + remote server. The pins are what stop runtime downloads: LSP store paths, `auto_update=false`, telemetry off |
| Shell additions | **Pod:** real files `~/.config/fish/conf.d/50-*.fish` and `~/.config/bashrc.d/*.sh` (bootstrap sources the latter from the generated `.bashrc`; `libexec/bootstrap:134-164`); `00-env.fish` is ours, rewritten each start. **Fleet-wide:** `nix/modules/shell.nix` (fish, starship, tmux, workmux) — a closure change. There is no zsh anywhere in the closure; fish is the interactive shell, bash the login shell | Drop-ins: durable per user. Module: closure | Interactive fish and bash sessions, including code-server's terminals |
| VS Code | **Windows client:** the kit's `vscode\` payload is consumed by `UNPACK.ps1` — a silent install when no local VS Code exists (updates stay off in the gap) and the settings template into `%APPDATA%\Code\User\settings.json`; a real file there wins and the template is written beside it as `settings.example.json` (`scripts/windows/UNPACK.ps1:72-111`). **Remote/Linux side:** the kit's `*.vsix` extensions are installed into a pre-seeded VS Code server under `~/.vscode-server/` by `setup-wsl.sh`, best-effort and offline (`scripts/setup-wsl.sh:69-97`). **Pod browser IDE:** `code-server` from the closure, with `sst-dev.opencode` seeded as a packaged default at `~/.local/share/code-server/extensions/` (`nix/modules/home.nix:226-233`); its own settings are real files under the durable `~/.local/share/code-server/` | Windows client: durable, never overwritten. Kit payload: per transfer | VS Code (Windows + remote server), code-server, Zed remains the other Windows editor |

Caveat on the WSL CA row, verified against Nix itself: a git checkout does
not expose gitignored files to the flake source tree (`flake.nix:53-61` says
so for `wsl-username`), and `security.pki.certificateFiles` is gated on
exactly that visibility check (`builtins.pathExists`, `nix/hosts/wsl.nix:27-33`).
The shipped setup path handles it: `scripts/setup-wsl.sh:99-111` copies
`ca-bundle.crt` and `wsl-username` next to the flake and `git add -f`s them
before the rebuild — staged files are part of the flake source, no commit
involved. If you rebuild by hand on a git checkout, do the same, or evaluate
the flake from a plain path (`path:/home/jensen/twentyx-airgap#wsl`). Never
commit the CA to the shared repo.

## 3. Does this change need a transfer?

| Change | Where it lands | Cost |
|---|---|---|
| `libexec/`, `agent/` (runtime scripts, plugins) | git text; CI re-tars `repo-layer.tar` per commit (`docker/mklayer.sh`, `.gitlab-ci.yml:66-68`) | **none** — one commit deploys |
| `flake.nix`, anything under `nix/` — including the Nix-generated shell, prompt, tmux, nvim and git configs | the closure | rebuild → **physical transfer** for the pod layer / new cache for WSL |
| String-level config edits that only feed `writeText`/`buildEnv`/`symlinkJoin` | the closure, but built from literals with no fetches | WSL rebuilds **offline, in seconds**; the pod gets them with the next transfer |
| Adding a package to `nix/modules/tools.nix` (or `nix/modules/lsp.nix`) | the closure | a transfer — this is exactly "adding a package is what forces a transfer" (AGENTS.md) |
| `docker/`, `.gitlab-ci.yml`, docs | git text, re-read by CI / humans | one commit |
| `zed-settings.json` | tracked text, but consumed by `nix/modules/home.nix` at eval, so it produces a new packaged default | next transfer (pod) / offline rebuild (WSL) |
| Derived base image (`FROM base / RUN / push`) | registry-side, per `docker/BASE-IMAGES.md` option 2 | no gap crossing; inside-registry build only |

Two standing rules from the code and AGENTS.md: **never run Nix inside a pod**
(the layer is built outside; the flake lock is law in the gap), and the
repo-layer override mechanism for packaged defaults — a real file at
`opt/twentyx/home-defaults/<path>` shipped by the repo layer, which overlayfs
would merge over the default — is **not wired yet**: `docker/mklayer.sh` stages
only `libexec/`, `agent/`, `VERSION` and generated `/etc` files, so add a
`home-defaults/` tree to `mklayer.sh` before relying on it. The user's real
file in `$HOME` wins over both, always.

## 4. Merging an inner (`tenx`-style) repo

Inventory the inner repo/CI image by what each piece actually is, then route it:

| In the inner repo / Dockerfile | Here | Cost |
|---|---|---|
| `RUN apt-get install …` / vendored CLI tarball | add the package to `nix/modules/tools.nix`; language servers go to `nix/modules/lsp.nix`, whose one list feeds fish PATH, nvim, Zed and opencode | closure → transfer |
| `COPY ca.crt … && update-ca-certificates` | pod: the injection mount (`/opt/airgap-env/ca-bundle.crt`); WSL: the flake-side file. A derived base is the escape hatch only when the CA must exist *before* runtime (`docker/BASE-IMAGES.md` option 2) | git file / mount; no image rebuild |
| `COPY pip.conf` / `PIP_INDEX_URL=…` | injection mount `pip.conf` (it wins over any base default, so a rebuilt base never strands old pods) | mount/PVC |
| `.npmrc`, `pip install`, `npm install` at build time | gone: packages come from the closure; there is no registry fetch in the gap | closure → transfer |
| Agent config, MCP servers, model choices | real `~/.config/opencode/opencode.json` on the durable home; endpoint/keys as workspace env | durable per user |
| Model weights / caches | durable home (`TORCH_HOME`, `HF_HOME` are set there by bootstrap); never `XDG_CACHE_HOME`, which is deliberately ephemeral local disk | durable |
| Dotfiles, shell rc, prompt | durable-home drop-ins for personal changes; `nix/modules/shell.nix` for fleet-wide | text / closure |
| `FROM <base>`, `RUN`, `docker push` | `docker/assemble.sh` appends the two layers registry-side; base choice and the derived-base recipe live in `docker/BASE-IMAGES.md` | no unpack, seconds per variant |
| Cluster facts and registry credentials | GitLab CI variables (`BASE_REGISTRY`, `BASE_TAG`, `IMAGE_VARIANTS`, `ARTIFACTORY_*` — defaults in `.gitlab-ci.yml:21-25`) or RunAI env; never in the repo. The layers CI fetches are published to the project's GitLab generic package registry first, Artifactory second (`.gitlab-ci.yml:1-11,47-65`) | per cluster |
| "Clone the tool repo at build" | this repo ships as `twentyx-airgap.bundle` (real git history) and CI re-tars the repo layer per commit | git text |

The two rules of thumb:

1. **Text → git.** If it is a file someone typed — `libexec/`, `agent/`, docs,
   CI, a user dotfile — it is a commit. CI rebuilds the ~380 KB repo layer per
   commit; no physical transfer.
2. **Store path → transfer.** If it changes the closure — a package, a
   Nix-generated config, a flake input — it crosses the gap physically: layers
   for the pod, cache/rootfs artifacts for WSL. Nix computes exactly what must
   cross, so there is no blob list to maintain and no drift.

## 5. Sanity checks

In a pod, start from an interactive shell and run the read-only diagnosis
(`MANUAL.md` §6):

```bash
runai exec -it -- /opt/twentyx/libexec/doctor
```

The lines that matter, verbatim from `libexec/doctor`:

| Area | Look for |
|---|---|
| home / identity | `ok   HOME is on the PVC -- state survives a restart`; `identity via hostname (workspace <username>-<whatever>-<n>-<n>)` (a warning here means the workspace name did not match — pin `SESSION_USER`) |
| closure | `ok   all N store paths present`; failure names the count: `bad  M of N store paths absent -- the layer did not arrive intact` |
| defaults | `ok   defaults are linked` and `ok   no stale links from a previous image` |
| root / containers | `ok   sudo: passwordless for gid 0`, `ok   podman: storage initialized` |
| terminal | `ok   stdout is a TTY` and `ok   terminfo entry for … resolves` |
| injection | `source   /opt/airgap-env`, then one `VAR -> path` line per known file, then `ok   ca-bundle readable`. Instead seeing `warn no /opt/airgap-env or /data/.airgap-env …` means the mount is missing |
| endpoint | `ok   reachable: <model-id>`; `bad  cannot reach …/models` names the failure |
| summary | `==> all checks passed`, or `==> N check(s) failed` |

Symlink-vs-real-file on the PVC (the `$HOME` rule: a symlink into
`/nix/store` is ours, a real file is yours):

```bash
ls -l ~/.config/opencode/plugins/preload.ts    # symlink -> /nix/store (ours)
ls -l ~/.config/opencode/opencode.json         # real file (yours)
ls -l ~/.config/zed/settings.json              # symlink ours / real file yours
ls -l ~/.config/git/config                     # real file (identity)
ls -l ~/.config/fish/conf.d/00-env.fish        # real; rewritten on every pod start
ls -l ~/.config/fish/conf.d/50-local.fish      # real; yours, survives
ls -l ~/.zed_server/                           # store symlinks + version shims
readlink -f <path>                             # where a symlink actually lands
```

`bootstrap` never touches a real file, so restoring a packaged default is:
move yours away, run `libexec/bootstrap` (or restart the pod, which runs it).

CA trust, after an injection source is mounted:

```bash
# Pod, from a shell that received the injection (interactive/login, or
# run-opencode's children). $SSL_CERT_FILE points at the injected bundle:
openssl s_client -connect <artifactory-host>:443 -servername <artifactory-host> \
  -CAfile "$SSL_CERT_FILE" -verify_return_error </dev/null 2>&1 | grep 'Verify return code'
# expect: Verify return code: 0 (ok)

# Pod, from CRI exec (`runai exec -- cmd`) the env is NOT there -- pass the
# file explicitly:
curl --cacert /opt/airgap-env/ca-bundle.crt -fsS https://<artifactory-host>/... && echo trusted

# WSL: the system trust store is merged by security.pki; no env var involved:
curl -fsS https://<artifactory-host>/... && echo trusted
```

A `python -m pip config list` in the pod should show the index the injected
`pip.conf` sets; if it does not, check `echo "$PIP_CONFIG_FILE"` first — an
empty value means the file was not found in the winning source directory.
