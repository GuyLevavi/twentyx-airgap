# History that survives the pod.
#
# $HOME is ephemeral, so the default ~/.bash_history is lost on every restart.
# Keep it on the PVC instead. Per-directory history (the trick of writing into
# the project dir) is also supported: set AIRGAP_HISTORY_PER_DIR=1.

if [ "${AIRGAP_HISTORY_PER_DIR:-0}" = "1" ] && [ -d .git ]; then
    export HISTFILE="$PWD/.git/.bash_history"
else
    export HISTFILE="${AIRGAP_STATE:-$HOME}/share/bash_history"
fi
mkdir -p "$(dirname "$HISTFILE")" 2>/dev/null || true

export HISTSIZE=100000
export HISTFILESIZE=200000
export HISTCONTROL=ignoreboth:erasedups
export HISTIGNORE="ls:ll:cd:pwd:exit:clear:history"
export HISTTIMEFORMAT="%F %T  "

shopt -s histappend cmdhist
shopt -s checkwinsize
shopt -s globstar 2>/dev/null || true
shopt -s autocd 2>/dev/null || true

# Flush after every command so a killed pod does not take the session with it.
PROMPT_COMMAND="history -a;${PROMPT_COMMAND:-}"
