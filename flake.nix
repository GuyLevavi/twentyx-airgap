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

      # The WSL username is PER MACHINE, by design: the toolchain is
      # distributed to a team, each member importing their own tarball under
      # their own Windows user. It is a cheap config line, not a closure
      # decision: put the username (one word) in a gitignored file next to
      # the flake and it takes precedence -- `echo alice > wsl-username`,
      # then `nix build .#wsl-tarball`. No file means the owner's default.
      # The pod side never sees this: in a RunAI pod the identity is
      # resolved at runtime from the workspace name (see airgap_user).
      username =
        let
          f = ./wsl-username;
        in
        if builtins.pathExists f
        then builtins.replaceStrings [ "\n" "\r" ] [ "" "" ] (builtins.readFile f)
        else "gl";

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

        # ── the Windows-side half of the first transfer ───────────────────
        # WSL2 MSI (Store-less Windows) + the Zed installer pinned to the
        # same upstream release as the closure's zed-editor, so the remote
        # client and server match by construction. See
        # nix/packages/windows-kit.nix for the re-pin procedure.
        windows-kit =
          (pkgs.callPackage ./nix/packages/windows-kit.nix {
            zedVersion = pkgs.zed-editor.version;
          }).kit;
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
