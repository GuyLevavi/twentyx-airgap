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
  username,
  ...
}:
{
  wsl = {
    enable = true;
    defaultUser = username;
    startMenuLaunchers = true;
    # Windows interop stays on: it is how VS Code, the browser and the Windows
    # clipboard are reachable, and how `wsl.exe`-side scripts are invoked.
    interop.register = true;
  };

  networking.hostName = "airgap-wsl";
  time.timeZone = "Asia/Jerusalem";
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
    trusted-public-keys = lib.mkForce [
      # Replace with the output of `nix key generate-public` on the connected
      # machine. Signing is free and makes the transfer tamper-evident — the
      # property vendor/CHECKSUMS.sha256 used to provide.
      "airgap-transfer:PLACEHOLDER_REPLACE_ME="
    ];
    # Fail immediately instead of hanging on a substituter that cannot resolve.
    connect-timeout = 5;
    trusted-users = [ username ];
    auto-optimise-store = true;
  };
  # Never try the public cache; the DNS lookup cannot succeed and every
  # operation would stall on it first.
  nix.channel.enable = false;

  # GC on a machine where re-downloading is a physical transfer: keep more
  # history than a connected box would, because a mistaken collection is
  # expensive to undo.
  nix.gc = {
    automatic = true;
    dates = "monthly";
    options = "--delete-older-than 90d";
  };

  nixpkgs.config.allowUnfree = true;

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

  # In the airgap the server tarball cannot be downloaded, so it must be
  # pre-seeded at ~/.vscode-server/bin/<commit>/ for the EXACT commit of the
  # Windows VS Code build (`code --version`, second line). Pin VS Code's
  # auto-update off on the Windows side or this breaks on every update.

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

  environment.systemPackages = with pkgs; [
    gitMinimal
    wget
    curl
  ];

  system.stateVersion = "25.05";
}
