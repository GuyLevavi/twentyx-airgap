

# Commands that should be applied only for interactive shells.
[[ $- == *i* ]] || return

HISTFILESIZE=100000
HISTSIZE=10000

shopt -s histappend
shopt -s extglob
shopt -s globstar
shopt -s checkjobs

alias -- la='eza -a'
alias -- ll='eza -l'
alias -- lla='eza -la'
alias -- ls=eza
alias -- lt='eza --tree'

if [[ ! -v BASH_COMPLETION_VERSINFO ]]; then
  . "/nix/store/8z4ss3bnpvgg3rvkcyj4v4ss1p2cy8jg-bash-completion-2.18.0/etc/profile.d/bash_completion.sh"
fi

# Before the exec, so a bash-only session (scripts, code-server tasks)
# gets the corrected values too.
# __eh must be a variable, and quoted at the point of use: the slashes
# in an inline path pattern terminate it early, and the substitution
# then silently produces garbage rather than failing.
__eh="/home/jensen"
if [ "$HOME" != "$__eh" ]; then
  for __v in $(compgen -e); do
    case "${!__v}" in
      *"$__eh"*) export "$__v=${!__v//"$__eh"/$HOME}" ;;
    esac
  done
fi
unset __eh __v

# Thread pools sized to the pod's CPU quota, and an early warning before
# the pids cgroup runs out -- after that, this shell would not start.
# See libexec/airgap-limits.sh and `airgap pids`.
if [ -r /opt/twentyx/libexec/airgap-limits.sh ]; then
  . /opt/twentyx/libexec/airgap-limits.sh
  if [[ $- == *i* ]] && airgap_pids_usage \
      && (( AIRGAP_PIDS_CUR * 4 >= AIRGAP_PIDS_MAX * 3 )); then
    printf '\033[33mwarn:\033[0m %s of %s PIDs in use; see: airgap pids\n' \
      "$AIRGAP_PIDS_CUR" "$AIRGAP_PIDS_MAX" >&2
  fi
fi

if [[ $- == *i* && -z "${BASH_EXECS_FISH:-}" && -z "${IN_NIX_SHELL:-}" ]]; then
  export BASH_EXECS_FISH=1
  exec /nix/store/wjy2jwb0m54cqdmjqpsps5hpkdwp90cs-fish-4.8.1/bin/fish
fi

function lg() {
    export LAZYGIT_NEW_DIR_FILE=~/.lazygit/newdir
    command lazygit "$@"
    if [ -f $LAZYGIT_NEW_DIR_FILE ]; then
      cd "$(cat $LAZYGIT_NEW_DIR_FILE)"
      rm -f $LAZYGIT_NEW_DIR_FILE > /dev/null
    fi
}

eval "$(/nix/store/q5s6iq0gqysmb2r76mkyxixkd2a9yk3p-direnv-2.37.1/bin/direnv hook bash)"

