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
# and paste the reported hash. One commit.
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

  kit = pkgs.runCommand "windows-kit-${zedVersion}" { } ''
    mkdir $out
    ln -s ${zedInstaller} $out/Zed-x86_64-${zedVersion}-setup.exe
    ln -s ${wslMsi} $out/wsl.2.9.12.0.x64.msi
    cat > $out/README.txt <<'EOF'
    Windows-side artifacts for the airgap (build once on a connected machine,
    carry with the transfer). Nothing here runs on Linux.

      Zed-x86_64-*-setup.exe   Zed for Windows, pinned to the same upstream
                               release as the remote server in the pod/WSL
                               closure. Install it, and in Zed settings set
                               "auto_update": false -- the remote server in
                               the images moves only when this pin moves.

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
in
{
  inherit zedInstaller wslMsi kit;
}
