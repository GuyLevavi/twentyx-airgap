# ~/.bashrc -- seeded once from the repo; yours after that.
# Runtime environment a pod generates at start (HOME relocation, XDG, caches,
# injected CA/pip). Absent on WSL, where the system sets these.
[ -r /opt/twentyx/etc/env.bash ] && . /opt/twentyx/etc/env.bash

HISTFILESIZE=100000
HISTSIZE=10000
shopt -s histappend

alias -- la='eza -a'
alias -- ll='eza -l'
alias -- lla='eza -la'
alias -- ls='eza --icons --group-directories-first'
alias -- lt='eza --tree'
alias -- cat='bat -p'
alias -- tldr='tldr --quiet'

# Login shell stays bash (scripts, code-server tasks, POSIX semantics);
# interactive sessions exec into fish. BASH_EXECS_FISH survives the exec, so a
# deliberate nested `bash` from inside fish does not bounce straight back.
if [[ $- == *i* && -z "${BASH_EXECS_FISH:-}" && -z "${IN_NIX_SHELL:-}" ]]; then
    export BASH_EXECS_FISH=1
    exec /opt/twentyx/profile/bin/fish
fi
