export PATH="$HOME/.local/bin:$PATH"
export EDITOR=nvim
export NVIM_APPNAME=nvim-cachyos

alias vi=nvim
autoload -Uz compinit && compinit
if (( $+commands[oh-my-posh] )); then
    eval "$(oh-my-posh init zsh --config "${XDG_CONFIG_HOME:-$HOME/.config}/zsh/pure-modified.omp.json")"
fi
