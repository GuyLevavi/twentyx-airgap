# WSL update: @RELEASE@

For the inner agent. Read this, then run one command.

## Do this

On every box, as the user, after the release is published (PROTOCOL.md, steps 5-8):

    ~/twentyx/wsl/update.sh

Then open a new shell. update.sh works out how many releases the box is behind
and applies each missing one in order with `apply.sh`. It prints the plan before
changing anything. A box that is two or more releases behind no longer breaks.

For a single release folder on a box one step behind, `sudo ./apply.sh` beside
the files works too. It needs `MANIFEST.txt`, `apply.sh`,
`wsl-<KIND>.nar.tar.gz` and `wsl-needs.txt`.

Both check that the box holds every path the release assumes
(`wsl-needs.txt`) before anything changes. If no release fits, update.sh stops,
writes `~/twentyx-baseline-<date>.store-paths`, and says so. Then either apply a
`-full` release or send that file outside. Do not work around it.

## Full releases (reset)

A release whose id ends in `-full` assumes nothing about the box: `wsl-needs.txt`
is empty and the payload is the whole system. `update.sh <id>-full` takes any box
straight to it, and later deltas build on it.

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

    cat /var/lib/twentyx/release      # = RELEASE
    readlink -f /run/current-system   # = WSL_SYSTEM in MANIFEST.txt
    @WSL_SYSTEM@
    nu -c 'version | get version'; ffprobe -version; python3.10 -V; harlequin --version
    chafa --version; pdftoppm -v      # yazi previews

## Clean up

Remove any stopgap links to store paths, e.g. `rm ~/.local/bin/nu`: they shadow
the profile and dangle after a GC. `apply.sh` also removes the November roots
in `/nix/var/nix/gcroots/twentyx-release`; the system profile holds everything.

## Undo

    sudo nix-env -p /nix/var/nix/profiles/system --rollback
    sudo /nix/var/nix/profiles/system/bin/switch-to-configuration switch

## Next time

Every release is the same: publish it, `update.sh`, new shell.
Pods and repo edits are in `HANDOVER.md`; they do not affect this step.
