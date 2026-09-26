#!/bin/bash
# Delete *.tmp files older than N days from a directory.
# Usage: cleanup.sh <dir> <days>
dir=$1
days=$2
for f in $(ls $dir/*.tmp); do
  if [ $(find $f -mtime +$days) ]; then
    rm $f
    echo "removed $f"
  fi
done
