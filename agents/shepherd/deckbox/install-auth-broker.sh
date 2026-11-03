#!/bin/sh
set -eu
[ "$(hostname -s)" = deckbox ] && [ "$HOME" = /home/tim ] || {
  echo 'install-auth-broker.sh: run as tim on deckbox' >&2
  exit 2
}
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
units="$HOME/.config/systemd/user"
profile="$HOME/.omp/profiles/auth-broker"
umask 077
mkdir -p "$units" "$profile/agent"
chmod 700 "$profile" "$profile/agent"
for unit in omp-auth-broker.service omp-auth-gateway.service; do
  ln -sfn "$here/$unit" "$units/$unit"
done
systemctl --user daemon-reload
systemd-analyze --user verify "$units/omp-auth-broker.service" "$units/omp-auth-gateway.service"
printf '%s\n' 'Units linked and verified. No enable or start was requested.'
