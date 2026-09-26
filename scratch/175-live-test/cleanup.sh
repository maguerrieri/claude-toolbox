#!/bin/bash
# Delete *.tmp files older than N days from a directory.
# Usage: cleanup.sh <dir> <days>
usage() { echo "usage: cleanup.sh <dir> <days>" >&2; exit 2; }
[ "$#" -eq 2 ] || usage
dir=$1
days=$2
[ -d "$dir" ] || usage
case $days in '' | *[!0-9]*) usage ;; esac
case $dir in -*) dir=./$dir ;; esac
find "$dir" -maxdepth 1 -type f -name '*.tmp' -mtime +"$days" \
  -delete -exec printf 'removed %s\n' {} +
