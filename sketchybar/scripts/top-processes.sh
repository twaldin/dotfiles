#!/bin/sh
set -eu
/bin/ps -Ao '%cpu=,comm=' -r 2>/dev/null | /usr/bin/awk 'NF { cpu=$1; $1=""; sub(/^ +/, ""); name=$0; sub(/^.*\//, "", name); printf "%5.1f%%   %s\n", cpu, name; count++; if (count == 4) exit }'
