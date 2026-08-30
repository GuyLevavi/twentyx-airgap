# PATH and core environment. Sourced by the generated ~/.bashrc.

case ":$PATH:" in
  *":$AIRGAP_ROOT/bin:"*) ;;
  *) export PATH="$AIRGAP_ROOT/bin:/usr/local/bin:$PATH" ;;
esac

# Our newer code-server shadows the base image's older one. Reverting is just
# removing this, with the base image left untouched.
if [ -x "$AIRGAP_ROOT/code-server/bin/code-server" ]; then
    export PATH="$AIRGAP_ROOT/code-server/bin:$PATH"
fi

# OpenShift gives us uid 10001 / gid 0 with no /etc/passwd entry, and the base
# image may not permit adding one. Most tools consult these variables before
# falling back to a passwd lookup, so setting them avoids the lookup entirely.
: "${USER:=${USERNAME:-jensen}}"; export USER
: "${LOGNAME:=$USER}";           export LOGNAME
export HOME="${HOME:-/home/jensen}"

export EDITOR="${EDITOR:-nvim}"
export VISUAL="$EDITOR"
export PAGER="${PAGER:-less}"
export LESS="-FRX"

# XDG, pointed at the persistent PVC rather than the ephemeral $HOME.
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_DATA_HOME="$HOME/.local/share"
export XDG_CACHE_HOME="$HOME/.cache"

# Keep language toolchains from writing into the ephemeral home.
export PIP_CACHE_DIR="$XDG_CACHE_HOME/pip"
export NPM_CONFIG_CACHE="$XDG_CACHE_HOME/npm"
export TORCH_HOME="${TORCH_HOME:-$AIRGAP_STATE/share/torch}"
export HF_HOME="${HF_HOME:-$AIRGAP_STATE/share/huggingface}"

# Fail fast instead of hanging for 30s on a DNS lookup that cannot succeed.
export PIP_DEFAULT_TIMEOUT=10
export GIT_TERMINAL_PROMPT=0
