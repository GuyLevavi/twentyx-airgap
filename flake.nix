{
  description = "twentyx-airgap — headless workspace toolchain for airgapped WSL + RunAI";

  inputs = {
    # Pinned deliberately. `nix flake update` runs ONLY on the connected
    # machine; inside the airgap the lock is law, because a changed input is a
    # physical transfer, not a download.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    nixos-wsl = {
      url = "github:nix-community/NixOS-WSL";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Vendored into the store by nix/profile.nix (no flake.nix upstream).
    # Pinned to the same revision the owner uses; the agents in the gap lose
    # every workflow without them.
    matt-skills = {
      url = "github:mattpocock/skills";
      flake = false;
    };

    # workmux: package, tmux integration and the opencode status plugin all
    # come from this ONE revision, so the plugin can never skew from the
    # binary. nixpkgs follows, so no second nixpkgs closure.
    workmux = {
      url = "github:raine/workmux";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Remote-WSL support for the Microsoft VS Code server: a user service
    # that patches each freshly installed server's bundled node for NixOS.
    # The server and the extension set themselves are pinned in
    # nix/vscode-version.nix and nix/vscode-extensions.nix -- this input is
    # only the patch mechanism.
    nixos-vscode-server = {
      url = "github:nix-community/nixos-vscode-server";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      nixos-wsl,
      ...
    }@inputs:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };

      # One profile builder for both targets. `wsl` only flips WSL-only
      # packages and locale vars; the pod layer takes the same attrs.
      mkProfile =
        { wsl, nvim }:
        import ./nix/profile.nix {
          inherit
            pkgs
            inputs
            wsl
            nvim
            ;
          lib = nixpkgs.lib;
        };
    in
    {
      # ── WSL: a full NixOS system ────────────────────────────────────────
      nixosConfigurations.wsl = nixpkgs.lib.nixosSystem {
        inherit system;
        # nix/hosts/wsl.nix imports nix/profile.nix, which needs the flake
        # inputs (matt-skills, workmux).
        specialArgs = { inherit inputs; };
        modules = [
          nixos-wsl.nixosModules.default
          ./nix/hosts/wsl.nix
        ];
      };

      # ── RunAI: evaluated HERE, never inside. Nothing below ever runs Nix
      # in a pod; we extract the built tree and ship it as an OCI layer.
      packages.${system} = {
        runai-layer = pkgs.callPackage ./nix/runai/layer.nix (mkProfile {
          wsl = false;
          nvim = false;
        });
        runai-layer-nvim = pkgs.callPackage ./nix/runai/layer.nix (mkProfile {
          wsl = false;
          nvim = true;
        });
        default = self.packages.${system}.runai-layer;

        # ── the very first transfer ────────────────────────────────────────
        # Chicken and egg: a NixOS-WSL machine is needed to build one, and
        # there is not one yet. This builds the rootfs tarball that
        # `wsl --import` takes.
        #
        # No sudo: the upstream builder demands EUID 0 for its chroot and bind
        # mounts, so the wrapper re-execs it inside a user namespace. Set
        # NO_UNSHARE=1 to skip the namespace if a caller genuinely is root.
        wsl-tarball =
          let
            inner = self.nixosConfigurations.wsl.config.system.build.tarballBuilder;
          in
          pkgs.writeShellScriptBin "nixos-wsl-tarball-builder" ''
            if [ "$(id -u)" = 0 ] || [ -n "''${NO_UNSHARE:-}" ]; then
              exec ${inner}/bin/nixos-wsl-tarball-builder "$@"
            fi
            exec ${pkgs.util-linux}/bin/unshare -rm ${inner}/bin/nixos-wsl-tarball-builder "$@"
          '';

        # ── the Windows-side half of the first transfer ───────────────────
        # WSL2 MSI + the Zed installer pinned to the same upstream release as
        # the closure's zed-editor, shipped as ONE tar.gz. See
        # nix/packages/windows-kit.nix for the re-pin procedure.
        windows-kit =
          (pkgs.callPackage ./nix/packages/windows-kit.nix {
            zedVersion = pkgs.zed-editor.version;
          }).kitTarball;
      };

      devShells.${system}.default = pkgs.mkShell {
        packages = with pkgs; [
          nix-tree
          nixfmt
          statix
          deadnix
          shellcheck
          shfmt
          go-containerregistry
          skopeo
          dive
          jq
        ];
      };
    };
}
