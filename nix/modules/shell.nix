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
  cfg = config.airgap;
in
{
  programs.bash = {
    enable = true;
    initExtra = ''
      if [[ $- == *i* && -z "''${BASH_EXECS_FISH:-}" && -z "''${IN_NIX_SHELL:-}" ]]; then
        export BASH_EXECS_FISH=1
        exec ${pkgs.fish}/bin/fish
      fi
    '';
  };

  programs.fish = {
    enable = true;
    interactiveShellInit = ''
      set -g fish_greeting

      # In a pod the emulator is remote and TERM arrives from the client.
      # WezTerm announces TERM=wezterm, whose terminfo we ship; anything we do
      # not recognise is clamped to a safe 256-colour entry rather than left to
      # degrade into a monochrome fallback.
      if not infocmp $TERM >/dev/null 2>&1
        set -gx TERM xterm-256color
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
      k = "kubectl";
    };
    shellAliases = {
      ls = "eza --icons --group-directories-first";
      cat = "bat -p";
    };
  };

  programs.starship = {
    enable = true;
    enableBashIntegration = false;
    enableFishIntegration = true;
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
