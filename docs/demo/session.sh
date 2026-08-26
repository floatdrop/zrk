#!/bin/bash
# The recorded session itself: type the command, run it, hold on the final panel.
# The URL shown is a stand-in — the run hits the local demo server.
set -eu
SHOWN='zrk -t4 -c128 -R400:3400 -d12s http://svc.local/'

pause() { perl -e 'select undef, undef, undef, $ARGV[0]' "$1"; }

printf '\033[?25l'
trap 'printf "\033[?25h"' EXIT

pause 0.25
printf '\033[38;5;245m$\033[0m '
for (( i=0; i<${#SHOWN}; i++ )); do
  printf '%s' "${SHOWN:$i:1}"
  pause 0.025
done
pause 0.45
printf '\n'

"$ZRK" -t4 -c128 -R400:3400 -d12s --refresh 100ms "$TARGET"
pause 1.5
