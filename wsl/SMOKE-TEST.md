# WSL smoke test: everything to verify, in order

Companion to `wsl/FIRST-BOOT.md` (why the first boot failed) and
`wsl/README.md` (install + no-WWW rehearsal). This is the "did I miss
anything" list: every capability the toolchain promises, the command that
proves it, and what a failure means.

Run everything from a `jensen` shell unless a line says root
(`wsl -d twentyx -u root -- ...`).

## 0. First boot sanity

```bash
whoami                               # jensen
stat -c '%a %U:%G' / /home /home/jensen   # 755 root:root, 755, 700 jensen:users
systemctl --failed                   # expect: no failed units
cat /var/log/bootlog.txt | head -40   # the automatic boot evidence
```

If `systemctl --failed` shows anything, that file already contains the
journal head and the reasons; report it.

## 1. Offline rebuild (the durable path — do this once)

This is what makes config edits cheap forever after; it needs the
`wsl-rebuild.tar.gz` + `repo-src.tar.gz` carried from the build host (already
in `C:\twentyx` if the transfer shipped them).

```bash
# as root (one-time; imports the eval inputs + stdenvNoCC into the store)
wsl -d twentyx -u root -- bash -lc '
  mkdir -p /root/twentyx /var/cache/nix-transfer
  tar -xzf /mnt/c/twentyx/repo-src.tar.gz -C /root/twentyx
  tar -xzf /mnt/c/twentyx/wsl-rebuild.tar.gz -C /var/cache/nix-transfer --strip-components=1
  nix copy --from file:///var/cache/nix-transfer --all
  nixos-rebuild switch --flake /root/twentyx#wsl
'
```

Verify it is genuinely offline: run the "no WWW" rehearsal
(`wsl/README.md`) and repeat a config-only edit — change a string in
`nix/modules/shell.nix`, then

```bash
wsl -d twentyx -u root -- nixos-rebuild switch --flake /root/twentyx#wsl
```

It must finish without any fetch. This is the property the whole Nix choice
buys; test it before trusting it in the gap.

## 2. nvim

```bash
nvim --version | head -2                       # 0.12.x from the closure
:checkhealth vim.lsp                            # all six servers: found
:lua =vim.lsp.get_clients()                     # after opening a file
```

| file to open | server that must attach |
|---|---|
| `.py` | basedpyright + ruff |
| `.nix` | nixd |
| `.yaml` | yamlls |
| `.toml` | taplo |
| `.sh` | bashls |

```bash
ps -o args= -u jensen | grep -E 'ruff|nixd|taplo|yaml-language|basedpyright|bash-language'
```

Expect real argv: `ruff server`, `taplo lsp stdio`,
`yaml-language-server --stdio`, `basedpyright-langserver --stdio`,
`bash-language-server start`. A bare binary printing help (the old failure)
means the nvim fix did not land. Completion: type `vim.` in a `.lua`? (no
lua_ls shipped) — type `pri` in a Python file and expect a completion menu.
`:messages` must be clean of LSP errors.

## 3. Zed (from Windows)

Client settings live in `%APPDATA%\Zed\settings.json` on Windows — set:

```jsonc
{ "auto_update": false, "telemetry": { "metrics": false, "diagnostics": false } }
```

The WSL side ships `~/.config/zed/settings.json` (packaged default) with the
LSP binaries pinned to closure paths, so the remote server never downloads a
language server. Check that:

```bash
ls -l ~/.config/zed/settings.json        # symlink into /nix/store
grep -o '"path": "[^"]*"' ~/.config/zed/settings.json | head
ls -la ~/.zed_server/                    # server + shims, mtimes OLD
ls -la ~/.local/share/zed/logs/ 2>/dev/null   # remote logs, if any
grep -ri 'download' ~/.local/share/zed/logs/ 2>/dev/null | head
```

Connect a Zed WSL project; opening a Python file must attach
`basedpyright-langserver` (see §2 ps) and nothing should spawn a download.
If Zed still tries to fetch something, note *what* and its log line — that
tells us which setting is missing.

## 4. opencode

```bash
opencode --version
echo "$TERM $TERM_PROGRAM"               # terminal identity, see §5
```

- **Theme**: in the TUI run `/theme` to list and pick; it persists to your
  config (`~/.config/opencode/opencode.json` → `"theme": "<name>"`). The
  packaged default is opencode's own; the repo deliberately does not ship
  your config.
- **shift+enter**: only reaches the TUI if the terminal reports the kitty
  keyboard protocol. The nvim warning "modes 2026/2027/2031/2048 unavailable"
  in your log says the terminal you used does not. Run it under WezTerm
  (supports it) or Windows Terminal ≥ 1.18; `echo $TERM_PROGRAM` tells you
  which you are in.
- **ACP into Zed**: Zed → agent OpenCode (§3) must start without network.

## 5. Terminal / WezTerm

You already run WezTerm with `default_domain = "WSL:twentyx"` and Tokyo Night
(`C:\Users\guyle\.wezterm.lua`; a dotfiles copy lives under
`Projects/dotfiles-wsl-main/wezterm/`). The one missing setting was the kitty
keyboard protocol; it has been added to both:

```lua
config.enable_kitty_keyboard = true
```

Restart WezTerm, then re-test shift+enter in opencode — and the nvim warning
about modes 2026/2027/2031/2048 should disappear. The theme chain now matches
end to end: WezTerm Tokyo Night → btop `tokyo-night` → opencode
`"theme": "tokyonight"`.

```bash
echo $TERM_PROGRAM $TERM                 # confirm which terminal the session is in
```

## 6. btop

```bash
btop   # colors: tokyo-night; background: your terminal's own
cat ~/.config/btop/btop.conf     # packaged default; replace with a real file to change
```

## 7. Python

```bash
python3 --version    # 3.12 only -- deliberate (tools.nix): one interpreter,
python3 -m pip --version  # uv manages envs; the closure does not ship 3.11
uv --version
```

If a project pins 3.11: `uv venv --python 3.11` needs an interpreter uv
already manages (`uv python list`); there is no network in the gap, so
"download a Python" is not a thing here. If 3.11 must exist, add `python311`
to `tools.nix` and re-transfer — by design, a physical transfer.

## 8. Podman / containers

```bash
podman info
podman run --rm -it alpine:latest echo hello   # only if the image is local
```

Offline means no pulls: images must arrive as archives. Verify whichever
images you carried (`podman images`, `podman load`).

## 9. Editors from Windows over SSH (if not using Zed's WSL project)

See `wsl/README.md` "SSH, both directions": keys, `gl@localhost`, VS Code
Remote-SSH. Zed's own WSL integration needs none of it (it spawns the server
itself), but the SSH path is the fallback and the one the pod side uses.

## 10. Nix itself

```bash
nixos-version
nix --version
nixos-rebuild --flake /root/twentyx#wsl dry-activate   # eval-only sanity
git config --global user.email you@work                    # once
```

Rebuilds must never hang: `nix.settings.connect-timeout = 5` and the
substituter is the local cache. A hang means something tried the network.

## 11. What to report back

If any step fails: the command, the output, and — for anything boot/session
related — `cat /var/log/bootlog.txt`. Everything in this file is
either already covered by the boot log or is a copy-pasteable command; a
report that includes the command and its output is enough to act on.
