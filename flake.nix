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
        wsl:
        import ./nix/profile.nix {
          inherit pkgs inputs wsl;
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

      # ── what scripts/transfer builds, here AND at base.rev ───────────────
      # The attribute names are the contract between a transfer and its base:
      # the script builds both from `git+file:.?rev=<base.rev>`, so renaming
      # one needs a --rebase. Nothing below ever runs Nix in a pod.
      packages.${system} = {
        # The pod's /opt/twentyx tree + closure list; scripts/pod-tar.sh packs
        # it with the store paths as an OCI layer.
        pod-opt = pkgs.callPackage ./nix/runai/layer.nix (mkProfile false);

        # The WSL system; its closure ships as a NAR (install/apply.sh).
        wsl-system = self.nixosConfigurations.wsl.config.system.build.toplevel;

        # ── the very first install ───────────────────────────────────────
        # The rootfs tarball `wsl --import` takes, built from base.rev so a
        # fresh machine has the base every delta is computed against. The
        # upstream builder, run under sudo:
        #   sudo ./result/bin/nixos-wsl-tarball-builder nixos-wsl.tar.gz
        wsl-tarball = self.nixosConfigurations.wsl.config.system.build.tarballBuilder;

        # ── the Windows-side half of the first install ──────────────────
        # WSL2 MSI + the Zed, VS Code and WezTerm installers, shipped as ONE
        # tar.gz. See nix/packages/windows-kit.nix for the re-pin procedure.
        windows-kit =
          (pkgs.callPackage ./nix/packages/windows-kit.nix {
            zedVersion = pkgs.zed-editor.version;
          }).kitTarball;

        default = self.packages.${system}.pod-opt;
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
          p7zip
          jq
        ];
      };
    };
}
