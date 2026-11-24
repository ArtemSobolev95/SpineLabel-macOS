#!/bin/bash
# Builds both packages (IsiX and Horos; each runs on Apple silicon and Intel) into ./dist.
cd "$(dirname "$0")"
TARGET=isix ./package.sh && TARGET=horos ./package.sh
status=$?
echo
if [ $status -eq 0 ]; then echo "Done:"; ls -1 dist/*.zip; open dist; else echo "Build failed (see above)."; fi
read -n 1 -s -r -p "Press any key to close."
