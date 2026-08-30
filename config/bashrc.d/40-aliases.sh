# Aliases. Every one degrades gracefully if its tool was not vendored.

command -v eza >/dev/null 2>&1 && {
    alias ls='eza --group-directories-first'
    alias ll='eza -l --git --group-directories-first'
    alias la='eza -la --git --group-directories-first'
    alias lt='eza --tree --level=2'
} || {
    alias ll='ls -lh'
    alias la='ls -lah'
}

command -v bat >/dev/null 2>&1 && alias cat='bat --paging=never --style=plain'
command -v rg  >/dev/null 2>&1 && alias grep='rg'
command -v nvim >/dev/null 2>&1 && { alias vim='nvim'; alias v='nvim'; }

alias g='git'
alias gs='git status -sb'
alias gd='git diff'
alias lg='lazygit'
alias ..='cd ..'
alias ...='cd ../..'

# pi through the launcher, so LD_PRELOAD is handled. Calling `pi` directly
# skips the wrapper and may segfault under the RunAI preloaders.
alias pi='airgap pi'

# GPU
alias smi='nvidia-smi'
alias watchgpu='nvidia-smi --query-gpu=index,name,utilization.gpu,memory.used,memory.total --format=csv -l 2'
