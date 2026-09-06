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
    vscode-server = {
      url = "github:nix-community/nixos-vscode-server";
      inputs.nixpkgs.follows = "nixpkgs";
    };

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
      lazyvim,
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

      mkRunai =
        { nvim }:
        home-manager.lib.homeManagerConfiguration {
          inherit pkgs;
          extraSpecialArgs = {
            inherit inputs;
            username = "jensen";
          };
          modules = [
            ./nix/modules/home.nix
            {
              airgap.target = "runai";
              airgap.nvim.enable = nvim;
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
      # Two flavors, because nvim roughly doubles the layer and not every
      # workspace wants an editor in it.
      homeConfigurations = {
        runai = mkRunai { nvim = false; };
        runai-nvim = mkRunai { nvim = true; };
      };

      packages.${system} = {
        runai-layer = pkgs.callPackage ./nix/runai/layer.nix {
          hm = self.homeConfigurations.runai;
        };
        runai-layer-nvim = pkgs.callPackage ./nix/runai/layer.nix {
          hm = self.homeConfigurations.runai-nvim;
        };
        default = self.packages.${system}.runai-layer;
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
