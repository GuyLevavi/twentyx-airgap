# fish as the interactive shell, bash as the login shell.
#
# bash stays login so scripts, `bash -c`, systemd units and code-server's
# non-interactive terminals keep POSIX semantics; it execs into fish only for
# interactive sessions. The BASH_EXECS_FISH marker survives the exec, so a
# deliberate nested `bash` from inside fish does not bounce straight back.
{
  lib,
  pkgs,
  config,
  ...
}:
let
  cfg = config.twentyx;

  # home-manager bakes home.homeDirectory into generated values at EVAL time --
  # STARSHIP_CONFIG and fish_complete_path today, and there is no guarantee the
  # list stays that short. In a pod $HOME is relocated onto the PVC by
  # bootstrap, so every one of those paths points at a directory that
  # does not exist, and each fails silently: starship falls back to defaults,
  # completions just never load.
  #
  # So rewrite them generically rather than maintaining a list of which
  # variables are affected this release. This has to run AFTER home-manager's
  # own init, which is the part that is easy to get wrong: fish sources
  # conf.d/*.fish BEFORE config.fish, so a conf.d drop-in -- the obvious place
  # -- is guaranteed to run too early and silently do nothing.
  evalHome = config.home.homeDirectory;
in
{
  programs.bash = {
    enable = true;
    initExtra = ''
      # Before the exec, so a bash-only session (scripts, code-server tasks)
      # gets the corrected values too.
      # __eh must be a variable, and quoted at the point of use: the slashes
      # in an inline path pattern terminate it early, and the substitution
      # then silently produces garbage rather than failing.
      __eh="${evalHome}"
      if [ "$HOME" != "$__eh" ]; then
        for __v in $(compgen -e); do
          case "''${!__v}" in
            *"$__eh"*) export "$__v=''${!__v//"$__eh"/$HOME}" ;;
          esac
        done
      fi
      unset __eh __v

      if [[ $- == *i* && -z "''${BASH_EXECS_FISH:-}" && -z "''${IN_NIX_SHELL:-}" ]]; then
        export BASH_EXECS_FISH=1
        # config.programs.fish.package, not pkgs.fish: the override that drops
        # the fish_config python UI must be the binary this exec lands on, or
        # the full interpreter stays in the closure through this line.
        exec ${config.programs.fish.package}/bin/fish
      fi
    '';
  };

  programs.fish = {
    enable = true;
    # fish's only use of python is the `fish_config` web UI. In the gap that
    # UI can never be reached, and the interpreter is 209 MB of closure; the
    # shell itself is unaffected.
    package = pkgs.fish.override { usePython = false; };

    # Runs in EVERY fish, interactive or not, and lands immediately after
    # home-manager's session-variable block in config.fish -- which is the only
    # position where this both sees the baked-in values and beats everything
    # that reads them.
    shellInit = ''
      if test "$HOME" != ${evalHome}
        for var in (set --names --export)
          if string match -q -- '*${evalHome}*' $$var
            set -gx $var (string replace -a -- ${evalHome} "$HOME" $$var) 2>/dev/null
          end
        end
      end
    '';

    interactiveShellInit = ''
      set -g fish_greeting

      # In a pod the emulator is remote and TERM arrives from the client.
      # WezTerm announces TERM=wezterm, whose terminfo we ship; anything we do
      # not recognise is clamped to a safe 256-colour entry rather than left to
      # degrade into a monochrome fallback.
      if not infocmp $TERM >/dev/null 2>&1
        set -gx TERM xterm-256color
      end

      # Second half of the rehome (see shellInit for the first). Deferred to
      # the first prompt because fish_complete_path is assigned further down
      # home-manager's config.fish, after this block: a rewrite running here
      # would miss the one value it is here to fix.
      if test "$HOME" != ${evalHome}
        function __rehome --on-event fish_prompt
          functions --erase __rehome
          set -g fish_complete_path (string replace -a -- ${evalHome} "$HOME" $fish_complete_path)
        end
      end
    '';

    # Abbreviations, not aliases: they expand in place before you hit enter, so
    # what runs is what you can see — which matters when the thing you are
    # about to run touches a shared PVC.
    shellAbbrs = {
      ll = "eza -l --icons --git";
      lt = "eza --tree --icons --level=2";
      lg = "lazygit";
      g = "git";
    }
    # kubectl is WSL-only by design; a dead abbreviation in the pod is noise
    # that suggests a capability the pod deliberately does not have.
    // lib.optionalAttrs cfg.tools.cluster.enable { k = "kubectl"; };
    shellAliases = {
      ls = "eza --icons --group-directories-first";
      cat = "bat -p";
      tldr = "tldr --quiet";
    };
  };

  programs.starship = {
    enable = true;
    enableBashIntegration = false;
    enableFishIntegration = true;
    settings = {
      add_newline = false;
      # In a pod the hostname IS the workspace name, and it is the fastest way
      # to notice you are typing into the wrong session. Locally it is noise,
      # so it only shows over a remote connection.
      hostname = {
        ssh_only = true;
        format = "[$hostname]($style) ";
      };
      # A prompt that lies about the environment is worse than no prompt: these
      # are the two that change what a command will do.
      kubernetes.disabled = false;
      python.disabled = false;
      # No network, so an upstream comparison can only hang.
      git_status.ignore_submodules = true;
    };
  };

  programs.zoxide = {
    enable = true;
    enableBashIntegration = false;
    enableFishIntegration = true;
  };

  programs.fzf = {
    enable = true;
    enableBashIntegration = false;
    enableFishIntegration = true;
    historyWidget.command = ""; # atuin owns Ctrl-R; fzf keeps Ctrl-T/Alt-C
  };

  programs.atuin = {
    enable = true;
    enableBashIntegration = false;
    enableFishIntegration = true;
    settings = {
      auto_sync = false;
      update_check = false;
      style = "compact";
      inline_height = 20;
    };
  };

  programs.direnv = {
    enable = true;
    enableFishIntegration = true;
    # nix-direnv drags the entire Nix package in — 161 MB of closure for a
    # feature that cannot work in a pod that has no Nix.
    nix-direnv.enable = cfg.target == "wsl";
  };

  programs.tmux = {
    enable = true;
    prefix = "C-a";
    baseIndex = 1;
    escapeTime = 0;
    terminal = "tmux-256color";
    mouse = true;
    keyMode = "vi";
    historyLimit = 50000;
    extraConfig = ''
      set -as terminal-features ",*:RGB"

      # OSC 52 clipboard. This is the only way a yank inside a RunAI pod
      # reaches the Windows clipboard: there is no X11, no Wayland, and no
      # wl-copy to forward to. tmux must both allow the sequence through from
      # nvim (allow-passthrough) and emit its own (set-clipboard on), and the
      # terminal emulator at the far end must honour it — WezTerm does.
      set -g allow-passthrough on
      set -g set-clipboard on

      bind | split-window -h -c "#{pane_current_path}"
      bind - split-window -v -c "#{pane_current_path}"
      unbind '"'
      unbind %

      # kubectl exec sessions die on any network blip. Losing the connection
      # should cost you nothing, so make detaching cheap and obvious.
      set -g status-right " #{session_name} "
    '';
  };
}
