# NixOS-WSL: the airgapped work laptop.
#
# A frozen appliance: nothing evaluates Nix inside the gap. A change to the
# closure is built on the connected machine and carried in as a NAR against
# base.rev (install/apply.sh). Config is the inner repo's dotfiles, linked into
# $HOME by its wsl/link.sh. See AGENTS.md.
{
  lib,
  pkgs,
  config,
  inputs,
  ...
}:
let
  # Fixed for everyone: the toolchain is one appliance, and the install
  # creates this user with the first free uid, 1000.
  username = "jensen";

  # One profile, one session environment, one tree of packaged defaults --
  # the same source the pod layer is built from.
  twentyx = import ../profile.nix {
    inherit
      lib
      pkgs
      inputs
      ;
    wsl = true;
  };

  # ── Windows-side assets ─────────────────────────────────────────────────
  # The kit (Zed installer, themes, client settings templates, WSL2 MSI,
  # VS Code) is built by .#windows-kit; the WSL side itself needs nothing from
  # it: Zed's WSL remote covers editing from Windows, and its server ships in
  # this closure.

  # ── VS Code (Microsoft, Remote-WSL) ─────────────────────────────────────
  # The Windows client is Microsoft VS Code, and its Remote-WSL extension
  # demands a server for the client's exact commit (`code --version`), which
  # cannot be downloaded here. nix/vscode-version.nix pins the release whose
  # Windows installer the kit ships and whose Linux server is pre-seeded
  # below; nix/vscode-extensions.nix pins the .vsix set, with engine ranges
  # checked against that release's version.
  vscode = import ../vscode-version.nix { inherit pkgs; };
  vscodeExtensions = import ../vscode-extensions.nix { inherit pkgs; };
  vscodeServerTar = pkgs.fetchurl {
    inherit (vscode.server) url name hash;
  };

  # The .vsix set as one list and one stamp. The stamp makes the seeding
  # service a no-op after its first successful run, and makes it run again
  # only when a transfer changes the set.
  vsixPaths = map (e: "${e.src}") vscodeExtensions;
  vsixStamp = builtins.hashString "sha256" (lib.concatStringsSep "\n" vsixPaths);

in
{
  wsl = {
    enable = true;
    defaultUser = username;
    startMenuLaunchers = true;
    # Windows interop stays on: it is how the browser and the Windows
    # clipboard are reachable, and how `wsl.exe`-side scripts are invoked.
    # `interop.register` stays at its default (false): WSL's own init already
    # binds the WSLInterop binfmt name and boot.protectBinfmt (default) keeps
    # it. Binding the same name again is refused with -EEXIST, which fails
    # systemd-binfmt and makes every switch exit 4.
    #
    # /bin/true for WSL >= 2.9.8: its init generates wsl-mnt-guard.service
    # with ExecStart=/bin/true, and NixOS-WSL's minimal /bin (wslpath, sh,
    # mount, bash) lacks it, so the unit dies 203/EXEC when
    # switch-to-configuration restarts sysinit-reactivation and the switch
    # exits 4 (NixOS-WSL#1100). mkAfter appends to the module's list.
    extraBin = lib.mkAfter [ { src = "${pkgs.coreutils}/bin/true"; } ];
  };

  i18n.defaultLocale = "en_US.UTF-8";

  # ── Frozen appliance, quiet Nix ─────────────────────────────────────────
  # Nothing evaluates Nix inside the gap: updates arrive as a NAR
  # (wsl-delta.nar / wsl-full.nar) applied by install/apply.sh with
  # nix-store --import + nix-env --set. Nix stays for that, for rollback and
  # for GC -- and nothing else: no flakes, no `nix` CLI, no substituter.
  nix.settings = {
    # mkForce: NixOS appends cache.nixos.org to whatever is set here, and a
    # lookup that cannot succeed stalls every operation first.
    substituters = lib.mkForce [ ];
    trusted-users = [ username ];
    auto-optimise-store = true;
  };
  # No <nixpkgs> channel: it used to symlink the ENTIRE nixpkgs source tree
  # (482 MB) into the system closure, dead weight on a machine that never
  # evaluates Nix.
  nix.channel.enable = false;

  networking.hostName = "twentyx-wsl";
  time.timeZone = "Asia/Jerusalem";

  # Headless by design: the editors run on Windows (Zed client) or in a
  # terminal (nvim). `hardware.graphics.enable` defaults to true on this
  # NixOS and drags mesa (~272 MB) plus llvm-lib (~540 MB) into the closure
  # via /etc/tmpfiles.d/graphics-driver.conf — measured dead weight here.
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

  # ── Internal CA at runtime ──────────────────────────────────────────────
  # /var/lib/airgap-env/ca-bundle.crt is dropped in by the inner repo's
  # wsl/link.sh (or by hand) and never baked in: the bundle rotates and
  # differs per cluster. The service concatenates it onto the system bundle;
  # /etc and NODE_EXTRA_CA_CERTS point at the result, so adding or rotating
  # the CA needs `systemctl restart airgap-ca`, not a transfer.
  systemd.services.airgap-ca = {
    description = "Build the runtime CA bundle (system store + injected CA)";
    wantedBy = [ "multi-user.target" ];
    before = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = [
      pkgs.bash
      pkgs.coreutils
    ];
    script = ''
      mkdir -p /var/lib/airgap-env
      cat ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt > /var/lib/airgap-env/ca-certificates.crt
      if [ -f /var/lib/airgap-env/ca-bundle.crt ]; then
        cat /var/lib/airgap-env/ca-bundle.crt >> /var/lib/airgap-env/ca-certificates.crt
      fi
    '';
  };

  environment.etc."ssl/certs/ca-certificates.crt".source =
    lib.mkForce "/var/lib/airgap-env/ca-certificates.crt";
  environment.etc."ssl/certs/ca-bundle.crt".source =
    lib.mkForce "/var/lib/airgap-env/ca-certificates.crt";

  # ── prebuilt binaries from other toolchains ─────────────────────────────
  # nix-ld gives foreign prebuilts (the runai CLI, uv-managed interpreters,
  # anything the team drops in) a generic FHS interpreter; NixOS has no
  # /lib64/ld-linux-x86-64.so.2 of its own.
  programs.nix-ld.enable = true;
  programs.nix-ld.libraries = with pkgs; [
    stdenv.cc.cc.lib
    zlib
    openssl
  ];

  virtualisation.podman = {
    enable = true;
    dockerCompat = true;
    defaultNetwork.settings.dns_enabled = true;
  };

  users.users.${username} = {
    isNormalUser = true;
    # WSL relay and SSH keys never ask for a password; "*" just locks
    # password logins outright.
    hashedPassword = "*";
    shell = pkgs.bash; # login shell stays bash; fish is exec'd interactively
    extraGroups = [
      "wheel"
      "podman"
    ];
    # isNormalUser defaults createHome=true, so nixos-install's activation
    # creates /home/jensen with the skeleton, owned 1000:100.
  };

  # sudo with no password prompt: the account's password is locked ("*"), so
  # a prompt is unanswerable rather than a gate -- and anyone who can run
  # `wsl` is one `wsl -u root` away from root anyway.
  security.sudo.wheelNeedsPassword = false;

  # /opt/twentyx is the stable tool path both targets share: editor settings
  # point at /opt/twentyx/profile/bin/... and never go stale when the store
  # moves. L+ forces the link, so a system update refreshes it on next boot.
  systemd.tmpfiles.rules = [
    "d /opt/twentyx 0755 root root -"
    "L+ /opt/twentyx/profile - - - - ${config.system.path}"
    "L+ /opt/twentyx/home-defaults - - - - ${twentyx.homeDefaults}"
  ];

  # Same session variables a pod gets as image ENV: shell rc files reach only
  # shells, and `runai exec`/code-server never source one. Node ignores the
  # system trust store, hence the runtime CA bundle.
  environment.sessionVariables = twentyx.sessionEnv // {
    NODE_EXTRA_CA_CERTS = "/var/lib/airgap-env/ca-certificates.crt";
  };

  # ── Static identity: the closure ships a complete /etc/passwd ──────────
  # The first boot of the imported distro died in dbus-broker ("Invalid
  # user-name ... user=systemd-oom", then launcher_open_journal EACCES,
  # exit -107): systemd's own D-Bus policy files reference internal users
  # that no module had declared in this image, and the launcher treats an
  # unknown user in a policy as fatal. Declaring them here — regardless of
  # whether the matching services run, because the policies ship with the
  # systemd package either way — makes the activation write a complete
  # passwd. With mutableUsers=false that write is a deterministic
  # regeneration from these declarations, not a useradd that can half-fail
  # inside the build's user namespace and still ship (the old "|| true").
  # mutableUsers=false + locked passwords is deliberate: the WSL relay never
  # authenticates and inbound SSH is key-only (keys are added post-import).
  # This flag acknowledges "no password anywhere" by design.
  users.allowNoPasswordLogin = true;
  users.mutableUsers = false;
  users.users.systemd-oom = {
    isSystemUser = true;
    group = "systemd-oom";
  };
  users.groups.systemd-oom = { };
  users.users.systemd-timesync = {
    isSystemUser = true;
    group = "systemd-timesync";
  };
  users.groups.systemd-timesync = { };

  # D-Bus is deliberately left at the NixOS default (dbus-broker).

  # ── SSH, both directions ────────────────────────────────────────────────
  # Inbound: the Zed client on Windows connects over plain SSH to this machine
  # (WSL2 forwards localhost, so Windows clients just use localhost).
  # Outbound: the runai CLI (uv tool install runai) drives `runai exec`, which
  # is what scripts/ssh-bridge.sh tunnels sshd -i through.
  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = false;
  };

  # ── VS Code (Remote-WSL): server + extensions + pins ───────────────────
  # The server tarball is pinned in nix/vscode-version.nix. The oneshot runs
  # as jensen after tmpfiles: extracts the server when absent (then it is a
  # real file the user owns) and installs the pinned extensions with the
  # server's own CLI. The machine settings (LSP pins) are a dotfile in the
  # inner repo. No marketplace, no activation script, no chowns.
  systemd.services.vscode-extensions = {
    description = "Seed the pinned VS Code server + extensions into ~/.vscode-server";
    wantedBy = [ "multi-user.target" ];
    after = [ "systemd-tmpfiles-setup.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = username;
      Group = "users";
    };
    path = [
      pkgs.bash
      pkgs.coreutils
      pkgs.gnutar
      pkgs.gzip
    ];
    script = ''
      set -euo pipefail
      home="/home/${username}"
      seed="$home/.vscode-server/bin/${vscode.commit}"
      if [ ! -x "$seed/bin/code-server" ]; then
        rm -rf "$seed"
        mkdir -p "$seed"
        tar -xzf ${vscodeServerTar} -C "$seed" --strip-components=1
      fi
      stamp="$home/.vscode-server/.airgap-vsix"
      want="${vsixStamp}"
      if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$want" ]; then
        exit 0
      fi
      for vsix in ${lib.concatStringsSep " " vsixPaths}; do
        "$seed/bin/code-server" --install-extension "$vsix" --force
      done
      printf '%s\n' "$want" > "$stamp"
    '';
  };

  environment.systemPackages = with pkgs; [
    twentyx.profile
    gitMinimal
    wget
    curl
    openssh
    socat # client side of the sshd -i bridge into RunAI pods
  ];

  # ── Boot evidence for the airgapped machine ────────────────────────────
  # One file read, not a support session: date, failed units, the journal
  # tail, copied to the shared Windows partition when it is mounted.
  systemd.services.bootlog = {
    description = "Airgap: write boot evidence to the Windows-mounted log";
    wantedBy = [ "multi-user.target" ];
    after = [ "multi-user.target" ];
    path = with pkgs; [
      coreutils
      systemd
    ];
    serviceConfig.Type = "oneshot";
    script = ''
      out="/var/log/bootlog.txt"
      {
        echo "════════ boot $(date -u '+%Y-%m-%dT%H:%M:%SZ') ════════"
        echo "── failed units:"
        systemctl --failed --no-pager
        echo "── journal tail:"
        journalctl -b --no-pager | tail -100
      } > "$out" 2>&1 || true
      # The shared Windows partition appears only once the WSL automount is
      # up; retry rather than guess the ordering.
      for _ in 1 2 3 4 5 6; do
        if [ -d /mnt/c/twentyx ]; then
          cp "$out" /mnt/c/twentyx/bootlog.txt 2>/dev/null && break
        fi
        sleep 5
      done
    '';
  };

  system.stateVersion = "25.05";
}
