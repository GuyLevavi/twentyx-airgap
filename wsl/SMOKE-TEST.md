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
| `.json` | jsonls |

```bash
ps -o args= -u jensen | grep -E 'ruff|nixd|taplo|yaml-language|basedpyright|bash-language|vscode-json'
```

Expect real argv: `ruff server`, `taplo lsp stdio`,
`yaml-language-server --stdio`, `basedpyright-langserver --stdio`,
`bash-language-server start`, `vscode-json-language-server --stdio`. A bare
binary printing help (the old failure) means the nvim fix did not land.
Completion: type `vim.` in a `.lua`? (no lua_ls shipped) — type `pri` in a
Python file and expect a completion menu. `:messages` must be clean of LSP
errors.

## 3. Zed (from Windows)

Client settings live in `%APPDATA%\Zed\settings.json` on Windows. Three keys
matter for the airgap and have been added there (2026-09-26):

```jsonc
{
  "auto_update": false,                 // freeze at the kit's pinned version
  "telemetry": { "metrics": false, "diagnostics": false },
  "auto_install_extensions": { "nix": true, "basedpyright": true, "ruff": true }
}
```

Extensions install on the CLIENT and are propagated to the remote server on
connect — the WSL side needs nothing extra. The kit also carries the theme
files (`windows-kit\themes\*.json` → copy to `%APPDATA%\Zed\themes\`) and a
client settings template; without them Zed offers registry downloads for
themes/extensions instead.

**The remote-server lookup is exact-match on the client's full version
string** (`zed-remote-server-stable-<1.17.2+stable.349.c8e44cf...>`, build
metadata included; zed `crates/remote/src/transport/wsl.rs`). The file is
"present" iff running it with `version` exits 0 — the closure ships a shim at
that exact name, pinned in `nix/zed-client-version.nix`. Verify:

```bash
ls -la ~/.zed_server/                    # the full-version name must be there
ls -l ~/.config/zed/settings.json        # symlink into /nix/store = our default
grep -o '"path": "[^"]*"' ~/.config/zed/settings.json | head
```

A REAL settings.json (not a symlink) wins over the packaged default — by
design, it is the user's file. If yours is real, merge the `lsp` + `languages`
blocks from the packaged default into it, or the pins do not apply.

Pass signals (this is what the pins buy):

```bash
ls ~/.local/share/zed/node 2>/dev/null          # absent = no Node download
ls ~/.local/share/zed/languages 2>/dev/null     # absent = no npm/GitHub LSPs
grep -ri 'downloading\|uploading remote server' ~/.local/share/zed/logs/ 2>/dev/null
```

Measured on the connected laptop (2026-09-26): with the default shadowed, Zed
downloaded Node.js, the basedpyright npm package and the ruff release tarball
— exactly the runtime fetches the gap forbids. If you see any of those again,
the log line names the thing that was missing; report it verbatim.

Connect a Zed WSL project; opening a Python file must attach
`basedpyright-langserver` from `/nix/store` (see §2 ps) and nothing may
download. The full-version shim, not the pins, is what stops the
first-connect server upload — if the client's log shows
`uploading remote server to WSL "..."`, the name in that line is the version
string to re-pin in `nix/zed-client-version.nix`.

All declared servers are pinned by store path: nixd, basedpyright, ruff,
json-language-server, bash-language-server, yaml-language-server (schema
store disabled — opening a `.yaml` must not fetch schemastore.org), tombi
(TOML; the `toml` extension is syntax-only since 1.0.3, Tombi is the server).
Terminal Threads: agent panel → New Thread → Terminal must start opencode by
itself (`agent.terminal_init_command` in the packaged settings).

## 4. opencode

```bash
opencode --version
echo "$TERM $TERM_PROGRAM"               # terminal identity, see §5
```

- **Theme**: in the TUI run `/theme` to list and pick; it persists to your
  config (`~/.config/opencode/opencode.json` → `"theme": "<name>"`). The
  packaged default is opencode's own; the repo deliberately does not ship
  your config.
- **shift+enter**: reaches the TUI only if the terminal reports the kitty
  keyboard protocol. Your WezTerm now enables it (`config.enable_kitty_keyboard
  = true`, see §5) — restart WezTerm and re-test; the nvim warning "modes
  2026/2027/2031/2048 unavailable" should disappear. `echo $TERM_PROGRAM`
  tells you which terminal you are in.
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

## 9. Editors from Windows (Zed WSL remote is the path)

Zed's WSL integration needs no SSH setup: it spawns the server itself (see
§3). The SSH bridge remains for the pod side and as a fallback — see
`wsl/README.md` "SSH, both directions": keys, `gl@localhost`.

VS Code was dropped from the kit and the image (2026-09-26): the pre-seeded
server cost ~500 MB in the image and ~220 MB in the kit, and Zed's WSL remote
covers the same workflow. To bring it back, re-add the installer + server
tarball to `nix/packages/windows-kit.nix` and the seed to `nix/hosts/wsl.nix`.

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
