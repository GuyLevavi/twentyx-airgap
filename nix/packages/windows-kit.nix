# Windows-side transfer artifacts, pinned like everything else.
#
# .#windows-kit is what physically crosses the gap FOR the Windows machines:
# the WSL2 MSI (so a Store-less, internet-less Windows can still get WSL2),
# the Zed installer pinned to the SAME upstream release as the nixpkgs
# zed-editor in the closure, the Zed theme files and the version-controlled
# client templates (Zed settings, WezTerm config) that used to live only on
# one laptop. Git stays text-only: the binaries are store artifacts fetched
# by hash; the templates are plain files in nix/packages/windows/.
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

  # VS Code (Microsoft, Remote-WSL): the installer the Windows side runs and
  # the raw .vsix files for every pinned extension. Version, commit, URLs and
  # hashes live in nix/vscode-version.nix — one file, one re-pin procedure,
  # and the eval-time check that the nixpkgs code-server pin has not moved.
  vscode = import ../vscode-version.nix { inherit pkgs; };
  vscodeExtensions = import ../vscode-extensions.nix { inherit pkgs; };
  vscodeInstaller = pkgs.fetchurl {
    inherit (vscode.windowsInstaller) url name hash;
  };
  # One symlink per .vsix; Nix interpolates both paths and names.
  vsixInstalls = lib.concatStringsSep "\n" (
    map (ext: ''ln -s ${ext.src} $out/vscode/vsix/${ext.src.name}'') vscodeExtensions
  );

  wslMsi = pkgs.fetchurl {
    # Latest stable WSL2 MSI from github.com/microsoft/WSL releases. Covers
    # Win10 and Win11 without the Microsoft Store or any network.
    url = "https://github.com/microsoft/WSL/releases/download/2.9.12/wsl.2.9.12.0.x64.msi";
    hash = "sha256-WAuLmQBi9kfyxqAvsw/GrBA1DuXhRKVrqwPUGdWfN9Y=";
  };

  # Theme files from the registry extensions the team uses (the /etc/nixos
  # zed.nix list). Zed loads user themes from %APPDATA%\Zed\themes\ — no
  # extension install, no registry access. Pinned to immutable commit SHAs;
  # re-pin by updating the sha in the URL and the hash together.
  themes = {
    "tokyo-night.json" = pkgs.fetchurl {
      url = "https://raw.githubusercontent.com/ssaunderss/zed-tokyo-night/6d731d0724a6fa487f9031cbb4f8db0b80769568/themes/tokyo-night.json";
      hash = "sha256-J5LOOKhNcMPNHb49O8nfY4bpmmmJkhADi0dQdoDotXg=";
    };
    "catppuccin-mauve.json" = pkgs.fetchurl {
      url = "https://raw.githubusercontent.com/catppuccin/zed/4314cb05c74d141b7962290a41d6087e8c0ad02f/themes/catppuccin-mauve.json";
      hash = "sha256-uPE9yx6RT1WWZszww5+iLZ0IrruEYddfiOBaA7uewbE=";
    };
    "catppuccin-no-italics-mauve.json" = pkgs.fetchurl {
      url = "https://raw.githubusercontent.com/catppuccin/zed/4314cb05c74d141b7962290a41d6087e8c0ad02f/themes/catppuccin-no-italics-mauve.json";
      hash = "sha256-Ve+18ICLrfdj+v0jRbZ6lxe1GgrsHZ/du3K2cmpH1ac=";
    };
    "Kanagawa.json" = pkgs.fetchurl {
      url = "https://raw.githubusercontent.com/ethangilmore/zed-kanagawa/e844633f3e64d208459d65f246190491ad0a61df/themes/Kanagawa.json";
      hash = "sha256-+AXR9bB09zgZkadbQYwBxUWgWQpCzcm5jy0DXMouGTM=";
    };
    "Kanagawa-no-italics.json" = pkgs.fetchurl {
      url = "https://raw.githubusercontent.com/ethangilmore/zed-kanagawa/e844633f3e64d208459d65f246190491ad0a61df/themes/Kanagawa-no-italics.json";
      hash = "sha256-oC56j0FKcD4uHf3mIV21MIkt4Qtg/+uMngzPVDcg438=";
    };
    "rose-pine.json" = pkgs.fetchurl {
      url = "https://raw.githubusercontent.com/rose-pine/zed/1446d31a2eec6bee627883d523ec63ef5c78ec9b/themes/rose-pine.json";
      hash = "sha256-pO53YNt5NIRKFBa0PyhQf2lteh7PYWt1G+EcieuMH7w=";
    };
    "rose-pine-dawn.json" = pkgs.fetchurl {
      url = "https://raw.githubusercontent.com/rose-pine/zed/1446d31a2eec6bee627883d523ec63ef5c78ec9b/themes/rose-pine-dawn.json";
      hash = "sha256-+su2Ve+IX+eCh0SNsuZ3qRYeEoQFBkeuOzbXFVOlGio=";
    };
    "rose-pine-moon.json" = pkgs.fetchurl {
      url = "https://raw.githubusercontent.com/rose-pine/zed/1446d31a2eec6bee627883d523ec63ef5c78ec9b/themes/rose-pine-moon.json";
      hash = "sha256-97UMyOW3Dcjcru/Zvl7QfpKT+e0gT1gMllIMlYKRIEA=";
    };
    "nord.json" = pkgs.fetchurl {
      url = "https://raw.githubusercontent.com/mikasius/zed-nord-theme/d0b459c49797aec598622bed992537e4a83688da/themes/nord.json";
      hash = "sha256-CONvCRq35bQe0IQQyMWo9zKleYjqOAJcuovSqQbpuhE=";
    };
    "dracula.json" = pkgs.fetchurl {
      url = "https://raw.githubusercontent.com/dracula/zed/c419d710e77f22ec4e4e8481324b93ef0916d368/themes/dracula.json";
      hash = "sha256-auc7bcSnyxwiZMNv5yOMxj6ejl0qts7NZh8ohAC0n7A=";
    };
    "eldritch.json" = pkgs.fetchurl {
      url = "https://raw.githubusercontent.com/edheltzel/eldritch-zed/e9a9633f15f191fba78dd20c220b6d720c887777/themes/eldritch.json";
      hash = "sha256-o0c9Nxa/LX1ncy8CkpI9Z88if33mU0Iwp6SIGiTsFlo=";
    };
  };

  # One shell line per theme; Nix interpolates both the store path and the
  # file name, the shell only does the copy.
  themeInstalls = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (name: src: ''install -m 0644 ${src} "$out/themes/${name}"'') themes
  );

  kit = pkgs.runCommand "windows-kit-${zedVersion}" { } ''
    mkdir -p $out/themes $out/vscode/vsix
    ln -s ${zedInstaller} $out/Zed-x86_64-${zedVersion}-setup.exe
    ln -s ${wslMsi} $out/wsl.2.9.12.0.x64.msi
    # Version-controlled client templates (repo files, not store paths).
    install -m 0644 ${./windows/zed-client-settings.json} $out/zed-client-settings.json
    install -m 0644 ${./windows/zed-client-settings.personal-example.json} $out/zed-client-settings.personal-example.json
    install -m 0644 ${./windows/wezterm.lua} $out/wezterm.lua
    # VS Code: installer + user-settings template + one .vsix per pinned
    # extension. The SAME vsix files are in the WSL closure, so the server
    # seeds them without ever touching this folder; the copies here are for a
    # Windows-side install or a manual sideload.
    ln -s ${vscodeInstaller} $out/vscode/${vscode.windowsInstaller.name}
    install -m 0644 ${./windows/vscode-settings.json} $out/vscode/vscode-settings.json
    ${vsixInstalls}
    ${themeInstalls}
    cat > $out/README.txt <<'EOF'
    Windows-side artifacts for the airgap (build once on a connected machine,
    carry with the transfer). Nothing here runs on Linux.

      Zed-x86_64-*-setup.exe   Zed for Windows, pinned to the same upstream
                               release as the remote server in the pod/WSL
                               closure. Install it, then copy
                               zed-client-settings.json to
                               %APPDATA%\Zed\settings.json (merge into yours
                               if one exists) -- it pins auto_update off,
                               telemetry off, and the airgap extensions.
                               zed-client-settings.personal-example.json is a
                               fuller client config (vim mode, which-key,
                               Catppuccin, right-docked panels, agent
                               auto-approve) -- copy it INSTEAD if you want
                               that exact setup.

      themes\*.json            Zed themes (Tokyo Night, Catppuccin, Kanagawa,
                               Rose Pine, Nord, Dracula, Eldritch). Copy the
                               whole themes\ folder into %APPDATA%\Zed\themes\
                               and pick one in Zed; no extension install and
                               no registry access needed. Gruvbox ships with
                               Zed itself.

      wezterm.lua              WezTerm config (Tokyo Night, kitty keyboard
                               protocol on -- required for shift+enter in
                               TUIs). Copy to %USERPROFILE%\.wezterm.lua.

      vscode\VSCodeSetup-x64-*.exe
                               VS Code for Windows (Microsoft, Remote-WSL),
                               pinned to the exact release whose Linux server
                               the distro pre-seeds for you. Install it and
                               copy vscode\vscode-settings.json to
                               %APPDATA%\Code\User\settings.json -- it pins
                               updates OFF, which is required: a newer client
                               demands a server the gap cannot download.
                               UNPACK.ps1 installs both for you.

      vscode\vsix\*.vsix       The pinned extensions (ruff, basedpyright,
                               nix-ide, YAML, two themes). setup-wsl.sh
                               installs them into the distro's VS Code server
                               offline; the Marketplace is unreachable here.

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
    kit
    kitTarball
    ;
}
