# The zsh-like ergonomics you actually miss, in bash.

# --- completion -----------------------------------------------------------
for f in /usr/share/bash-completion/bash_completion /etc/bash_completion; do
    [ -r "$f" ] && { . "$f"; break; }
done

# Case-insensitive, menu-cycling completion -- the main thing zsh gives you.
bind 'set completion-ignore-case on'      2>/dev/null
bind 'set completion-map-case on'         2>/dev/null
bind 'set show-all-if-ambiguous on'       2>/dev/null
bind 'set menu-complete-display-prefix on' 2>/dev/null
bind 'TAB:menu-complete'                  2>/dev/null
bind '"\e[Z":menu-complete-backward'      2>/dev/null

# Up/Down search history by the prefix already typed. Closest thing to
# zsh-autosuggestions without a plugin, and it needs no dependency.
bind '"\e[A":history-search-backward'     2>/dev/null
bind '"\e[B":history-search-forward'      2>/dev/null

# --- fzf ------------------------------------------------------------------
if command -v fzf >/dev/null 2>&1; then
    export FZF_DEFAULT_OPTS="--height 40% --layout=reverse --border --info=inline"
    command -v fd >/dev/null 2>&1 && \
        export FZF_DEFAULT_COMMAND='fd --type f --hidden --follow --exclude .git'
    export FZF_CTRL_T_COMMAND="$FZF_DEFAULT_COMMAND"
    # fzf ships its own bash bindings (Ctrl-R history, Ctrl-T files, Alt-C cd).
    for f in /usr/share/fzf/key-bindings.bash \
             /usr/share/doc/fzf/examples/key-bindings.bash \
             "$AIRGAP_ROOT/config/fzf/key-bindings.bash"; do
        [ -r "$f" ] && { . "$f"; break; }
    done
fi

# --- zoxide / starship ----------------------------------------------------
command -v zoxide   >/dev/null 2>&1 && eval "$(zoxide init bash)"
command -v starship >/dev/null 2>&1 && eval "$(starship init bash)"
