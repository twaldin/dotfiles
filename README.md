# Personal Dotfiles

My personal configuration files for zsh and neovim.

## Structure

- `zsh/zshrc` - Zsh configuration
- `nvim/` - LazyVim neovim configuration

## Usage

### Local
Symlink files to home directory:
```bash
ln -sf ~/.dotfiles/zsh/zshrc ~/.zshrc
ln -sf ~/.dotfiles/nvim ~/.config/nvim
```

### Container
Files are automatically symlinked during container build.