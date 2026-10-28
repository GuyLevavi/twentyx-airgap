{
  description = "twentyx-airgap — headless workspace toolchain for airgapped WSL + RunAI";

  inputs = {
    # Pinned deliberately. `nix flake update` runs ONLY on the connected
    # machine; inside the airgap the lock is law, because a changed input is a
    # physical transfer, not a download.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixos-wsl = {
      url = "github:nix-community/NixOS-WSL";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # VS Code Server ships a prebuilt node that hardcodes
    # /lib64/ld-linux-x86-64.so.2, which does not exist on NixOS. Without this
    # module, connecting VS Code (Windows) to NixOS-WSL hangs forever on
    # "Setting up VS Code Server" — the exact thing that works today only
    # because Fedora is FHS.
    # No `follows`: this flake declares no nixpkgs input, and overriding a
    # non-existent one is a warning on every single evaluation.
    vscode-server.url = "github:nix-community/nixos-vscode-server";

    lazyvim = {
      url = "github:pfassina/lazyvim-nix/v16.0.0";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      home-manager,
      nixos-wsl,
      vscode-server,
      ...
    }@inputs:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };

      # The username differs per target: `gl` in WSL, resolved at runtime from
      # the RunAI workspace name in a pod. Only the WSL side needs it at eval.
      username = "gl";

      runaiHome = home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        extraSpecialArgs = {
          inherit inputs;
          username = "jensen";
        };
        modules = [
          ./nix/modules/home.nix
          {
            airgap.target = "runai";
            home.username = "jensen";
            # Replaced at runtime by airgap-bootstrap once the workspace name
            # resolves; at eval time it only has to be *a* path.
            home.homeDirectory = "/home/jensen";
          }
        ];
      };
    in
    {
      # ── WSL: a full NixOS system, rebuilt offline ──────────────────────
      nixosConfigurations.wsl = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit inputs username; };
        modules = [
          nixos-wsl.nixosModules.default
          vscode-server.nixosModules.default
          home-manager.nixosModules.home-manager
          ./nix/hosts/wsl.nix
          {
            home-manager = {
              useGlobalPkgs = true;
              useUserPackages = true;
              backupFileExtension = "hm-bak";
              extraSpecialArgs = { inherit inputs username; };
              users.${username} = {
                imports = [ ./nix/modules/home.nix ];
                airgap.target = "wsl";
              };
            };
          }
        ];
      };

      # ── RunAI: evaluated HERE, never inside. Nothing below ever runs Nix
      # in a pod; we extract the built tree and ship it as an OCI layer.
      #
      # One flavor, with the editor. A second, editor-less layer existed to
      # save the ~250 MB nvim costs, but every workspace inside ended up on
      # the nvim one, and two layers meant two deltas per transfer. The
      # `-nvim` names stay: they are what is already in Artifactory, and the
      # image tags people pull.
      homeConfigurations.runai-nvim = runaiHome;

      packages.${system} = {
        runai-layer-nvim = pkgs.callPackage ./nix/runai/layer.nix {
          hm = self.homeConfigurations.runai-nvim;
        };
        default = self.packages.${system}.runai-layer-nvim;

        # ── the very first transfer ────────────────────────────────────────
        # Chicken and egg: nix-import.sh needs a NixOS-WSL machine, and there
        # is not one yet. This builds the rootfs tarball that `wsl --import`
        # takes, so the airgapped laptop can be created from a Windows shell
        # with no Nix anywhere on it.
        #
        #   nix build .#wsl-tarball
        #   sudo ./result/bin/nixos-wsl-tarball-builder     # -> nixos.wsl
        #
        # It runs as root because it assembles a filesystem image; it does not
        # touch the running system.
        wsl-tarball = self.nixosConfigurations.wsl.config.system.build.tarballBuilder;
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
