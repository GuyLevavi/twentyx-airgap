# NixOS-WSL: the airgapped work laptop.
#
# This machine is INSIDE the gap. It has Nix, and it can rebuild — but only
# from what is already in its store. The practical consequence, which is the
# whole reason for switching to Nix: a config edit rebuilds offline in seconds
# (writeText/buildEnv/symlinkJoin need only stdenvNoCC, 78 MB, and build from
# string literals with no fetches), while adding a *package* requires a
# physical transfer. The closure enforces the rule that discipline used to.
{
  lib,
  pkgs,
  config,
  inputs,
  username,
  ...
}:
let
  # Written by scripts/nix-export.sh when it signs a transfer, and gitignored
  # because it is per-machine. Deriving both settings from one file's existence
  # means neither path needs an edit: sign and the key is trusted, do not sign
  # and signature checking is off. A hardcoded placeholder key would instead be
  # an invalid base64 string that fails at activation time, days later, on the
  # machine least able to debug it.
  pubkeyFile = ../../cache-pubkey;
  havePubkey = builtins.pathExists pubkeyFile;

  # The internal CA bundle, same file the pod gets via the env-injection
  # mount. WSL does not run airgap-bootstrap, so without this nothing on the
  # WSL side trusts the internal CA: push-artifactory.sh, the runai CLI and
  # uv all do TLS against Artifactory. Gitignored and optional — carry it with
  # the transfer (wsl/README.md), presence is detected like cache-pubkey.
  caBundle = ../../ca-bundle.crt;
  haveCaBundle = builtins.pathExists caBundle;

  # In the airgap the server tarball cannot be downloaded, so it is pre-seeded
  # from the pinned kit (nix/packages/windows-kit.nix): the SAME release and
  # commit as the VS Code installer the team installs, so Remote-SSH works on
  # first connect. An activation script extracts it once, into the user's
  # home, only when absent -- a real ~/.vscode-server dir is never clobbered
  # (the $HOME layering rule).
  windowsKit = pkgs.callPackage ../packages/windows-kit.nix {
    zedVersion = pkgs.zed-editor.version;
  };
  vscodeCommit = "2242ebbb54efeeb0129e08e919e7e8d43033cd83"; # VS Code 1.139.0; keep in sync with windows-kit.nix

  # WSL-registry files the upstream tarballBuilder installs into the tarball.
  # wsl-distribution.conf is what makes `wsl --import` register the distro
  # with a Start-Menu shortcut; the default configuration.nix is the
  # just-in-case file a teammate finds under /etc/nixos.
  wslDistroConf = pkgs.writeText "wsl-distribution.conf" ''
    [oobe]
    defaultName = NixOS

    [shortcut]
    icon = /etc/nixos.ico
  '';
  defaultNixosConfig = pkgs.writeText "default-configuration.nix" ''
    # This is the entry the shipped system already builds from; the durable
    # rebuild path on the WSL machine is this repository's flake, transferred
    # by nix-import.sh. Kept here so /etc/nixos is not empty.
    { config, lib, pkgs, ... }:

    {
      imports = [ <nixos-wsl/modules> ];

      wsl.enable = true;
      wsl.defaultUser = "${username}";

      system.stateVersion = "25.05";
    }
  '';
in
{
  wsl = {
    enable = true;
    defaultUser = username;
    startMenuLaunchers = true;
    # Windows interop stays on: it is how VS Code, the browser and the Windows
    # clipboard are reachable, and how `wsl.exe`-side scripts are invoked.
    interop.register = true;
  };

  i18n.defaultLocale = "en_US.UTF-8";

  # ── Offline substitution ────────────────────────────────────────────────
  # There is no cache.nixos.org here. Transfers arrive as a binary cache
  # directory unpacked at /var/cache/nix-transfer; Nix substitutes from it as
  # if it were a remote cache, and reconciles purely by store hash — which is
  # what makes a sharded transfer safe to reassemble in any order.
  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    substituters = lib.mkForce [ "file:///var/cache/nix-transfer" ];
    trusted-public-keys = lib.mkForce (
      lib.optional havePubkey (lib.removeSuffix "\n" (builtins.readFile pubkeyFile))
    );
    # Signing is free and makes the transfer tamper-evident — the property
    # vendor/CHECKSUMS.sha256 used to provide, except that Nix verifies it per
    # store path rather than per tarball. Without a key there is nothing to
    # verify against, and demanding signatures would simply refuse the import.
    require-sigs = havePubkey;
    # Fail immediately instead of hanging on a substituter that cannot resolve.
    connect-timeout = 5;
    trusted-users = [ username ];
    auto-optimise-store = true;
  };
  # Never try the public cache; the DNS lookup cannot succeed and every
  # operation would stall on it first. This also keeps the <nixpkgs> channel
  # out — it used to symlink the ENTIRE nixpkgs source tree (482 MB) into the
  # system closure, dead weight on a machine whose source of truth is this
  # flake. (hostName/timeZone live right above; do not lose them.)
  nix.channel.enable = false;

  networking.hostName = "airgap-wsl";
  time.timeZone = "Asia/Jerusalem";

  # Headless by design: the editors run on Windows (Zed client, VS Code) or
  # in a terminal (nvim). `hardware.graphics.enable` defaults to true on this
  # NixOS and drags mesa (~272 MB) plus llvm-lib (~540 MB) into the closure
  # via /etc/tmpfiles.d/graphics-driver.conf — measured dead weight here.
  # If a GUI app is ever wanted natively on WSLg, re-enable deliberately.
  # If a GUI app is ever wanted natively on WSLg, re-enable deliberately.
  # mkForce: the NixOS-WSL module sets it true for graphics support.
  hardware.graphics.enable = lib.mkForce false;

  # The default global Nix registry pins <nixpkgs> to its source tree
  # (187 MB via /etc/nix/registry.json) — and `nixpkgs#` lookups are not a
  # thing this machine needs: it rebuilds from this flake.
  nix.registry = lib.mkForce { };

  # GC on a machine where re-downloading is a physical transfer: keep more
  # history than a connected box would, because a mistaken collection is
  # expensive to undo.
  nix.gc = {
    automatic = true;
    dates = "monthly";
    options = "--delete-older-than 90d";
  };

  nixpkgs.config.allowUnfree = true;

  # Internal CA trust for the WSL side (pod side uses the env-injection
  # contract instead). No-op until ca-bundle.crt is carried across.
  security.pki.certificateFiles = lib.optionals haveCaBundle [ caBundle ];

  # ── VS Code from Windows ────────────────────────────────────────────────
  # This works today on Fedora only because Fedora is FHS: the prebuilt
  # vscode-server node binary hardcodes /lib64/ld-linux-x86-64.so.2, which
  # NixOS does not have. Moving to NixOS-WSL breaks it, and the failure mode is
  # a silent hang on "Setting up VS Code Server" rather than an error.
  #
  # Two independent fixes, both needed:
  services.vscode-server.enable = true; # patches the server's node on install
  programs.nix-ld.enable = true; # generic FHS interpreter for other prebuilts
  programs.nix-ld.libraries = with pkgs; [
    stdenv.cc.cc.lib
    zlib
    openssl
  ];

  system.activationScripts.vscodeServerSeed = lib.stringAfter [ "users" ] ''
    commit="${vscodeCommit}"
    home="/home/${username}"
    seed="$home/.vscode-server/bin/$commit"
    if [ ! -d "$seed" ]; then
        mkdir -p "$seed"
        # Absolute paths for BOTH tar and gzip: the activation environment
        # has neither on PATH, and tar -z execs `gzip` by NAME (bare tar once
        # failed with 127, then bare -z failed with "gzip: Cannot exec").
        ${pkgs.gzip}/bin/gzip -dc "${windowsKit.vscodeServerTar}" \
            | ${pkgs.gnutar}/bin/tar -x -C "$seed" --strip-components=1
        chown -R ${username}:users "$home/.vscode-server"
    fi
  '';

  virtualisation.podman = {
    enable = true;
    dockerCompat = true;
    defaultNetwork.settings.dns_enabled = true;
  };

  users.users.${username} = {
    isNormalUser = true;
    shell = pkgs.bash; # login shell stays bash; fish is exec'd interactively
    extraGroups = [
      "wheel"
      "podman"
    ];
  };

  # ── SSH, both directions ────────────────────────────────────────────────
  # Inbound: Zed/VS Code from Windows connect over plain SSH to this machine
  # (WSL2 forwards localhost, so Windows clients just use localhost).
  # Outbound: the runai CLI (uv tool install runai) drives `runai exec`, which
  # is what scripts/ssh-bridge.sh tunnels sshd -i through.
  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = false;
  };
  # ── git: neutral settings, system scope ────────────────────────────────
  # Same file the repo layer ships into pods (docker/mklayer.sh) — keep the
  # two in sync. No packaged ~/.config/git/config anywhere: per-user identity
  # is a real file on the durable home (git config --global user.email),
  # because a store symlink would make that write fail.
  environment.etc."gitconfig".text = ''
    # Managed by the airgap flake. Per-user identity belongs in the user's
    # own ~/.config/git/config (durable home), set once: git config --global.
    [init]
    	defaultBranch = main
    [pull]
    	rebase = true
    [pager]
    	diff = delta
    	log = delta
    	reflog = delta
    	show = delta
    [interactive]
    	diffFilter = delta --color-only
    [delta]
    	navigate = true
    	side-by-side = true
    	line-numbers = true
    [merge]
    	conflictstyle = diff3
  '';

  environment.systemPackages = with pkgs; [
    gitMinimal
    wget
    curl
    openssh
    socat # client side of the sshd -i bridge into RunAI pods
  ];

  # ── the WSL rootfs tarball, built without root ─────────────────────────
  # Replaces the upstream tarballBuilder: its nixos-install path cannot run
  # in a user namespace — the trusted daemon copies the closure into the
  # chroot store as real root, then the namespaced client chowns
  # daemon-owned files and gets EINVAL. Same outcome here with the client
  # doing every write: `nix copy --to local?root=` is in-process, the
  # system profile is a direct symlink, and `tar --owner=0` stamps root
  # ownership into the archive at packaging time (which also makes the
  # bytes reproducible across runs). The wrapper in flake.nix still re-execs
  # via `unshare -rm` so nothing lands owned by the real user mid-build.
  # No vscode-server pre-seed at build time (that was nixos-install's
  # chroot activation) — the seed snippet runs on first boot instead,
  # unpacking the same pinned tarball, same end state.
  system.build.tarballBuilder = lib.mkForce (pkgs.writeShellApplication {
    name = "nixos-wsl-tarball-builder";
    runtimeInputs = with pkgs; [
      coreutils
      gnutar
      pigz
      config.nix.package
    ];
    text = ''
      out="nixos.wsl"
      if [ "$#" -gt 1 ] || { [ "$#" -eq 1 ] && [ "$1" = "-h" ]; }; then
        echo "Usage: $0 [output.tar.gz]"
        exit 1
      fi
      [ "$#" -eq 1 ] && out="$1"

      root=$(mktemp -d)
      trap 'rm -rf "$root"' EXIT

      # Every nix invocation against the chroot store must run with an empty
      # build-users-group: the default ("nixbld") makes the LocalStore init
      # chown the store dir to the group's gid, which is not mapped inside
      # the user namespace → EINVAL. With an empty group the check is
      # skipped entirely; the imported system's own nix.conf is untouched.
      export NIX_CONFIG="build-users-group = "

      echo "[NixOS-WSL] Installing..."
      install -d "$root/nix/store" "$root/nix/var/nix/profiles/per-user/root" "$root/etc"

      # Copy the closure client-side and register the store DB from nix's own
      # dump format (`nix-store --dump-db` → `--load-db`, proven round trip).
      # This is the one step that forced root in the upstream builder: with
      # nixos-install, the trusted daemon copies the closure as real root and
      # the namespaced client then chowns daemon-owned files → EINVAL. Here
      # the client does every write, so `unshare -rm` is self-sufficient.
      # Ownership is stamped into the tarball by --owner=0 at packaging time;
      # file modes and timestamps come straight from the store.
      nix path-info -r ${config.system.build.toplevel} | while read -r storePath; do
        cp -r --preserve=mode,timestamps "$storePath" "$root/nix/store/"
      done
      nix path-info -r ${config.system.build.toplevel} \
        | xargs -d '\n' nix-store --dump-db \
        | nix-store --store "local?root=$root" --load-db

      echo "[NixOS-WSL] Setting the system profile..."
      install -d "$root/nix/var/nix/profiles/per-user/root" "$root/etc"
      ln -sfn ${config.system.build.toplevel} "$root/nix/var/nix/profiles/system"
      touch "$root/etc/NIXOS"

      echo "[NixOS-WSL] Adding wsl-distribution.conf"
      install -Dm644 ${wslDistroConf} "$root/etc/wsl-distribution.conf"
      install -Dm644 ${inputs.nixos-wsl}/assets/NixOS-WSL.ico "$root/etc/nixos.ico"

      echo "[NixOS-WSL] Adding default config..."
      install -Dm644 ${defaultNixosConfig} "$root/etc/nixos/configuration.nix"

      echo "[NixOS-WSL] Compressing..."
      tar -C "$root" -c --sort=name --mtime='@1' --numeric-owner --owner=0 --group=0 --hard-dereference . \
        | pigz > "$out"
    '';
  });

  system.stateVersion = "25.05";
}
