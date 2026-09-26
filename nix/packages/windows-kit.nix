# Windows-side transfer artifacts, pinned like everything else.
#
# .#windows-kit is what physically crosses the gap FOR the Windows machines:
# the WSL2 MSI (so a Store-less, internet-less Windows can still get WSL2)
# and the Zed installer pinned to the SAME upstream release as the nixpkgs
# zed-editor in the closure -- client and remote server match by
# construction, and nothing ever downloads at runtime. Git stays text-only:
# these are store artifacts, fetched by hash like every other input.
#
# Re-pin when nixpkgs bumps zed-editor (or a new WSL stable is wanted):
# change the version in the URL, run
#     nix store prefetch-file --json <url>
# and paste the reported hash. One commit. Also update
# nix/zed-client-version.nix in the SAME commit — the remote-server lookup is
# keyed on the client's full version string, so a kit bump without it makes
# the first offline Zed connect download its server.
{
  lib,
  pkgs,
  zedVersion,
}:
let
  zedInstaller = pkgs.fetchurl {
    url = "https://github.com/zed-industries/zed/releases/download/v${zedVersion}/Zed-x86_64.exe";
    hash = "sha256-Ts5mC3Hmt5BJcAJ82gxXS1R1Vcn7dFly7RVPacG6NpI=";
  };

  wslMsi = pkgs.fetchurl {
    # Latest stable WSL2 MSI from github.com/microsoft/WSL releases. Covers
    # Win10 and Win11 without the Microsoft Store or any network.
    url = "https://github.com/microsoft/WSL/releases/download/2.9.12/wsl.2.9.12.0.x64.msi";
    hash = "sha256-WAuLmQBi9kfyxqAvsw/GrBA1DuXhRKVrqwPUGdWfN9Y=";
  };

  # VS Code: the installer the team installs, and the Linux server tarball
  # for the SAME release (its commit), which nix/hosts/wsl.nix pre-seeds into
  # ~/.vscode-server -- Remote-SSH works on first connect with no Store and
  # no network. Re-pin in lockstep when VS Code updates: bump the version,
  # fetch both URLs, re-pin the hashes and the commit in wsl.nix.
  vscodeVersion = "1.139.0";
  vscodeCommit = "2242ebbb54efeeb0129e08e919e7e8d43033cd83";
  vscodeInstaller = pkgs.fetchurl {
    url = "https://update.code.visualstudio.com/${vscodeVersion}/win32-x64/stable";
    hash = "sha256-+IXC5n1W8E26LVyp9Oc6fcsS3+p/1ByHNc9FHjIS5Tw=";
  };
  vscodeServerTar = pkgs.fetchurl {
    url = "https://update.code.visualstudio.com/commit:${vscodeCommit}/server-linux-x64/stable";
    hash = "sha256-PBn/HVMPX9GLJwj4A/Iz3gTIFI6tQeJbednkvQHRonw=";
  };

  kit = pkgs.runCommand "windows-kit-${zedVersion}" { } ''
    mkdir $out
    ln -s ${zedInstaller} $out/Zed-x86_64-${zedVersion}-setup.exe
    ln -s ${wslMsi} $out/wsl.2.9.12.0.x64.msi
    ln -s ${vscodeInstaller} $out/VSCodeSetup-x64-${vscodeVersion}.exe
    cat > $out/README.txt <<'EOF'
    Windows-side artifacts for the airgap (build once on a connected machine,
    carry with the transfer). Nothing here runs on Linux.

      Zed-x86_64-*-setup.exe   Zed for Windows, pinned to the same upstream
                               release as the remote server in the pod/WSL
                               closure. Install it, and in Zed settings set
                               "auto_update": false -- the remote server in
                               the images moves only when this pin moves.

      VSCodeSetup-x64-*.exe    VS Code for Windows, pinned to the release the
                               WSL machine pre-seeds its vscode-server for
                               (same version + commit). Set
                               "update.mode": "none" in VS Code settings.

      wsl.*.x64.msi            WSL2 itself, for Windows boxes with no Store
                               and no internet. Setup order: the two DISM
                               feature lines (Microsoft-Windows-Subsystem-
                               Linux, VirtualMachinePlatform), reboot, then
                               msiexec /i wsl.*.x64.msi, then
                               wsl --set-default-version 2. See MANUAL.md.

      (the NixOS-WSL root tarball is a separate flake output: nix build
       .#wsl-tarball -- see MANUAL.md section 1)
    EOF
  '';
  # The kit as ONE archive: no bare .exe/.msi ever crosses the gap in a
  # transfer or an email attachment — Windows 10/11 ships tar.exe (bsdtar),
  # so extraction needs nothing installed:
  #     tar -xf windows-kit.tar.gz
  kitTarball = pkgs.runCommand "windows-kit-${zedVersion}.tar.gz" { } ''
    mkdir bundle
    ln -s ${kit} bundle/windows-kit
    # -h dereferences the store symlinks into real bytes; sort+fixed
    # mtime+owner keep the bytes reproducible.
    tar -C bundle \
      -c -h --sort=name --mtime='@1' --owner=0 --group=0 \
      windows-kit \
      | gzip -n > $out
  '';
in
{
  inherit
    zedInstaller
    wslMsi
    vscodeInstaller
    vscodeServerTar
    kit
    kitTarball
    ;
}
