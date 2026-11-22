# WSL update: @RELEASE@

For the inner agent. Read this, then run one command.

## Do this

    sudo ./apply.sh

Then open a new shell. That is the whole update. It needs only the files
beside it: `MANIFEST.txt`, `apply.sh`, `wsl-delta.nar.tar.gz`, `wsl-needs.txt`.

`apply.sh` checks that the box holds every path the release assumes
(`wsl-needs.txt`). If one is missing it stops before changing anything and
prints the list: send that list outside, do not work around it.

## What it does

Outside builds the box's whole system, `nixos-system-twentyx-wsl`, and ships it
minus what the box already has. `apply.sh` imports it and switches to it:

    nix-env -p /nix/var/nix/profiles/system --set <WSL_SYSTEM>
    <WSL_SYSTEM>/bin/switch-to-configuration switch

Nothing is evaluated or rebuilt inside. There is no flake inside, and none is
needed: do not run `nixos-rebuild`, and do not build from `inside-seed/`
(that flake is outside's and its hostname differs).

## Why November's updates did not show up

The 20261102, 20261103 and 20261118 releases only imported packages and never
switched: they wrongly assumed the box rebuilds from a flake of its own. So
their tools (nushell, harlequin, ffmpeg, python3.10/3.11, open-code-review...)
sat in the store, off PATH. From this release on, every release switches.

## Check

    readlink -f /run/current-system   # = WSL_SYSTEM in MANIFEST.txt
    @WSL_SYSTEM@
    nu -c 'version | get version'; ffprobe -version; python3.10 -V; harlequin --version
    ls /run/current-system/sw/share/nushell/vendor/autoload   # 10-zoxide.nu 20-twentyx.nu

## Config: what comes from where

The release changes the system, never `$HOME`. Your `$HOME` config is inner's
`dotfiles/`, linked by `wsl/link.sh`, as before.

- **nu** needs nothing in `$HOME`: starship, atuin (its jobs left out of
  starship's count), zoxide and direnv load from
  `/run/current-system/sw/share/nushell/vendor/autoload/`. A
  `~/.config/nushell/config.nu` of yours still loads first; drop any
  starship/atuin lines in it, or they run twice.
- **starship** reads inner's `dotfiles/.config/starship.toml`. For the green
  `nu` marker in nu (fish and bash stay unmarked), add:

      [shell]
      disabled = false
      fish_indicator = ""
      bash_indicator = ""
      nu_indicator = "nu "
      style = "bold green"
      format = "[$indicator]($style)"

## Clean up

Remove any stopgap links to store paths, e.g. `rm ~/.local/bin/nu`: they shadow
the profile and dangle after a GC. `apply.sh` also removes the November roots
in `/nix/var/nix/gcroots/twentyx-release`; the system profile holds everything.

## Undo

    sudo nix-env -p /nix/var/nix/profiles/system --rollback
    sudo /nix/var/nix/profiles/system/bin/switch-to-configuration switch

## Next time

Every release is the same: copy the folder, `sudo ./apply.sh`, new shell.
Pods and repo edits are in `HANDOVER.md`; they do not affect this step.
