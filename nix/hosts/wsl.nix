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
  # mount. WSL does not run bootstrap, so without this nothing on the
  # WSL side trusts the internal CA: push-artifactory.sh, the runai CLI and
  # uv all do TLS against Artifactory. Gitignored and optional — carry it with
  # the transfer (wsl/README.md), presence is detected like cache-pubkey.
  caBundle = ../../ca-bundle.crt;
  haveCaBundle = builtins.pathExists caBundle;

  # ── Windows-side assets ─────────────────────────────────────────────────
  # The kit (Zed installer, themes, client settings templates, WSL2 MSI) is
  # built by .#windows-kit; the WSL side itself needs nothing from it since
  # the VS Code server pre-seed was dropped (Zed's WSL remote covers editing
  # from Windows, and its server ships in this closure).

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

  networking.hostName = "twentyx-wsl";
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
    # Ownership cannot be set inside the build's user namespace (only uid 0
    # is mapped, so every chown to a real user returns EINVAL). A home dir
    # created by the in-chroot activation therefore ships root:root 0700 —
    # measured: `su - jensen` could not cd into it and home-manager-jensen
    # failed. tmpfiles (below) creates/re-owns it on first boot, where root
    # really is root.
    createHome = false;
  };

  # /home/<user> has to be owned by the user with mode 0700. tmpfiles runs
  # as real root at boot: `d` creates it, `z` fixes ownership recursively
  # (in the build's user namespace only uid 0 is mapped, so anything the
  # chroot activation writes under the home lands root-owned).
  systemd.tmpfiles.rules = [
    "d /home/${username} 0700 ${username} users -"
    "z /home/${username} - ${username} users -"
  ];

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
  # authenticates and inbound SSH is key-only (keys are added post-import,
  # wsl/README.md). This flag acknowledges "no password anywhere" by design.
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

  # D-Bus is deliberately left at the NixOS default (dbus-broker). Its
  # launcher's EACCES on journald's socket, which once looked like the root
  # cause, was a symptom of the 0700-/ invariant violation fixed in the
  # builder below — not a reason to deviate. See wsl/FIRST-BOOT.md.

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

  # ── Boot evidence for the airgapped machine ────────────────────────────
  # The machine we cannot debug is the one that boots badly. Every boot, this
  # appends the decisive evidence — journal head, failed units, and a real
  # non-root login-shell exec test — to a log the Windows side can read,
  # so a diagnosis costs one file read, not a support session.
  systemd.services.bootlog = {
    description = "Airgap: append boot evidence to the Windows-mounted log";
    wantedBy = [ "multi-user.target" ];
    after = [ "multi-user.target" ];
    # Explicit PATH: the default ExecStart environment has no coreutils/shadow.
    path = with pkgs; [
      coreutils
      util-linux
      shadow
      systemd
    ];
    serviceConfig.Type = "oneshot";
    script = ''
      mkdir -p /var/log 2>/dev/null || true
      out="/var/log/bootlog.txt"
      {
        echo
        echo "════════ boot $(date -u '+%Y-%m-%dT%H:%M:%SZ') ════════"
        echo "── identity ${username}:"
        id ${username} 2>&1 || true
        echo "── root directory (must be 755 root:root):"
        stat -c '%a %U:%G /' / 2>&1 || true
        ls -ld /home /home/${username} 2>&1 || true
        echo "── non-root login-shell exec test:"
        timeout 20 su -l ${username} -c 'id; echo EXEC_OK' 2>&1 || true
        echo "── failed units:"
        systemctl --failed --no-pager 2>&1 || true
        echo "── dbus unit:"
        systemctl status dbus --no-pager -n 6 2>&1 || true
        echo "── /run permissions:"
        ls -ld /run/systemd/journal /run/systemd/journal/socket 2>&1 || true
        echo "── mounts:"
        mount | grep -E ' on / | on /run ' 2>&1 || true
        echo "── journal head:"
        journalctl -b --no-pager 2>&1 | head -120 || true
      } >> "$out" 2>&1 || true
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
  system.build.tarballBuilder = lib.mkForce (pkgs.writeShellApplication {
    name = "nixos-wsl-tarball-builder";
    runtimeInputs = with pkgs; [
      coreutils
      findutils
      gnugrep
      gnutar
      pigz
      config.nix.package
      nixos-install-tools
    ];
    text = ''
      out="nixos.wsl"
      if [ "$#" -gt 1 ] || { [ "$#" -eq 1 ] && [ "$1" = "-h" ]; }; then
        echo "Usage: $0 [output.tar.gz]"
        exit 1
      fi
      [ "$#" -eq 1 ] && out="$1"

      root=$(mktemp -d)
      # Every command guarded: under errexit, an unguarded failure inside
      # the EXIT trap aborts the remaining commands — an unguarded umount
      # (host submounts inside the rbinds return nonzero) left a 4.6 GB
      # tempdir behind after a successful tar (measured).
      # chmod first: the copied store paths carry the store's read-only
      # modes (r--r--r--), and plain rm cannot descend into those dirs —
      # measured leaving a 4.6 GB /tmp tempdir behind and failing the run
      # with rc=65 after a successful tar.
      trap 'umount -R "$root/dev" "$root/sys" "$root/proc" 2>/dev/null || true; chmod -R u+w "$root" 2>/dev/null || true; rm -rf "$root" 2>/dev/null || true' EXIT

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

      # Run the system activation against the tarball root — the step the
      # upstream builder got for free from nixos-install. This populates
      # /etc (passwd, fstab, systemd units), /bin and /sbin (sh + init
      # shim) and users. Without it the
      # imported distro fails with "getpwuid(0) failed" and "execvpe
      # (/bin/sh) failed" — measured. nixos-enter mounts only /dev /sys
      # /proc and uses the chroot's own store; it self-namespaces so no
      # bind leaks into the tar.
      echo "[NixOS-WSL] Running the system activation..."
      ln -sfn /proc/mounts "$root/etc/mtab"
      # Run the system activation against the tarball root — the step the
      # upstream builder got for free from nixos-install. This populates
      # /etc (passwd, fstab, systemd units), /bin and /sbin (sh + init
      # shim) and users. Without it the
      # imported distro fails with "getpwuid(0) failed" and "execvpe
      # (/bin/sh) failed" — measured. The bind mounts cover the specialfs
      # snippet, whose own mounts fail in a user namespace (devpts gid,
      # sysfs type) and are non-fatal: the activation continues and
      # everything that matters lands in the root. The
      # /nix/users-chown-to-unmapped-gid failures (specialfs, /etc/shadow)
      # are corrected by tar --owner=0 at packaging time.
      # switch-to-configuration was tried first — it is an ELF binary now
      # and defers all work to actual boot; the direct activate script is
      # what populates the tree.
      echo "[NixOS-WSL] Running the system activation..."
      ln -sfn /proc/mounts "$root/etc/mtab"
      # These are the steps nixos-enter performs, in our existing mount
      # namespace (its own nested re-exec cannot mount /proc here).
      mount --make-rprivate /
      mkdir -p "$root/dev" "$root/sys" "$root/proc"
      mount --rbind /dev "$root/dev"
      mount --rbind /sys "$root/sys"
      mount --rbind /proc "$root/proc"
      # || true: inside the namespace the activation *reports* failures —
      # the specialfs mounts (devpts gid), the /etc/shadow chown (unmapped
      # gid) and the seed's chown to the unmapped uid — but every file
      # still lands, and tar --owner=0 stamps the final ownership into the
      # archive. A nonzero activation here is expected; aborting on it
      # would ship an unpopulated root (rc=64, no /etc/passwd — measured).
      chroot "$root" /nix/var/nix/profiles/system/activate || true
      # Best effort: the rbind'd trees hold host submounts (hugepages, fuse
      # connections, module sysfs) that plain `umount -R` cannot fully
      # unwind from here. Anything left over dies with the namespace, and
      # the tar step above excludes /dev /sys /proc entirely.
      umount -R "$root/dev" "$root/sys" "$root/proc" 2>/dev/null || true

      echo "[NixOS-WSL] Adding wsl-distribution.conf"
      install -Dm644 ${wslDistroConf} "$root/etc/wsl-distribution.conf"
      install -Dm644 ${inputs.nixos-wsl}/assets/NixOS-WSL.ico "$root/etc/nixos.ico"

      echo "[NixOS-WSL] Adding default config..."
      install -Dm644 ${defaultNixosConfig} "$root/etc/nixos/configuration.nix"

      echo "[NixOS-WSL] Normalizing directory permissions..."
      # Directory traversal invariant, enforced for the WHOLE tree instead of
      # path by path. The build root comes from `mktemp -d` (mode 0700) and
      # the user-namespace activation cannot chown, so restrictive directory
      # modes can survive into the archive; tar records them and extractors
      # (GNU tar, measured; WSL's import too) apply them to the distro. A
      # 0700 / then makes every non-root process fail EACCES on every
      # absolute path: user shells cannot exec, messagebus cannot reach
      # journald, login cannot chdir, the WSL relay cannot start a session.
      # Root bypasses via DAC_OVERRIDE, so it presents as "root works,
      # nothing user-level does" — every failure in wsl/FIRST-BOOT.md traces
      # back to this. Files are deliberately NOT widened: the store already
      # carries correct exec bits, and sshd refuses to start if host keys
      # are anything but 0600. The bind-mounted trees are pruned: they are
      # host state, excluded from the tar anyway, and cannot be chmodded.
      prune=( -path "$root/dev" -o -path "$root/sys" -o -path "$root/proc" )
      find "$root" \( "''${prune[@]}" \) -prune -o -type d -exec chmod a+rx {} +
      if find "$root" \( "''${prune[@]}" \) -prune -o -type d ! -perm -o+x -print -quit | grep -q .; then
        echo "[NixOS-WSL] FATAL: a directory in the image is not traversable" >&2
        exit 1
      fi
      # /dev /sys /proc are bind-mounted host trees during the activation
      # step — runtime mounts, not distro content (WSL mounts its own /dev
      # and /proc at import). Excluding keeps live sysfs state (which tar
      # reads with "file shrank" warnings) out of the archive.
      tar -C "$root" -c --sort=name --mtime='@1' --numeric-owner --owner=0 --group=0 \
        --hard-dereference \
        --exclude=./dev --exclude=./sys --exclude=./proc \
        . | pigz > "$out"
    '';
  });

  system.stateVersion = "25.05";
}
