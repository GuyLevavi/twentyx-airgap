# twentyx (inner repo)

The configuration half of the TwentyX airgap toolchain: everything that is
text. The binaries (compilers, editors, opencode, the Nix closure) are built
outside and arrive as a **store release** in this project's package registry;
this repo pins one in `STORE_RELEASE` and adds the config on top.

| Path | What | Lands in |
|---|---|---|
| `dotfiles/` | every Linux-side config (shells, tmux, nvim, opencode, zed, git, VS Code machine settings) | `$HOME`, as links (pods and WSL) |
| `pod/` | the pod boot chain: `entrypoint`, `link-home`, `run-opencode`, `restore-preload.sh`, `sshd-inetd`, `doctor` | `/opt/twentyx/libexec/` in the image |
| `docker/` | `mklayer.sh` (this repo as an image layer), `assemble.sh` (append onto the bases) | CI |
| `.gitlab-ci.yml` | `assemble` and `smoke` | CI |
| `wsl/` | `link.sh` (dotfiles into `$HOME`, stage `env/`), `update.sh` (pull the pinned release), `ssh-bridge.sh` (Zed/SSH into a pod) | the WSL distro, run from the clone at `~/twentyx` |
| `windows/` | WezTerm, Zed and VS Code client configs | Windows, via `UNPACK.ps1` |
| `env/` | the internal CA and pip.conf for WSL | `/var/lib/airgap-env/` |
| `scripts/push-gitlab-packages.sh` | publish a store release | the package registry |
| `STORE_RELEASE` | the release this repo builds on | CI, `wsl/update.sh` |
| `CONTRACT.md` | the interface with the outside repo | — |
| `REQUESTS.md` | what to ask the outside for (binaries, system changes) | carried out by hand |

## The loop

Edit a config (on WSL, `~/.config/<file>` is a link into `~/twentyx`, so you
are editing the repo), commit, push. CI builds a new workspace image in
seconds; teammates `git pull`. A real file in `$HOME` is yours and is never
touched; delete it to get the repo's version back.

Anything that needs a new binary or a WSL system change is a line in
`REQUESTS.md`, never an edit here.

## Read next

- [`MANUAL.md`](MANUAL.md): publish a release, CI, pods, WSL, Windows, troubleshooting.
- [`AGENTS.md`](AGENTS.md): the rules for changing this repo.
- [`NOTES.md`](NOTES.md): why the load-bearing pieces are the way they are.
