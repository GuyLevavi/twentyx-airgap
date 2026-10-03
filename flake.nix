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

    # Vendored into the store by nix/modules/skills.nix (no flake.nix
    # upstream). Same source as /etc/nixos, pinned to the same revision the
    # owner uses -- the agents in the gap lose every workflow without them.
    matt-skills = {
      url = "github:mattpocock/skills";
      flake = false;
    };

    # workmux: worktrees + tmux windows for parallel agents. Package, tmux
    # integration and the opencode status plugin all come from this ONE
    # revision (nix/modules/shell.nix), so the plugin can never skew from the
    # binary. nixpkgs follows, so no second nixpkgs closure.
    workmux = {
      url = "github:raine/workmux";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Remote-WSL support for the Microsoft VS Code server: a user service
    # that patches each freshly installed server's bundled node for NixOS
    # (interpreter, RPATH, the vsce-sign libssl dependency). The server and
    # the extension set themselves are pinned in nix/vscode-version.nix and
    # nix/vscode-extensions.nix -- this input is only the patch mechanism.
    nixos-vscode-server = {
      url = "github:nix-community/nixos-vscode-server";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      home-manager,
      nixos-wsl,
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
      # then `nix build .#wsl-tarball`. The file mechanism only bites in a
      # PLAIN-DIRECTORY copy of the flake (a git checkout excludes ignored
      # files from the source tree, so there the default is what ships —
      # which is why the owner default is jensen, matching the pod side).
      # The pod side never sees this: in a RunAI pod the identity is
      # resolved at runtime from the workspace name (see session_user).
      username =
        let
          f = ./wsl-username;
        in
        if builtins.pathExists f
        then builtins.replaceStrings [ "\n" "\r" ] [ "" "" ] (builtins.readFile f)
        else "jensen";

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
              twentyx.target = "runai";
              twentyx.nvim.enable = nvim;
              home.username = "jensen";
              # Replaced at runtime by bootstrap once the workspace name
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
                twentyx.target = "wsl";
              };
            };
          }
        ];
      };

      # ── RunAI: evaluated HERE, never inside. Nothing below ever runs Nix
      # in a pod; we extract the built tree and ship it as an OCI layer.
      #
      # Two flavors, because not every workspace wants an editor in it.
      # Measured 2026-09-27: nvim adds ~48 MiB of profile closure (~17 MB
      # compressed) -- an editor, not a second layer.
      homeConfigurations = {
        runai = mkRunai { nvim = false; };
        runai-nvim = mkRunai { nvim = true; };
      };

      # ── WSL rolling-update delta roots ───────────────────────────────────
      # Store paths a rebuild needs that an older imported image does not
      # have, consumed by scripts/export-rebuild-cache.sh (which packs them
      # into dist/wsl-rebuild.tar.gz; see that script's header for the rest
      # of the root list). Deliberately NOT the whole closure: a delta that
      # carries the closure is a re-import with extra steps. Add a path here
      # only when a rolling update names it as missing; a rebase (fresh
      # wsl --import of a rebuilt tarball) never needs it.
      wslDeltaRoots =
        let
          vscode = import ./nix/vscode-version.nix { inherit pkgs; };
          vscodeExtensions = import ./nix/vscode-extensions.nix { inherit pkgs; };
          # Same derivation the module installs, built with OUR nixpkgs
          # (the input's own flake has no nixpkgs input to build against).
          autoFixVscodeServer = pkgs.callPackage "${inputs.nixos-vscode-server}/pkgs/auto-fix-vscode-server.nix" { };
        in
        [
          pkgs.tree-sitter
          # The script the VS Code server node patching runs from; its
          # closure carries inotify-tools/patchelf/icu/krb5/... for it.
          autoFixVscodeServer
          # The pre-seeded Remote-WSL server plus every pinned .vsix.
          (pkgs.fetchurl { inherit (vscode.server) url name hash; })
        ]
        ++ map (e: e.src) vscodeExtensions;

      packages.${system} = {
        runai-layer = pkgs.callPackage ./nix/runai/layer.nix {
          hm = self.homeConfigurations.runai;
        };
        runai-layer-nvim = pkgs.callPackage ./nix/runai/layer.nix {
          hm = self.homeConfigurations.runai-nvim;
        };
        default = self.packages.${system}.runai-layer;

        # ── the very first transfer ────────────────────────────────────────
        # Chicken and egg: a NixOS-WSL machine is needed to build one, and
        # there is not one yet. This builds the rootfs tarball that `wsl --import`
        # takes, so the airgapped laptop can be created from a Windows shell
        # with no Nix anywhere on it.
        #
        #   nix build .#wsl-tarball
        #   ./result/bin/nixos-wsl-tarball-builder        # -> nixos.wsl
        #
        # No sudo: the upstream builder demands EUID 0 for its chroot and
        # bind mounts, so the wrapper re-execs it inside a user namespace
        # (`unshare -rm`, this uid mapped to namespace-root). Nothing it
        # produces is owned by root — nixos.wsl lands owned by the invoking
        # user, unlike the sudo run. Set NO_UNSHARE=1 to skip the
        # namespace if a caller genuinely is root (or cannot use userns).
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
        # WSL2 MSI (Store-less Windows) + the Zed installer pinned to the
        # same upstream release as the closure's zed-editor, so the remote
        # client and server match by construction. Shipped as ONE tar.gz —
        # no bare .exe/.msi crosses the gap (extract on Windows with its
        # built-in tar.exe). See nix/packages/windows-kit.nix for the
        # re-pin procedure.
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
