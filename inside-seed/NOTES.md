# Notes: open items and the why (inside)

What is still open, and the reasoning behind pieces that are load-bearing
and must not be "simplified". The Nix-side why lives in the outside repo.

## Open items

- **First release against the real bases:** PATH prepending on a pytorch
  base, the ENTRYPOINT hand-over on a `vscode-*` one, `smoke` on a real
  runner. Verify on the first pipeline after adopting the split.
- **`no-new-privileges`.** If RunAI sets it, the setuid sudo cannot work;
  `doctor`'s sudo line answers it on a real pod.
- **CUDA under the real fractioning preloaders.** The preload split is tested
  with a hostile stand-in outside; the proprietary libraries exist only in a
  fractioned pod. `doctor` prints `torch.cuda shell` vs `torch.cuda agent`.
- **sshd bridge** (`pod/sshd-inetd` + `wsl/ssh-bridge.sh`): implemented, only
  provable against a real `runai exec`.
- **nginx site config.** nginx is in the pod closure; what RunAI expects (if
  anything) is unpinned. When known, it belongs in the injection mount.
- **opencode slowness on WSL.** Reported, not diagnosed. Get the log:
  `tail -150 "$(ls -t ~/.local/share/opencode/log/*.log | head -1)"`.
- **Zed `cloud.zed.dev` preflight** on first connect: should not be needed
  with the vendored extensions and the matched server; only the gap proves it.

## `runai exec` never runs the entrypoint

A CRI exec gets image ENV plus pod-spec env, and `HOME=/` for the arbitrary
UID; it never passes through `ENTRYPOINT` and inherits nothing from it. So:

- anything static is image ENV (`assemble.sh`): the closure's session
  variables, `PATH`, `XDG_CACHE_HOME`, `CONTAINERS_STORAGE_CONF`;
- anything resolved at start (who you are, the PVC home, injected CA/pip) is
  resolved once by `pod/entrypoint` and written to
  `/opt/twentyx/etc/session.env` as `export K="v"` lines, which bash and fish
  both parse. Shells (`.bashrc`, `config.fish`, `/etc/profile.d/twentyx.sh`),
  `run-opencode`, `sshd-inetd` and `doctor` source it. Nothing else
  re-derives `HOME`.

code-server works because the base's entrypoint is exec'd *by* ours
(`BASE_ENTRYPOINT`, recorded by `assemble.sh`) and inherits its exports.

## Image assembly rules (silent failures, not build errors)

- `crane mutate --env PATH=...` replaces: the base's `PATH` is read from its
  config and **prepended** to, or torch loses its conda paths.
- `ENTRYPOINT` is replaced (that is how ours runs at all), so the base's is
  stashed in `BASE_ENTRYPOINT` and handed back, or a `vscode-*` workspace
  boots with no IDE. `crane mutate --entrypoint` also clears `CMD`.
- The store image is built under a `-partial` tag and moved by the final
  mutate, so a run that dies halfway never leaves a tag later runs reuse.
- The repo layer is deterministic (`--sort=name --mtime=@1`, owner 0,
  `--mode=g=u`): identical inputs give an identical blob, so a rebuild does
  not upload a new layer. `g=u` + group 0 is the OpenShift arbitrary-UID
  requirement.

## Identity on the shared PVC

Every runtime user is uid 10001/gid 0, and the hostname is
`<workspace>-<n>-<n>`. `SESSION_USER` → the workspace name's first component →
`USERNAME`. A baked identity would file everyone's state into one person's
PVC directory, so none exists; git identity is each user's `~/.gitconfig`
(a real file `link-home` creates empty, so `git config --global` never writes
through the shared `~/.config/git/config` link).

The arbitrary UID has no passwd entry and a nameless gid; the entrypoint
appends them when `/etc/passwd` is writable. If it is not, the durable fix is
a thin derived base:
`RUN chgrp 0 /etc/passwd /etc/group && chmod g+w /etc/passwd /etc/group`.

## The `$HOME` rule

`$HOME` holds links into two roots that update themselves: the dotfiles (pod:
`/opt/twentyx/dotfiles` from the repo layer; WSL: the clone) and
`/opt/twentyx/home-defaults` (binary-coupled defaults from the closure). A
real file is the user's and is never touched. `pod/link-home` is the one
linker on both targets: stow `--no-folding -R` (which also prunes links to
removed files) plus a pass that skips real files and replaces the old
store-era links. stow refuses absolute links inside a package, which is why
the closure's defaults are referenced by path (`opencode.jsonc`'s `skills`
and `plugin`) rather than linked file by file; only `~/.zed_server` and the
pod's code-server extension are linked, once, because their names never
change. Never `stow --adopt`: it moves the user's file into the repo.

`XDG_CACHE_HOME` is deliberately local disk (`/tmp/twentyx-cache`): the PVC
is network-backed, and nvim/LSP/pip caches on it are painfully slow.

## LD_PRELOAD / CUDA split

RunAI injects GPU-fractioning `.so`s through `LD_PRELOAD`; they crash
opencode, but CUDA needs them in everything the agent runs.
`run-opencode` does **not** unset `LD_PRELOAD`: it replaces it with the libc
matching opencode's own glibc (a system libc preloaded into a Nix binary is a
`GLIBC_PRIVATE` symbol error) and stashes the original in
`PRELOAD_ORIGINAL`. Children get it back through
`dotfiles/.config/opencode/plugins/preload.ts` (opencode's `shell.env`) and
`pod/restore-preload.sh` (`BASH_ENV`). Start opencode through
`run-opencode` in pods.

**SIGPIPE trap:** `ldd ... | awk '... exit'` returns 141 under
`set -o pipefail`; every such probe carries `|| true`.

## opencode offline

- **npm stall:** at startup opencode npm-installs `@opencode-ai/plugin` in
  every config dir; with no registry the TUI stalls ~1.5 min. It skips the
  install when the lock names the dependency and `node_modules/` exists:
  `dotfiles/.config/opencode/package-lock.json` + `node_modules/.keep`
  (with a `.gitignore` exception). Re-check when opencode bumps.
- Model fetch, LSP downloads, default plugins and sharing are off through
  the closure's session variables (`OPENCODE_DISABLE_*`).

## sudo

The setuid `sudo` (mode 4555) ships in the store layer at
`/opt/twentyx/bin/sudo`; this repo's layer ships `/etc/sudoers` granting gid
0 passwordless sudo. The sudoers file must be owned by root and not
group-writable, hence the tar's `--owner=0` and its 0440 mode. Nothing needs
sudo to work: the entrypoint's CA refresh is best effort.

## Shell gotchas worth keeping

- **One heredoc per language.** A bash heredoc nested in a generated fish
  file once made fish reject the whole file, so no env reached any pod shell.
  `session.env` is plain `export K="v"` for this reason.
- **tmux panes opened as bash** when the server inherited `BASH_EXECS_FISH`;
  tmux's `default-shell` is the profile fish directly.
- **Shift+Enter in opencode under tmux** needs `extended-keys always` with
  `csi-u` format: opencode asks for the kitty protocol, which tmux does not
  speak, so with `on` it got a plain CR.
- **stow's `--ignore`** is a regex on the target-relative path (no leading
  `/`), anchored at the end.
