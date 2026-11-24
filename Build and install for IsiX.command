#!/bin/bash
# Builds SpineLabel and installs it into IsiX (restart IsiX afterwards).
cd "$(dirname "$0")"
./build.sh install
status=$?
echo
if [ $status -eq 0 ]; then echo "Done. Quit and reopen IsiX to load SpineLabel."; else echo "Build failed (see above)."; fi
read -n 1 -s -r -p "Press any key to close."
