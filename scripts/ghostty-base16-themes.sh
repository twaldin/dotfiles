#!/usr/bin/env bash
# Lists only Ghostty themes that have a matching base16-nvim colorscheme.
# Matching means nvim's auto-detection resolves correctly — no fallback.
#
# Usage:
#   ghostty-base16-themes          # list all matches
#   ghostty-base16-themes gruvbox  # case-insensitive filter

NVIM_COLORS="${HOME}/.local/share/nvim/site/pack/core/opt/base16-nvim/colors"

if [[ ! -d "$NVIM_COLORS" ]]; then
  echo "base16-nvim not found: $NVIM_COLORS" >&2
  exit 1
fi

PYFILE=$(mktemp /tmp/ghostty-base16-XXXXXX.py)
trap 'rm -f "$PYFILE"' EXIT

cat > "$PYFILE" << 'PYEOF'
import sys, os, re

def norm(s):
    return re.sub(r'[\s\-_]', '', s.lower())

colors_dir = sys.argv[1]
query      = sys.argv[2].lower() if len(sys.argv) > 2 else ''

nvim = {}
for f in os.listdir(colors_dir):
    if f.startswith('base16-') and f.endswith('.vim'):
        name = f[len('base16-'):-len('.vim')]
        nvim[norm(name)] = 'base16-' + name

for line in sys.stdin:
    theme = line.strip()
    match = nvim.get(norm(theme))
    if match and (not query or query in theme.lower() or query in match.lower()):
        print(f'{theme:<42}  ->  {match}')
PYEOF

ghostty +list-themes 2>/dev/null \
  | sed 's/ (.*//' \
  | python3 "$PYFILE" "$NVIM_COLORS" "${1:-}"
