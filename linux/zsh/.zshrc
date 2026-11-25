export PATH="$HOME/.local/bin:$PATH"
export EDITOR=nvim
export NVIM_APPNAME=nvim-cachyos

HISTFILE="$ZDOTDIR/.zsh_history"
HISTSIZE=10000
SAVEHIST=10000
setopt append_history

alias vi=nvim
autoload -Uz compinit && compinit
bindkey -e
if (( $+commands[oh-my-posh] )); then
    eval "$(oh-my-posh init zsh --config "$ZDOTDIR/pure-modified.omp.json")"
fi

if [[ -n $GHOSTTY_RESOURCES_DIR ]]; then
    source "$GHOSTTY_RESOURCES_DIR/shell-integration/zsh/ghostty-integration"
fi
