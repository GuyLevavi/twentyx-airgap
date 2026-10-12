# Windows-side transfer artifacts, pinned like everything else.
#
# .#windows-kit is what physically crosses the gap FOR the Windows machines:
# the WSL2 MSI (so a Store-less, internet-less Windows can still get WSL2),
# the WezTerm installer, the Zed installer pinned to the SAME upstream release
# as the nixpkgs zed-editor in the closure, the Zed theme files and the
# version-controlled client templates (Zed settings, WezTerm config) that used
# to live only on one laptop. Git stays text-only: the binaries are store artifacts fetched
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

  # WezTerm for Windows: the terminal the kit's wezterm.lua configures.
  # Nightly, not the 2024 stable: upstream publishes it under one moving asset
  # name, so the hash pins whatever was current on the date in `name`. A
  # fetched copy stays in the store, so rebuilds are cache hits; when the
  # store has lost it the fetch fails on the hash. Re-pin at a rebase:
  #     nix store prefetch-file --json --name WezTerm-nightly-<yyyymmdd>-setup.exe <url>
  # and paste the name date + hash.
  weztermInstaller = pkgs.fetchurl {
    name = "WezTerm-nightly-20261013-setup.exe";
    url = "https://github.com/wez/wezterm/releases/download/nightly/WezTerm-nightly-setup.exe";
    hash = "sha256-WVhQCIhyMFedpCmegeBU+o96mD3ZcsGa1YI09qRXp3k=";
  };

  wslMsi = pkgs.fetchurl {
    # Latest stable WSL2 MSI from github.com/microsoft/WSL releases. Covers
    # Win10 and Win11 without the Microsoft Store or any network.
    url = "https://github.com/microsoft/WSL/releases/download/2.9.12/wsl.2.9.12.0.x64.msi";
    hash = "sha256-WAuLmQBi9kfyxqAvsw/GrBA1DuXhRKVrqwPUGdWfN9Y=";
  };

  # Zed extensions, vendored for the client. The remote server has built-in
  # adapters for basedpyright, ruff, json, yaml, bash and
  # package-version-server; nixd and tombi are NOT built in, so those
  # extensions must exist client-side and are uploaded to the remote on
  # connect. Re-pin: fetch https://api.zed.dev/extensions/<id>, take the last
  # version, prefetch the download URL, paste the hash.
  zedExtensions = {
    nix = pkgs.fetchurl {
      name = "nix.tar.gz";
      url = "https://api.zed.dev/extensions/nix/download?version=0.1.5";
      hash = "sha256-tdpTAcwrY98Bkty++AaMRa+hmEoipNaoqWnBfjrdRTg=";
    };
    toml = pkgs.fetchurl {
      name = "toml.tar.gz";
      url = "https://api.zed.dev/extensions/toml/download?version=1.0.3";
      hash = "sha256-zqpESXTk1tqLnHe6j+o+qO8JU+r2elaItbHZJF015o4=";
    };
    tombi = pkgs.fetchurl {
      name = "tombi.tar.gz";
      url = "https://api.zed.dev/extensions/tombi/download?version=0.2.4";
      hash = "sha256-Mg6jSGiPwophNnhy2pCcFdkFjIxJe7v9AYc62BWTIZg=";
    };
    dockerfile = pkgs.fetchurl {
      name = "dockerfile.tar.gz";
      url = "https://api.zed.dev/extensions/dockerfile/download?version=0.3.0";
      hash = "sha256-hkNVh2B0qazsvWS8jtTjQnP5ToinpYB4ycOqlKwqo2Q=";
    };
    env = pkgs.fetchurl {
      name = "env.tar.gz";
      url = "https://api.zed.dev/extensions/env/download?version=0.0.2";
      hash = "sha256-rntsB2OD9vMgaQv7g6FOanQNfBEkhYu12dtBoaHrtqY=";
    };
  };
  zedExtensionInstalls = lib.concatMapStrings (id: ''
    ln -s ${zedExtensions.${id}} "$out/zed-extensions/${id}.tar.gz"
  '') (lib.attrNames zedExtensions);

  # Theme files from the extensions the team uses. Zed loads user themes from
  # %APPDATA%\Zed\themes\ -- no extension install, no registry access. Pinned
  # to immutable commit SHAs; re-pin by updating the sha in the URL and the
  # hash together.
  themes = {
    "tokyo-night.json" = pkgs.fetchurl {
      url = "https://raw.githubusercontent.com/ssaunderss/zed-tokyo-night/6d731d0724a6fa487f9031cbb4f8db0b80769568/themes/tokyo-night.json";
      hash = "sha256-J5LOOKhNcMPNHb49O8nfY4bpmmmJkhADi0dQdoDotXg=";
    };
    "catppuccin-mauve.json" = pkgs.fetchurl {
      url = "https://raw.githubusercontent.com/catppuccin/zed/4314cb05c74d141b7962290a41d6087e8c0ad02f/themes/catppuccin-mauve.json";
      hash = "sha256-uPE9yx6RT1WWZszww5+iLZ0IrruEYddfiOBaA7uewbE=";
    };
  };

  # One shell line per theme; Nix interpolates both the store path and the
  # file name, the shell only does the copy.
  themeInstalls = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (name: src: ''install -m 0644 ${src} "$out/themes/${name}"'') themes
  );

  kit = pkgs.runCommand "windows-kit-${zedVersion}" { } ''
    mkdir -p $out/themes $out/vscode/vsix $out/zed-extensions
    ln -s ${zedInstaller} $out/Zed-x86_64-${zedVersion}-setup.exe
    ln -s ${wslMsi} $out/${wslMsi.name}
    ln -s ${weztermInstaller} $out/${weztermInstaller.name}
    # Version-controlled client templates (repo files, not store paths).
    install -m 0644 ${./windows/zed-client-settings.json} $out/zed-client-settings.json
    install -m 0644 ${./windows/wezterm.lua} $out/wezterm.lua
    ${zedExtensionInstalls}
    # VS Code: installer + user-settings template + one .vsix per pinned
    # extension. The SAME vsix files are in the WSL closure, so the server
    # seeds them without ever touching this folder; the copies here are for a
    # Windows-side install or a manual sideload.
    ln -s ${vscodeInstaller} $out/vscode/${vscode.windowsInstaller.name}
    install -m 0644 ${./windows/vscode-settings.json} $out/vscode/vscode-settings.json
    ${vsixInstalls}
    ${themeInstalls}
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
  inherit kitTarball;
}
